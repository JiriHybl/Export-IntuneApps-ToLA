## 5. Power BI

1. **Log Analytics Workspace → Logs** — paste the KQL query from `IntuneDetectedApps-PowerBI.kql` (Main query section) and run it to verify results
2. **Export → Export to Power BI (M query)** — LA will download a `.txt` file containing the M query
3. **Power BI Desktop → Home → Transform data → Advanced Editor** — create a blank query, open Advanced Editor and paste the M query from the `.txt` file
4. Rename the query and click **Done → Close & Apply**
5. For searchable filters use the **Text Filter** visual from the Power BI marketplace

### Recommended Visuals

**Current state page:**
- Text Filter — ApplicationName, ApplicationPublisher, DeviceName, Platform
- Matrix — ApplicationName vs. Platform
- Table — DeviceName, EmailAddress, ApplicationName, ApplicationVersion

**Historical trend page:**
- Slicer on TimeGenerated (style: Between)
- Line chart — unique app/device count over time
- Use queries from the HISTORICAL REPORT section in the KQL file