<#
.SYNOPSIS
    Exports Intune App Inventory to Azure Log Analytics using Blob Storage.

.DESCRIPTION
    Azure Automation Runbook (PowerShell 7.2+).
    - Authentication: System Assigned Managed Identity via Get-AzAccessToken
    - Data source:    Intune Export API (Graph beta, reportName: AppInvRawData)
    - Storage:        ZIP is streamed directly to Azure Blob Storage,
                      bypassing the 1 GB local disk limit of the Automation sandbox.
                      CSV is read as a seekable stream from Blob — never touches local disk.
    - Destination:    Log Analytics custom table via Logs Ingestion API (DCR v2)

    Use this version for large tenants where the ZIP file may exceed ~800 MB.
    For smaller tenants use Export-IntuneApps-ToLA.ps1 (simpler, no Blob required).

.REQUIREMENTS
    Managed Identity must have:
      a) Graph API app roles (Application):
           DeviceManagementManagedDevices.Read.All
           DeviceManagementApps.Read.All
      b) IAM role on DCR:              Monitoring Metrics Publisher
      c) IAM role on Blob container:   Storage Blob Data Contributor

    Log Analytics custom table IntuneDetectedApps_CL must exist
    with a matching DCR (created automatically via portal table wizard).

    Az.Storage module must be available in the Automation Account.

.NOTES
    Version: 1.1
#>

#region ── CONFIGURATION ────────────────────────────────────────────────────────

# --- Logs Ingestion API (DCR) ---
# Azure Monitor → Data Collection Rules → your DCR → Overview → JSON View
$DcrImmutableId  = "dcr-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"   # "immutableId" field
$DcrIngestionUri = "https://xxxx.eastus-1.ingest.monitor.azure.com"  # "logsIngestion" field from DCE
$StreamName      = "Custom-IntuneDetectedApps_CL"           # Custom- + table name without _CL

# --- Azure Blob Storage (temporary ZIP staging) ---
# The container only holds the ZIP during processing; it is deleted after ingestion.
$StorageAccountName = "yourstorageaccount"
$ContainerName      = "intune-export-temp"
$BlobName           = "AppInvRawData-latest.zip"

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

Write-Output "=== Intune App Inventory → Log Analytics (Blob Storage) ==="
Write-Output "Start: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC"

# ── 1. Authentication via Managed Identity ────────────────────────────────────
Write-Output "Connecting Managed Identity..."
Connect-AzAccount -Identity | Out-Null

Write-Output "Acquiring tokens..."
$GraphToken    = (Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com/").Token
$MonitorToken  = (Get-AzAccessToken -ResourceUrl "https://monitor.azure.com/").Token
$StorageToken  = (Get-AzAccessToken -ResourceUrl "https://storage.azure.com/").Token
Write-Output "Tokens acquired."

# ── Retry helper — respects Retry-After, handles 429 & 503 ──────────────────
function Invoke-WithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxRetries = 5
    )
    $attempt = 0
    while ($true) {
        try {
            return & $ScriptBlock
        } catch {
            $statusCode = $_.Exception.Response?.StatusCode.value__
            if ($statusCode -in 429, 503 -and $attempt -lt $MaxRetries) {
                $retryAfter = 30
                $raHeader = $_.Exception.Response?.Headers?['Retry-After']
                if ($raHeader) { $retryAfter = [int]$raHeader }
                $attempt++
                Write-Warning "HTTP $statusCode — throttled. Retry $attempt/$MaxRetries in $retryAfter s..."
                Start-Sleep -Seconds $retryAfter
            } else {
                throw
            }
        }
    }
}

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
    $exportJob = Invoke-WithRetry {
        Invoke-RestMethod `
            -Uri     "$GraphBaseUrl/deviceManagement/reports/exportJobs" `
            -Method  POST `
            -Headers $GraphHeaders `
            -Body    $exportBody
    }
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
    $jobStatus = Invoke-WithRetry {
        Invoke-RestMethod `
            -Uri     "$GraphBaseUrl/deviceManagement/reports/exportJobs/$jobId" `
            -Method  GET `
            -Headers $GraphHeaders
    }
    Write-Output "  [$elapsed s] Status: $($jobStatus.status)"
    switch ($jobStatus.status) {
        "completed" { $downloadUrl = $jobStatus.url; break }
        "failed"    { throw "Export Job failed. ID: $jobId" }
    }
} while (-not $downloadUrl -and $elapsed -lt $MaxWaitSeconds)

if (-not $downloadUrl) { throw "Timeout: Export Job did not complete within $MaxWaitSeconds s." }

# ── 4. Stream ZIP from Intune directly to Blob Storage ───────────────────────
# No local disk used — ZIP is piped from Intune SAS URL straight to Blob.
# Blob Storage has no practical size limit, unlike the 1 GB sandbox disk.
Write-Output "Uploading ZIP to Blob Storage..."
Add-Type -AssemblyName System.IO.Compression.FileSystem

$BlobUri     = "https://$StorageAccountName.blob.core.windows.net/$ContainerName/$BlobName"
$BlobHeaders = @{
    "Authorization"  = "Bearer $StorageToken"
    "x-ms-version"   = "2020-04-08"
    "x-ms-blob-type" = "BlockBlob"
}

# Download ZIP bytes from Intune SAS URL and upload to Blob in one operation
$httpClient   = [System.Net.Http.HttpClient]::new()
$zipBytes     = $httpClient.GetByteArrayAsync($downloadUrl).Result
$httpClient.Dispose()

$uploadResp = Invoke-WebRequest `
    -Uri         $BlobUri `
    -Method      PUT `
    -Headers     $BlobHeaders `
    -Body        $zipBytes `
    -ContentType "application/octet-stream" `
    -UseBasicParsing

if ($uploadResp.StatusCode -notin 200, 201) {
    throw "Blob upload failed: HTTP $($uploadResp.StatusCode)"
}
Write-Output "ZIP uploaded to Blob: $BlobUri"
$zipBytes = $null
[System.GC]::Collect()

# ── 5. Open ZIP from Blob as seekable stream ──────────────────────────────────
# Blob stream is seekable — required by ZipArchive to navigate the ZIP structure.
# CSV entry is opened as a stream inside the ZIP — no extraction to disk.
Write-Output "Opening ZIP stream from Blob..."

$storageCtx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount
$blobRef    = Get-AzStorageBlob -Container $ContainerName -Blob $BlobName -Context $storageCtx
$blobStream = $blobRef.ICloudBlob.OpenRead()

$zipArchive = [System.IO.Compression.ZipArchive]::new($blobStream, [System.IO.Compression.ZipArchiveMode]::Read)
$csvEntry   = $zipArchive.Entries | Where-Object { $_.Name -like "*.csv" } | Select-Object -First 1
if (-not $csvEntry) {
    $zipArchive.Dispose(); $blobStream.Dispose()
    throw "CSV file not found in ZIP archive."
}

Write-Output "CSV: $($csvEntry.Name) ($([math]::Round($csvEntry.Length / 1MB, 1)) MB uncompressed)"

$zipStream = $csvEntry.Open()
$reader    = [System.IO.StreamReader]::new($zipStream, [System.Text.Encoding]::UTF8)
$header    = $reader.ReadLine() -split ','
$colIndex  = @{}
for ($c = 0; $c -lt $header.Count; $c++) {
    $colIndex[$header[$c].Trim('"')] = $c
}

# ── 6. Stream records to Log Analytics ───────────────────────────────────────
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
    $resp   = Invoke-WithRetry {
        Invoke-WebRequest `
            -Uri $ingestUri -Method POST -Headers $ingestHeaders `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) `
            -UseBasicParsing
    }
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
        TimeGenerated           = $now
        ApplicationName         = Get-ColValue $cols "ApplicationName"
        ApplicationPublisher    = Get-ColValue $cols "ApplicationPublisher"
        ApplicationShortVersion = Get-ColValue $cols "ApplicationShortVersion"
        ApplicationVersion      = Get-ColValue $cols "ApplicationVersion"
        DeviceName              = Get-ColValue $cols "DeviceName"
        EmailAddress            = Get-ColValue $cols "EmailAddress"
        OSDescription           = Get-ColValue $cols "OSDescription"
        OSVersion               = Get-ColValue $cols "OSVersion"
        Platform                = Get-ColValue $cols "Platform"
        UserName                = Get-ColValue $cols "UserName"
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

# ── 7. Cleanup — delete temporary Blob ───────────────────────────────────────
$reader.Dispose()
$zipArchive.Dispose()
$blobStream.Dispose()

Write-Output "Deleting temporary Blob..."
Remove-AzStorageBlob -Container $ContainerName -Blob $BlobName -Context $storageCtx -Force

Write-Output ""
Write-Output "Done! Total records sent: $totalSent → IntuneDetectedApps_CL"
Write-Output "End: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC"

#endregion
