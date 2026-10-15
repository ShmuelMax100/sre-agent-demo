#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
readonly IAC_DIR="$ROOT_DIR/iac"
readonly APP_DIR="$ROOT_DIR/src/teams-bridge"

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

command -v az >/dev/null 2>&1 || { printf '%s\n' 'Azure CLI is required.' >&2; exit 1; }
command -v func >/dev/null 2>&1 || { printf '%s\n' 'Azure Functions Core Tools v4 is required.' >&2; exit 1; }
command -v terraform >/dev/null 2>&1 || { printf '%s\n' 'Terraform is required.' >&2; exit 1; }

function_app_name=$(terraform -chdir="$IAC_DIR" output -json teams_bridge | jq -r '.function_app_name')
key_vault_name=$(terraform -chdir="$IAC_DIR" output -json teams_bridge | jq -r '.key_vault_name')
messaging_endpoint=$(terraform -chdir="$IAC_DIR" output -json teams_bridge | jq -r '.messaging_endpoint')
bot_client_id=$(terraform -chdir="$IAC_DIR" output -json teams_bridge | jq -r '.bot_client_id')

for secret_name in bot-client-secret github-webhook-secret mcp-shared-key; do
  az keyvault secret show \
    --vault-name "$key_vault_name" \
    --name "$secret_name" \
    --query id \
    --output tsv >/dev/null || {
      printf 'Required Key Vault secret is missing: %s\n' "$secret_name" >&2
      exit 1
    }
done

publish_log=$(mktemp "${TMPDIR:-/tmp}/teams-bridge-publish.XXXXXX")
chmod 600 "$publish_log"
trap 'rm -f "$publish_log"' EXIT

publish_status=0
(
  cd "$APP_DIR"
  func azure functionapp publish "$function_app_name" --python --build remote 2>&1 \
    | tee "$publish_log"
) || publish_status=$?
if (( publish_status != 0 )); then
  if grep -F 'Deployment was successful but the app appears to be unhealthy' \
    "$publish_log" >/dev/null; then
    printf '%s\n' \
      'Core Tools publish health check failed; continuing with managed-identity storage cleanup before the authoritative health check.' >&2
  else
    exit "$publish_status"
  fi
fi

# Core Tools synthesizes this classic connection string during publish even when
# local.settings.json is excluded. It overrides the managed-identity components.
az functionapp config appsettings delete \
  --resource-group "$(terraform -chdir="$IAC_DIR" output -raw resource_group_name)" \
  --name "$function_app_name" \
  --setting-names AzureWebJobsStorage \
  --output none

legacy_storage_count=$(az functionapp config appsettings list \
  --resource-group "$(terraform -chdir="$IAC_DIR" output -raw resource_group_name)" \
  --name "$function_app_name" \
  --query "length([?name == 'AzureWebJobsStorage'])" \
  --output tsv)
[[ "$legacy_storage_count" == "0" ]] || {
  printf '%s\n' 'Legacy AzureWebJobsStorage setting remains after publish.' >&2
  exit 1
}
az functionapp restart \
  --resource-group "$(terraform -chdir="$IAC_DIR" output -raw resource_group_name)" \
  --name "$function_app_name"

function_hostname=${messaging_endpoint#https://}
function_hostname=${function_hostname%/api/messages}
"$ROOT_DIR/scripts/package-teams-app.sh" \
  --bot-client-id "$bot_client_id" \
  --function-hostname "$function_hostname"

curl --fail-with-body --silent --show-error \
  --retry 12 \
  --retry-all-errors \
  --retry-delay 5 \
  "https://$function_hostname/api/health" \
  | jq -e '.status == "ok"' >/dev/null
"$ROOT_DIR/scripts/configure-sre-agent-capabilities.sh"
"$ROOT_DIR/scripts/configure-github-webhook.sh"
printf 'Teams bridge deployed and healthy: https://%s/api/health\n' "$function_hostname"