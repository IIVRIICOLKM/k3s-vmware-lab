#!/usr/bin/env bash
# Starts vmrest over HTTPS on 127.0.0.1 only, as the current user, and verifies the binding.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

if ss -Hltn "( sport = :$VMREST_PORT )" | grep -q .; then
  log "something already listens on :$VMREST_PORT; not starting a second vmrest"
  ss -Hltn "( sport = :$VMREST_PORT )"
  exit 0
fi
for f in vmrest.crt vmrest.key; do [[ -f "$LAB_SECRETS_DIR/$f" ]] || die "missing $LAB_SECRETS_DIR/$f"; done
mkdir -p "$LAB_LOG_DIR"
setsid -f nohup vmrest -c "$LAB_SECRETS_DIR/vmrest.crt" -k "$LAB_SECRETS_DIR/vmrest.key" -p "$VMREST_PORT" \
  >"$LAB_LOG_DIR/vmrest.log" 2>&1 </dev/null

for _ in $(seq 20); do
  listeners=$(ss -Hltn "( sport = :$VMREST_PORT )" | awk '{print $4}')
  [[ -n "$listeners" ]] && break
  sleep 0.5
done
[[ -n "${listeners:-}" ]] || die "vmrest did not start; see $LAB_LOG_DIR/vmrest.log"
# vmrest 1.3.1 has no bind-address flag; refuse to leave it running if it ever binds beyond loopback.
if grep -qvE "^(127\.0\.0\.1|\[::1\]):$VMREST_PORT$" <<<"$listeners"; then
  pkill -x vmrest || true
  die "vmrest bound beyond loopback ($listeners); stopped it"
fi
log "vmrest listening on $listeners (HTTPS)"
