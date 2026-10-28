# CAF는 선택적으로 신규 이름만 생성합니다. 기존 이름은 변경하지 않습니다.
resource "azurecaf_name" "amw" {
  count         = var.use_caf_name ? 1 : 0
  name          = var.amw_name
  resource_type = "azurerm_monitor_workspace"
  clean_input   = true
}

resource "azurerm_monitor_workspace" "docdb" {
  name                = var.use_caf_name ? azurecaf_name.amw[0].result : var.amw_name
  resource_group_name = var.resource_group_name
  location            = var.location

  # 가져온 AMW의 태그 및 네트워크 설정은 이 구성에서 변경하지 않습니다.
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [tags, public_network_access_enabled]
  }
}

resource "azurerm_role_assignment" "collector_publish" {
  scope                = azurerm_monitor_workspace.docdb.default_data_collection_rule_id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = var.collector_principal_id
  principal_type       = "ServicePrincipal"

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_role_assignment" "grafana_amw_read" {
  scope                = azurerm_monitor_workspace.docdb.id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = var.grafana_principal_id
  principal_type       = "ServicePrincipal"

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_role_assignment" "grafana_platform_read" {
  scope                = var.documentdb_resource_group_id
  role_definition_name = "Monitoring Reader"
  principal_id         = var.grafana_principal_id
  principal_type       = "ServicePrincipal"

  lifecycle {
    prevent_destroy = true
  }
}