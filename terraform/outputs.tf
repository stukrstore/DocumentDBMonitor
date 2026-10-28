output "amw_id" {
  description = "Azure Monitor workspace 리소스 ID."
  value       = azurerm_monitor_workspace.docdb.id
}

output "amw_name" {
  description = "실제 Azure Monitor workspace 이름."
  value       = azurerm_monitor_workspace.docdb.name
}

output "query_endpoint" {
  description = "Grafana Prometheus 데이터 소스에 사용하는 AMW 쿼리 엔드포인트."
  value       = azurerm_monitor_workspace.docdb.query_endpoint
}

output "default_dcr_id" {
  description = "기본 DCR의 Azure 리소스 ID. DCR immutable ID가 아닙니다."
  value       = azurerm_monitor_workspace.docdb.default_data_collection_rule_id
}

output "default_dce_id" {
  description = "기본 DCE의 Azure 리소스 ID. metrics ingestion URL이 아닙니다."
  value       = azurerm_monitor_workspace.docdb.default_data_collection_endpoint_id
}

output "role_assignment_ids" {
  description = "Terraform이 관리하는 세 역할 할당의 Azure 리소스 ID."
  value = {
    collector_publish     = azurerm_role_assignment.collector_publish.id
    grafana_amw_read      = azurerm_role_assignment.grafana_amw_read.id
    grafana_platform_read = azurerm_role_assignment.grafana_platform_read.id
  }
}