# =============================================================================
# VectorPlane Azure Onboarding - Webhook Callback
# =============================================================================
# Notifies VectorPlane upon successful Terraform apply.
# Uses HMAC signature for webhook authentication.
# Mirrors gcp-connect/webhook.tf pattern.
# =============================================================================

locals {
  webhook_payload = jsonencode({
    external_id         = var.external_id
    subscription_id     = var.subscription_id
    tenant_id           = data.azuread_client_config.current.tenant_id
    client_id           = azuread_application.vectorplane.client_id
    onboarding_scope    = var.onboarding_scope
    management_group_id = var.onboarding_scope == "MANAGEMENT_GROUP" ? var.management_group_id : null
  })

  webhook_timestamp = timestamp()
}

# -----------------------------------------------------------------------------
# Webhook Callback with HMAC Signature
# -----------------------------------------------------------------------------

resource "null_resource" "webhook_callback" {
  depends_on = [time_sleep.iam_propagation]

  triggers = {
    external_id         = var.external_id
    subscription_id     = var.subscription_id
    client_id           = azuread_application.vectorplane.client_id
    onboarding_scope    = var.onboarding_scope
    management_group_id = var.management_group_id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    command = <<-EOT
      set -e

      PAYLOAD='${local.webhook_payload}'
      TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

      # Compute HMAC-SHA256 signature
      SIGNATURE_INPUT="$TIMESTAMP.$PAYLOAD"
      SIGNATURE=$(echo -n "$SIGNATURE_INPUT" | openssl dgst -sha256 -hmac '${var.webhook_secret}' -binary | base64)

      echo "Sending webhook to VectorPlane..."

      HTTP_RESPONSE=$(curl -s -w "%%{http_code}" -o /tmp/webhook_response.txt \
        -X POST "${var.vectorplane_callback_url}" \
        -H "Content-Type: application/json" \
        -H "X-VectorPlane-Signature: sha256=$SIGNATURE" \
        -H "X-VectorPlane-Timestamp: $TIMESTAMP" \
        -H "X-VectorPlane-External-ID: ${var.external_id}" \
        -d "$PAYLOAD" \
        --connect-timeout 30 \
        --max-time 60)

      RESPONSE_BODY=$(cat /tmp/webhook_response.txt 2>/dev/null || echo "")

      echo "HTTP Status: $HTTP_RESPONSE"
      echo "Response: $RESPONSE_BODY"

      if [[ "$HTTP_RESPONSE" =~ ^2[0-9][0-9]$ ]]; then
        echo "Webhook callback succeeded!"
        exit 0
      else
        echo "ERROR: Webhook callback failed with status $HTTP_RESPONSE"
        echo "Please verify your VectorPlane session is still active."
        exit 1
      fi
    EOT

    environment = {
      TF_LOG = ""
    }
  }
}

# -----------------------------------------------------------------------------
# Verification Instructions
# -----------------------------------------------------------------------------

resource "null_resource" "verification_instructions" {
  depends_on = [null_resource.webhook_callback]

  provisioner "local-exec" {
    command = <<-EOT
      echo ""
      echo "=============================================="
      echo "VectorPlane Azure Integration - Setup Complete!"
      echo "=============================================="
      echo ""
      echo "If the automatic callback failed, provide these"
      echo "details to VectorPlane support:"
      echo ""
      echo "  External ID:         ${var.external_id}"
      echo "  Subscription ID:     ${var.subscription_id}"
      echo "  Tenant ID:           ${data.azuread_client_config.current.tenant_id}"
      echo "  Client ID:           ${azuread_application.vectorplane.client_id}"
      echo "  Onboarding Scope:    ${var.onboarding_scope}"
      echo "  Management Group ID: ${var.management_group_id}"
      echo ""
      echo "=============================================="
    EOT
  }
}
