# Intune App Inventory → Log Analytics → Power BI

Automatizovaný pipeline pro export inventury aplikací z Microsoft Intune do Azure Log Analytics a vizualizaci v Power BI.

## Obsah repozitáře

```
├── Export-IntuneApps-ToLA.ps1                # Runbook bez Blob Storage (malé a střední tenanty)
├── Export-IntuneApps-ToLA-BlobStorage.ps1    # Runbook s Blob Storage (velké tenanty)
├── IntuneDetectedApps-PowerBI.kql            # KQL dotazy pro Power BI
├── la-table-schema-sample.json               # Sample JSON pro vytvoření LA tabulky
├── README.md                                 # Tento soubor (česky)
└── README.en.md                              # English version
```

## Architektura

```
Intune (Graph API — AppInvRawData)
    ↓  Export Job → ZIP/CSV
Azure Automation Runbook (PowerShell 7.2+, System Assigned MI)
    ↓  [volitelně přes Azure Blob Storage]
Logs Ingestion API (DCR v2)
    ↓
Log Analytics → IntuneDetectedApps_CL
    ↓  KQL
Power BI Report
```

## Která verze skriptu?

| Verze | Soubor | Použij když |
|---|---|---|
| Bez Blob Storage | `Export-IntuneApps-ToLA.ps1` | ZIP export < ~800 MB (do ~8M záznamů) |
| S Blob Storage | `Export-IntuneApps-ToLA-BlobStorage.ps1` | ZIP export > ~800 MB, velké tenanty |

Obě verze jsou funkčně identické — liší se pouze způsobem uložení ZIP souboru během zpracování.

---

## 1. Log Analytics — vytvoření tabulky

1. **portal.azure.com → Log Analytics Workspace → Tables → Create → New custom log (DCR based)**
2. Název tabulky: `IntuneDetectedApps` (LA přidá `_CL` automaticky)
3. Nahraj `la-table-schema-sample.json` pro definici schématu
4. Poznamenej si po vytvoření:
   - **DCR Immutable ID** → Monitor → Data Collection Rules → tvůj DCR → Overview → JSON View → pole `immutableId`
   - **Logs Ingestion URI** → Monitor → Data Collection Endpoints → tvůj DCE → Overview → **Logs Ingestion**

---

## 2. Azure Automation — Managed Identity

### Krok 1: Zapni System Assigned Managed Identity

**Automation Account → Identity → System assigned → Status: On → Save**

Poznamenej si **Object ID**.

### Krok 2: Přiřaď Graph API oprávnění

Otevři **Cloud Shell** (portal.azure.com → ikona `>_`) → PowerShell:

```powershell
Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All"
```

Spusť tyto dva příkazy (dosaď svůj Object ID):

```powershell
$MIObjectId = "<OBJECT-ID>"
$sp = Get-MgServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"
```

```powershell
"DeviceManagementManagedDevices.Read.All","DeviceManagementApps.Read.All" | ForEach-Object { $role = $sp.AppRoles | Where-Object -Property Value -EQ $_; New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $MIObjectId -PrincipalId $MIObjectId -ResourceId $sp.Id -AppRoleId $role.Id }
```

### Krok 3: Přiřaď Monitoring Metrics Publisher na DCR

1. **Monitor → Data Collection Rules → tvůj DCR → Access Control (IAM)**
2. **Add role assignment → Monitoring Metrics Publisher**
3. Assign access to: **Managed Identity** → vyber Automation Account → Save

### Krok 4 (pouze Blob verze): Přiřaď Storage Blob Data Contributor

1. **Storage Account → tvůj container → Access Control (IAM)**
2. **Add role assignment → Storage Blob Data Contributor**
3. Assign access to: **Managed Identity** → vyber Automation Account → Save

---

## 3. Konfigurace skriptu

Uprav proměnné v sekci `CONFIGURATION`:

| Proměnná | Kde najít |
|---|---|
| `$DcrImmutableId` | DCR → Overview → JSON View → `immutableId` |
| `$DcrIngestionUri` | DCE → Overview → Logs Ingestion URI |
| `$StreamName` | `Custom-IntuneDetectedApps_CL` |
| `$StorageAccountName` | Název Storage Accountu *(pouze Blob verze)* |
| `$ContainerName` | Název containeru *(pouze Blob verze)* |

Importuj skript do Automation Account:
**Automation Account → Runbooks → Import a runbook → nahraj .ps1 → Publish**

---

## 4. Schedule

**Automation Account → Schedules → Add a schedule**
- Frekvence: **Daily**, čas: např. **02:00 UTC**

Přiřaď k Runbooku: **Runbook → Link to schedule**

---

## 5. Power BI

1. **Power BI Desktop → Načíst data → Protokoly Azure Monitoru**
2. Přihlaš se → vyber Subscription → Resource Group → LA Workspace
3. Vlož KQL dotaz z `IntuneDetectedApps-PowerBI.kql` (sekce "Main query")
4. Pro vyhledávání v filtrech použij vizuál **Text Filter** z Power BI marketplace

### Doporučené vizuály

**Aktuální stav:**
- Text Filter — ApplicationName, ApplicationPublisher, DeviceName, Platform
- Matice — ApplicationName vs. Platform
- Tabulka — DeviceName, EmailAddress, ApplicationName, ApplicationVersion

**Historický trend:**
- Slicer na TimeGenerated (styl: Mezi)
- Spojnicový graf — počet unikátních aplikací/zařízení v čase
- Použij dotazy ze sekce HISTORICAL REPORT v KQL souboru

---

## 6. Troubleshooting

| Chyba | Příčina | Řešení |
|---|---|---|
| HTTP 400 na Export Job | Špatný `reportName` | Musí být `AppInvRawData` |
| HTTP 403 na Export Job | MI nemá Graph oprávnění | Zopakuj Krok 2 |
| HTTP 403 na ingestion | MI nemá Monitoring Metrics Publisher | Zopakuj Krok 3 |
| `InvalidStream` | Špatný `$StreamName` | Musí být `Custom-IntuneDetectedApps_CL` |
| `OutOfMemoryException` | Sandbox RAM limit (400 MB) | Sniž `$BatchSize` |
| Sandbox disk full | ZIP > 1 GB | Přejdi na Blob Storage verzi |
| Data v LA prázdná | Ingestion delay | Počkej 5 minut: `IntuneDetectedApps_CL \| take 5` |
