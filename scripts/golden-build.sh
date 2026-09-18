#!/usr/bin/env bash
# Builds the Rocky Linux 9.8 Server (no GUI) golden image with Packer, records SHA-256 of its VMX/VMDK, makes them read-only and registers
# the VM in vmrest so Terraform can clone it. Images are immutable: an existing version is never rebuilt.
# Usage: scripts/golden-build.sh [version]   (default: YYYYMMDD-1)
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
# The Packer log contains the rendered Kickstart (password hash); keep logs and image files owner-only.
umask 077

VERSION="${1:-$(date +%Y%m%d)-1}"
NAME="k3slab-golden-rocky98"
VM_NAME="$NAME-$VERSION"
ISO="$LAB_ISO_DIR/$PIN_ROCKY_ISO_FILENAME"
OUT="$LAB_IMAGE_DIR/$VM_NAME"
TEMPLATES="$REPO_ROOT/infra/packer/templates"
LOG="$LAB_LOG_DIR/golden-build-$VM_NAME.log"

[[ -f "$ISO" ]] || die "missing $ISO (run scripts/fetch-rocky-iso.sh first)"
[[ "$(stat -c %s "$ISO")" == "$PIN_ROCKY_ISO_SIZE" ]] || die "$ISO has the wrong size"
[[ "$(sha256sum "$ISO" | cut -d' ' -f1)" == "$PIN_ROCKY_ISO_SHA256" ]] || die "$ISO failed SHA-256 verification"
[[ ! -e "$OUT" ]] || die "$OUT already exists; images are immutable, pass a new version"
load_vmrest_env
# shellcheck disable=SC1091
source "$LAB_SECRETS_DIR/golden-console.env"
mkdir -p "$LAB_LOG_DIR"

# Static build address on vmnet8 (below its .128-.254 DHCP pool); the NAT gateway is .2 on VMware desktop hypervisors.
vmnet8_cidr=$(ip -4 -o addr show dev vmnet8 | awk '{print $4}')
[[ "$vmnet8_cidr" == */24 ]] || die "expected a /24 on vmnet8, found '$vmnet8_cidr'"
net3=${vmnet8_cidr%.*}
export PKR_VAR_build_ip="${BUILD_IP:-$net3.10}"
export PKR_VAR_build_gateway="$net3.2"
if ping -c 2 -W 1 "$PKR_VAR_build_ip" >/dev/null 2>&1; then
  die "build address $PKR_VAR_build_ip already answers on vmnet8; pick another with BUILD_IP=..."
fi

export PKR_VAR_image_version="$VERSION"
export PKR_VAR_image_root="$LAB_IMAGE_DIR"
export PKR_VAR_iso_path="$ISO"
export PKR_VAR_admin_password_hash="$GOLDEN_CONSOLE_PASSWORD_SHA512"
PKR_VAR_ssh_public_key="$(cat "$LAB_SECRETS_DIR/ansible_ed25519.pub")"
export PKR_VAR_ssh_public_key
export PKR_VAR_ssh_private_key_file="$LAB_SECRETS_DIR/ansible_ed25519"

log "packer init + validate"
packer init "$TEMPLATES"
packer validate "$TEMPLATES"

log "packer build $VM_NAME (headless; log: $LOG)"
PACKER_LOG=1 PACKER_LOG_PATH="$LOG" packer build -color=false "$TEMPLATES"

# Packer writes every VMX key in lower case. VMware ignores key case, but vmrest's /params lookups do not, and the
# provider finds VMs (and reads their names) through /params/displayName; without this, lookups return "".
sed -i 's/^displayname = /displayName = /' "$OUT/$VM_NAME.vmx"
grep -q '^displayName = ' "$OUT/$VM_NAME.vmx" || die "no displayName in $OUT/$VM_NAME.vmx"

log "record SHA-256, lock the image read-only"
(cd "$OUT" && sha256sum ./*.vmx ./*.vmdk >SHA256SUMS)
chmod 0444 "$OUT"/*.vmx "$OUT"/*.vmdk
cat "$OUT/SHA256SUMS"

log "register in vmrest as '$VM_NAME'"
code=$(vmrest_api -o /dev/null -w '%{http_code}' -H "$VMREST_CT" -X POST \
  -d "{\"name\":\"$VM_NAME\",\"path\":\"$OUT/$VM_NAME.vmx\"}" "$VMREST_BASE/vms/registration")
[[ "$code" == "201" ]] || die "vmrest registration returned HTTP $code"
ID=$(vmrest_find_id_by_name "$VM_NAME") || die "registration did not show up in vmrest"
NIC=$(vmrest_api "$VMREST_BASE/vms/$ID/nic" | jq -c '[.nics[] | {type, vmnet}]')
[[ "$NIC" == '[{"type":"custom","vmnet":"vmnet8"}]' ]] || die "golden NIC is $NIC, expected custom/vmnet8"

jq -n --arg name "$VM_NAME" --arg id "$ID" --arg iso "$(basename "$ISO")" --arg os "$PIN_GUEST_OS" --arg profile "server-product-environment" --arg created "$(date -Is)" \
  --arg packer "$(packer version | head -1)" --rawfile sums "$OUT/SHA256SUMS" \
  '{name: $name, vmrest_id: $id, iso: $iso, os: $os, package_profile: $profile, graphical_environment: false, created: $created, packer: $packer, sha256sums: $sums}' >"$OUT/image.json"
log "golden image ready: $VM_NAME (vmrest id $ID); set golden_vm_name in infra/terraform accordingly"
