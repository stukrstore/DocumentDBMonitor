<#
.SYNOPSIS
Validates and delegates to a separately security-reviewed root deployment script.
.DESCRIPTION
The legacy root deploy.ps1 creates a new Entra credential on every run and can leak
it on failure. It is intentionally blocked. A replacement must be independently
reviewed for credential handling, non-destructive changes and access control.
The operator supplies the SHA-256 of that exact reviewed file before execution.
.EXAMPLE
./az-cli/deploy.ps1 -SubscriptionId '00000000-0000-0000-0000-000000000000' -ResourceGroup 'rg-example' -Location 'eastus' -Prefix 'example' -AllowedPrincipals 'user@example.com' -AllowedHostSuffixes '.example.com' -DiscoveryScope '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example' -VnetResourceGroup 'rg-network' -VnetName 'vnet-example' -AcaSubnetName 'aca' -AcaSubnetPrefix '10.0.0.0/27' -PeSubnetName 'private-endpoints' -EnvName 'cae-example'
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResourceGroup,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Location,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,20}$')][string]$Prefix,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AllowedPrincipals,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AllowedHostSuffixes,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$DiscoveryScope,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$VnetResourceGroup,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$VnetName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AcaSubnetName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AcaSubnetPrefix,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PeSubnetName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EnvName,
    [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ReviewedDeploySha256,
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'common.ps1')

if ($SubscriptionId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { throw 'SubscriptionId must be a subscription GUID.' }
if ($DiscoveryScope -notmatch ('^/subscriptions/' + [regex]::Escape($SubscriptionId) + '/resourceGroups/[^/]+(?:/providers/.+)?$')) { throw 'DiscoveryScope must be a resource group or resource within the specified subscription, not subscription-wide.' }
foreach ($suffix in ($AllowedHostSuffixes -split ',')) {
    if ($suffix.Trim() -notmatch '^\.[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)+$') { throw 'AllowedHostSuffixes must contain explicit DNS suffixes beginning with a dot.' }
}
if (@($AllowedPrincipals -split ',' | Where-Object { $_.Trim() -notmatch '^[^\s,@]+@[^\s,@]+$' }).Count -gt 0) { throw 'AllowedPrincipals must contain explicit comma-separated UPNs.' }

$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'deploy.ps1'
$app = Join-Path $root 'app'
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw 'The repository root deploy.ps1 is missing.' }
if (-not (Test-Path -LiteralPath $app -PathType Container)) { throw 'The repository root app directory is missing.' }
if (((Get-Item -LiteralPath $script -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -or
    ((Get-Item -LiteralPath $app -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'The root deployment script and app directory must not be symbolic links or junctions.'
}
$hash = (Get-FileHash -LiteralPath $script -Algorithm SHA256).Hash
$source = Get-Content -LiteralPath $script -Raw
$legacyUnsafe = $source -match '(?is)\bcredential\s+reset\b|--client-secret\b'
if (Test-Path -LiteralPath (Join-Path $root '.deploy')) { throw 'The root .deploy path already exists; refusing to risk existing files.' }

$parameters = @{
    ResourceGroup = $ResourceGroup; Location = $Location; Prefix = $Prefix
    AllowedPrincipals = $AllowedPrincipals; AllowedHostSuffixes = $AllowedHostSuffixes
    DiscoveryScope = $DiscoveryScope; VnetResourceGroup = $VnetResourceGroup; VnetName = $VnetName
    AcaSubnetName = $AcaSubnetName; AcaSubnetPrefix = $AcaSubnetPrefix; PeSubnetName = $PeSubnetName; EnvName = $EnvName
}
$rootParameters = (Get-Command -Name $script).Parameters
foreach ($name in $parameters.Keys) { if (-not $rootParameters.ContainsKey($name)) { throw "The reviewed root script does not support required parameter '$name'." } }
Write-Host "Root deployment SHA-256: $hash"
if (-not $Execute) {
    if ($legacyUnsafe) { Write-Warning 'Root deployment contains unsafe credential handling and is blocked from execution.' }
    else { Write-Host 'Local preflight passed; independent security review is still required.' }
    Write-Host 'No Azure operations were performed.'
    return
}
if ($legacyUnsafe) { throw 'The root deployment uses unsafe credential creation or command-line secrets and cannot be invoked by this wrapper.' }
if (-not $ReviewedDeploySha256 -or $hash -ne $ReviewedDeploySha256) { throw 'Execution requires the SHA-256 of the independently reviewed root deploy.ps1.' }
$null = Assert-AzContext -SubscriptionId $SubscriptionId
if ($PSCmdlet.ShouldProcess("subscription $SubscriptionId / resource group $ResourceGroup", 'Run independently reviewed root deployment')) {
    # A hash is an operator attestation, not a proof of safety. Never relay root output/errors.
    if ((Get-FileHash -LiteralPath $script -Algorithm SHA256).Hash -ne $hash) { throw 'The reviewed root script changed after validation.' }
    # Reviewed scripts must throw on failure; shell exit codes cannot establish success
    # for arbitrary nested native commands. App and dependencies require separate review.
    $global:LASTEXITCODE = 0
    try { & $script @parameters *> $null; if ($LASTEXITCODE -ne 0) { throw 'Native command failed.' } }
    catch { throw 'Root deployment failed; output suppressed to avoid exposing sensitive data. Review Azure resource state before retrying.' }
    Write-Host 'Root deployment completed. Review the resulting Azure resources.'
}