#!/bin/bash
# VectorPlane Azure Integration — Device Flow Onboarding (RFC 8628)
# Clones the Terraform module, exchanges a pairing code for configuration,
# then deploys App Registration + Federated Identity Credential via Terraform.
#
# Usage (in Azure Cloud Shell):
#   curl -sL https://raw.githubusercontent.com/vectorplane/azure-connect/main/deploy.sh | bash
#
# Idempotent: safe to re-run after partial failures.
#   - Terraform state is stored locally in the cloned workspace
#   - Pre-flight recovery imports orphaned Azure resources into state
#   - Every failure reports clean error details to the VectorPlane dashboard

set -e

# Production default; override with VP_API_BASE for dev/testing
API_BASE="${VP_API_BASE:-https://api.vectorplane.io}"
EXCHANGE_URL="${API_BASE}/api/v1/onboarding/azure/pairing-exchange"
ERROR_URL="${API_BASE}/api/v1/onboarding/azure/report-error"

# Module repo — cloned into Azure Cloud Shell
MODULE_REPO="${VP_MODULE_REPO:-https://github.com/thesystemsguy06/azure-connect.git}"
MODULE_BRANCH="${VP_MODULE_BRANCH:-main}"

# Session ID — set after successful pairing exchange
SESSION_ID=""

# ── Helpers ───────────────────────────────────────────────────────────

# Strip ANSI escape codes and Terraform box-drawing characters.
clean_tf_output() {
    sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r│' | sed 's/^[[:space:]]*//'
}

# Send error telemetry to VectorPlane dashboard.
report_error() {
    local error_type="${1:-unexpected}"
    local detail="${2:-}"
    if [ -n "$SESSION_ID" ]; then
        local payload
        payload=$(jq -n \
            --arg sid "$SESSION_ID" \
            --arg etype "$error_type" \
            --arg det "$detail" \
            '{session_id: $sid, error_type: $etype, detail: $det}')
        curl -s -X POST "$ERROR_URL" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            > /dev/null 2>&1 || true
    fi
}

echo ""
echo "------------------------------------------------"
echo "  VectorPlane Azure Onboarding"
echo "------------------------------------------------"
echo ""

# ── Step 1: Clone Terraform module ────────────────────────────────────
echo "[1/5] Downloading Terraform module..."

WORK_DIR="$HOME/vectorplane-azure-connect"

if [ -d "$WORK_DIR/.git" ]; then
    echo "  Module already cloned. Pulling latest..."
    cd "$WORK_DIR"
    git pull --quiet origin "$MODULE_BRANCH" 2>/dev/null || true
else
    if [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
    if ! git clone --quiet --branch "$MODULE_BRANCH" "$MODULE_REPO" "$WORK_DIR" 2>&1; then
        echo "Error: Failed to download Terraform module."
        echo "  URL: $MODULE_REPO"
        echo ""
        echo "If this is a private repo or network issue, you can clone manually:"
        echo "  git clone $MODULE_REPO $WORK_DIR"
        exit 1
    fi
    cd "$WORK_DIR"
fi

echo "  Module ready: $WORK_DIR"

# ── Step 2: Pairing Code (with retry) ────────────────────────────────
MAX_CODE_ATTEMPTS=3
ATTEMPT=0
BODY=""

while [ $ATTEMPT -lt $MAX_CODE_ATTEMPTS ]; do
    ATTEMPT=$((ATTEMPT + 1))

    echo ""
    read -p "Enter pairing code from dashboard (e.g. VP-XXXX): " USER_CODE
    USER_CODE=$(echo "$USER_CODE" | tr '[:lower:]' '[:upper:]' | xargs)

    if [ -z "$USER_CODE" ]; then
        echo "No code entered."
        if [ $ATTEMPT -lt $MAX_CODE_ATTEMPTS ]; then
            echo ""
            continue
        fi
        echo "Max attempts reached. Get a fresh code from your VectorPlane dashboard."
        exit 1
    fi

    echo ""
    echo "[2/5] Authenticating with VectorPlane..."

    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$EXCHANGE_URL" \
        -H "Content-Type: application/json" \
        -d "{\"pairing_code\": \"$USER_CODE\"}")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" = "200" ]; then
        break
    fi

    ERROR_MSG=$(echo "$BODY" | jq -r '.detail // "Unknown error"' 2>/dev/null || echo "$BODY")
    echo "Error: $ERROR_MSG"

    if [ "$HTTP_CODE" = "410" ]; then
        echo ""
        echo "A newer code was generated. Check your VectorPlane dashboard."
        echo ""
    elif [ $ATTEMPT -lt $MAX_CODE_ATTEMPTS ]; then
        echo ""
        echo "Try again, or get a new code from your VectorPlane dashboard."
        echo ""
    else
        echo ""
        echo "Max attempts reached. Please regenerate a code in the dashboard."
        exit 1
    fi
done

# Write the full payload as terraform.tfvars.json
echo "$BODY" > terraform.tfvars.json

# Validate JSON
if ! jq empty terraform.tfvars.json 2>/dev/null; then
    echo "Error: Invalid configuration received."
    exit 1
fi

# Extract session ID, scope, and identifiers for error reporting
SESSION_ID=$(jq -r '.external_id' terraform.tfvars.json)
SUBSCRIPTION_ID=$(jq -r '.subscription_id // ""' terraform.tfvars.json)
ONBOARDING_SCOPE=$(jq -r '.onboarding_scope // "SUBSCRIPTION"' terraform.tfvars.json)
MANAGEMENT_GROUP_ID=$(jq -r '.management_group_id // ""' terraform.tfvars.json)

# Generate scope-aware app display name (avoids Azure AD ambiguity)
if [ "$ONBOARDING_SCOPE" = "MANAGEMENT_GROUP" ]; then
    MG_SHORT=$(echo "$MANAGEMENT_GROUP_ID" | cut -c1-8)
    APP_DISPLAY_NAME="VectorPlane Security (mg-${MG_SHORT})"
    echo "Identity verified. Management Group: $MANAGEMENT_GROUP_ID"
else
    SUB_SHORT=$(echo "$SUBSCRIPTION_ID" | cut -c1-8)
    APP_DISPLAY_NAME="VectorPlane Security (${SUB_SHORT})"
    echo "Identity verified. Subscription: $SUBSCRIPTION_ID"
fi

jq --arg name "$APP_DISPLAY_NAME" '. + {app_display_name: $name}' \
    terraform.tfvars.json > terraform.tfvars.json.tmp \
    && mv terraform.tfvars.json.tmp terraform.tfvars.json

# ── From here on, errors are reported to the dashboard ────────────────
trap 'report_error "unexpected" "Script failed at line $LINENO"' ERR

# ── Step 3: Verify Azure context ──────────────────────────────────────
echo ""
echo "[3/5] Verifying Azure context..."

# Azure Cloud Shell is pre-authenticated. Verify context matches scope.
CURRENT_SUB=$(az account show --query id -o tsv 2>/dev/null || echo "")

if [ -z "$CURRENT_SUB" ]; then
    echo "Error: Not logged into Azure. Run 'az login' first."
    report_error "permissions" "Not logged into Azure CLI"
    exit 1
fi

if [ "$ONBOARDING_SCOPE" = "MANAGEMENT_GROUP" ]; then
    # MG scope: use current subscription for azurerm provider, verify MG access
    if [ -z "$SUBSCRIPTION_ID" ]; then
        SUBSCRIPTION_ID="$CURRENT_SUB"
        jq --arg sid "$SUBSCRIPTION_ID" '.subscription_id = $sid' \
            terraform.tfvars.json > terraform.tfvars.json.tmp \
            && mv terraform.tfvars.json.tmp terraform.tfvars.json
        echo "  Using current subscription for provider: $SUBSCRIPTION_ID"
    fi
    echo "  Verifying Management Group access..."
    if ! az account management-group show --name "$MANAGEMENT_GROUP_ID" > /dev/null 2>&1; then
        report_error "permissions" "Cannot access Management Group $MANAGEMENT_GROUP_ID"
        echo "Error: Cannot access Management Group '$MANAGEMENT_GROUP_ID'."
        echo "  Ensure you have Reader access on the Management Group."
        exit 1
    fi
    echo "  Management Group: $MANAGEMENT_GROUP_ID"
else
    # Subscription scope: verify the specific subscription
    if [ "$CURRENT_SUB" != "$SUBSCRIPTION_ID" ]; then
        echo "  Switching to subscription $SUBSCRIPTION_ID..."
        if ! az account set --subscription "$SUBSCRIPTION_ID" 2>&1; then
            report_error "permissions" "Cannot access subscription $SUBSCRIPTION_ID"
            echo "Error: Cannot access subscription $SUBSCRIPTION_ID."
            echo "  Ensure you have Owner or User Access Administrator role."
            exit 1
        fi
    fi
    echo "  Subscription: $SUBSCRIPTION_ID"
fi
echo "  Tenant: $(az account show --query tenantId -o tsv 2>/dev/null)"

# ── Step 4: Terraform init + pre-flight recovery ─────────────────────
echo ""
echo "[4/5] Initializing Terraform + reconciling..."

if ! terraform init -input=false 2>&1; then
    report_error "terraform_init" "terraform init failed"
    echo "Error: Terraform initialization failed."
    echo "  Azure Cloud Shell includes Terraform. If you see version errors,"
    echo "  try: terraform version"
    exit 1
fi

echo "  Terraform initialized."

# --- Pre-flight resource recovery ---
# Handles two edge cases that would otherwise cause conflicts:
#   (a) Resources exist in Azure AD/ARM but not in Terraform state (orphaned
#       from a previous session where state was lost)
#   (b) Resources were soft-deleted (Azure AD retains for 30 days) — must be
#       restored before Terraform can manage them again
#
# If state already has resources (normal retry), this block is skipped entirely.

RESOURCES=$(terraform state list 2>/dev/null || echo "")
if [ -z "$RESOURCES" ]; then
    echo "  Reconciling with existing Azure resources..."

    # ── Phase 1: Restore soft-deleted resources ─────────────────────
    # Azure AD retains deleted apps for 30 days. If the user previously
    # deleted the VectorPlane app, restore it so Terraform can manage it.
    DELETED_APP=$(az rest --method GET \
        --url "https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.application?\$filter=displayName eq '${APP_DISPLAY_NAME}'" \
        --query "value[0].{id:id, appId:appId}" -o json 2>/dev/null || echo "{}")
    DELETED_APP_ID=$(echo "$DELETED_APP" | jq -r '.id // empty')
    DELETED_APP_CLIENT_ID=$(echo "$DELETED_APP" | jq -r '.appId // empty')

    if [ -n "$DELETED_APP_ID" ]; then
        echo "    Restoring soft-deleted App Registration..."
        if az rest --method POST \
            --url "https://graph.microsoft.com/v1.0/directory/deletedItems/${DELETED_APP_ID}/restore" \
            > /dev/null 2>&1; then
            echo "    Restored App Registration"
        fi

        # Azure requires restoring the service principal separately
        DELETED_SP_ID=$(az rest --method GET \
            --url "https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.servicePrincipal?\$filter=appId eq '${DELETED_APP_CLIENT_ID}'" \
            --query "value[0].id" -o tsv 2>/dev/null || echo "")
        if [ -n "$DELETED_SP_ID" ]; then
            if az rest --method POST \
                --url "https://graph.microsoft.com/v1.0/directory/deletedItems/${DELETED_SP_ID}/restore" \
                > /dev/null 2>&1; then
                echo "    Restored Service Principal"
            fi
        fi

        sleep 5  # Wait for Azure AD propagation after restore
    fi

    # ── Phase 2: Import existing resources into Terraform state ─────
    # Each import succeeds if the resource exists in Azure, fails silently
    # if not. This lets terraform apply update/no-op existing resources
    # instead of trying to create them (which would error).
    IMPORTED=0

    # 2a. Find existing App Registration by display name
    APP_INFO=$(az ad app list \
        --filter "displayName eq '${APP_DISPLAY_NAME}'" \
        --query "[0].{objectId:id, appId:appId}" -o json 2>/dev/null || echo "{}")
    APP_OBJECT_ID=$(echo "$APP_INFO" | jq -r '.objectId // empty')
    APP_CLIENT_ID=$(echo "$APP_INFO" | jq -r '.appId // empty')

    if [ -n "$APP_OBJECT_ID" ]; then
        if terraform import -input=false \
            "azuread_application.vectorplane" \
            "/applications/${APP_OBJECT_ID}" > /dev/null 2>&1; then
            echo "    Imported App Registration"
            IMPORTED=$((IMPORTED + 1))
        fi

        # 2b. Find existing Service Principal by appId
        SP_OBJECT_ID=$(az ad sp list \
            --filter "appId eq '${APP_CLIENT_ID}'" \
            --query "[0].id" -o tsv 2>/dev/null || echo "")

        if [ -n "$SP_OBJECT_ID" ]; then
            if terraform import -input=false \
                "azuread_service_principal.vectorplane" \
                "/servicePrincipals/${SP_OBJECT_ID}" > /dev/null 2>&1; then
                echo "    Imported Service Principal"
                IMPORTED=$((IMPORTED + 1))
            fi

            # 2c. Find existing Federated Identity Credential
            FIC_ID=$(az ad app federated-credential list \
                --id "$APP_OBJECT_ID" \
                --query "[?name=='VectorPlane WIF'].id | [0]" -o tsv 2>/dev/null || echo "")

            if [ -n "$FIC_ID" ]; then
                if terraform import -input=false \
                    "azuread_application_federated_identity_credential.vectorplane" \
                    "${APP_OBJECT_ID}/federatedIdentityCredential/${FIC_ID}" > /dev/null 2>&1; then
                    echo "    Imported Federated Identity Credential"
                    IMPORTED=$((IMPORTED + 1))
                fi
            fi

            # 2d. Find and import existing Role Assignments (scope-aware)
            if [ "$ONBOARDING_SCOPE" = "MANAGEMENT_GROUP" ]; then
                ROLE_SCOPE="/providers/Microsoft.Management/managementGroups/${MANAGEMENT_GROUP_ID}"
            else
                ROLE_SCOPE="/subscriptions/${SUBSCRIPTION_ID}"
            fi

            for ROLE_PAIR in \
                "Reader:reader" \
                "Storage Blob Data Reader:storage_blob_reader" \
                "Security Reader:security_reader"; do

                ROLE_NAME="${ROLE_PAIR%%:*}"
                TF_NAME="${ROLE_PAIR##*:}"

                ASSIGNMENT_ID=$(az role assignment list \
                    --assignee "$SP_OBJECT_ID" \
                    --role "$ROLE_NAME" \
                    --scope "$ROLE_SCOPE" \
                    --query "[0].id" -o tsv 2>/dev/null || echo "")

                if [ -n "$ASSIGNMENT_ID" ]; then
                    if terraform import -input=false \
                        "azurerm_role_assignment.${TF_NAME}" \
                        "${ASSIGNMENT_ID}" > /dev/null 2>&1; then
                        echo "    Imported role: ${ROLE_NAME}"
                        IMPORTED=$((IMPORTED + 1))
                    fi
                fi
            done
        fi
    fi

    if [ $IMPORTED -gt 0 ]; then
        echo "  Recovered $IMPORTED existing resource(s) into state."
    else
        echo "  No existing resources found. Fresh deployment."
    fi
else
    echo "  State loaded ($(echo "$RESOURCES" | wc -l | tr -d ' ') resources). Resuming."
fi

# ── Step 5: Terraform apply ───────────────────────────────────────────
echo ""
echo "[5/5] Deploying integration..."
TF_OUTPUT=""
if TF_OUTPUT=$(terraform apply -auto-approve -input=false 2>&1); then
    echo "$TF_OUTPUT"
    echo ""
    echo "================================================"
    echo "  VectorPlane Azure integration deployed!"
    echo ""
    echo "  - App Registration created"
    echo "  - Federated Identity Credential configured"
    if [ "$ONBOARDING_SCOPE" = "MANAGEMENT_GROUP" ]; then
    echo "  - Reader + Storage + Security Reader assigned to MG"
    echo "  - Subscriptions will be discovered automatically"
    else
    echo "  - Reader + Storage + Security Reader roles assigned"
    fi
    echo "  - Zero client secrets exchanged"
    echo ""
    echo "  Check your VectorPlane dashboard for findings."
    echo ""
    echo "  To remove: cd $WORK_DIR && terraform destroy"
    echo "================================================"
else
    echo "$TF_OUTPUT"
    # Extract clean error lines for dashboard
    LAST_ERROR=$(echo "$TF_OUTPUT" | clean_tf_output | grep -i "error" | tail -3 | head -c 500)
    report_error "terraform_apply" "$LAST_ERROR"
    echo ""
    echo "Error: Deployment failed. Your VectorPlane dashboard will show details."
    exit 1
fi
