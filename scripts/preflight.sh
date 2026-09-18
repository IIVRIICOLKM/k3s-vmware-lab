#!/usr/bin/env bash
# Read-only host checks for the k3s-vmware-lab workflow. Changes nothing; exits 1 on any FAIL.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

fails=0
warns=0
pass() { printf '  [PASS] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  [FAIL] %s\n' "$*"; fails=$((fails + 1)); }
info() { printf '  [INFO] %s\n' "$*"; }
check_eq() { if [[ "$2" == "$3" ]]; then pass "$1: $2"; else fail "$1: found '$2', pinned '$3'"; fi; }

echo "== Host"
[[ "$(uname -s)/$(uname -m)" == "Linux/x86_64" ]] && pass "Linux x86_64, kernel $(uname -r)" || fail "unsupported host $(uname -s)/$(uname -m)"

echo "== Pinned tool versions (status: $PIN_STATUS${PIN_VERIFIED_ON:+, verified $PIN_VERIFIED_ON})"
check_eq "VMware Workstation" "$(vmware --version 2>/dev/null | awk '{print $3" "$4}')" "$PIN_WORKSTATION_VERSION $PIN_WORKSTATION_BUILD"
check_eq "vmrest" "$(vmrest -v 2>/dev/null | awk '/^vmrest /{print $2}')" "$PIN_VMREST_VERSION"
check_eq "terraform" "$(terraform version -json 2>/dev/null | jq -r .terraform_version)" "$PIN_TERRAFORM_VERSION"
check_eq "packer" "$(packer version 2>/dev/null | awk 'NR==1{sub(/^v/,"",$2); print $2}')" "$PIN_PACKER_VERSION"
# ansible refuses to start when stdio handles are non-blocking, so give it plain files/pipes.
check_eq "ansible-core" "$(ansible --version </dev/null 2>/dev/null | awk -F'[][ ]+' 'NR==1{print $3}')" "$PIN_ANSIBLE_CORE_VERSION"
info "guest image target: $PIN_GUEST_OS"

echo "== VMware kernel modules"
running=$(uname -r)
for m in vmmon vmnet; do
  lsmod | awk '{print $1}' | grep -qx "$m" && pass "$m loaded" || fail "$m not loaded"
  [[ -f "/lib/modules/$running/misc/$m.ko" ]] && pass "$m.ko built for $running" ||
    fail "$m.ko missing for $running (maintenance: sudo vmware-modconfig --console --install-all)"
done
# Workstation does not rebuild its modules on kernel updates; this is what made vmware.service fail at boot on 2026-09-11.
newest=$(find /lib/modules -mindepth 1 -maxdepth 1 -printf '%f\n' | sort -V | tail -1)
if [[ "$newest" != "$running" && ! -f "/lib/modules/$newest/misc/vmmon.ko" ]]; then
  warn "newest installed kernel $newest has no vmmon.ko: VMware will fail after the next reboot until modules are rebuilt"
fi
if lsmod | awk '{print $1}' | grep -qx kvm_amd; then
  info "kvm_amd loaded (kvm.enable_virt_at_load=$(cat /sys/module/kvm/parameters/enable_virt_at_load 2>/dev/null || echo n/a)); coexistence with VMware $PIN_WORKSTATION_VERSION verified 2026-09-18"
fi

echo "== VMware NAT network (vmnet8)"
v8=$(ip -4 -o addr show dev vmnet8 2>/dev/null | awk '{print $4}')
[[ -n "$v8" ]] && pass "vmnet8 up with $v8" || fail "vmnet8 has no IPv4 address"
pgrep -f 'vmnet-dhcpd .*vmnet8' >/dev/null && pass "vmnet-dhcpd (vmnet8) running" || fail "vmnet-dhcpd for vmnet8 not running"
pgrep -x vmnet-natd >/dev/null && pass "vmnet-natd running" || fail "vmnet-natd not running"

echo "== vmrest"
listeners=$(ss -Hltn "( sport = :$VMREST_PORT )" | awk '{print $4}')
if [[ -z "$listeners" ]]; then
  fail "vmrest not listening on :$VMREST_PORT (start it with scripts/vmrest-start.sh)"
elif grep -qvE "^(127\.0\.0\.1|\[::1\]):$VMREST_PORT$" <<<"$listeners"; then
  fail "vmrest reachable beyond loopback: $(tr '\n' ' ' <<<"$listeners")"
else
  pass "vmrest bound to loopback only ($listeners)"
fi
if [[ -f "$LAB_SECRETS_DIR/vmrest.env" ]]; then
  load_vmrest_env
  code=$(vmrest_api -o /dev/null -w '%{http_code}' "$VMREST_BASE/vms" 2>/dev/null || true)
  [[ "$code" == "200" ]] && pass "vmrest HTTPS auth OK (certificate verified)" || fail "vmrest auth/TLS check returned HTTP ${code:-none}"
else
  fail "missing $LAB_SECRETS_DIR/vmrest.env"
fi

echo "== Secrets and local paths"
[[ "$(stat -c %a "$LAB_SECRETS_DIR" 2>/dev/null)" == "700" ]] && pass "$LAB_SECRETS_DIR is 0700" || fail "$LAB_SECRETS_DIR must exist with mode 0700"
while IFS= read -r f; do
  [[ "$(stat -c %a "$f")" == "600" ]] || fail "$f is not 0600"
done < <(find "$LAB_SECRETS_DIR" -type f 2>/dev/null)
for d in "$LAB_VM_DIR" "$LAB_IMAGE_DIR" "$LAB_ISO_DIR" "$LAB_STATE_DIR/terraform"; do
  [[ -d "$d" ]] && pass "exists: $d" || fail "missing: $d"
done
tf_state_dir="$LAB_STATE_DIR/terraform"
[[ "$(stat -c %a "$tf_state_dir" 2>/dev/null)" == "700" ]] && pass "$tf_state_dir is 0700" || fail "$tf_state_dir must be mode 0700 (state may hold sensitive values)"
while IFS= read -r f; do
  [[ "$(stat -c %a "$f")" == "600" ]] || fail "$f is not 0600"
done < <(find "$tf_state_dir" -type f -name 'terraform.tfstate*' 2>/dev/null)
# vmrest's clone API has no destination argument; clones always land in Workstation's default VM path.
default_vm_dir=$(workstation_default_vm_dir)
check_eq "Workstation prefvmx.defaultVMPath" "$default_vm_dir" "$LAB_VM_DIR"

echo "== Rocky Linux installation media"
rocky_iso="$LAB_ISO_DIR/$PIN_ROCKY_ISO_FILENAME"
if [[ -f "$rocky_iso" ]]; then
  check_eq "Rocky ISO size" "$(stat -c %s "$rocky_iso")" "$PIN_ROCKY_ISO_SIZE"
  check_eq "Rocky ISO SHA-256" "$(sha256sum "$rocky_iso" | cut -d' ' -f1)" "$PIN_ROCKY_ISO_SHA256"
else
  info "Rocky ISO not downloaded yet (scripts/fetch-rocky-iso.sh)"
fi
legacy=$(find "$LAB_IMAGE_DIR" "$LAB_VM_DIR" "$LAB_ISO_DIR" -maxdepth 3 -iname '*ubuntu*' -print -quit 2>/dev/null)
[[ -z "$legacy" ]] && pass "no active Ubuntu guest artifacts" || fail "legacy Ubuntu guest artifact remains: $legacy"

echo "== Capacity"
avail_gb=$(df -BG --output=avail "$LAB_DATA_DIR" | tail -1 | tr -dc '0-9')
((avail_gb >= 40)) && pass "free disk under $LAB_DATA_DIR: ${avail_gb}G" || warn "only ${avail_gb}G free under $LAB_DATA_DIR (golden image + 3 VMs need ~40G)"
mem_gb=$(awk '/MemAvailable/{printf "%d", $2/1048576}' /proc/meminfo)
((mem_gb >= 14)) && pass "available memory: ${mem_gb}G" || warn "available memory ${mem_gb}G; the 3-VM cluster reserves 12G"

echo "== Terraform provider lock"
lock="$REPO_ROOT/infra/terraform/.terraform.lock.hcl"
if [[ -f "$lock" ]]; then
  grep -q "zh:$PIN_PROVIDER_VMWORKSTATION_ZIP_SHA256_LINUX_AMD64" "$lock" &&
    pass "lock file pins provider zip sha256 ${PIN_PROVIDER_VMWORKSTATION_ZIP_SHA256_LINUX_AMD64:0:12}..." ||
    fail "lock file does not contain the pinned provider hash"
else
  info "no infra/terraform/.terraform.lock.hcl yet"
fi

echo "== Packer plugin"
while read -r sum _ ver _ bin; do
  f="$HOME/.config/packer/plugins/github.com/hashicorp/vmware/$bin"
  if [[ ! -f "$f" ]]; then
    info "packer plugin $ver not installed yet (packer init infra/packer/templates)"
  elif [[ "$(sha256sum "$f" | cut -d' ' -f1)" == "$sum" ]]; then
    pass "packer plugin vmware $ver matches infra/packer/plugins.sha256"
  else
    fail "packer plugin $bin differs from infra/packer/plugins.sha256"
  fi
done < <(grep -v '^#' "$REPO_ROOT/infra/packer/plugins.sha256")

echo "== Golden images (must stay unchanged and read-only)"
shopt -s nullglob
images=("$LAB_IMAGE_DIR"/*/SHA256SUMS)
((${#images[@]})) || info "no golden image built yet (scripts/golden-build.sh)"
for sums in "${images[@]}"; do
  dir=$(dirname "$sums")
  [[ "$(basename "$dir")" == k3slab-golden-rocky98-* ]] && pass "$(basename "$dir"): Rocky 9.8 image name" || fail "unexpected golden image: $(basename "$dir")"
  (cd "$dir" && sha256sum --quiet -c SHA256SUMS >/dev/null 2>&1) && pass "$(basename "$dir"): files match SHA256SUMS" || fail "$(basename "$dir"): files changed since the build"
  jq -e '.os == "Rocky Linux 9.8 Server (no GUI)" and .package_profile == "server-product-environment" and .graphical_environment == false' "$dir/image.json" >/dev/null 2>&1 &&
    pass "$(basename "$dir"): Server profile, GUI disabled" || fail "$(basename "$dir"): image metadata does not prove Rocky Server/no-GUI"
  writable=$(find "$dir" -maxdepth 1 \( -name '*.vmx' -o -name '*.vmdk' \) -perm /222 -printf '%f ')
  [[ -z "$writable" ]] && pass "$(basename "$dir"): VMX/VMDK are read-only" || fail "$(basename "$dir"): writable golden files: $writable"
done
shopt -u nullglob

echo "== Remote-session guard"
remote=$(pgrep -a -f 'teamviewerd|krfb|sshd: .*@' 2>/dev/null | awk '{print $2}' | xargs -r -n1 basename | sort -u | tr '\n' ' ')
[[ -n "$remote" ]] && info "remote access active ($remote); these scripts never touch host networking or services" || true

echo
echo "preflight: $fails FAIL, $warns WARN"
((fails == 0))
