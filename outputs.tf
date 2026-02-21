# =============================================================================
# VectorPlane Azure Onboarding - Outputs
# =============================================================================

output "tenant_id" {
  description = "Azure AD Tenant ID"
  value       = data.azuread_client_config.current.tenant_id
}

output "client_id" {
  description = "App Registration Client ID (used by VectorPlane for WIF)"
  value       = azuread_application.vectorplane.client_id
}

output "subscription_id" {
  description = "Azure Subscription ID"
  value       = var.subscription_id
}

output "app_display_name" {
  description = "App Registration display name"
  value       = azuread_application.vectorplane.display_name
}

output "onboarding_scope" {
  description = "Onboarding scope: SUBSCRIPTION or MANAGEMENT_GROUP"
  value       = var.onboarding_scope
}

output "management_group_id" {
  description = "Management Group ID (if MANAGEMENT_GROUP scope)"
  value       = var.management_group_id
}

output "role_scope" {
  description = "Effective scope for role assignments"
  value       = local.role_scope
}
