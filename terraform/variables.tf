variable "subscription_id" {
  description = "AMW가 속한 구독 ID."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id는 UUID 형식이어야 합니다."
  }
}

variable "resource_group_name" {
  description = "AMW가 속할 기존 리소스 그룹 이름."
  type        = string

  validation {
    condition     = length(var.resource_group_name) >= 1 && length(var.resource_group_name) <= 90 && can(regex("^[a-zA-Z0-9_.()\\-]+$", var.resource_group_name)) && !endswith(var.resource_group_name, ".")
    error_message = "resource_group_name은 유효한 Azure 리소스 그룹 이름이어야 합니다."
  }
}

variable "location" {
  description = "AMW Azure 리전. 기존 AMW를 import할 경우 기존 리전과 일치해야 합니다."
  type        = string

  validation {
    condition     = length(trimspace(var.location)) > 0 && var.location == trimspace(var.location)
    error_message = "location은 앞뒤 공백이 없는 Azure 리전이어야 합니다."
  }
}

variable "amw_name" {
  description = "AMW 이름. use_caf_name이 false면 정확한 리소스 이름, true면 CAF 생성에 사용할 기본 이름입니다."
  type        = string

  validation {
    condition     = length(var.amw_name) >= 1 && length(var.amw_name) <= 63 && can(regex("^[a-zA-Z0-9][a-zA-Z0-9_-]*$", var.amw_name))
    error_message = "amw_name은 영숫자로 시작하는 1~63자의 영숫자, 밑줄 또는 하이픈이어야 합니다."
  }
}

variable "use_caf_name" {
  description = "새 AMW에만 CAF 생성 이름을 사용합니다. 기존 이름은 false로 그대로 입력하세요."
  type        = bool
  default     = false
}

variable "collector_principal_id" {
  description = "기존 수집기 관리 ID의 Microsoft Entra principal/object ID (client ID 아님)."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.collector_principal_id))
    error_message = "collector_principal_id는 관리 ID의 principal/object UUID여야 합니다."
  }
}

variable "grafana_principal_id" {
  description = "기존 Grafana 관리 ID의 Microsoft Entra principal/object ID (client ID 아님)."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.grafana_principal_id))
    error_message = "grafana_principal_id는 관리 ID의 principal/object UUID여야 합니다."
  }
}

variable "documentdb_resource_group_id" {
  description = "DocumentDB가 속한 기존 리소스 그룹의 전체 Azure 리소스 ID."
  type        = string

  validation {
    condition     = can(regex("(?i)^/subscriptions/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/resourcegroups/[a-z0-9_.()\\-]+$", var.documentdb_resource_group_id)) && !endswith(var.documentdb_resource_group_id, ".")
    error_message = "documentdb_resource_group_id는 /subscriptions/<UUID>/resourceGroups/<이름> 형식이어야 합니다."
  }
}