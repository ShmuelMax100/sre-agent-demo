#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
readonly IAC_DIR="$ROOT_DIR/iac"
readonly EXPECTED_SUBSCRIPTION="${TF_VAR_subscription_id:-}"
readonly EXPECTED_TENANT="${TF_VAR_tenant_id:-}"
CORE_PLAN=$(mktemp "${TMPDIR:-/tmp}/sre-demo-core.XXXXXX.tfplan")
readonly CORE_PLAN
CORE_JSON=$(mktemp "${TMPDIR:-/tmp}/sre-demo-core.XXXXXX.json")
readonly CORE_JSON
FULL_PLAN=$(mktemp "${TMPDIR:-/tmp}/sre-demo-full.XXXXXX.tfplan")
readonly FULL_PLAN
FULL_JSON=$(mktemp "${TMPDIR:-/tmp}/sre-demo-full.XXXXXX.json")
readonly FULL_JSON
readonly REQUIRED_PROVIDERS=(
  Microsoft.AlertsManagement
  Microsoft.App
  Microsoft.Authorization
  Microsoft.ContainerRegistry
  Microsoft.ContainerService
  Microsoft.Dashboard
  Microsoft.Insights
  Microsoft.ManagedIdentity
  Microsoft.Monitor
  Microsoft.Network
  Microsoft.OperationalInsights
  Microsoft.PolicyInsights
)
readonly REQUIRED_FEATURES=(
  "Microsoft.Compute|EncryptionAtHost"
)

TEAMS_PLAN_VARS=(-var='enable_teams_bridge=true')
if [[ ! -f "$IAC_DIR/terraform.tfvars" ]]; then
  TEAMS_PLAN_VARS+=(
    -var='teams_tenant_id=00000000-0000-0000-0000-000000000002'
    -var='teams_team_id=00000000-0000-0000-0000-000000000003'
    -var='teams_channel_id=19:test@thread.tacv2'
    -var='teams_allowed_user_object_id=00000000-0000-0000-0000-000000000004'
  )
fi

cleanup() {
  rm -f "$CORE_PLAN" "$CORE_JSON" "$FULL_PLAN" "$FULL_JSON"
}
trap cleanup EXIT

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

command -v terraform >/dev/null 2>&1 || { printf '%s\n' 'Terraform is required.' >&2; exit 1; }
command -v az >/dev/null 2>&1 || { printf '%s\n' 'Azure CLI is required.' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf '%s\n' 'jq is required.' >&2; exit 1; }
command -v uvx >/dev/null 2>&1 || { printf '%s\n' 'uvx is required for the ephemeral Checkov scan.' >&2; exit 1; }

grep -F 'SecretName=bot-client-secret' "$IAC_DIR/modules/teams-bridge/main.tf" >/dev/null
grep -F 'SecretName=github-webhook-secret' "$IAC_DIR/modules/teams-bridge/main.tf" >/dev/null
grep -F 'SecretName=mcp-shared-key' "$IAC_DIR/modules/teams-bridge/main.tf" >/dev/null
if grep -R 'resource "azurerm_key_vault_secret"' "$IAC_DIR" >/dev/null; then
  printf '%s\n' 'Terraform must not store bridge secret values in state.' >&2
  exit 1
fi
grep -A 25 -F 'resource "azurerm_role_definition" "aks_node_reader"' \
  "$IAC_DIR/modules/sre-agent/main.tf" \
  | grep -F 'scope       = var.aks_id' >/dev/null
grep -A 25 -F 'resource "azurerm_role_definition" "aks_node_reader"' \
  "$IAC_DIR/modules/sre-agent/main.tf" \
  | grep -F 'assignable_scopes = [var.aks_id]' >/dev/null
grep -A 10 -F 'resource "azurerm_role_assignment" "aks_node_reader"' \
  "$IAC_DIR/modules/sre-agent/main.tf" \
  | grep -F 'scope                            = var.aks_id' >/dev/null

[[ -n "$EXPECTED_SUBSCRIPTION" ]] || {
  printf '%s\n' 'Set TF_VAR_subscription_id before running Terraform verification.' >&2
  exit 2
}
[[ -n "$EXPECTED_TENANT" ]] || {
  printf '%s\n' 'Set TF_VAR_tenant_id before running Terraform verification.' >&2
  exit 2
}

active_subscription=$(az account show --query id -o tsv)
active_tenant=$(az account show --query tenantId -o tsv)
[[ "$active_subscription" == "$EXPECTED_SUBSCRIPTION" ]] || {
  printf 'Azure CLI subscription %s does not match TF_VAR_subscription_id %s.\n' \
    "$active_subscription" "$EXPECTED_SUBSCRIPTION" >&2
  exit 1
}
[[ "$active_tenant" == "$EXPECTED_TENANT" ]] || {
  printf 'Azure CLI tenant %s does not match TF_VAR_tenant_id %s.\n' \
    "$active_tenant" "$EXPECTED_TENANT" >&2
  exit 1
}

for provider in "${REQUIRED_PROVIDERS[@]}"; do
  registration_state=$(az provider show --namespace "$provider" --query registrationState -o tsv)
  [[ "$registration_state" == "Registered" ]] || {
    printf 'Required Azure provider %s is %s, not Registered.\n' \
      "$provider" "$registration_state" >&2
    exit 1
  }
done

for entry in "${REQUIRED_FEATURES[@]}"; do
  namespace=${entry%%|*}
  feature=${entry#*|}
  registration_state=$(az feature show \
    --namespace "$namespace" \
    --name "$feature" \
    --query properties.state \
    -o tsv)
  [[ "$registration_state" == "Registered" ]] || {
    printf 'Required Azure feature %s/%s is %s, not Registered.\n' \
      "$namespace" "$feature" "$registration_state" >&2
    exit 1
  }
done

terraform -chdir="$IAC_DIR" fmt -check -recursive
terraform -chdir="$IAC_DIR" init -backend=false -input=false >/dev/null
terraform -chdir="$IAC_DIR" validate -no-color

uvx --index https://packagefeedproxy.microsoft.io/pypi/simple \
  --from checkov checkov \
  --directory "$IAC_DIR" \
  --framework terraform \
  --compact \
  --quiet \
  --output cli

terraform -chdir="$IAC_DIR" plan \
  -refresh=false \
  -lock=false \
  -input=false \
  -out="$CORE_PLAN" >/dev/null
terraform -chdir="$IAC_DIR" show -json "$CORE_PLAN" >"$CORE_JSON"

terraform -chdir="$IAC_DIR" plan \
  -refresh=false \
  -lock=false \
  -input=false \
  -out="$FULL_PLAN" \
  -var='enable_observability=true' \
  -var='enable_sre_agent=true' \
  "${TEAMS_PLAN_VARS[@]}" >/dev/null
terraform -chdir="$IAC_DIR" show -json "$FULL_PLAN" >"$FULL_JSON"

audit_plan_tags() {
  local plan_json=$1
  local missing
  missing=$(jq -r '
    .resource_changes[]
    | select(
        .change.after.tags? != null
        and (.change.after.tags | type) == "object"
        and .change.after.tags.SecurityControl != "Ignore"
      )
    | .address
  ' "$plan_json")
  [[ -z "$missing" ]] || {
    printf 'Planned resources missing SecurityControl=Ignore:\n%s\n' "$missing" >&2
    return 1
  }
  jq -e '
    .resource_changes[]
    | select(.type == "azurerm_kubernetes_cluster")
    | .change.after.default_node_pool[0].tags.SecurityControl == "Ignore"
  ' "$plan_json" >/dev/null
}

audit_plan_tags "$CORE_JSON"
audit_plan_tags "$FULL_JSON"

jq -e '[.resource_changes[] | select(.change.actions | index("delete"))] | length == 0' \
  "$CORE_JSON" >/dev/null
jq -e '[.resource_changes[] | select(.change.actions | index("delete"))] | length == 0' \
  "$FULL_JSON" >/dev/null

jq -e '
  [
    .resource_changes[]
    | select(.change.actions == ["forget"])
    | .address
  ]
  | all(.[];
      . == "module.teams_bridge[0].azapi_resource.blob_service"
      or . == "module.teams_bridge[0].azapi_resource.table_service"
    )
' "$FULL_JSON" >/dev/null

if ! jq -e '
    .resource_changes[]
    | select(.address == "module.sre_agent[0].azapi_resource.this")
    | .change.after.body.properties
    | .actionConfiguration.accessLevel == "Low"
      and .actionConfiguration.mode == "Review"
      and .incidentManagementConfiguration.type == "AzMonitor"
      and .incidentManagementConfiguration.connectionName == "azmonitor"
  ' "$FULL_JSON" >/dev/null; then
  jq -e '
    .resource_changes[]
    | select(.address == "module.sre_agent[0].azapi_resource.this")
    | .change.after_unknown.body.properties == true
  ' "$FULL_JSON" >/dev/null
  grep -A 25 -F 'body = {' "$IAC_DIR/modules/sre-agent/main.tf" \
    | grep -F 'accessLevel = "Low"' >/dev/null
  grep -A 25 -F 'body = {' "$IAC_DIR/modules/sre-agent/main.tf" \
    | grep -F 'mode        = "Review"' >/dev/null
  grep -A 25 -F 'body = {' "$IAC_DIR/modules/sre-agent/main.tf" \
    | grep -F 'connectionName = "azmonitor"' >/dev/null
  grep -A 25 -F 'body = {' "$IAC_DIR/modules/sre-agent/main.tf" \
    | grep -F 'type           = "AzMonitor"' >/dev/null
fi

jq -e '
  .resource_changes[]
  | select(.address == "module.teams_bridge[0].azurerm_function_app_flex_consumption.this")
  | .change.after
  | .runtime_name == "python"
    and .runtime_version == "3.12"
    and .storage_authentication_type == "UserAssignedIdentity"
    and .https_only == true
    and .webdeploy_publish_basic_authentication_enabled == false
' "$FULL_JSON" >/dev/null

if ! jq -e '
    .resource_changes[]
    | select(.address == "module.teams_bridge[0].azurerm_function_app_flex_consumption.this")
    | .change.after.app_settings
    | (.TEAMS_PERSONAL_CHAT_ENABLED as $enabled | ["true", "false"] | index($enabled))
      and (.TEAMS_PERSONAL_CHAT_ACCESS_MODE as $mode | ["allowed_user", "tenant"] | index($mode))
      and ((.TEAMS_PERSONAL_CHAT_TURNS_PER_HOUR | tonumber) >= 1)
      and ((.TEAMS_PERSONAL_CHAT_TURNS_PER_HOUR | tonumber) <= 100)
      and (.AZURE_SUBSCRIPTION_ID | type == "string" and length > 0)
      and (.ALERT_RESOLUTION_POLL_SECONDS == "30")
      and (.ALERT_RESOLUTION_TIMEOUT_MINUTES == "30")
      and (.ALERT_RESOLUTION_RETRY_MINUTES == "10")
  ' "$FULL_JSON" >/dev/null; then
  jq -e '
    .resource_changes[]
    | select(.address == "module.teams_bridge[0].azurerm_function_app_flex_consumption.this")
    | .change.after_unknown.app_settings == true
  ' "$FULL_JSON" >/dev/null
  grep -F 'TEAMS_PERSONAL_CHAT_ENABLED        = tostring(var.teams_personal_chat_enabled)' \
    "$IAC_DIR/modules/teams-bridge/main.tf" >/dev/null
  grep -F 'TEAMS_PERSONAL_CHAT_ACCESS_MODE    = var.teams_personal_chat_access_mode' \
    "$IAC_DIR/modules/teams-bridge/main.tf" >/dev/null
  grep -F 'TEAMS_PERSONAL_CHAT_TURNS_PER_HOUR = tostring(var.teams_personal_chat_turns_per_hour)' \
    "$IAC_DIR/modules/teams-bridge/main.tf" >/dev/null
  grep -F 'AZURE_SUBSCRIPTION_ID              = var.subscription_id' \
    "$IAC_DIR/modules/teams-bridge/main.tf" >/dev/null
  grep -F 'ALERT_RESOLUTION_POLL_SECONDS      = "30"' \
    "$IAC_DIR/modules/teams-bridge/main.tf" >/dev/null
  grep -F 'ALERT_RESOLUTION_TIMEOUT_MINUTES   = "30"' \
    "$IAC_DIR/modules/teams-bridge/main.tf" >/dev/null
  grep -F 'ALERT_RESOLUTION_RETRY_MINUTES     = "10"' \
    "$IAC_DIR/modules/teams-bridge/main.tf" >/dev/null
fi

jq -e '
  .resource_changes[]
  | select(.address == "module.teams_bridge[0].azapi_resource.storage_account")
  | .change.after.body.properties
  | .allowSharedKeyAccess == false
    and .allowBlobPublicAccess == false
    and .defaultToOAuthAuthentication == true
' "$FULL_JSON" >/dev/null

jq -e '
  [
    .resource_changes[]
    | select(.module_address == "module.teams_bridge[0]")
    | select(.type == "azurerm_role_assignment")
    | select(.name != "alert_reader")
    | .change.after.role_definition_name
  ] as $roles
  | [
      "Key Vault Secrets User",
      "SRE Agent Standard User",
      "Storage Account Contributor",
      "Storage Blob Data Owner",
      "Storage Queue Data Contributor",
      "Storage Table Data Contributor"
    ]
    | all(. as $role | $roles | index($role))
  | select($roles | all(
      . == "Key Vault Secrets User"
      or . == "Key Vault Secrets Officer"
      or . == "SRE Agent Standard User"
      or . == "Storage Account Contributor"
      or . == "Storage Blob Data Owner"
      or . == "Storage Queue Data Contributor"
      or . == "Storage Table Data Contributor"
    ))
' "$FULL_JSON" >/dev/null

jq -e '
  .resource_changes[]
  | select(.address == "module.teams_bridge[0].azurerm_role_definition.alert_reader")
  | .change.after
  | .scope == ("/subscriptions/" + env.TF_VAR_subscription_id)
    and .assignable_scopes == [("/subscriptions/" + env.TF_VAR_subscription_id)]
    and .permissions[0].actions == ["Microsoft.AlertsManagement/alerts/read"]
    and .permissions[0].not_actions == []
' "$FULL_JSON" >/dev/null

jq -e '
  .resource_changes[]
  | select(.address == "module.teams_bridge[0].azurerm_role_assignment.alert_reader")
  | .change.after
  | .scope == ("/subscriptions/" + env.TF_VAR_subscription_id)
    and .principal_type == "ServicePrincipal"
    and .skip_service_principal_aad_check == true
' "$FULL_JSON" >/dev/null

jq -e '
  [
    .resource_changes[]
    | select(.module_address == "module.sre_agent[0]")
    | select(.type == "azurerm_role_assignment")
    | select(.name != "aks_node_reader")
    | .change.after.role_definition_name
  ] as $roles
  | [
      "Reader",
      "Monitoring Reader",
      "Monitoring Contributor",
      "Log Analytics Reader",
      "Azure Kubernetes Service Cluster User Role",
      "Azure Kubernetes Service RBAC Reader"
    ]
    | all(. as $role | $roles | index($role))
  | select($roles | all(
      . == "Reader"
      or . == "Monitoring Reader"
      or . == "Monitoring Contributor"
      or . == "Log Analytics Reader"
      or . == "Azure Kubernetes Service Cluster User Role"
      or . == "Azure Kubernetes Service RBAC Reader"
      or . == "SRE Agent Administrator"
    ))
' "$FULL_JSON" >/dev/null

jq -e '
  .resource_changes[]
  | select(.address == "module.sre_agent[0].azurerm_role_definition.aks_node_reader")
  | .change
  | .after.permissions[0].actions == []
    and .after.permissions[0].not_actions == []
    and .after.permissions[0].data_actions == ["Microsoft.ContainerService/managedClusters/nodes/read"]
    and (.after.permissions[0].not_data_actions // []) == []
    and (
      (.after.scope == null and .after.assignable_scopes == null)
      or (
        (.after.scope | type) == "string"
        and .after.assignable_scopes == [.after.scope]
      )
    )
' "$FULL_JSON" >/dev/null

jq -e '
  .resource_changes[]
  | select(.address == "module.sre_agent[0].azurerm_role_assignment.aks_node_reader")
  | .change.after
  | .principal_type == "ServicePrincipal"
    and .skip_service_principal_aad_check == true
' "$FULL_JSON" >/dev/null

core_resources=$(jq '[.resource_changes[] | select(.change.actions != ["no-op"])] | length' "$CORE_JSON")
full_resources=$(jq '[.resource_changes[] | select(.change.actions != ["no-op"])] | length' "$FULL_JSON")
observability_resources=$(jq '[.resource_changes[] | select(.module_address == "module.observability[0]")] | length' "$FULL_JSON")
aks_monitoring_resources=$(jq '[.resource_changes[] | select(.module_address == "module.aks_monitoring[0]")] | length' "$FULL_JSON")
sre_agent_resources=$(jq '
  [.resource_changes[]
   | select(.module_address == "module.sre_agent[0]")
   | select(.change.actions != ["forget"])]
  | length
' "$FULL_JSON")
teams_bridge_resources=$(jq '
  [.resource_changes[]
   | select(.module_address == "module.teams_bridge[0]")
   | select(.change.actions != ["forget"])]
  | length
' "$FULL_JSON")

[[ "$observability_resources" == "5" ]] || {
  printf 'Expected 5 observability resources, found %s.\n' "$observability_resources" >&2
  exit 1
}
[[ "$aks_monitoring_resources" == "9" ]] || {
  printf 'Expected 9 AKS monitoring resources, found %s.\n' "$aks_monitoring_resources" >&2
  exit 1
}
(( sre_agent_resources >= 10 && sre_agent_resources <= 11 )) || {
  printf 'Expected 10-11 SRE Agent resources, found %s.\n' "$sre_agent_resources" >&2
  exit 1
}
(( teams_bridge_resources >= 20 && teams_bridge_resources <= 21 )) || {
  printf 'Expected 20-21 Teams bridge resources, found %s.\n' "$teams_bridge_resources" >&2
  exit 1
}
(( full_resources >= core_resources )) || {
  printf 'Full plan resource count %s is smaller than core plan count %s.\n' \
    "$full_resources" "$core_resources" >&2
  exit 1
}

printf 'PASS: Terraform foundation is valid and plans without applying.\n'
printf 'Providers: AzureRM 4.81, AzureAD 3.9, AzAPI 2.11, random 3.9\n'
printf 'Current core plan: %s resources\n' "$core_resources"
printf 'Current full plan: %s resources (%s observability, %s AKS monitoring, %s SRE Agent, %s Teams bridge)\n' \
  "$full_resources" "$observability_resources" "$aks_monitoring_resources" "$sre_agent_resources" "$teams_bridge_resources"
printf 'Security: zero destroys, Checkov and RBAC allowlist pass\n'
