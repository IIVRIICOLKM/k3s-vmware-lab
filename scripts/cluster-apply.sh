#!/usr/bin/env bash
# Applies infra/terraform in two phases, because elsudano/vmworkstation 2.0.1 fails when it creates a VM powered on:
#   1) VMs that are about to be created (or replaced) get state "off"; existing VMs keep their desired state.
#   2) A normal apply then powers the new VMs on.
#   3) Every managed VM is registered in the VMware Workstation UI library.
# Usage: scripts/cluster-apply.sh [-auto-approve] [-replace=ADDR ...] [-var ...]
#   -replace only applies to phase 1 (otherwise the VM would be replaced twice); -auto-approve is not given to plan.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
TF="$REPO_ROOT/scripts/tf.sh"

plan_args=()
final_args=()
for a in "$@"; do
  [[ "$a" == -auto-approve ]] || plan_args+=("$a")
  [[ "$a" == -replace=* ]] || final_args+=("$a")
done

PLAN="$LAB_STATE_DIR/terraform/cluster-apply.tfplan"
"$TF" plan -input=false -out="$PLAN" "${plan_args[@]}" >/dev/null
new=$("$TF" show -json "$PLAN" | jq -c '[.resource_changes[]
  | select(.type == "vmworkstation_virtual_machine" and (.change.actions | index("create")))
  | .index]')
rm -f "$PLAN"

if [[ "$new" != "[]" ]]; then
  overrides=$(jq -c 'map({(.): "off"}) | add' <<<"$new")
  log "phase 1: creating $new powered off"
  "$TF" apply -input=false -var "power_state_overrides=$overrides" "$@"
fi
log "phase 2: apply desired power state"
"$TF" apply -input=false "${final_args[@]}"
"$REPO_ROOT/scripts/register-vms.sh"
