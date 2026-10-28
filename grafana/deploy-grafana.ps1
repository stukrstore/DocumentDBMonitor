[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$GrafanaResourceGroup,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$GrafanaName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AmwResourceGroup,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AmwName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ClusterResourceGroup,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ClusterName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ClusterRegion,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][guid]$ClusterSubscriptionId,
    [string]$DataSourceName = 'DocDB Monitor AMW'
)
$ErrorActionPreference = 'Stop'

# Grafana and AMW use the active subscription; the cluster may be in another.
$AzExe = (Get-Command az -CommandType Application | Select-Object -First 1).Source
function Az {
    $PSNativeCommandUseErrorActionPreference = $false
    try { $out = & $AzExe @args --only-show-errors 2>$null; $exitCode = $LASTEXITCODE }
    catch { throw 'Azure CLI invocation failed; details suppressed.' }
    if ($exitCode -ne 0) { throw "Azure CLI failed (exit code $exitCode); details suppressed." }
    $out
}

$template = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'docdb-monitor-dashboard.json') -Raw
$values = @{
    '<SUBSCRIPTION_ID>' = $ClusterSubscriptionId.ToString()
    '<CLUSTER_RESOURCE_GROUP>' = $ClusterResourceGroup
    '<CLUSTER_NAME>' = $ClusterName
    '<AZURE_REGION>' = $ClusterRegion
}
foreach ($key in $values.Keys) {
    if (-not $template.Contains($key)) { throw "Dashboard placeholder $key not found." }
    # Encode as JSON string content to preserve validity, including panel titles.
    $encoded = ConvertTo-Json -InputObject ([string]$values[$key]) -Compress
    $template = $template.Replace($key, $encoded.Substring(1, $encoded.Length - 2))
}
if ($template -match '<(?:SUBSCRIPTION_ID|CLUSTER_RESOURCE_GROUP|CLUSTER_NAME|AZURE_REGION)>') {
    throw 'Dashboard contains unresolved placeholders.'
}
$null = $template | ConvertFrom-Json

$grafana = Az grafana show -g $GrafanaResourceGroup -n $GrafanaName -o json | ConvertFrom-Json
$principal = $grafana.identity.principalId
if (-not $principal) { throw 'Grafana must have a system-assigned managed identity.' }
$amw = Az monitor account show -g $AmwResourceGroup -n $AmwName -o json | ConvertFrom-Json

Write-Host '== Grafana MI role assignments'
foreach ($a in @(@{ role = 'Monitoring Data Reader'; scope = $amw.id },
                 @{ role = 'Monitoring Reader'; scope = "/subscriptions/$ClusterSubscriptionId/resourceGroups/$ClusterResourceGroup" })) {
    $has = @(Az role assignment list --assignee $principal --role $a.role --scope $a.scope -o json | ConvertFrom-Json).Count
    if ($has -eq 0) {
        Az role assignment create --assignee-object-id $principal --assignee-principal-type ServicePrincipal --role $a.role --scope $a.scope -o none
        Write-Host "  + $($a.role) @ $($a.scope)"
    } else { Write-Host "  = $($a.role) (exists)" }
}

Write-Host '== Prometheus data source and dashboard'
$ds = @{
    name = $DataSourceName; uid = 'docdb-amw'; type = 'grafana-azureprometheus-datasource'; access = 'proxy'
    url = $amw.metrics.prometheusQueryEndpoint
    jsonData = @{ httpMethod = 'POST'; timeInterval = '5s'; azureCredentials = @{ authType = 'msi' } }
} | ConvertTo-Json -Depth 6 -Compress
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    $defFile = Join-Path $tempDir 'datasource.json'
    $dashboardFile = Join-Path $tempDir 'dashboard.json'
    [System.IO.File]::WriteAllText($defFile, $ds, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($dashboardFile, $template, [System.Text.UTF8Encoding]::new($false))
    $exists = @(Az grafana data-source list -g $GrafanaResourceGroup -n $GrafanaName -o json | ConvertFrom-Json | Where-Object uid -eq 'docdb-amw').Count
    if ($exists -eq 0) { Az grafana data-source create -g $GrafanaResourceGroup -n $GrafanaName --definition "@$defFile" -o none }
    else { Az grafana data-source update -g $GrafanaResourceGroup -n $GrafanaName --data-source docdb-amw --definition "@$defFile" -o none }
    Az grafana dashboard update -g $GrafanaResourceGroup -n $GrafanaName --overwrite true --definition "@$dashboardFile" -o none
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "URL: $($grafana.properties.endpoint)/d/docdb-monitor"

