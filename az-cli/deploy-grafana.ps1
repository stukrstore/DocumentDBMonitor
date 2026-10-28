<#
.SYNOPSIS
Safely creates an AMW data source in an existing Azure Managed Grafana instance.
.DESCRIPTION
By default this is read-only. -Apply creates a missing data source, never updates
one. -GrantAmwReader additionally permits a narrowly scoped RBAC assignment.
No dashboard is imported, and no credentials are created or printed.
.EXAMPLE
./az-cli/deploy-grafana.ps1 -SubscriptionId '00000000-0000-0000-0000-000000000000' -GrafanaResourceGroup 'rg-grafana' -GrafanaName 'grafana-example' -AmwResourceGroup 'rg-monitor' -AmwName 'amw-example' -DataSourceName 'DocDB AMW' -DataSourceUid 'docdb-amw'
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$GrafanaResourceGroup,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$GrafanaName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AmwResourceGroup,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AmwName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$DataSourceName,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]{1,40}$')][string]$DataSourceUid,
    [switch]$GrantAmwReader,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')
if ($GrantAmwReader -and -not $Apply) { throw 'GrantAmwReader requires Apply.' }

# Prevent Azure CLI from installing extensions or enabling preview features implicitly.
$previousDynamicInstall = $env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL
$env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = 'no'
try {
    $null = Assert-AzContext -SubscriptionId $SubscriptionId
    $grafana = Get-AzJson -Arguments @('grafana', 'show', '-g', $GrafanaResourceGroup, '-n', $GrafanaName, '--subscription', $SubscriptionId)
    $amw = Get-AzJson -Arguments @('monitor', 'account', 'show', '-g', $AmwResourceGroup, '-n', $AmwName, '--subscription', $SubscriptionId)
    if (-not $grafana.identity -or -not $grafana.identity.principalId) { throw 'Grafana must have an existing system-assigned managed identity.' }
    if (-not $amw.id -or -not $amw.metrics.prometheusQueryEndpoint) { throw 'AMW resource ID or Prometheus query endpoint is unavailable.' }
    $endpoint = [uri]$amw.metrics.prometheusQueryEndpoint
    if ($endpoint.Scheme -ne 'https') { throw 'AMW query endpoint must use HTTPS.' }
    $principal = [string]$grafana.identity.principalId
    $assignments = @(Get-AzJson -Arguments @('role', 'assignment', 'list', '--assignee-object-id', $principal, '--fill-principal-name', 'false', '--role', 'Monitoring Data Reader', '--scope', $amw.id, '--include-inherited', '--subscription', $SubscriptionId))
    $allowedScopes = @($amw.id, "/subscriptions/$SubscriptionId/resourceGroups/$AmwResourceGroup", "/subscriptions/$SubscriptionId")
    $hasReader = @($assignments | Where-Object { $_.scope -in $allowedScopes -and $_.roleDefinitionName -eq 'Monitoring Data Reader' -and (-not $_.condition) }).Count -gt 0
    $sources = @(Get-AzJson -Arguments @('grafana', 'data-source', 'list', '-g', $GrafanaResourceGroup, '-n', $GrafanaName, '--subscription', $SubscriptionId))
    $matches = @($sources | Where-Object { $_.uid -eq $DataSourceUid -or $_.name -eq $DataSourceName })
    if ($matches.Count -gt 0) { throw 'A data source with this UID or name already exists; it will not be changed.' }
    Write-Host "Preflight: Grafana and AMW found; AMW-scoped Monitoring Data Reader present: $hasReader."
    if (-not $Apply) { Write-Host 'Read-only preflight completed; no resources were changed.'; return }
    if (-not $hasReader -and -not $GrantAmwReader) { throw 'The Grafana identity lacks the AMW-scoped role. Grant it separately or explicitly use GrantAmwReader.' }

    if (-not $hasReader) {
        if (-not $PSCmdlet.ShouldProcess($amw.id, 'Grant Grafana managed identity Monitoring Data Reader')) {
            Write-Warning 'Role assignment was not approved; the data source will not be created.'
            return
        }
        $null = Invoke-AzChecked -Arguments @('role', 'assignment', 'create', '--assignee-object-id', $principal, '--assignee-principal-type', 'ServicePrincipal', '--role', 'Monitoring Data Reader', '--scope', $amw.id, '--subscription', $SubscriptionId, '--output', 'none')
    }
    if ($PSCmdlet.ShouldProcess("$GrafanaName / $DataSourceUid", 'Create AMW Prometheus data source')) {
        $definition = @{
            name = $DataSourceName; uid = $DataSourceUid; type = 'prometheus'
            access = 'proxy'; url = $endpoint.AbsoluteUri
            jsonData = @{ httpMethod = 'POST'; timeInterval = '5s'; azureCredentials = @{ authType = 'msi' } }
        } | ConvertTo-Json -Depth 6 -Compress
        $file = [System.IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllText($file, $definition, [System.Text.UTF8Encoding]::new($false))
            $null = Invoke-AzChecked -Arguments @('grafana', 'data-source', 'create', '-g', $GrafanaResourceGroup, '-n', $GrafanaName, '--definition', "@$file", '--subscription', $SubscriptionId, '--output', 'none')
        } finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
        Write-Host 'Grafana AMW data source created. Role propagation may take time.'
    }
} finally {
    $env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = $previousDynamicInstall
}