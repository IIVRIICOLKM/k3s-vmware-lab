#!/usr/bin/env bash
# Terraform wrapper for infra/terraform: injects vmrest credentials as sensitive variables, keeps state in the XDG
# state dir, forces -parallelism=1 (vmrest cannot serve concurrent changes) and backs the state up before changes.
# Usage: scripts/tf.sh <terraform args...>
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

load_vmrest_env
# The state can contain sensitive values: create it, its backups and plan files owner-only.
umask 077
export TF_VAR_vm_root_dir="$LAB_VM_DIR"
export TF_IN_AUTOMATION=1
for cmd in plan apply destroy refresh import; do
  export "TF_CLI_ARGS_$cmd=-parallelism=1"
done

TFDIR="$REPO_ROOT/infra/terraform"
STATE="$LAB_STATE_DIR/terraform/terraform.tfstate"
BACKUPS="$LAB_STATE_DIR/terraform/backups"

case "${1:-}" in
init)
  shift
  exec terraform -chdir="$TFDIR" init -input=false -backend-config="path=$STATE" "$@"
  ;;
apply | destroy | import | state | taint | untaint)
  if [[ -s "$STATE" ]]; then
    mkdir -p "$BACKUPS"
    cp "$STATE" "$BACKUPS/terraform.tfstate.$(date +%Y%m%dT%H%M%S)"
    find "$BACKUPS" -name 'terraform.tfstate.*' -printf '%T@ %p\n' | sort -rn | tail -n +31 | cut -d' ' -f2- | xargs -r rm -f
  fi
  ;;
esac
exec terraform -chdir="$TFDIR" "$@"
