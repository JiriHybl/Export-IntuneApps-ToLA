<#
.SYNOPSIS
    Exports Intune App Inventory to Azure Log Analytics.

.DESCRIPTION
    Azure Automation Runbook (PowerShell 7.2+).
    - Authentication: System Assigned Managed Identity via Get-AzAccessToken
    - Data source:    Intune Export API (Graph beta, reportName: AppInvRawData)
    - Storage:        ZIP downloaded to Automation sandbox local disk (1 GB limit)
                      CSV is read directly from ZIP stream — never extracted to disk
    - Destination:    Log Analytics custom table via Logs Ingestion API (DCR v2)

    Use this version for small to medium tenants where the ZIP file
    is unlikely to exceed ~800 MB (roughly 8M+ app records).
    For larger tenants use Export-IntuneApps-ToLA-BlobStorage.ps1.

.REQUIREMENTS
    Managed Identity must have:
      a) Graph API app roles (Application):
           DeviceManagementManagedDevices.Read.All
           DeviceManagementApps.Read.All
      b) IAM role on DCR: Monitoring Metrics Publisher

    Log Analytics custom table IntuneDetectedApps_CL must exist
    with a matching DCR (created automatically via portal table wizard).

.NOTES
    Version: 1.0
#>

#region ── CONFIGURATION ────────────────────────────────────────────────────────

# --- Logs Ingestion API (DCR) ---
# Azure Monitor → Data Collection Rules → your DCR → Overview → JSON View
$DcrImmutableId  = "dcr-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"   # "immutableId" field
$DcrIngestionUri = "https://xxxx.eastus-1.ingest.monitor.azure.com"  # "logsIngestion" field from DCE
$StreamName      = "Custom-IntuneDetectedApps_CL"           # Custom- + table name without _CL

# --- Intune Export API ---
$GraphBaseUrl    = "https://graph.microsoft.com/beta"
$ReportName      = "AppInvRawData"
$ExportFormat    = "csv"
$MaxWaitSeconds  = 300
$PollIntervalSec = 10

# --- Columns to export (reduces payload size and LA ingestion cost) ---
$SelectColumns = @(
    "ApplicationName",
    "ApplicationPublisher",
    "ApplicationShortVersion",
    "ApplicationVersion",
    "DeviceName",
    "EmailAddress",
    "OSDescription",
    "OSVersion",
    "Platform",
    "UserName"
)

# --- Batching (Logs Ingestion API limit: 1 MB per request) ---
$BatchSize = 1000

#endregion

#region ── MAIN ─────────────────────────────────────────────────────────────────

Write-Output "=== Intune App Inventory → Log Analytics (local disk) ==="
Write-Output "Start: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC"

# ── 1. Authentication via Managed Identity ────────────────────────────────────
Write-Output "Connecting Managed Identity..."
Connect-AzAccount -Identity | Out-Null

Write-Output "Acquiring tokens..."
$GraphToken   = (Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com/").Token
$MonitorToken = (Get-AzAccessToken -ResourceUrl "https://monitor.azure.com/").Token
Write-Output "Tokens acquired."

$GraphHeaders = @{
    "Authorization" = "Bearer $GraphToken"
    "Content-Type"  = "application/json"
}

# ── 2. Submit Intune Export Job ───────────────────────────────────────────────
Write-Output "Submitting Export Job: $ReportName..."

$exportBody = @{
    reportName = $ReportName
    format     = $ExportFormat
    select     = $SelectColumns
} | ConvertTo-Json

try {
    $exportJob = Invoke-RestMethod `
        -Uri     "$GraphBaseUrl/deviceManagement/reports/exportJobs" `
        -Method  POST `
        -Headers $GraphHeaders `
        -Body    $exportBody
} catch {
    Write-Output "HTTP $($_.Exception.Response.StatusCode.value__) - Graph error:"
    Write-Output $_.ErrorDetails.Message
    throw "Export Job POST failed."
}

$jobId = $exportJob.id
Write-Output "Job ID: $jobId"

# ── 3. Poll for job completion ────────────────────────────────────────────────
Write-Output "Waiting for job completion..."
$elapsed     = 0
$downloadUrl = $null

do {
    Start-Sleep -Seconds $PollIntervalSec
    $elapsed += $PollIntervalSec
    $jobStatus = Invoke-RestMethod `
        -Uri     "$GraphBaseUrl/deviceManagement/reports/exportJobs/$jobId" `
        -Method  GET `
        -Headers $GraphHeaders
    Write-Output "  [$elapsed s] Status: $($jobStatus.status)"
    switch ($jobStatus.status) {
        "completed" { $downloadUrl = $jobStatus.url; break }
        "failed"    { throw "Export Job failed. ID: $jobId" }
    }
} while (-not $downloadUrl -and $elapsed -lt $MaxWaitSeconds)

if (-not $downloadUrl) { throw "Timeout: Export Job did not complete within $MaxWaitSeconds s." }

# ── 4. Download ZIP to local disk + open CSV as stream ───────────────────────
# ZIP lands on local sandbox disk (~60% of CSV size due to compression).
# CSV is never extracted to disk — read directly from ZIP stream.
Write-Output "Downloading ZIP..."
Add-Type -AssemblyName System.IO.Compression.FileSystem

$tempZip = [System.IO.Path]::GetTempFileName() + ".zip"
Invoke-WebRequest -Uri $downloadUrl -OutFile $tempZip -UseBasicParsing

$zipArchive = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
$csvEntry   = $zipArchive.Entries | Where-Object { $_.Name -like "*.csv" } | Select-Object -First 1
if (-not $csvEntry) {
    $zipArchive.Dispose()
    Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    throw "CSV file not found in ZIP archive."
}

Write-Output "CSV: $($csvEntry.Name) ($([math]::Round($csvEntry.Length / 1MB, 1)) MB uncompressed)"

# Open CSV entry as a stream — no disk extraction needed
$zipStream = $csvEntry.Open()
$reader    = [System.IO.StreamReader]::new($zipStream, [System.Text.Encoding]::UTF8)
$header    = $reader.ReadLine() -split ','
$colIndex  = @{}
for ($c = 0; $c -lt $header.Count; $c++) {
    $colIndex[$header[$c].Trim('"')] = $c
}

# ── 5. Stream records to Log Analytics ───────────────────────────────────────
$now       = (Get-Date).ToUniversalTime().ToString("o")
$totalSent = 0
$batchNum  = 0

$ingestUri = "$DcrIngestionUri/dataCollectionRules/$DcrImmutableId/streams/$StreamName" +
             "?api-version=2023-01-01"

$ingestHeaders = @{
    "Authorization" = "Bearer $MonitorToken"
    "Content-Type"  = "application/json"
}

function Get-ColValue($cols, $name) {
    $idx = $colIndex[$name]
    if ($null -eq $idx) { return "" }
    return $cols[$idx].Trim('"')
}

$batch = [System.Collections.Generic.List[object]]::new()

function Send-Batch {
    param($b, $num)
    if ($b.Count -eq 0) { return }
    $json   = $b | ConvertTo-Json -Depth 2 -Compress
    $sizeKB = [System.Text.Encoding]::UTF8.GetByteCount($json) / 1KB
    $resp   = Invoke-WebRequest `
                  -Uri $ingestUri -Method POST -Headers $ingestHeaders `
                  -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) `
                  -UseBasicParsing
    Write-Output "  Batch $num → HTTP $($resp.StatusCode) | $($b.Count) records | $([math]::Round($sizeKB)) KB"
    if ($resp.StatusCode -notin 200, 204) {
        Write-Warning "Unexpected HTTP $($resp.StatusCode): $($resp.Content)"
    }
}

Write-Output "Sending in batches of $BatchSize records (streaming)..."

while (-not $reader.EndOfStream) {
    $line = $reader.ReadLine()
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    # Split CSV line respecting quoted fields
    $cols = $line -split ',(?=(?:[^"]*"[^"]*")*[^"]*$)'

    $batch.Add([PSCustomObject]@{
        TimeGenerated          = $now
        ApplicationName        = Get-ColValue $cols "ApplicationName"
        ApplicationPublisher   = Get-ColValue $cols "ApplicationPublisher"
        ApplicationShortVersion = Get-ColValue $cols "ApplicationShortVersion"
        ApplicationVersion     = Get-ColValue $cols "ApplicationVersion"
        DeviceName             = Get-ColValue $cols "DeviceName"
        EmailAddress           = Get-ColValue $cols "EmailAddress"
        OSDescription          = Get-ColValue $cols "OSDescription"
        OSVersion              = Get-ColValue $cols "OSVersion"
        Platform               = Get-ColValue $cols "Platform"
        UserName               = Get-ColValue $cols "UserName"
    })

    if ($batch.Count -ge $BatchSize) {
        $batchNum++
        $totalSent += $batch.Count
        Send-Batch $batch $batchNum
        $batch.Clear()
        [System.GC]::Collect()   # release RAM after each batch
    }
}

# Send remaining records
if ($batch.Count -gt 0) {
    $batchNum++
    $totalSent += $batch.Count
    Send-Batch $batch $batchNum
}

# ── 6. Cleanup ────────────────────────────────────────────────────────────────
$reader.Dispose()
$zipArchive.Dispose()
Remove-Item $tempZip -Force -ErrorAction SilentlyContinue

Write-Output ""
Write-Output "Done! Total records sent: $totalSent → IntuneDetectedApps_CL"
Write-Output "End: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC"

#endregion
