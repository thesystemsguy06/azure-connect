# =============================================================================
# VectorPlane Azure Onboarding - Main Configuration
# =============================================================================
# Creates:
# 1. Azure AD App Registration (identity for VectorPlane)
# 2. Service Principal (enables role assignments)
# 3. Federated Identity Credential (trusts VectorPlane OIDC issuer)
# 4. Role Assignments: Reader, Storage Blob Data Reader, Security Reader
#
# Scope-aware: role assignments target either a single subscription or a
# management group, controlled by var.onboarding_scope.
# =============================================================================

data "azurerm_subscription" "current" {}

data "azuread_client_config" "current" {}

# -----------------------------------------------------------------------------
# Scope Resolution
# -----------------------------------------------------------------------------
# Role assignments are scoped to either:
#   - /subscriptions/{id}                                    (SUBSCRIPTION scope)
#   - /providers/Microsoft.Management/managementGroups/{id}  (MANAGEMENT_GROUP scope)
#
# App Registration, Service Principal, and FIC are tenant-level resources
# and do not change based on scope.

locals {
  role_scope = var.onboarding_scope == "MANAGEMENT_GROUP" ? (
    "/providers/Microsoft.Management/managementGroups/${var.management_group_id}"
  ) : data.azurerm_subscription.current.id
}

# -----------------------------------------------------------------------------
# App Registration — VectorPlane's identity in Azure AD
# -----------------------------------------------------------------------------

resource "azuread_application" "vectorplane" {
  display_name = var.app_display_name

  tags = ["VectorPlane", "SecurityTriage", "ManagedByTerraform"]
}

resource "azuread_service_principal" "vectorplane" {
  client_id = azuread_application.vectorplane.client_id

  tags = ["VectorPlane", "SecurityTriage"]
}

# -----------------------------------------------------------------------------
# Federated Identity Credential — Zero-trust OIDC trust
# -----------------------------------------------------------------------------
# Azure AD will accept JWTs signed by VectorPlane's OIDC provider if:
#   - issuer matches vectorplane_oidc_issuer
#   - subject matches vectorplane_oidc_subject
#   - audience matches vectorplane_oidc_audience
# VectorPlane hosts .well-known/openid-configuration and jwks.json at the issuer URL.

resource "azuread_application_federated_identity_credential" "vectorplane" {
  application_id = azuread_application.vectorplane.id
  display_name   = "vectorplane-wif"
  description    = "Trust VectorPlane OIDC IdP for zero-secret authentication"

  issuer    = var.vectorplane_oidc_issuer
  subject   = var.vectorplane_oidc_subject
  audiences = [var.vectorplane_oidc_audience]
}

# -----------------------------------------------------------------------------
# Role Assignments — Scope-aware access
# -----------------------------------------------------------------------------
# For SUBSCRIPTION scope:  roles target /subscriptions/{id}
# For MANAGEMENT_GROUP scope: roles target /providers/Microsoft.Management/managementGroups/{id}
#   (inherits to all child subscriptions)

# Reader — list resources, read metadata
resource "azurerm_role_assignment" "reader" {
  scope                = local.role_scope
  role_definition_name = "Reader"
  principal_id         = azuread_service_principal.vectorplane.object_id
}

# Storage Blob Data Reader — read Terraform state files
resource "azurerm_role_assignment" "storage_blob_reader" {
  scope                = local.role_scope
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azuread_service_principal.vectorplane.object_id
}

# Security Reader — read Defender for Cloud assessments
resource "azurerm_role_assignment" "security_reader" {
  scope                = local.role_scope
  role_definition_name = "Security Reader"
  principal_id         = azuread_service_principal.vectorplane.object_id
}

# -----------------------------------------------------------------------------
# IAM Propagation Delay
# -----------------------------------------------------------------------------
# Azure AD role assignments are eventually consistent. Wait for propagation
# before triggering the webhook callback.

resource "time_sleep" "iam_propagation" {
  depends_on = [
    azurerm_role_assignment.reader,
    azurerm_role_assignment.storage_blob_reader,
    azurerm_role_assignment.security_reader,
    azuread_application_federated_identity_credential.vectorplane,
  ]

  create_duration = "30s"
}
