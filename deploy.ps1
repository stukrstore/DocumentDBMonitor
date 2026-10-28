<#
.SYNOPSIS
  Deploys DocDB Monitor (UI + exporter + Prometheus agent sidecar) to Azure Container Apps.
  Minimal footprint: ACR(Basic) + UAMI + Key Vault + Azure Monitor workspace + ACA (no Log Analytics) + 1 app (2 containers).

.EXAMPLE
  .\deploy.ps1 -ResourceGroup rg-docdb-monitor -Location eastus2
#>
param(
    [string]$ResourceGroup = "rg-docdb-monitor",
    [string]$Location = "eastus2",
    [string]$AllowedPrincipals = "",          # comma separated UPNs; default = current az user
    [string]$AllowedHostSuffixes = "",        # e.g. ".mongocluster.cosmos.azure.com" (SSRF guard for the test endpoint)
    [string]$PrometheusSource = "quay.io/prometheus/prometheus:v2.55.1",
    [string]$Prefix = "docdb-monitor",
    # Existing VNet (e.g. the VNet that holds the DocumentDB private endpoint). Empty = create a dedicated VNet.
    [string]$VnetResourceGroup = "",
    [string]$VnetName = "",
    [string]$AcaSubnetName = "snet-docdb-monitor-aca",
    [string]$AcaSubnetPrefix = "10.40.2.0/27", # Example only; choose a non-overlapping prefix for your VNet.
    [string]$PeSubnetName = "PrivateLink-Subnet",
    [string]$EnvName = "",
    # Scope for the discovery role (list DocumentDB clusters + connection string templates). Default = subscription.
    [string]$DiscoveryScope = ""
)
$ErrorActionPreference = "Stop"
$env:AZURE_EXTENSION_USE_DYNAMIC_INSTALL = "yes_without_prompt"
$env:AZURE_EXTENSION_DYNAMIC_INSTALL_ALLOW_PREVIEW = "true"

$AzExe = (Get-Command az -CommandType Application | Select-Object -First 1).Source
function Az {
  # CLI stderr may echo credentials and arguments may themselves contain secrets.
  # Never include either in an exception or in the PowerShell error stream.
  $PSNativeCommandUseErrorActionPreference = $false
  try { $out = & $AzExe @args --only-show-errors 2>$null; $exitCode = $LASTEXITCODE }
  catch { throw "Azure CLI invocation failed. See the deployment step above; details suppressed to protect secrets." }
  if ($exitCode -ne 0) { throw "Azure CLI failed (exit code $exitCode). See the deployment step above; details suppressed to protect secrets." }
    $out
}
function Step($m) { Write-Host "`n== $m" -ForegroundColor Cyan }

$acct = Az account show -o json | ConvertFrom-Json
$sub = $acct.id; $tenant = $acct.tenantId
if (-not $AllowedPrincipals) { $AllowedPrincipals = $acct.user.name }
$sha = [System.Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes("$sub/$ResourceGroup"))
$sfx = (($sha | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 6)

$acrName = "acrdocdbmon$sfx"
$kvName = "kv-docdbmon-$sfx"
$amwName = "amw-$Prefix"
$idName = "id-$Prefix"
$envName = if ($EnvName) { $EnvName } else { "cae-$Prefix-vnet" }
$appName = "ca-$Prefix"
$tag = (Get-Date -Format "yyyyMMddHHmmss")
$appDir = Join-Path $PSScriptRoot "app"
$work = Join-Path $PSScriptRoot ".deploy"
New-Item -ItemType Directory -Force $work | Out-Null

Step "Resource group / identity"
Az group create -n $ResourceGroup -l $Location -o none
$id = Az identity create -g $ResourceGroup -n $idName -l $Location -o json | ConvertFrom-Json

Step "Key Vault (RBAC)"
if ((Az keyvault list -g $ResourceGroup --query "[?name=='$kvName'] | length(@)" -o tsv) -eq "0") {
    Az keyvault create -g $ResourceGroup -n $kvName -l $Location --enable-rbac-authorization true -o none
}
$kv = Az keyvault show -g $ResourceGroup -n $kvName -o json | ConvertFrom-Json

# Subscription policy forces Key Vault publicNetworkAccess=Disabled -> VNet-integrated ACA env + private endpoint.
Step "VNet + Key Vault private endpoint"
if ($VnetName) {
    # Shared VNet: ACA gets its own delegated subnet; the Key Vault PE goes to the existing PE subnet.
    # DocumentDB private endpoint + privatelink.mongocluster zone link of that VNet make the cluster reachable privately.
    $vnetRg = if ($VnetResourceGroup) { $VnetResourceGroup } else { $ResourceGroup }
    $vnetId = Az network vnet show -g $vnetRg -n $VnetName --query id -o tsv
    if ((Az network vnet subnet list -g $vnetRg --vnet-name $VnetName --query "[?name=='$AcaSubnetName'] | length(@)" -o tsv) -eq "0") {
        Az network vnet subnet create -g $vnetRg --vnet-name $VnetName -n $AcaSubnetName --address-prefixes $AcaSubnetPrefix `
            --delegations Microsoft.App/environments -o none
    }
    $acaSubnetId = Az network vnet subnet show -g $vnetRg --vnet-name $VnetName -n $AcaSubnetName --query id -o tsv
    $peSubnetId = Az network vnet subnet show -g $vnetRg --vnet-name $VnetName -n $PeSubnetName --query id -o tsv
    $linkVnetRef = $vnetId
} else {
    $vnetName = "vnet-$Prefix"
    if ((Az network vnet list -g $ResourceGroup --query "[?name=='$vnetName'] | length(@)" -o tsv) -eq "0") {
        Az network vnet create -g $ResourceGroup -n $vnetName -l $Location --address-prefixes 10.40.0.0/16 `
            --subnet-name snet-aca --subnet-prefixes 10.40.0.0/27 -o none
        Az network vnet subnet update -g $ResourceGroup --vnet-name $vnetName -n snet-aca --delegations Microsoft.App/environments -o none
        Az network vnet subnet create -g $ResourceGroup --vnet-name $vnetName -n snet-pe --address-prefixes 10.40.1.0/28 -o none
    }
    $acaSubnetId = Az network vnet subnet show -g $ResourceGroup --vnet-name $vnetName -n snet-aca --query id -o tsv
    $peSubnetId = Az network vnet subnet show -g $ResourceGroup --vnet-name $vnetName -n snet-pe --query id -o tsv
    $linkVnetRef = Az network vnet show -g $ResourceGroup -n $vnetName --query id -o tsv
}
if ((Az network private-dns zone list -g $ResourceGroup --query "[?name=='privatelink.vaultcore.azure.net'] | length(@)" -o tsv) -eq "0") {
    Az network private-dns zone create -g $ResourceGroup -n privatelink.vaultcore.azure.net -o none
}
$linkName = ("link-" + ($linkVnetRef.Split("/")[-1])).ToLower()
if ((Az network private-dns link vnet list -g $ResourceGroup -z privatelink.vaultcore.azure.net --query "[?name=='$linkName'] | length(@)" -o tsv) -eq "0") {
    Az network private-dns link vnet create -g $ResourceGroup -z privatelink.vaultcore.azure.net -n $linkName `
        -v $linkVnetRef -e false -o none
}
if ((Az network private-endpoint list -g $ResourceGroup --query "[?name=='pe-$kvName'] | length(@)" -o tsv) -eq "0") {
    Az network private-endpoint create -g $ResourceGroup -n "pe-$kvName" -l $Location --subnet $peSubnetId `
        --private-connection-resource-id $kv.id --group-id vault --connection-name kv -o none
    Az network private-endpoint dns-zone-group create -g $ResourceGroup --endpoint-name "pe-$kvName" -n default `
        --private-dns-zone privatelink.vaultcore.azure.net --zone-name vault -o none
}

Step "ACR (Basic)"
Az acr create -g $ResourceGroup -n $acrName -l $Location --sku Basic -o none
$acr = Az acr show -g $ResourceGroup -n $acrName -o json | ConvertFrom-Json

Step "Azure Monitor workspace (Prometheus metrics store)"
Az monitor account create -g $ResourceGroup -n $amwName -l $Location -o none
$amw = Az monitor account show -g $ResourceGroup -n $amwName -o json | ConvertFrom-Json
$dcrId = $amw.defaultIngestionSettings.dataCollectionRuleResourceId
$dceId = $amw.defaultIngestionSettings.dataCollectionEndpointResourceId
$dcrImm = Az rest --method get --url "https://management.azure.com$($dcrId)?api-version=2022-06-01" --query properties.immutableId -o tsv
$dceUrl = Az rest --method get --url "https://management.azure.com$($dceId)?api-version=2022-06-01" --query properties.metricsIngestion.endpoint -o tsv
$remoteWrite = "$dceUrl/dataCollectionRules/$dcrImm/streams/Microsoft-PrometheusMetrics/api/v1/write?api-version=2023-04-24"
Write-Host "remote_write: $remoteWrite"

Step "Role assignments for the managed identity"
$pid_ = $id.principalId
Az role assignment create --assignee-object-id $pid_ --assignee-principal-type ServicePrincipal --role AcrPull --scope $acr.id -o none
Az role assignment create --assignee-object-id $pid_ --assignee-principal-type ServicePrincipal --role "Monitoring Metrics Publisher" --scope $dcrId -o none
Az role assignment create --assignee-object-id $pid_ --assignee-principal-type ServicePrincipal --role "Key Vault Secrets Officer" --scope $kv.id -o none

# Discovery: list DocumentDB (Mongo vCore) clusters + connection string templates (no passwords) so the UI can offer a picker.
if (-not $DiscoveryScope) { $DiscoveryScope = "/subscriptions/$sub" }
$roleName = "DocDB Monitor Discovery"
$roleDef = @{
    Name = $roleName
    Description = "List DocumentDB (Mongo vCore) clusters and read connection string templates"
    Actions = @("Microsoft.DocumentDB/mongoClusters/read", "Microsoft.DocumentDB/mongoClusters/listConnectionStrings/action")
    NotActions = @()
    AssignableScopes = @("/subscriptions/$sub")
} | ConvertTo-Json -Depth 4
$roleFile = Join-Path $work "role.json"
Set-Content -Path $roleFile -Value $roleDef -Encoding utf8
if ((Az role definition list --custom-role-only true --query "[?roleName=='$roleName'] | length(@)" -o tsv) -eq "0") {
    Az role definition create --role-definition $roleFile -o none
    Start-Sleep -Seconds 20
}
Az role assignment create --assignee-object-id $pid_ --assignee-principal-type ServicePrincipal --role $roleName --scope $DiscoveryScope -o none

Step "Build / import images"
Az acr build -r $acrName -t "docdb-monitor:$tag" --no-logs $appDir -o none
$last = Az acr task list-runs -r $acrName --top 1 --query "[0].status" -o tsv
if ($last -ne "Succeeded") { throw "acr build status: $last" }
$promTag = $PrometheusSource.Split("/")[-1]
Az acr import -n $acrName --source $PrometheusSource -t "prometheus:$($promTag.Split(':')[-1])" --force -o none
$appImage = "$($acr.loginServer)/docdb-monitor:$tag"
$promImage = "$($acr.loginServer)/prometheus:$($promTag.Split(':')[-1])"

Step "Container Apps environment (VNet integrated, no Log Analytics)"
if ((Az containerapp env list -g $ResourceGroup --query "[?name=='$envName'] | length(@)" -o tsv) -eq "0") {
    Az containerapp env create -g $ResourceGroup -n $envName -l $Location --logs-destination none `
        --infrastructure-subnet-resource-id $acaSubnetId -o none
}
$envInfo = Az containerapp env show -g $ResourceGroup -n $envName -o json | ConvertFrom-Json
$fqdn = "$appName.$($envInfo.properties.defaultDomain)"

Step "Entra app registration for Easy Auth"
$appReg = Az ad app list --display-name "$Prefix-ui" --query "[0].appId" -o tsv
if (-not $appReg) {
    $appReg = Az ad app create --display-name "$Prefix-ui" --sign-in-audience AzureADMyOrg `
        --web-redirect-uris "https://$fqdn/.auth/login/aad/callback" --enable-id-token-issuance true --query appId -o tsv
}
Az ad app update --id $appReg --web-redirect-uris "https://$fqdn/.auth/login/aad/callback"
$secret = Az ad app credential reset --id $appReg --append --display-name easyauth --years 1 --query password -o tsv

Step "Wait for role propagation"
Start-Sleep -Seconds 45

Step "Deploy container app"
$promCfg = @"
global:
  scrape_interval: 1m
  scrape_timeout: 20s
scrape_configs:
  - job_name: docdb
    metrics_path: /probe
    http_sd_configs:
      - url: http://127.0.0.1:9100/sd
        refresh_interval: 30s
    relabel_configs:
      - source_labels: [__meta_docdb_name]
        target_label: __param_target
      - source_labels: [__meta_docdb_name]
        target_label: cluster
      - source_labels: [__meta_docdb_interval]
        target_label: __scrape_interval__
      - source_labels: [__meta_docdb_timeout]
        target_label: __scrape_timeout__
remote_write:
  - url: $remoteWrite
    azuread:
      cloud: AzurePublic
      managed_identity:
        client_id: $($id.clientId)
    write_relabel_configs:
      - source_labels: [__name__]
        regex: "docdb_.*|up"
        action: keep
"@
$indent = ($promCfg -split "`n" | ForEach-Object { "          " + $_.TrimEnd("`r") }) -join "`n"

$yaml = @"
name: $appName
type: Microsoft.App/containerApps
location: $Location
identity:
  type: UserAssigned
  userAssignedIdentities:
    $($id.id): {}
properties:
  environmentId: $($envInfo.id)
  configuration:
    activeRevisionsMode: Single
    ingress:
      external: true
      targetPort: 8080
      transport: auto
      allowInsecure: false
    registries:
      - server: $($acr.loginServer)
        identity: $($id.id)
    secrets:
      - name: prom-config
        value: |
$indent
  template:
    containers:
      - name: app
        image: $appImage
        resources: {cpu: 0.25, memory: 0.5Gi}
        env:
          - {name: KEY_VAULT_URL, value: "$($kv.properties.vaultUri)"}
          - {name: AZURE_CLIENT_ID, value: "$($id.clientId)"}
          - {name: AZURE_SUBSCRIPTION_ID, value: "$sub"}
          - {name: REQUIRE_AUTH, value: "true"}
          - {name: ALLOWED_PRINCIPALS, value: "$AllowedPrincipals"}
          - {name: ALLOWED_HOST_SUFFIXES, value: "$AllowedHostSuffixes"}
        probes:
          - type: Liveness
            httpGet: {path: /healthz, port: 8080}
            periodSeconds: 30
      - name: prometheus
        image: $promImage
        args:
          - --config.file=/etc/prometheus/prometheus.yml
          - --enable-feature=agent
          - --storage.agent.path=/prometheus
        resources: {cpu: 0.25, memory: 0.5Gi}
        volumeMounts:
          - {volumeName: promcfg, mountPath: /etc/prometheus}
          - {volumeName: promdata, mountPath: /prometheus}
    volumes:
      - name: promcfg
        storageType: Secret
        secrets:
          - {secretRef: prom-config, path: prometheus.yml}
      - name: promdata
        storageType: EmptyDir
    scale:
      minReplicas: 1
      maxReplicas: 1
"@
$yamlPath = Join-Path $work "app.yaml"
Set-Content -Path $yamlPath -Value $yaml -Encoding utf8
$exists = Az containerapp list -g $ResourceGroup --query "[?name=='$appName'] | length(@)" -o tsv
if ($exists -eq "0") { Az containerapp create -g $ResourceGroup -n $appName --yaml $yamlPath -o none }
else { Az containerapp update -g $ResourceGroup -n $appName --yaml $yamlPath -o none }

Step "Easy Auth (Entra, single tenant)"
Az containerapp auth microsoft update -g $ResourceGroup -n $appName --client-id $appReg --client-secret $secret `
    --issuer "https://login.microsoftonline.com/$tenant/v2.0" --yes -o none
Az containerapp auth update -g $ResourceGroup -n $appName --enabled true --action RedirectToLoginPage `
    --redirect-provider azureactivedirectory --require-https true --yes -o none

Remove-Item $work -Recurse -Force
Write-Host "`nUI: https://$fqdn" -ForegroundColor Green
Write-Host "Key Vault: $($kv.properties.vaultUri)  AMW: $amwName"
