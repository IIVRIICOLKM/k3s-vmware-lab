#!/usr/bin/env bash
# Registers every Terraform-managed VM in the VMware Workstation UI library.
# The vmworkstation provider creates and powers VMs through vmrest, but clones can be absent from
# ~/.vmware/inventory.vmls. This script reconciles that UI-only inventory without touching VM state.
# Usage: scripts/register-vms.sh
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  sed -n '2,5s/^# \{0,1\}//p' "$0"
  exit 0
fi
(($# == 0)) || die "scripts/register-vms.sh takes no arguments (see --help)"

inventory="$HOME/.vmware/inventory.vmls"

inventory_path_count() {
  local vmx=$1
  if [[ ! -f "$inventory" ]]; then
    printf '0\n'
    return
  fi
  sed -n 's/^vmlist[0-9][0-9]*\.config = "\(.*\)"$/\1/p' "$inventory" |
    awk -v path="$vmx" '$0 == path {count++} END {print count + 0}'
}

load_vmrest_env
nodes=$("$REPO_ROOT/scripts/tf.sh" output -json nodes)
jq -e 'type == "object" and length > 0' <<<"$nodes" >/dev/null ||
  die "Terraform output 'nodes' is empty; create the VMs before registering them"

registered=0
already_present=0
while IFS= read -r name; do
  vmx=$(jq -er --arg name "$name" '.[$name].path | select(type == "string" and length > 0)' <<<"$nodes")
  [[ -f "$vmx" ]] || die "managed VMX is missing for $name: $vmx"

  count=$(inventory_path_count "$vmx")
  ((count <= 1)) || die "$name appears $count times in $inventory; remove duplicate UI library entries before retrying"
  if ((count == 1)); then
    log "Workstation UI: $name already registered"
    already_present=$((already_present + 1))
    continue
  fi

  payload=$(jq -cn --arg name "$name" --arg path "$vmx" '{name:$name,path:$path}')
  response=$(vmrest_api -w $'\n%{http_code}' -H "$VMREST_CT" -X POST --data "$payload" "$VMREST_BASE/vms/registration")
  code=${response##*$'\n'}
  body=${response%$'\n'*}
  [[ "$code" == 201 ]] || die "failed to register $name in the Workstation UI (HTTP $code): $body"
  jq -e --arg path "$vmx" '.path == $path and (.id | type == "string" and length > 0)' <<<"$body" >/dev/null ||
    die "vmrest returned an unexpected registration response for $name: $body"
  [[ "$(inventory_path_count "$vmx")" == 1 ]] || die "vmrest registered $name but $inventory was not updated exactly once"

  log "Workstation UI: registered $name"
  registered=$((registered + 1))
done < <(jq -r 'keys[]' <<<"$nodes")

log "Workstation UI inventory ready: $registered added, $already_present already present"
