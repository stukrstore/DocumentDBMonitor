Set-StrictMode -Version Latest

function Invoke-AzChecked {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $az = Get-Command az -CommandType Application -ErrorAction Stop | Select-Object -First 1
    # Do not echo arguments or stderr: either can contain sensitive information.
    $oldErrorPreference = $ErrorActionPreference
    $oldNativePreference = $null
    $hasNativePreference = Test-Path variable:PSNativeCommandUseErrorActionPreference
    if ($hasNativePreference) { $oldNativePreference = $PSNativeCommandUseErrorActionPreference; $PSNativeCommandUseErrorActionPreference = $false }
    try {
        $ErrorActionPreference = 'Continue'
        $result = & $az.Source @Arguments --only-show-errors 2>$null
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorPreference
        if ($hasNativePreference) { $PSNativeCommandUseErrorActionPreference = $oldNativePreference }
    }
    $operation = ($Arguments | Select-Object -First 2) -join ' '
    if ($exitCode -ne 0) { throw "Azure CLI operation '$operation' failed (exit code $exitCode); details suppressed to protect sensitive information." }
    return ($result -join "`n")
}

function Get-AzJson {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $json = Invoke-AzChecked -Arguments ($Arguments + @('--output', 'json'))
    try { return (ConvertFrom-Json -InputObject $json -ErrorAction Stop) }
    catch { throw 'Azure CLI returned invalid JSON; details suppressed.' }
}

function Assert-AzContext {
    param([Parameter(Mandatory)][string]$SubscriptionId)
    $account = Get-AzJson -Arguments @('account', 'show')
    if ($account.id -ne $SubscriptionId) {
        throw 'The active Azure CLI subscription does not match SubscriptionId. Select the intended subscription before running this script.'
    }
    return $account
}