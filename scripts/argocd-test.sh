#!/usr/bin/env bash
# Verifies Git-driven deployment with Argo CD (proposal slide on CI/CD, weeks 11-13): the inference service is synced from
# Git, a hand-made change is reverted (self-heal), a values commit becomes a new deployed revision, and the previous
# revision can be restored (rollback). Starts ONE inference pod on the GPU and removes it at the end.
# Usage: scripts/argocd-test.sh [--keep]    (--keep leaves the Application and its GPU pod running)
# Needs: scripts/argocd-deploy.sh up done. Report: docs/labs/argocd-<date>.md
#
# [한국어 설명] Argo CD가 "Git에 적힌 상태 = 클러스터 상태"를 지키는지 실제로 확인하고 보고서로 남긴다.
#   ① 처음 동기화  : Application을 만들면 추론 파드가 gpu-host에서 Ready가 되고 응답하는지
#   ② 자가 치유    : 손으로 replicas를 2로 바꾸면(그리고 Service를 지우면) Argo CD가 Git 값으로 되돌리는지
#   ③ 새 리비전    : values 파일(infer.maxBatch)을 Git에 커밋하면 새 리비전이 자동 배포되는지
#   ④ 롤백         : 이전 리비전으로 되돌린다. (a) `argocd app rollback`(자동 동기화를 잠시 끄고) (b) Git revert(GitOps 방식)
#   ⑤ 메모리 사용량 기록, 끝나면 Application을 지워 GPU 파드를 내린다.
#   [주의] GPU를 1장 쓴다(추론 파드). 총괄의 승인을 받은 뒤 실행할 것. 학습 Job이 GPU를 쓰는 중이면 추론 파드가 Pending이라 실패한다.
#   [실패하면] 우회하지 않고 멈춘다. 멈춰도 종료할 때 Application을 지워 GPU를 돌려준다(--keep이면 지우지 않음).
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 인자와 상수 ---
# sed -n '2,6s/^# \{0,1\}//p' "$0" : 이 파일 2~6번째 줄(영문 설명)을 도움말로 출력
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  sed -n '2,6s/^# \{0,1\}//p' "$0"
  exit 0
fi
KEEP=0
[[ "${1:-}" != --keep ]] || KEEP=1
ARGO_NS="argocd"
APP_NS="k3slab-apps"
GIT_NS="k3slab-system"
APP="infer"                        # Application 이름 = Helm 릴리스 이름 = Deployment·Service 이름
VALUES_FILE="charts/k3slab-workload/values-infer-argocd.yaml"
DEPLOY_SH="$REPO_ROOT/scripts/argocd-deploy.sh"
SOURCE_SH="$REPO_ROOT/scripts/argocd-source.sh"
KUBECONFIG_FILE="$LAB_SECRETS_DIR/kubeconfig"
REPORT="$REPO_ROOT/docs/labs/argocd-$(date +%Y%m%d-%H%M).md"
PASS=0
FAIL=0
APP_STARTED=0
WORK=$(mktemp -d)
mkdir -p "$(dirname "$REPORT")"

# k : 이 클러스터용 kubectl (K3S_CONFIG_FILE=/dev/null은 k3s 링크의 권한 경고 제거)
k() { K3S_CONFIG_FILE=/dev/null KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"; }
# md 줄... : 보고서 끝에 줄 추가 / block "제목" 내용 : 제목과 코드 블록을 추가
md() { printf '%s\n' "$@" >>"$REPORT"; }
block() { md "" "**$1**" "" '```text' "$2" '```'; }
# check "설명" 명령... : 성공하면 PASS, 아니면 FAIL로 집계해 보고서에 남김
check() {
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); md "" "- ✅ **PASS** — $desc"; log "PASS $desc"
  else
    FAIL=$((FAIL + 1)); md "" "- ❌ **FAIL** — $desc"; log "FAIL $desc"
  fi
}
# cleanup : 종료할 때 (--keep이 아니면) Application을 지워 GPU 파드를 내리고 임시 폴더를 지운다. 시험이 중간에 멈춰도 실행된다.
cleanup() {
  if ((APP_STARTED && !KEEP)); then
    log "cleanup: deleting Application $APP (GPU pod goes away with it)"
    "$DEPLOY_SH" app-down || log "WARNING: app-down failed; delete it by hand: kubectl -n $ARGO_NS delete application $APP"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- 2) 상태 확인 함수 ---
# app_q jq식 [jq 옵션...] : Application 객체에서 값을 뽑는다
app_q() { local expr=$1; shift; k -n "$ARGO_NS" get application "$APP" -o json | jq -r "$@" "$expr"; }
# app_state : 한 줄 요약 "sync=... health=... revision=... phase=..."
app_state() {
  app_q '"sync=\(.status.sync.status) health=\(.status.health.status) revision=\(.status.sync.revision // "-" | .[0:8]) phase=\(.status.operationState.phase // "-")"'
}
# synced_healthy_at 커밋 : Synced + Healthy이고 배포된 커밋이 그 커밋이면 성공
synced_healthy_at() {
  [[ "$(app_q '.status.sync.status == "Synced" and .status.health.status == "Healthy" and .status.sync.revision == $rev' --arg rev "$1")" == true ]]
}
# synced_at 커밋 : (건강 상태와 무관하게) Synced이고 커밋이 같으면 성공
synced_at() {
  [[ "$(app_q '.status.sync.status == "Synced" and .status.sync.revision == $rev' --arg rev "$1")" == true ]]
}
# live_pods : 추론 파드(삭제 대기 중이 아닌 것) 이름들, 오래된 순
live_pods() {
  k -n "$APP_NS" get pods -l app.kubernetes.io/instance="$APP" -o json |
    jq -r '[.items[] | select(.metadata.deletionTimestamp == null)] | sort_by(.metadata.creationTimestamp) | .[].metadata.name'
}
# newest_pod : 가장 최근에 만들어진 파드
newest_pod() { live_pods | tail -1; }
# pod_ready 파드 : 그 파드가 Ready이면 성공
pod_ready() { [[ "$(k -n "$APP_NS" get pod "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == True ]]; }
# env_is 이름 값 : Deployment의 첫 컨테이너 환경변수가 그 값이면 성공
env_is() {
  [[ "$(k -n "$APP_NS" get deploy "$APP" -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$1\")].value}" 2>/dev/null)" == "$2" ]]
}
# replicas_is 값 : Deployment의 spec.replicas가 그 값이면 성공
replicas_is() { [[ "$(k -n "$APP_NS" get deploy "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)" == "$1" ]]; }
# rolled_to_new_pod 이전파드 : 이전과 다른 파드가 Ready이고, 파드가 정확히 1개(예전 파드는 사라짐)이면 성공
rolled_to_new_pod() {
  local p; p=$(newest_pod)
  [[ -n "$p" && "$p" != "$1" && "$(live_pods | wc -l)" == 1 ]] && pod_ready "$p"
}
# pod_field 파드 jsonpath : 파드의 필드 값
pod_field() { k -n "$APP_NS" get pod "$1" -o jsonpath="$2" 2>/dev/null; }
# pod_on_gpu_host 파드 : gpu-host에서 실행 중이고 GPU 1개를 요청했으면 성공
pod_on_gpu_host() {
  [[ "$(pod_field "$1" '{.spec.nodeName}')" == gpu-host && "$(pod_field "$1" '{.spec.containers[0].resources.limits.nvidia\.com/gpu}')" == 1 ]]
}
# pod_restarts_zero 파드 : 컨테이너 재시작 횟수가 0이면 성공
pod_restarts_zero() { [[ "$(pod_field "$1" '{.status.containerStatuses[0].restartCount}')" == 0 ]]; }
# pod_log_has 파드 문자열 : 파드 로그에 문자열이 있으면 성공 (로그를 먼저 받아서 검사 — pipefail+grep -q 함정 회피)
pod_log_has() { local out; out=$(k -n "$APP_NS" logs "$1" 2>/dev/null) && grep -q -- "$2" <<<"$out"; }
# healed_by_argocd 시각 : 마지막 동기화가 자동 동기화이고 그 시각 이후에 시작했으면 성공 (시각은 date로 초 단위 숫자로 바꿔 비교)
healed_by_argocd() {
  local started
  started=$(app_q '.status.operationState.startedAt') || return 1
  [[ "$(app_q '.status.operationState.operation.initiatedBy.automated // false')" == true &&
    "$(date -d "$started" +%s)" -ge "$(date -d "$1" +%s)" ]]
}
# history_has 커밋... : 배포 이력에 그 커밋들이 모두 있으면 성공
history_has() {
  local rev
  for rev in "$@"; do
    [[ "$(app_q '[.status.history[].revision] | index($rev) != null' --arg rev "$rev")" == true ]] || return 1
  done
}
# history_last_is 커밋 : 배포 이력의 마지막 항목이 그 커밋이면 성공
history_last_is() { [[ "$(app_q '.status.history[-1].revision')" == "$1" ]]; }
# selfheal_on : Application의 자동 동기화(self-heal)가 켜져 있으면 성공
selfheal_on() { [[ "$(app_q '.spec.syncPolicy.automated.selfHeal // false')" == true ]]; }
# pods_unchanged 파드 : 추론 파드가 정확히 그 하나뿐이면 성공 (다시 만들어지지 않았다는 뜻)
pods_unchanged() { [[ "$(live_pods | tr '\n' ' ')" == "$1 " ]]; }
# no_infer_pods : 앱 네임스페이스에 파드가 없으면 성공
no_infer_pods() { [[ -z "$(k -n "$APP_NS" get pods --no-headers 2>/dev/null)" ]]; }
# is_out_of_sync : Application이 OutOfSync이면 성공
is_out_of_sync() { [[ "$(app_q '.status.sync.status')" == OutOfSync ]]; }
# wait_for 제한초 명령... : 명령이 성공할 때까지 1초 간격으로 반복, 시간 초과면 return 1
wait_for() {
  local limit=$1 start=$SECONDS
  shift
  while ((SECONDS - start < limit)); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}
# stuck 설명 : 기다리던 조건이 안 맞아 멈출 때 Application 상태와 파드를 보고서에 남기고 종료
stuck() {
  block "멈춘 이유: $1" "$(app_state 2>&1 || true)
$(k -n "$ARGO_NS" get application "$APP" -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' 2>&1 || true)
$(k -n "$APP_NS" get pods -o wide 2>&1 || true)
$(k -n "$APP_NS" get events --sort-by=.lastTimestamp 2>&1 | tail -8 || true)"
  md "" "## 결과 요약" "" "중단됨: $1 (PASS $PASS, FAIL $FAIL)"
  die "$1 (see $REPORT)"
}

# --- 3) 추론 서비스 호출 ---
# infer_post : svc/infer에 port-forward를 열어 /healthz와 /infer를 호출하고 응답 JSON을 출력한다.
#   본문은 시드 고정 64개 숫자(infer-bench.sh와 같음). port-forward는 이 함수가 끝나면 닫는다.
infer_post() {
  local port pf i ok=0
  port=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  # k 함수가 아니라 kubectl을 직접 백그라운드로 실행한다: 그래야 $!가 kubectl의 PID라서 kill이 port-forward를 정말 끝낸다
  K3S_CONFIG_FILE=/dev/null KUBECONFIG="$KUBECONFIG_FILE" kubectl -n "$APP_NS" port-forward "svc/$APP" "$port:8080" >"$WORK/pf-infer.log" 2>&1 &
  pf=$!
  for i in $(seq 20); do
    if curl -fs -o /dev/null "http://127.0.0.1:$port/healthz"; then ok=1; break; fi
    sleep 1
  done
  if ((ok)); then
    awk 'BEGIN { srand(1); printf "{\"x\":["; for (i = 0; i < 64; i++) printf "%s%.4f", (i ? "," : ""), rand() * 2 - 1; print "]}" }' |
      curl -fsS --max-time 20 -X POST --data @- "http://127.0.0.1:$port/infer" || ok=0
  fi
  kill "$pf" 2>/dev/null || true
  ((ok))
}
# infer_ok : 응답에 확률 10개가 있으면 성공 (RESP에 마지막 응답을 보관)
RESP=""
infer_ok() {
  RESP=$(infer_post) && jq -e '(.probs | length) == 10 and (.class | type) == "number"' <<<"$RESP" >/dev/null
}

# --- 4) Argo CD CLI (서버 파드 안) ---
# argocd_cli 인자... : argocd-server 파드 안의 argocd 명령. 관리자 초기 비밀번호는 표준입력으로 넘긴다(명령줄·화면에 남지 않음).
#   설정 파일은 쓰기 가능한 /tmp(emptyDir)에 둔다. 서버는 HTTP(server.insecure)라서 --plaintext.
argocd_cli() {
  local pw
  pw=$(k -n "$ARGO_NS" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
  printf '%s\n' "$pw" | k -n "$ARGO_NS" exec -i deploy/argocd-server -- sh -c '
    read -r PW
    argocd --config /tmp/argocd-cli.cfg login localhost:8080 --plaintext --username admin --password "$PW" >/dev/null || exit 1
    exec argocd --config /tmp/argocd-cli.cfg --plaintext "$@"' sh "$@"
}

# --- 5) 메모리 사용량 ---
# mem_rows 네임스페이스 [라벨선택자] : "파드이름 사용량(MiB)" 줄들. metrics-server(kubectl top)가 있으면 그 값을 쓰고,
#   없으면 파드 안에서 cgroup의 memory.current를 읽는다(컨테이너 전체 메모리, page cache 포함).
mem_rows() {
  local ns=$1 sel=${2:-} rows pod
  if rows=$(k -n "$ns" top pods ${sel:+-l "$sel"} --no-headers 2>/dev/null) && [[ -n "$rows" ]]; then
    awk '{v = $3; if (v ~ /Gi$/) {sub(/Gi$/, "", v); v *= 1024} else {sub(/Mi$/, "", v)}; printf "%s %d\n", $1, v}' <<<"$rows"
    return 0
  fi
  for pod in $(k -n "$ns" get pods ${sel:+-l "$sel"} -o name 2>/dev/null); do
    k -n "$ns" exec "$pod" -- cat /sys/fs/cgroup/memory.current 2>/dev/null | awk -v p="${pod#pod/}" '{printf "%s %d\n", p, $1 / 1048576}' || true
  done
}
# mem_usage : 보고서에 넣을 표 (Argo CD 파드별, Gitea, 노드). 출처(top/cgroup)를 첫 줄에 적는다.
mem_usage() {
  echo "# MiB, source: $(k -n "$ARGO_NS" top pods --no-headers >/dev/null 2>&1 && echo 'kubectl top (metrics-server)' || echo 'cgroup memory.current inside each pod')"
  echo "[argocd]"
  mem_rows "$ARGO_NS"
  echo "[gitea]"
  mem_rows "$GIT_NS" app.kubernetes.io/name=gitea
  echo "[nodes]"
  k top nodes 2>&1 || true
}
# mem_total_mib 네임스페이스 [라벨선택자] : 파드 메모리 합계(MiB)
mem_total_mib() { mem_rows "$@" | awk '{s += $2} END {print s + 0}'; }

# ============================================================
# --- 6) 보고서 머리 ---
{
  printf '# Argo CD 배포 자동화 시험 (%s)\n\n' "$(date '+%Y-%m-%d %H:%M')"
  printf -- '- 생성: `scripts/argocd-test.sh`\n'
  printf -- '- Argo CD `%s`, Git 서버 `%s`\n' \
    "$(k -n "$ARGO_NS" get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)" \
    "$(k -n "$GIT_NS" get deploy gitea -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
  printf -- '- 대상: Application `%s` = 차트 `charts/k3slab-workload` + `values-infer.yaml` + `values-infer-argocd.yaml` → 네임스페이스 `%s`\n' "$APP" "$APP_NS"
  printf -- '- Git 저장소: `%s` (연구실 Git 서버. GitHub 저장소는 공개이고 클러스터에 GitHub 쓰기 자격증명을 두지 않기 위해 이쪽을 쓴다)\n' "$("$SOURCE_SH" url)"
  printf -- '- 자동 동기화: prune 켬, self-heal 켬. 재확인 주기 30초(argocd-cm `timeout.reconciliation`)\n'
} >"$REPORT"

# --- 7) 0. 사전 확인 ---
log "check Argo CD and Gitea"
md "" "## 0. 사전 확인"
argocd_ready() {
  local d
  for d in argocd-server argocd-repo-server argocd-redis; do
    [[ "$(k -n "$ARGO_NS" get deploy "$d" -o jsonpath='{.status.readyReplicas}')" == 1 ]] || return 1
  done
  [[ "$(k -n "$ARGO_NS" get statefulset argocd-application-controller -o jsonpath='{.status.readyReplicas}')" == 1 ]]
}
gitea_ready() { [[ "$(k -n "$GIT_NS" get deploy gitea -o jsonpath='{.status.readyReplicas}')" == 1 ]]; }
check "Argo CD 구성요소 4개(server, repo-server, application-controller, redis) Ready" argocd_ready
check "Git 서버(Gitea) Ready" gitea_ready
((FAIL == 0)) || stuck "Argo CD or Gitea is not ready (run scripts/argocd-deploy.sh up)"
# 작업 폴더의 최신 차트를 Git에 반영한다 (바뀐 게 없으면 새 커밋은 만들지 않는다)
REV0=$("$SOURCE_SH" push "argocd-test: sync charts/ from the working tree")
md "" "- Git 최신 커밋(시험 시작): \`$REV0\`"
GPU_BEFORE=$(k describe node gpu-host 2>/dev/null | awk '/Allocated resources/ {f = 1} f && /nvidia.com\/gpu/ {print $2; exit}' || true)
md "- gpu-host가 시험 시작 때 할당한 GPU: \`${GPU_BEFORE:-?}\`"

# --- 8) 1. 처음 동기화 ---
log "1. first sync"
md "" "## 1. 처음 동기화 (Application 생성 → 파드 Ready → 응답)"
t0=$SECONDS
APP_STARTED=1
"$DEPLOY_SH" app
wait_for 900 synced_healthy_at "$REV0" || stuck "the Application did not become Synced+Healthy at $REV0 within 15 minutes"
T_SYNC=$((SECONDS - t0))
POD0=$(newest_pod)
block "Application 상태 (Application 생성 후 ${T_SYNC}초)" "$(k -n "$ARGO_NS" get application "$APP" -o wide)
$(k -n "$APP_NS" get deploy,svc,pods -o wide)"
check "Application이 Synced + Healthy, 배포된 커밋이 Git 최신($REV0)과 같음" synced_healthy_at "$REV0"
check "추론 파드($POD0)가 gpu-host에서 실행 중, GPU 1개 요청" pod_on_gpu_host "$POD0"
check "/healthz와 /infer가 응답 (확률 10개)" infer_ok
block "추론 응답" "$RESP"
block "파드 로그 (시작 줄)" "$(k -n "$APP_NS" logs "$POD0" | head -5)"

# --- 9) 2. 자가 치유 ---
log "2. self-heal"
md "" "## 2. 자가 치유 (손으로 바꾼 값을 Argo CD가 되돌리는지)"
T_SCALE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
t0=$SECONDS
k -n "$APP_NS" scale "deploy/$APP" --replicas=2 >/dev/null
md "" "- 손으로 \`kubectl scale deploy/$APP --replicas=2\` 실행 (Git 값은 1)"
wait_for 120 replicas_is 1 || stuck "self-heal did not restore replicas=1 within 2 minutes"
T_HEAL=$((SECONDS - t0))
wait_for 120 synced_healthy_at "$REV0" || stuck "the Application did not settle after self-heal"
check "replicas가 ${T_HEAL}초 만에 Git 값(1)으로 돌아옴" replicas_is 1
check "되돌린 것은 Argo CD의 자동 동기화 (operationState.operation.initiatedBy.automated, 손으로 바꾼 뒤 시작)" healed_by_argocd "$T_SCALE"
check "원래 추론 파드($POD0)는 재시작 없이 그대로" pod_restarts_zero "$POD0"
block "자가 치유 뒤 Application" "$(app_state)"
# 지워진 객체도 다시 만드는지: Service를 지운다 (GPU 파드는 건드리지 않는다)
t0=$SECONDS
k -n "$APP_NS" delete "svc/$APP" >/dev/null
md "" "- 손으로 \`kubectl delete svc/$APP\` 실행"
wait_for 120 k -n "$APP_NS" get "svc/$APP" || stuck "self-heal did not recreate the Service within 2 minutes"
T_HEAL_SVC=$((SECONDS - t0))
check "삭제한 Service가 ${T_HEAL_SVC}초 만에 다시 만들어지고 응답함" infer_ok

# --- 10) 3. values 커밋 → 새 리비전 ---
log "3. new revision from a values commit"
md "" "## 3. values 변경 → 새 리비전 배포"
t0=$SECONDS
REV1=$("$SOURCE_SH" edit "$VALUES_FILE" 's/^  maxBatch: .*/  maxBatch: 4/' "argocd-test: infer.maxBatch 8 -> 4")
md "" "- Git에 커밋: \`$VALUES_FILE\`의 \`infer.maxBatch\` 8 → 4 (커밋 \`$REV1\`)"
wait_for 300 synced_healthy_at "$REV1" || stuck "the new revision $REV1 was not deployed within 5 minutes"
wait_for 180 rolled_to_new_pod "$POD0" || stuck "no new Ready pod after the new revision"
T_REV=$((SECONDS - t0))
POD1=$(newest_pod)
block "새 리비전 배포 후 (커밋부터 ${T_REV}초)" "$(k -n "$ARGO_NS" get application "$APP" -o wide)
$(k -n "$APP_NS" get deploy,rs,pods -o wide)"
check "새 커밋($REV1)이 자동으로 배포됨 (Synced + Healthy)" synced_healthy_at "$REV1"
check "Deployment 환경변수 MAX_BATCH=4" env_is MAX_BATCH 4
check "새 파드($POD1)가 Ready이고 로그에 MAX_BATCH=4, 예전 파드는 사라짐" pod_log_has "$POD1" 'MAX_BATCH=4'
check "새 파드가 응답 (확률 10개)" infer_ok
check "배포 이력(status.history)에 두 리비전($REV0, $REV1)이 남음" history_has "$REV0" "$REV1"
block "배포 이력 (id, 커밋, 시각)" "$(app_q '.status.history[] | "\(.id)  \(.revision)  \(.deployedAt)"')"

# --- 11) 4. 롤백 ---
log "4. rollback"
md "" "## 4. 이전 리비전으로 롤백"
HIST0=$(app_q '[.status.history[] | select(.revision == $rev)] | last | .id' --arg rev "$REV0")
md "" "### 4a. \`argocd app rollback\` (배포 이력 id $HIST0 = 커밋 \`$REV0\`)" "" \
  "자동 동기화가 켜져 있으면 Argo CD가 롤백을 거부한다(Git 최신으로 곧바로 다시 맞추기 때문). 그래서 잠시 끈다."
k -n "$ARGO_NS" patch application "$APP" --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
t0=$SECONDS
ROLLBACK_OUT=$(argocd_cli app rollback "$APP" "$HIST0" 2>&1) || { block "argocd app rollback 출력" "$ROLLBACK_OUT"; stuck "argocd app rollback failed"; }
block "argocd app rollback 출력" "$ROLLBACK_OUT"
wait_for 300 env_is MAX_BATCH 8 || stuck "rollback did not restore MAX_BATCH=8"
wait_for 180 rolled_to_new_pod "$POD1" || stuck "no new Ready pod after the rollback"
T_ROLLBACK=$((SECONDS - t0))
POD2=$(newest_pod)
check "롤백 뒤 Deployment MAX_BATCH=8 (이전 리비전 값), 새 파드($POD2) Ready" env_is MAX_BATCH 8
check "롤백 뒤 응답" infer_ok
check "배포 이력의 마지막 항목이 이전 커밋($REV0)" history_last_is "$REV0"
# 롤백만 했으면 Git 최신(REV1, maxBatch=4)과 달라서 OutOfSync로 보여야 한다. 상태 갱신(최대 35초)을 기다린다.
wait_for 90 is_out_of_sync || true
check "Git 최신($REV1)과 달라서 OutOfSync로 표시됨 (롤백은 Git을 바꾸지 않는다)" is_out_of_sync
block "롤백 직후 (${T_ROLLBACK}초)" "$(app_state)
$(k -n "$APP_NS" get pods -o wide)"

md "" "### 4b. Git revert (GitOps 방식 롤백)" "" \
  "롤백한 상태를 Git에도 반영한다: $REV1 커밋을 되돌리는 새 커밋을 올린 뒤 자동 동기화를 다시 켠다."
REV2=$("$SOURCE_SH" revert "$REV1")
md "" "- revert 커밋: \`$REV2\`"
# 새 커밋을 Argo CD가 바로 보게 강제 새로고침(hard refresh)한다. 자동 동기화가 꺼져 있는 동안이라 클러스터는 바뀌지 않는다.
k -n "$ARGO_NS" annotate application "$APP" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
wait_for 120 synced_at "$REV2" || stuck "the Application did not become Synced at the revert commit $REV2"
POD_BEFORE_RESYNC=$(newest_pod)
"$DEPLOY_SH" app
wait_for 180 synced_healthy_at "$REV2" || stuck "the Application is not Synced+Healthy at $REV2 after enabling auto-sync again"
check "Git revert 커밋($REV2)이 Synced + Healthy" synced_healthy_at "$REV2"
check "자동 동기화(self-heal)가 다시 켜짐" selfheal_on
check "롤백한 값(MAX_BATCH=8)이 유지됨" env_is MAX_BATCH 8
check "다시 켠 뒤에도 파드는 다시 만들어지지 않음 ($POD_BEFORE_RESYNC 하나뿐)" pods_unchanged "$POD_BEFORE_RESYNC"
block "최종 배포 이력" "$(app_q '.status.history[] | "\(.id)  \(.revision)  \(.deployedAt)"')"

# --- 12) 5. 메모리 사용량과 정리 ---
log "5. memory and cleanup"
md "" "## 5. 메모리 사용량 (추론 파드가 떠 있는 상태)"
MEM=$(mem_usage)
MEM_TOTAL=$(mem_total_mib "$ARGO_NS")
GITEA_MEM=$(mem_total_mib "$GIT_NS" app.kubernetes.io/name=gitea)
block "파드별 메모리 사용량" "$MEM"
md "" "- Argo CD 파드 4개 합계: **${MEM_TOTAL} MiB** (limits 합계 1280 MiB: controller 512 + repo-server 384 + server 256 + redis 128)" \
  "- Gitea: ${GITEA_MEM} MiB (limit 256 MiB)"
ARGO_NODE=$(k -n "$ARGO_NS" get pod -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].spec.nodeName}')
block "Argo CD가 올라간 노드($ARGO_NODE)의 자원 할당(requests/limits)" "$(k describe node "$ARGO_NODE" 2>&1 | sed -n '/Allocated resources/,/Events/p')"

md "" "## 6. 정리 (GPU 파드 내리기)"
if ((KEEP)); then
  md "" "- \`--keep\`: Application과 GPU 파드를 그대로 둠. 내리려면 \`scripts/argocd-deploy.sh app-down\`"
else
  "$DEPLOY_SH" app-down
  APP_STARTED=0
  check "Application 삭제 뒤 추론 파드가 모두 사라짐 (GPU 반환)" no_infer_pods
  GPU_AFTER=$(k describe node gpu-host 2>/dev/null | awk '/Allocated resources/ {f = 1} f && /nvidia.com\/gpu/ {print $2; exit}' || true)
  md "" "- gpu-host가 할당한 GPU: 시험 전 \`${GPU_BEFORE:-?}\` → 후 \`${GPU_AFTER:-?}\`"
fi

# --- 13) 요약 ---
md "" "## 결과 요약" "" "PASS $PASS, FAIL $FAIL" "" \
  "| 단계 | 걸린 시간 |" "|---|---|" \
  "| 처음 동기화 (Application 생성 → Synced+Healthy. 이미지가 노드에 없으면 pull 시간이 더해진다) | ${T_SYNC}초 |" \
  "| 자가 치유: replicas 되돌림 | ${T_HEAL}초 |" \
  "| 자가 치유: 삭제한 Service 재생성 | ${T_HEAL_SVC}초 |" \
  "| values 커밋 → 새 파드 Ready | ${T_REV}초 |" \
  "| \`argocd app rollback\` → 이전 값의 새 파드 Ready | ${T_ROLLBACK}초 |" \
  "" "- Git 커밋: 시작 \`$REV0\` → maxBatch 4 \`$REV1\` → revert \`$REV2\`" \
  "- Argo CD 파드 4개 메모리 합계 ${MEM_TOTAL} MiB, Gitea ${GITEA_MEM} MiB"
log "argocd test: PASS $PASS, FAIL $FAIL (report: $REPORT)"
((FAIL == 0))
