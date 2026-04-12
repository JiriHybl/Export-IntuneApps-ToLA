# Intune App Inventory → Log Analytics → Power BI

Automated pipeline to export application inventory from Microsoft Intune into Azure Log Analytics and visualize it in Power BI.

## Repository Contents

```
├── Export-IntuneApps-ToLA.ps1                # Runbook without Blob Storage (small/medium tenants)
├── Export-IntuneApps-ToLA-BlobStorage.ps1    # Runbook with Blob Storage (large tenants)
├── IntuneDetectedApps-PowerBI.kql            # KQL queries for Power BI
├── la-table-schema-sample.json               # Sample JSON for creating the LA table
├── README.md                                 # This file
└── README.cz.md                              # Czech version
```

## Architecture

```
Intune (Graph API — AppInvRawData)
    ↓  Export Job → ZIP/CSV
Azure Automation Runbook (PowerShell 7.2+, System Assigned MI)
    ↓  [optionally via Azure Blob Storage]
Logs Ingestion API (DCR v2)
    ↓
Log Analytics → IntuneDetectedApps_CL
    ↓  KQL
Power BI Report
```

## Which Script Version?

| Version | File | Use when |
|---|---|---|
| Without Blob Storage | `Export-IntuneApps-ToLA.ps1` | ZIP export < ~800 MB (up to ~8M records) |
| With Blob Storage | `Export-IntuneApps-ToLA-BlobStorage.ps1` | ZIP export > ~800 MB, large tenants |

Both versions are functionally identical — they differ only in how the ZIP file is stored during processing.

---

## 1. Log Analytics — Create the Table

1. **portal.azure.com → Log Analytics Workspace → Tables → Create → New custom log (DCR based)**
2. Table name: `IntuneDetectedApps` (LA will append `_CL` automatically)
3. Upload `la-table-schema-sample.json` to define the schema
4. After creation, note down:
   - **DCR Immutable ID** → Monitor → Data Collection Rules → your DCR → Overview → JSON View → `immutableId` field
   - **Logs Ingestion URI** → Monitor → Data Collection Endpoints → your DCE → Overview → **Logs Ingestion**

---

## 2. Azure Automation — Managed Identity

### Step 1: Enable System Assigned Managed Identity

**Automation Account → Identity → System assigned → Status: On → Save**

Note the **Object ID**.

### Step 2: Assign Graph API Permissions

Open **Cloud Shell** (portal.azure.com → `>_` icon) → PowerShell:

```powershell
Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All"
```

Run these two commands (replace with your Object ID):

```powershell
$MIObjectId = "<OBJECT-ID>"
$sp = Get-MgServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"
```

```powershell
"DeviceManagementManagedDevices.Read.All","DeviceManagementApps.Read.All" | ForEach-Object { $role = $sp.AppRoles | Where-Object -Property Value -EQ $_; New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $MIObjectId -PrincipalId $MIObjectId -ResourceId $sp.Id -AppRoleId $role.Id }
```

### Step 3: Assign Monitoring Metrics Publisher on DCR

1. **Monitor → Data Collection Rules → your DCR → Access Control (IAM)**
2. **Add role assignment → Monitoring Metrics Publisher**
3. Assign access to: **Managed Identity** → select Automation Account → Save

### Step 4 (Blob version only): Assign Storage Blob Data Contributor

1. **Storage Account → your container → Access Control (IAM)**
2. **Add role assignment → Storage Blob Data Contributor**
3. Assign access to: **Managed Identity** → select Automation Account → Save

---

## 3. Script Configuration

Edit the variables in the `CONFIGURATION` section:

| Variable | Where to find it |
|---|---|
| `$DcrImmutableId` | DCR → Overview → JSON View → `immutableId` |
| `$DcrIngestionUri` | DCE → Overview → Logs Ingestion URI |
| `$StreamName` | `Custom-IntuneDetectedApps_CL` |
| `$StorageAccountName` | Storage Account name *(Blob version only)* |
| `$ContainerName` | Container name *(Blob version only)* |

Import the script into your Automation Account:
**Automation Account → Runbooks → Import a runbook → upload .ps1 → Publish**

---

## 4. Schedule

**Automation Account → Schedules → Add a schedule**
- Frequency: **Daily**, time: e.g. **02:00 UTC**

Link to the Runbook: **Runbook → Link to schedule**

---

## 5. Power BI

1. **Power BI Desktop → Get Data → Azure Monitor Logs**
2. Sign in → select Subscription → Resource Group → LA Workspace
3. Paste the KQL query from `IntuneDetectedApps-PowerBI.kql` (Main query section)
4. For searchable filters use the **Text Filter** visual from the Power BI marketplace

### Recommended Visuals

**Current state page:**
- Text Filter — ApplicationName, ApplicationPublisher, DeviceName, Platform
- Matrix — ApplicationName vs. Platform
- Table — DeviceName, EmailAddress, ApplicationName, ApplicationVersion

**Historical trend page:**
- Slicer on TimeGenerated (style: Between)
- Line chart — unique app/device count over time
- Use queries from the HISTORICAL REPORT section in the KQL file

---

## 6. Troubleshooting

| Error | Cause | Solution |
|---|---|---|
| HTTP 400 on Export Job | Wrong `reportName` | Must be `AppInvRawData` |
| HTTP 403 on Export Job | MI missing Graph permissions | Repeat Step 2 |
| HTTP 403 on ingestion | MI missing Monitoring Metrics Publisher | Repeat Step 3 |
| `InvalidStream` | Wrong `$StreamName` | Must be `Custom-IntuneDetectedApps_CL` |
| `OutOfMemoryException` | Sandbox RAM limit (400 MB) | Reduce `$BatchSize` |
| Sandbox disk full | ZIP > 1 GB | Switch to Blob Storage version |
| No data in LA | Ingestion delay | Wait 5 min, then: `IntuneDetectedApps_CL \| take 5` |
