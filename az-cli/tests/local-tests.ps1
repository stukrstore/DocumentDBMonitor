<#! Offline tests: do not contact Azure or modify deployment resources. #>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$cli = Split-Path -Parent $PSScriptRoot
$root = Split-Path -Parent $cli
$deployment = Join-Path $cli 'deploy.ps1'

foreach ($file in (Get-ChildItem -LiteralPath $cli -Filter '*.ps1' -Recurse)) {
    $tokens = $null; $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "PowerShell parse failed for $($file.Name)." }
    Write-Host "PASS parse: $($file.Name)"
}
$params = @{
    SubscriptionId = '00000000-0000-0000-0000-000000000000'; ResourceGroup = 'rg-example'; Location = 'eastus'
    Prefix = 'example'; AllowedPrincipals = 'user@example.com'; AllowedHostSuffixes = '.example.com'
    DiscoveryScope = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example'
    VnetResourceGroup = 'rg-network'; VnetName = 'vnet'; AcaSubnetName = 'aca'; AcaSubnetPrefix = '10.0.0.0/27'
    PeSubnetName = 'private-endpoints'; EnvName = 'cae-example'
}
& $deployment @params
Write-Host 'PASS local preflight'

function Expect-Failure {
    param([string]$Name, [scriptblock]$Action, [string]$Message)
    try { & $Action; throw "Expected failure did not occur: $Name" }
    catch { if ($_.Exception.Message -notlike "*$Message*") { throw }; Write-Host "PASS $Name" }
}
$badScope = $params.Clone(); $badScope.DiscoveryScope = '/subscriptions/00000000-0000-0000-0000-000000000000'
Expect-Failure 'subscription scope rejected' { & $deployment @badScope } 'DiscoveryScope'
$badSuffix = $params.Clone(); $badSuffix.AllowedHostSuffixes = '*'
Expect-Failure 'wildcard suffix rejected' { & $deployment @badSuffix } 'AllowedHostSuffixes'
$source = Get-Content -LiteralPath (Join-Path $root 'deploy.ps1') -Raw
if ($source -match '(?is)\bcredential\s+reset\b|--client-secret\b') {
    $sha = (Get-FileHash -LiteralPath (Join-Path $root 'deploy.ps1') -Algorithm SHA256).Hash
    Expect-Failure 'legacy root blocked even with reviewed hash' { & $deployment @params -Execute -ReviewedDeploySha256 $sha -Confirm:$false } 'unsafe credential'
} else { Write-Host 'SKIP legacy-root block: root script has changed' }
Write-Host 'Offline tests complete; no Azure calls were made.'