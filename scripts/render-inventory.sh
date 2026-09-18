#!/usr/bin/env bash
# Renders the Ansible inventory of the Terraform-managed VMs into infra/ansible/inventories/lab/.generated/.
# Terraform supplies names, vmrest ids and groups; guest IPs come from vmrest (/vms/{id}/ip, reported by
# open-vm-tools) because the provider's ip attribute is only a placeholder.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
load_vmrest_env

OUT_DIR="$REPO_ROOT/infra/ansible/inventories/lab/.generated"
OUT="$OUT_DIR/terraform.yml"
TIMEOUT="${IP_TIMEOUT_SECONDS:-300}"

nodes=$("$REPO_ROOT/scripts/tf.sh" output -json nodes)
[[ "$(jq 'length' <<<"$nodes")" -gt 0 ]] || die "Terraform reports no nodes; run scripts/cluster-apply.sh first"

hosts="{}"
for name in $(jq -r 'keys[]' <<<"$nodes"); do
  id=$(jq -r --arg n "$name" '.[$n].id' <<<"$nodes")
  ip=""
  deadline=$((SECONDS + TIMEOUT))
  while ((SECONDS < deadline)); do
    ip=$(vmrest_api "$VMREST_BASE/vms/$id/ip" | jq -r '.ip // empty' 2>/dev/null || true)
    [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && break
    ip=""
    sleep 5
  done
  [[ -n "$ip" ]] || die "$name ($id): no guest IP from vmrest after ${TIMEOUT}s (is the VM on and open-vm-tools running?)"
  log "$name -> $ip"
  hosts=$(jq --arg n "$name" --arg ip "$ip" --arg id "$id" '. + {($n): {ansible_host: $ip, vmrest_id: $id}}' <<<"$hosts")
done

# Clones mint new SSH host keys, so a rebuilt node reuses an address with a different key; forget old keys for these IPs.
KNOWN_HOSTS="$LAB_STATE_DIR/ansible/known_hosts"
mkdir -p "$(dirname "$KNOWN_HOSTS")"
touch "$KNOWN_HOSTS"
for ip in $(jq -r '.[].ansible_host' <<<"$hosts"); do
  ssh-keygen -R "$ip" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true
done
rm -f "$KNOWN_HOSTS.old"

mkdir -p "$OUT_DIR"
# JSON is valid YAML, so the yaml inventory plugin reads this file as-is.
jq -n --argjson nodes "$nodes" --argjson hosts "$hosts" '
  {all: {children: (
    {vms: {hosts: $hosts}} +
    ([$nodes | to_entries[] | .key as $h | .value.ansible_groups[] | {group: ., host: $h}]
     | group_by(.group)
     | map({key: .[0].group, value: {hosts: (map({key: .host, value: {}}) | from_entries)}})
     | from_entries)
  )}}' >"$OUT.tmp"
mv "$OUT.tmp" "$OUT"
log "wrote $OUT"
