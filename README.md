# DocumentDB Monitor

Azure DocumentDB(MongoDB vCore)의 내부 지표를 수집하고 Azure Monitor workspace(AMW) 및 Grafana에서 확인하는 예제입니다. FastAPI UI/exporter와 Prometheus agent는 Azure Container Apps에서 함께 실행되며 연결 문자열은 Key Vault에 저장합니다. Azure Monitor 플랫폼 지표는 Grafana에서 별도로 조회합니다.

## 구성

- `app/`: UI, exporter, 컨테이너 이미지 정의. 로컬 저장소는 연결 문자열을 **평문**으로 저장하므로 실제 비밀을 사용하지 마세요.
- `deploy.ps1`: Azure CLI로 수집기, AMW, ID, Key Vault, 네트워크, 앱 인증을 배포하는 독립 스크립트.
- `grafana/`: 대시보드 템플릿 및 기존 Azure Managed Grafana에 적용하는 스크립트.
- `docs/architecture-and-setup.html`: 구성 및 설정 안내. `docs/azure-icons/`를 포함하므로 오프라인에서도 로컬 아이콘이 표시됩니다.

## 배포 범위 및 사전 조건

Azure CLI 로그인, 필요한 확장, 구독 및 리소스 생성/역할 할당/앱 등록 권한이 필요합니다. 실제 대상에 맞는 네트워크, 사설 DNS, Key Vault 접근과 DocumentDB 접근 권한을 준비하세요. 기존 VNet을 사용하면 겹치지 않는 `-AcaSubnetPrefix` 및 실제 Private Endpoint 서브넷을 지정하세요. 외부 접근 제한을 위해 `-AllowedPrincipals`와 `-AllowedHostSuffixes`를 명시하는 것이 좋습니다.

루트 `deploy.ps1`은 AMW를 포함한 수집기 전체를 Azure CLI로 배포합니다. 별도 `az-cli/` 래퍼는 독립 수집기 구현이 아니며 안전 검토가 끝나기 전 루트 스크립트 실행을 차단합니다. 해당 도구의 안내를 따르세요. 별도 Terraform 구성은 AMW·관리 ID·RBAC 범위일 수 있으며 **수집기는 별도 Azure CLI 단계로 배포**해야 합니다. 두 방식이 같은 리소스를 관리·생성할 경우 충돌하지 않도록 사전에 변수, state 및 plan을 검토하세요. Terraform state와 plan은 민감할 수 있으므로 안전한 원격 저장소와 접근 제어가 필요합니다.

```powershell
.\deploy.ps1 -ResourceGroup "<monitor-resource-group>" -Location "<azure-region>" `
  -VnetResourceGroup "<vnet-resource-group>" -VnetName "<vnet-name>" `
  -AcaSubnetPrefix "<available-subnet-cidr>" -PeSubnetName "<private-endpoint-subnet>" `
  -AllowedPrincipals "<authorized-principals>" -AllowedHostSuffixes ".mongocluster.cosmos.azure.com"
```

기존 VNet을 생략하면 전용 VNet을 만듭니다. 스크립트는 인증용 클라이언트 비밀을 생성하며 Azure CLI 명령줄 인자로 전달합니다. 실패 메시지에서는 인자와 CLI 오류를 숨기지만, 동일 호스트의 프로세스 검사나 별도 로깅을 통한 노출까지 방지하지는 못합니다. `.deploy/`에는 환경 식별자가 포함될 수 있고 실패 시 남을 수 있으므로 보호하고 삭제하세요. 진단 시에도 민감한 정보를 공개하지 마세요. 이미지 빌드 전 `app/`에서 로컬 데이터와 비밀을 제거하세요. `.dockerignore`만으로 원격 빌드 컨텍스트의 보안을 보장하지 않습니다.

**운영 전 보안 검토 필요:** 외부 ingress가 Easy Auth 설정보다 먼저 생성되므로 인증 설정 실패 또는 진행 중에는 요청을 제한해야 합니다. 기본 호스트 허용 목록이 비어 있으면 대상 제한이 없으며, 전용 Key Vault와 선행 점(`.`)을 포함한 허용 접미사를 사용하세요. 기존 Entra 앱의 redirect URI와 Grafana의 고정 UID가 갱신·덮어쓰기될 수 있습니다.

## Grafana 및 대시보드

기존 Azure Managed Grafana의 시스템 할당 관리 ID와 `Azure Monitor` 데이터 소스를 준비합니다. Grafana와 AMW는 Azure CLI의 현재 구독에서 조회하며 클러스터 구독은 별도 입력합니다. 스크립트는 해당 ID에 읽기 권한을 부여하고 `docdb-amw` UID의 Prometheus 데이터 소스를 생성 또는 갱신한 후 대시보드를 업로드합니다. 이 작업에는 역할 할당 및 Grafana 데이터 소스/대시보드 관리 권한이 필요합니다.

```powershell
.\grafana\deploy-grafana.ps1 -GrafanaResourceGroup "<grafana-resource-group>" -GrafanaName "<grafana-name>" `
  -AmwResourceGroup "<monitor-resource-group>" -AmwName "<amw-name>" `
  -ClusterSubscriptionId "<subscription-id>" -ClusterResourceGroup "<cluster-resource-group>" `
  -ClusterName "<cluster-name>" -ClusterRegion "<azure-region>"
```

대시보드 JSON의 `<SUBSCRIPTION_ID>`, `<CLUSTER_RESOURCE_GROUP>`, `<CLUSTER_NAME>`, `<AZURE_REGION>`은 템플릿 자리표시자입니다. 스크립트는 입력값으로 임시 사본만 치환합니다. 수동 import 시에는 사본의 모든 자리표시자를 교체하고 Azure Monitor 데이터 소스 이름 및 Prometheus UID를 자신의 환경에 맞게 확인하세요. JSON을 실제 값으로 채운 후 공개 저장소에 커밋하지 마세요.

Prometheus 클러스터 선택 변수는 Azure Monitor 패널에 적용되지 않습니다. Azure Monitor 패널은 배포 시 지정한 단일 클러스터를 표시합니다. 기존 Grafana의 같은 UID는 갱신·덮어쓰기되므로 사전에 확인하세요.

## 로컬 개발

`app/requirements.txt` 의존성을 설치하고 `app/main.py`를 실행하면 UI가 포트 8080에서 동작합니다. 기본 로컬 모드는 인증이 꺼져 있고 연결 정보가 `app/data/`에 평문으로 기록됩니다. 운영 환경에 노출하거나 실제 자격 증명을 사용하지 마세요.

## 검증 범위

실제 DocumentDB 수집, Prometheus managed identity remote_write, Easy Auth 및 Grafana/AMW 배포는 대상 환경에서 별도로 검증해야 합니다. 상세 설정과 제한 사항은 HTML 가이드를 참고하세요.
