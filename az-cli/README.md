# Azure CLI 배포 도구

PowerShell 7, Azure CLI 및 사전에 설치된 `amg` 확장이 필요합니다. 구독을 직접 선택하고 로그인한 상태에서 실행합니다. 자동 확장 설치나 자동 로그인은 하지 않습니다. 모든 리소스 이름과 구독은 매개변수로 명시합니다.

## 애플리케이션

[deploy.ps1](deploy.ps1)은 기본적으로 로컬 사전 점검만 합니다. 루트 배포 스크립트와 앱 소스는 별도 담당자가 제공해야 합니다. 현재 보존된 루트 스크립트는 실행 때마다 Entra credential을 추가하고 명령줄에 비밀을 전달하므로 **실행이 차단됩니다**. 이 래퍼는 UI/수집기를 독립적으로 배포하지 않습니다.

```powershell
$params = @{
  SubscriptionId = '<subscription-guid>'; ResourceGroup = '<resource-group>'; Location = '<region>'
  Prefix = '<prefix>'; AllowedPrincipals = '<user@domain>'
  AllowedHostSuffixes = '.<approved-domain>'; DiscoveryScope = '/subscriptions/<subscription-guid>/resourceGroups/<resource-group>'
  VnetResourceGroup = '<network-resource-group>'; VnetName = '<vnet>'
  AcaSubnetName = '<aca-subnet>'; AcaSubnetPrefix = '<subnet-cidr>'
  PeSubnetName = '<private-endpoint-subnet>'; EnvName = '<aca-environment>'
}
./az-cli/deploy.ps1 @params
```

실제 배포는 루트 스크립트를 안전하게 교체하고 앱 소스와 의존성을 포함하여 **별도로 보안·비파괴 검토**한 후, 출력된 루트 스크립트 해시를 `-ReviewedDeploySha256`으로 지정하고 `-Execute` 및 확인을 명시해야 합니다. 해시는 루트 스크립트만 고정하며 앱 코드, 다른 파일, 배포 동작의 안전성 또는 검사 후 변경을 보증하지 않습니다. 대체 스크립트는 모든 오류를 종료 오류로 보고해야 합니다. 기존 스크립트의 위험 요소 검출은 제한적인 차단 장치이며 안전성 검사기가 아닙니다. 실행 출력은 비밀 보호를 위해 숨겨집니다. 실패 시 재실행하기 전에 Azure 상태를 확인하세요.

## Grafana 및 AMW

[deploy-grafana.ps1](deploy-grafana.ps1)은 **기존** Azure Managed Grafana 및 Azure Monitor workspace를 이용합니다. Grafana의 시스템 할당 관리 ID와 Grafana 데이터 소스 관리 권한이 필요합니다. 기본 실행은 읽기 전용이며, 이미 같은 UID 또는 이름의 데이터 소스가 있으면 중단합니다.

```powershell
$grafana = @{
  SubscriptionId = '<subscription-guid>'; GrafanaResourceGroup = '<grafana-rg>'; GrafanaName = '<grafana>'
  AmwResourceGroup = '<amw-rg>'; AmwName = '<amw>'
  DataSourceName = '<new-data-source-name>'; DataSourceUid = '<new-uid>'
}
./az-cli/deploy-grafana.ps1 @grafana
./az-cli/deploy-grafana.ps1 @grafana -Apply -WhatIf
./az-cli/deploy-grafana.ps1 @grafana -Apply
```

관리 ID에 AMW `Monitoring Data Reader`가 없을 때만 별도 승인으로 `-Apply -GrantAmwReader`를 사용할 수 있습니다. RBAC 권한이 필요하고, 역할 할당 이후 데이터 소스 생성이 실패하면 역할은 남습니다. `-WhatIf`는 읽기 API를 호출하지만 변경하지 않습니다. 전파 지연으로 생성 직후 쿼리가 실패할 수 있습니다.

기존 대시보드는 특정 환경과 다른 데이터 소스 타입에 묶여 있으므로 자동 가져오기·덮어쓰기를 하지 않습니다. 대시보드는 환경에 맞게 검토하고 데이터 소스 UID와 타입을 수정한 후 별도로 가져오세요. AMW/Collector 생성, Azure Monitor 대시보드용 별도 `Monitoring Reader` 할당 및 AMW 수집 검증은 범위 밖입니다. 동시 실행 간 사전 검사와 생성 사이에는 경쟁 조건이 있습니다. 임시 정의 파일에는 비밀이 없으며 생성 후 삭제합니다.

참고: [Grafana 데이터 소스 CLI](https://learn.microsoft.com/en-us/cli/azure/grafana/data-source), [Azure RBAC CLI](https://learn.microsoft.com/en-us/cli/azure/role/assignment).

## 오프라인 검사

`./az-cli/tests/local-tests.ps1`은 PowerShell 구문, 입력 거부 및 기존 루트 스크립트 실행 차단을 Azure 호출 없이 검사합니다. 실제 인증, RBAC 또는 데이터 소스 연결은 검사하지 않습니다.
