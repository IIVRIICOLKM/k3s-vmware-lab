# shellcheck shell=bash
# Shared helpers for k3s-vmware-lab scripts. Source this file; do not execute it.

LAB_NAME="k3s-vmware-lab"
LAB_DATA_DIR="${LAB_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$LAB_NAME}"
LAB_STATE_DIR="${LAB_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/$LAB_NAME}"
LAB_CONFIG_DIR="${LAB_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/$LAB_NAME}"
LAB_SECRETS_DIR="$LAB_CONFIG_DIR/secrets"
LAB_LOG_DIR="$LAB_STATE_DIR/logs"
LAB_VM_DIR="$LAB_DATA_DIR/vms"
LAB_IMAGE_DIR="$LAB_DATA_DIR/images"
LAB_ISO_DIR="$LAB_DATA_DIR/iso-cache"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

VMREST_HOST="127.0.0.1"
VMREST_PORT="8697"
VMREST_BASE="https://$VMREST_HOST:$VMREST_PORT/api"
VMREST_ACCEPT="Accept: application/vnd.vmware.vmw.rest-v1+json"
VMREST_CT="Content-Type: application/vnd.vmware.vmw.rest-v1+json"

# shellcheck source=pinned-versions.env
source "$REPO_ROOT/scripts/lib/pinned-versions.env"

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "FATAL: $*" >&2; exit 1; }

load_vmrest_env() {
  local f="$LAB_SECRETS_DIR/vmrest.env"
  [[ -f "$f" ]] || die "missing $f (see README: vmrest credentials)"
  [[ "$(stat -c %a "$f")" == "600" ]] || die "$f must be mode 600"
  # shellcheck disable=SC1090
  source "$f"
  : "${VMWS_USERNAME:?}" "${VMWS_PASSWORD:?}" "${VMWS_ENDPOINT:?}"
  # The provider marks endpoint/username/password as required, so its VMWS_* env fallback
  # never runs; Terraform has to receive them as (sensitive) input variables instead.
  export TF_VAR_vmws_endpoint="$VMWS_ENDPOINT" TF_VAR_vmws_username="$VMWS_USERNAME" TF_VAR_vmws_password="$VMWS_PASSWORD"
}

# Credentials are fed through stdin so they never show up in the process list.
vmrest_api() {
  printf 'user = "%s:%s"\n' "$VMWS_USERNAME" "$VMWS_PASSWORD" |
    curl --silent --show-error --config - --cacert "$LAB_SECRETS_DIR/vmrest.crt" -H "$VMREST_ACCEPT" "$@"
}

vmrest_find_id_by_name() {
  local name=$1 id
  for id in $(vmrest_api "$VMREST_BASE/vms" | jq -r '.[].id'); do
    if [[ "$(vmrest_api "$VMREST_BASE/vms/$id/params/displayName" | jq -r '.value')" == "$name" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done
  return 1
}

vmrest_power_state() { vmrest_api "$VMREST_BASE/vms/$1/power" | jq -r '.power_state'; }

workstation_default_vm_dir() {
  local v
  v=$(sed -n 's/^prefvmx\.defaultVMPath = "\(.*\)"$/\1/p' "$HOME/.vmware/preferences" 2>/dev/null | tail -1)
  printf '%s\n' "${v:-$HOME/vmware}"
}
