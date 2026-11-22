#!/usr/bin/env bash
# Fault-injection experiments for the lab cluster (proposal slides 14-15): break one thing on purpose, measure how long
# recovery takes and what the user sees, then put the cluster back. One sub-command per experiment; --dry-run only
# prints the procedure. Reports go to docs/labs/fault-<experiment>-<date>.md. Design: docs/plan-week13-verification.md
# Usage: scripts/fault-test.sh list | inspect | cleanup [--node NAME]
#        scripts/fault-test.sh <infer-kill|train-kill|node-stop|mysql-down|gpu-busy|registry-down|overload|bad-deploy> [options]
#        options: --dry-run  --yes  --model-job ID  --tag TAG  --gpu 0|1  --mode M  --node NAME  --toleration-seconds N  --spread
#
# [한국어 설명] 장애를 일부러 하나 일으키고, 복구에 걸린 시간과 사용자가 겪는 영향을 재고, 원래 상태로 되돌린다 (제안서 14·15번).
#   설계·성공 기준·근거는 docs/plan-week13-verification.md에 있다. 실험은 하위 명령 하나씩이고, 한 번에 하나만 돌린다.
#   list          실험 목록
#   inspect       읽기 전용 점검: 막을 수 없는 장애의 근거(노드 수, 디스크에 묶인 데이터, 복제본 1개짜리)를 모은다
#   infer-kill    F1 추론 파드 강제 종료 → 복구 시간, 실패 요청 수            (옵션 --gpu 0|1, --mode force|graceful)
#   train-kill    F2 학습 파드 중단 → 체크포인트 재개 (기존 train-resume-test.sh 재사용; --mode force는 SIGKILL 변형)
#   node-stop     F3 worker VM 정지 → 파드 재배치 시간, 요청 실패          (옵션 --node, --toleration-seconds, --spread)
#   mysql-down    F4 MySQL 중단 → 등록 요청 거절, 추론 지속, 데이터 보존    (옵션 --down-seconds, --with-training)
#   gpu-busy      F5 GPU 사용 불가 → CPU 대체 경로(DEVICE=auto)와 GPU 복귀
#   registry-down F6 레지스트리 중단 → 이미지 받기 실패와 복구 시간          (옵션 --down-seconds)
#   overload      F7 과부하 → 429(즉시 거절)와 큐 대기                      (옵션 --requests, --concurrency)
#   bad-deploy    F8 잘못된 배포(없는 이미지 태그) → 서비스 유지와 롤백      (옵션 --gpu 0|1)
#   cleanup       실험이 중간에 끊겼을 때 남은 것을 되돌린다(MySQL·레지스트리 replicas 1, 실험용 네임스페이스 삭제, VM 기동)
#   [공통 규칙]
#   - --dry-run: 절차만 출력한다. 클러스터·VM을 건드리지 않고 보고서도 만들지 않는다.
#   - 승인: 실행하면 파드·VM·DB를 일부러 멈춘다. 총괄 승인 뒤에만 실행한다. 승인 표시로 --yes를 주거나 터미널에서 yes를 입력한다.
#   - 시작 전에 노드 4개가 모두 Ready인지 보고, 이전 실험 흔적(k3slab-fault 네임스페이스)이 있으면 멈춘다.
#   - 끝나면(실패·Ctrl+C 포함) 복구 단계가 거꾸로 실행된다: VM 기동, MySQL·레지스트리 replicas 1, 실험용 릴리스·네임스페이스 삭제.
#   - sudo를 쓰지 않는다. VM은 vmrun으로 끄고 켠다. 비밀번호는 다루지 않는다(MySQL 접속은 파드 안 환경변수를 쓴다).
#   - Prometheus 값은 설정했을 때만 보고서에 더한다: --prom <네임스페이스>/<서비스>:<포트> (예: monitoring/prometheus-server:80)
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 상수 ---
# FAULT_NS: 실험용 파드·릴리스만 두는 전용 네임스페이스(끝나면 통째로 지운다) / INFER_RELEASE: 실험용 추론 릴리스 이름
# CKPT_ROOT: 학습 결과가 있는 gpu-host 폴더(이 스크립트는 gpu-host 위에서 돈다) / EXPECT_NODES: 정상일 때 Ready 노드 수
# MISSING_TAG: 레지스트리에 올린 적 없는 이미지 태그(잘못된 배포 흉내). 이미지·도구는 고정 버전을 쓴다(latest 금지).
FAULT_NS="k3slab-fault"
INFER_RELEASE="infer-fault"
CHART="$REPO_ROOT/charts/k3slab-workload"
VALUES_INFER="$CHART/values-infer.yaml"
KUBECONFIG_FILE="$LAB_SECRETS_DIR/kubeconfig"
CKPT_ROOT="/var/lib/k3slab/checkpoints"
DB_NS="k3slab-system"
EXPECT_NODES=4
CURL_IMAGE="docker.io/curlimages/curl:8.23.0"
BUSYBOX_IMAGE="docker.io/library/busybox:1.37.0"
WHOAMI_IMAGE="docker.io/traefik/whoami:v1.12.0"
MISSING_TAG="v0.0.0-fault-missing"
ID_RE='^[a-z0-9]([-a-z0-9]{0,40}[a-z0-9])?$'
# values-infer.yaml의 image.tag(들여쓰기 2칸 `  tag:` 줄)를 기본 태그로 쓴다
DEFAULT_TAG=$(awk '/^  tag:/ {print $2; exit}' "$VALUES_INFER")

# 명령줄에서 채워지는 설정(기본값) — parse_args가 덮어쓴다
EXP=""
DRY=0
ASSUME_YES=0
MODEL_JOB="${FAULT_MODEL_JOB:-}"
TAG=""
GPU=0
MODE=""
NODE="worker-cpu-2"
TOL=""
SPREAD=0
DOWN_SECONDS=""
REQUESTS=300
CONC=150
JOB_ID=""
ALLOW_OTHER=0
WITH_TRAINING=0
PROM_PROXY="${FAULT_PROM:-}"
ARGS_ECHO=""

# 보고서·집계 상태 (begin_report가 REPORT를 정한다)
REPORT=""
PASS=0
FAIL=0
# 복구 단계 목록 (push_restore가 쌓고, run_restores가 거꾸로 실행한다)
RESTORES=()
# 실험 중 쓰는 프로버 파드 이름과 시작 시각(Prometheus 구간 계산용)
PROBE="fault-probe"
EXP_START=0

# --- 2) 인자 읽기 ---

# usage [종료코드] : 이 파일 2~7번째 줄(영문 사용법)을 출력하고 종료
usage() {
  sed -n '2,7s/^# \{0,1\}//p' "$0"
  exit "${1:-0}"
}

# need_num 옵션이름 값 : 0 이상의 정수가 아니면 중단
need_num() { [[ "$2" =~ ^[0-9]+$ ]] || die "$1 needs a whole number, got '$2'"; }

# parse_args 인자... : 옵션을 전역 설정 변수에 담는다. 값이 필요한 옵션은 다음 인자를 값으로 읽는다.
parse_args() {
  while (($#)); do
    case $1 in
      --dry-run) DRY=1; shift ;;
      --yes) ASSUME_YES=1; shift ;;
      --spread) SPREAD=1; shift ;;
      --allow-other-pods) ALLOW_OTHER=1; shift ;;
      --with-training) WITH_TRAINING=1; shift ;;
      -h | --help) usage 0 ;;
      --model-job | --tag | --gpu | --mode | --node | --toleration-seconds | --down-seconds | --requests | --concurrency | --job-id | --prom)
        (($# >= 2)) || die "$1 needs a value"
        case $1 in
          --model-job) MODEL_JOB=$2 ;;
          --tag) TAG=$2 ;;
          --gpu) GPU=$2 ;;
          --mode) MODE=$2 ;;
          --node) NODE=$2 ;;
          --toleration-seconds) TOL=$2 ;;
          --down-seconds) DOWN_SECONDS=$2 ;;
          --requests) REQUESTS=$2 ;;
          --concurrency) CONC=$2 ;;
          --job-id) JOB_ID=$2 ;;
          --prom) PROM_PROXY=$2 ;;
        esac
        shift 2
        ;;
      *) die "unknown option $1 (see --help)" ;;
    esac
  done
}

# validate_args : 값 형식 검사. SQL·Helm·노드 이름에 그대로 들어가므로 안전한 문자만 허용한다.
validate_args() {
  [[ -z "$MODEL_JOB" || "$MODEL_JOB" =~ $ID_RE ]] || die "--model-job must be lowercase letters, digits and '-': '$MODEL_JOB'"
  [[ -z "$JOB_ID" || "$JOB_ID" =~ $ID_RE ]] || die "--job-id must be lowercase letters, digits and '-': '$JOB_ID'"
  [[ "$GPU" == 0 || "$GPU" == 1 ]] || die "--gpu must be 0 or 1"
  [[ "$NODE" =~ ^[a-z0-9][-a-z0-9.]{0,62}$ ]] || die "--node must be a node name: '$NODE'"
  [[ -z "$TAG" || "$TAG" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "--tag has unsupported characters"
  [[ -z "$PROM_PROXY" || "$PROM_PROXY" =~ ^[a-z0-9-]+/[a-z0-9.-]+:[0-9]+$ ]] || die "--prom must look like monitoring/prometheus-server:80"
  [[ -z "$TOL" ]] || need_num --toleration-seconds "$TOL"
  [[ -z "$DOWN_SECONDS" ]] || need_num --down-seconds "$DOWN_SECONDS"
  need_num --requests "$REQUESTS"
  need_num --concurrency "$CONC"
  ((REQUESTS >= 1 && CONC >= 1)) || die "--requests and --concurrency must be at least 1"
  TAG=${TAG:-$DEFAULT_TAG}
}

# --- 3) 보조 함수: 출력·보고서·시각 ---

# md 줄... : 보고서 끝에 줄 추가 / block "제목" 내용 : 제목과 코드 블록을 추가
md() { printf '%s\n' "$@" >>"$REPORT"; }
block() { md "" "**$1**" "" '```text' "$2" '```'; }
# metric "이름" 값 : 측정값 한 줄을 보고서와 화면에 남긴다
metric() { md "" "- 📏 $1: **$2**"; log "METRIC $1: $2"; }
# note 문장 : 보고서에 설명 문단 한 줄 추가
note() { md "" "$*"; log "$*"; }
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
# awkc : 소수점이 항상 '.'이도록 로케일을 C로 고정한 awk
awkc() { LC_ALL=C awk "$@"; }
# now : 지금 시각(에폭 초, 소수 9자리) / elapsed 시작 끝 : 두 시각의 차이(초, 소수 1자리)
now() { date +%s.%N; }
elapsed() { awkc -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }
# epoch_of 시각문자열 : 쿠버네티스 시각(예: 2026-11-21T03:56:32Z)을 에폭 초로
epoch_of() { date -d "$1" +%s; }
# kv "key=value ..." 키 : 요약 문자열에서 키의 값을 꺼낸다
kv() { sed -n "s/.*\b$2=\([^ ]*\).*/\1/p" <<<"$1" | head -1; }
# is_true 값 : 값이 1이면 성공 (check에 조건으로 넘기는 용도)
is_true() { [[ "$1" == 1 ]]; }
# le 값 한계 : 값이 한계 이하이면 성공 (소수 비교용)
le() { awkc -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 <= b + 0) }'; }

# begin_report 제목 : 보고서 파일을 만들고 머리글을 쓴다 (실행 모드에서만 호출)
begin_report() {
  REPORT="$REPO_ROOT/docs/labs/fault-$EXP-$(date +%Y%m%d-%H%M).md"
  mkdir -p "$(dirname "$REPORT")"
  {
    printf '# %s (%s)\n\n' "$1" "$(date '+%Y-%m-%d %H:%M')"
    printf -- '- 생성: `scripts/fault-test.sh %s`\n' "$ARGS_ECHO"
    printf -- '- 설계: `docs/plan-week13-verification.md`. 시각은 이 PC(gpu-host) 시계 기준이고, 측정 오차는 확인 간격(약 1초) 안팎이다.\n'
  } >"$REPORT"
  EXP_START=$(date +%s)
  log "report: $REPORT"
}

# --- 4) 보조 함수: kubectl·helm·대기·복구 ---

# k / kf / h : 이 클러스터용 kubectl(전체·실험 네임스페이스)과 helm (K3S_CONFIG_FILE=/dev/null은 k3s 링크의 권한 경고 제거)
k() { K3S_CONFIG_FILE=/dev/null KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"; }
kf() { k -n "$FAULT_NS" "$@"; }
h() { KUBECONFIG="$KUBECONFIG_FILE" helm "$@"; }
# db 쿼리 : MySQL 파드 안에서 앱 계정으로 실행 (job.sh와 같은 방식, 비밀번호는 파드 안 환경변수라 여기에 나오지 않는다)
db() { k -n "$DB_NS" exec -i deploy/mysql -- sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" exec mysql -uk3slab -N -B -r k3slab' <<<"$1"; }

# wait_for 제한초 명령... : 명령이 성공할 때까지 1초 간격으로 반복, 시간 초과면 return 1 (시간을 재므로 간격을 짧게 둔다)
wait_for() {
  local limit=$1 start=$SECONDS
  shift
  while ((SECONDS - start < limit)); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# push_restore 함수이름 : 복구 단계를 등록한다. 장애를 일으키기 "전에" 등록해야 중간에 끊겨도 되돌린다.
push_restore() { RESTORES+=("$1"); }
# run_restores : 등록된 복구 단계를 거꾸로(마지막에 등록한 것부터) 실행하고 목록을 비운다. 한 단계가 실패해도 나머지는 계속한다.
run_restores() {
  local i fn
  for ((i = ${#RESTORES[@]} - 1; i >= 0; i--)); do
    fn=${RESTORES[i]}
    log "restore: $fn"
    "$fn" || log "WARN restore step failed: $fn"
  done
  RESTORES=()
}
# on_exit : 스크립트가 끝날 때 복구 단계가 남아 있으면(오류·Ctrl+C) 실행한다. 종료 코드는 그대로 돌려준다.
on_exit() {
  local rc=$?
  if ((${#RESTORES[@]} > 0)); then
    log "stopping early (exit $rc): running the restore steps"
    run_restores
  fi
  exit "$rc"
}

# confirm "설명" : 파괴적 실험을 실행하기 전 승인. --yes가 있으면 통과, 터미널이면 yes를 입력받고, 둘 다 아니면 거절한다.
confirm() {
  if ((ASSUME_YES)); then
    log "approved with --yes: $1"
    return 0
  fi
  [[ -t 0 ]] || die "approval needed but stdin is not a terminal; pass --yes only after the coordinator approved: $1"
  printf '%s\n실행하려면 yes 를 입력하세요: ' "$1" >&2
  local ans
  read -r ans
  [[ "$ans" == yes ]] || die "cancelled"
}

# --- 5) 보조 함수: 상태 조회 ---

# nodes_ready : Ready인 노드 수 / all_nodes_ready : 정상일 때의 노드 수(EXPECT_NODES)와 같으면 성공
nodes_ready() { k get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l; }
all_nodes_ready() { [[ "$(nodes_ready)" -eq "$EXPECT_NODES" ]]; }
# node_ready 노드 : 그 노드의 Ready 조건이 True면 성공 / node_not_ready : 아니면(False 또는 Unknown) 성공
node_ready() { [[ "$(k get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]]; }
node_not_ready() { ! node_ready "$1"; }
# deploy_ready 네임스페이스 이름 : Deployment의 준비된 복제본이 원하는 수(1 이상)와 같으면 성공
deploy_ready() {
  local j
  j=$(k -n "$1" get deploy "$2" -o json 2>/dev/null) || return 1
  jq -e '(.spec.replicas // 0) >= 1 and (.status.readyReplicas // 0) == .spec.replicas' <<<"$j" >/dev/null
}
# ns_gone : 실험용 네임스페이스가 없으면 성공
ns_gone() { ! k get namespace "$FAULT_NS" >/dev/null 2>&1; }
# gpu_pods : GPU를 요청하는(끝나지 않은) 파드 이름 목록
gpu_pods() {
  k get pods -A -o json | jq -r '.items[]
    | select(.status.phase == "Running" or .status.phase == "Pending")
    | select(any(.spec.containers[]; (.resources.limits["nvidia.com/gpu"] // "0") != "0"))
    | "\(.metadata.namespace)/\(.metadata.name)"'
}
# gpu_free : GPU를 쓰는 파드가 하나도 없으면 성공
gpu_free() { [[ -z "$(gpu_pods)" ]]; }
# model_exists 작업번호 : 학습 결과(model.k3sm)가 이 PC의 체크포인트 폴더에 있으면 성공
model_exists() { [[ -s "$CKPT_ROOT/$1/model.k3sm" ]]; }

# api_reachable : kubeconfig의 API 서버(host:6443)에 5초 안에 TCP로 닿으면 성공.
#   클러스터가 꺼져 있으면 kubectl은 재시도 때문에 50초 넘게 걸려서, 먼저 짧게 확인하고 바로 알려 준다.
api_reachable() {
  local url host port
  url=$(awk '/^ *server:/ {print $2; exit}' "$KUBECONFIG_FILE")
  host=${url#*://}
  host=${host%%:*}
  port=${url##*:}
  port=${port%%/*}
  [[ -n "$host" && "$port" =~ ^[0-9]+$ ]] || return 1
  timeout 5 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
}

# preflight_common : 모든 실험 앞의 공통 점검 — 도구, kubeconfig, 노드 4개 Ready, MySQL·레지스트리 정상, 이전 실험 흔적 없음
preflight_common() {
  local t
  for t in kubectl helm jq; do command -v "$t" >/dev/null || die "$t not found"; done
  [[ -f "$KUBECONFIG_FILE" ]] || die "missing $KUBECONFIG_FILE (is the cluster up? scripts/entry.sh is run by the platform owner)"
  api_reachable || die "cannot reach the Kubernetes API server within 5 seconds: the cluster looks down (starting it is the platform owner's job)"
  k get nodes --request-timeout=10s >/dev/null 2>&1 || die "cannot read the nodes (is the cluster up?)"
  all_nodes_ready || die "expected $EXPECT_NODES Ready nodes, found $(nodes_ready): not starting an experiment on a degraded cluster"
  deploy_ready "$DB_NS" mysql || die "MySQL ($DB_NS/mysql) is not ready"
  deploy_ready "$DB_NS" registry || die "registry ($DB_NS/registry) is not ready"
  ns_gone || die "namespace $FAULT_NS exists: a previous experiment was cut short. Run scripts/fault-test.sh cleanup first"
}
# need_model : 추론을 띄우는 실험은 학습 결과가 필요하다
need_model() {
  [[ -n "$MODEL_JOB" ]] || die "--model-job <training job id> is required (a finished training job whose model.k3sm is served)"
  model_exists "$MODEL_JOB" || die "no $CKPT_ROOT/$MODEL_JOB/model.k3sm (run this on gpu-host; train it with scripts/job.sh submit train)"
}

# ensure_ns : 실험용 네임스페이스를 만든다 (이미 preflight가 없음을 확인했다) / restore_ns : 지운다
ensure_ns() {
  k create namespace "$FAULT_NS" >/dev/null
  k label namespace "$FAULT_NS" k3slab.io/purpose=fault-test >/dev/null
}
restore_ns() { k delete namespace "$FAULT_NS" --ignore-not-found --wait=false >/dev/null 2>&1; }
# restore_infer : 실험용 추론 릴리스 제거
restore_infer() { h uninstall "$INFER_RELEASE" -n "$FAULT_NS" >/dev/null 2>&1 || true; }
# restore_mysql / restore_registry : replicas를 1로 되돌리고 준비될 때까지 기다린다
restore_mysql() {
  k -n "$DB_NS" scale deploy/mysql --replicas=1 >/dev/null
  k -n "$DB_NS" rollout status deploy/mysql --timeout=5m >/dev/null
}
restore_registry() {
  k -n "$DB_NS" scale deploy/registry --replicas=1 >/dev/null
  k -n "$DB_NS" rollout status deploy/registry --timeout=5m >/dev/null
}

# verify_restored : 실험이 끝난 뒤 원래 상태인지 확인한다 — 이 점검도 보고서에 남는다
verify_restored() {
  wait_for 180 ns_gone || true
  check "실험용 네임스페이스($FAULT_NS)가 사라짐" ns_gone
  check "노드 ${EXPECT_NODES}개 모두 Ready" all_nodes_ready
  check "MySQL이 1/1 Ready" deploy_ready "$DB_NS" mysql
  check "레지스트리가 1/1 Ready" deploy_ready "$DB_NS" registry
}

# finish : 보고서 마무리와 종료 코드(FAIL이 있으면 1)
finish() {
  md "" "## 결과 요약" "" "PASS $PASS, FAIL $FAIL"
  log "$EXP: PASS $PASS, FAIL $FAIL (report: $REPORT)"
  ((FAIL == 0))
}

# --- 6) 보조 함수: 프로버(요청 측정)와 추론 배포 ---

# probe_start 이름 URL POST(0|1) [피할노드] : 실험 네임스페이스에 curl 파드를 띄운다. 파드 안에서 초당 약 10번 요청을 보내
#   "<파드 가동 초> <HTTP 코드>" 한 줄씩 로그로 남긴다(실패·시간 초과는 코드 000). 첫 줄은 시작 시각이다.
#   파드 안에서 /proc/uptime(0.01초 단위)으로 재는 이유: 이 이미지의 busybox date는 밀리초를 못 낸다(infer-bench.sh와 같음).
probe_start() {
  local name=$1 url=$2 post=$3 avoid=${4:-} aff=""
  if [[ -n "$avoid" ]]; then
    aff="  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: kubernetes.io/hostname
                operator: NotIn
                values: [\"$avoid\"]"
  fi
  kf apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  labels:
    app: fault-probe
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
$aff
  containers:
    - name: probe
      image: $CURL_IMAGE
      env:
        - name: PROBE_URL
          value: "$url"
        - name: PROBE_POST
          value: "$post"
      command:
        - sh
        - -c
        - |
          awk 'BEGIN { srand(1); printf "{\"x\":["; for (i = 0; i < 64; i++) printf "%s%.4f", (i ? "," : ""), rand() * 2 - 1; print "]}" }' > /tmp/body.json
          up() { cut -d' ' -f1 /proc/uptime; }
          echo "start_epoch=\$(date +%s) start_uptime=\$(up)"
          while :; do
            if [ "\$PROBE_POST" = 1 ]; then
              code=\$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 3 -X POST --data @/tmp/body.json "\$PROBE_URL")
            else
              code=\$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 3 "\$PROBE_URL")
            fi
            echo "\$(up) \$code"
            sleep 0.1 2>/dev/null || sleep 1
          done
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 64Mi
EOF
}
# probe_lines 이름 : 프로버 로그의 요청 기록 줄 수
probe_lines() { kf logs "$1" 2>/dev/null | awk 'NF == 2' | wc -l; }
# probe_ready 이름 : 요청 기록이 20줄 이상이고 마지막 10줄이 모두 200이면 성공 (평상시가 정상인지 확인)
probe_ready() {
  local out
  out=$(kf logs "$1" 2>/dev/null) || return 1
  awk 'NF == 2 { n++; last[n] = $2 } END { if (n < 20) exit 1; for (i = n - 9; i <= n; i++) if (last[i] != "200") exit 1 }' <<<"$out"
}
# probe_tail_ok 로그파일 N : 로그 마지막 N개 요청이 모두 200이면 성공 (복구 뒤 안정 확인)
probe_tail_ok() {
  awk -v n="$2" 'NF == 2 { c++; v[c] = $2 } END { if (c < n) exit 1; for (i = c - n + 1; i <= c; i++) if (v[i] != "200") exit 1 }' "$1"
}
# probe_summary 로그파일 T0 : 요청 결과 요약을 "key=value ..." 두 줄로 출력한다.
#   total 전체, failed 200이 아닌 요청, codes 코드별 개수(코드:개수,...), first/last_fail_after_t0 첫·마지막 실패 시각(T0 기준 초),
#   fail_window 첫~마지막 실패 사이(초). 실패 시각은 "요청이 끝난 시각"이고, 파드(VM)와 이 PC의 시계 차이가 섞인다.
#   fail_window와 개수는 파드 시계만 써서 시계 차이와 무관하다.
probe_summary() {
  awkc -v t0="${2:-0}" '
    /^start_epoch=/ { split($1, a, "="); split($2, b, "="); se = a[2]; su = b[2]; next }
    NF == 2 && $1 ~ /^[0-9.]+$/ {
      total++; code[$2]++
      if ($2 != "200") { failed++; if (first == "") first = $1; last = $1 }
    }
    END {
      codes = ""
      for (c in code) codes = codes (codes == "" ? "" : ",") c ":" code[c]
      printf "total=%d failed=%d codes=%s\n", total, failed, codes
      if (failed > 0) printf "first_fail_after_t0=%.1f last_fail_after_t0=%.1f fail_window=%.1f\n", se + first - su - t0, se + last - su - t0, last - first
      else printf "first_fail_after_t0=- last_fail_after_t0=- fail_window=0.0\n"
    }' "$1"
}
# window_text 요약 : 프로버 요약에서 실패 구간을 사람이 읽는 문장으로 ("실패 없음" 또는 "1.0초 (T0+7.0s ~ T0+8.0s)")
window_text() {
  if [[ "$(kv "$1" failed)" == 0 ]]; then
    printf '실패 없음'
  else
    printf '%s초 (T0+%ss ~ T0+%ss)' "$(kv "$1" fail_window)" "$(kv "$1" first_fail_after_t0)" "$(kv "$1" last_fail_after_t0)"
  fi
}
# probe_stop 이름 로그파일 : 프로버 로그를 파일로 받고 파드를 지운다
probe_stop() {
  kf logs "$1" >"$2" 2>/dev/null || true
  kf delete pod "$1" --wait=false >/dev/null 2>&1 || true
}
# probe_report 로그파일 T0 : 요약을 보고서에 쓰고, 요약 문자열을 출력한다 (호출한 쪽이 kv로 값을 꺼낸다)
probe_report() {
  local s
  s=$(probe_summary "$1" "$2")
  block "프로버 요약 (초당 약 10회 요청, 실패 = HTTP 200이 아닌 응답 또는 시간 초과 000)" "$s"
  printf '%s\n' "$s"
}

# infer_helm GPU 장치 [helm 인자...] : 실험용 추론 릴리스를 배포/갱신한다(기다리지 않음). 장치는 cpu | cuda | auto.
#   values-infer.yaml 위에 실험값만 --set으로 덮어쓴다. WORK_MS 0 = 실제 계산만, 타임아웃 10초 = 대기 때문에 504가 나지 않게.
#   추가 인자는 기본값 뒤에 붙으므로 같은 키를 다시 --set하면 그 값이 이긴다.
infer_helm() {
  local gpu=$1 dev=$2
  shift 2
  h upgrade --install "$INFER_RELEASE" "$CHART" -n "$FAULT_NS" -f "$VALUES_INFER" \
    --set infer.modelJobId="$MODEL_JOB" --set image.tag="$TAG" --set gpu="$gpu" --set-string infer.device="$dev" \
    --set-string model.version=fault-test --set infer.workMs=0 --set infer.timeoutMs=10000 "$@" >/dev/null
}
# infer_deploy GPU 장치 [helm 인자...] : infer_helm에 --wait(파드 Ready까지, 최대 5분)를 더한 것 + Service가 퍼질 시간 5초
infer_deploy() {
  local gpu=$1 dev=$2
  shift 2
  infer_helm "$gpu" "$dev" "$@" --wait --timeout 5m
  sleep 5
}
# infer_url : 실험용 추론 Service 주소(같은 네임스페이스 안에서 쓰는 짧은 이름)
infer_url() { printf 'http://%s:8080' "$INFER_RELEASE"; }
# infer_pod : 삭제 중이 아닌 가장 최근 추론 파드 이름
infer_pod() {
  kf get pods -l "app.kubernetes.io/instance=$INFER_RELEASE" -o json |
    jq -r '[.items[] | select(.metadata.deletionTimestamp == null)] | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty'
}
# ready_pod_other_than 이름 : 그 파드가 아닌, 삭제 중이 아닌 추론 파드 중 Ready인 것이 있으면 성공
ready_pod_other_than() {
  kf get pods -l "app.kubernetes.io/instance=$INFER_RELEASE" -o json |
    jq -e --arg old "$1" '[.items[]
      | select(.metadata.name != $old and .metadata.deletionTimestamp == null)
      | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length > 0' >/dev/null
}
# infer_metrics : 프로버 파드 안에서 추론 워커의 /metrics를 읽는다
infer_metrics() { kf exec "$PROBE" -- curl -s --max-time 5 "$(infer_url)/metrics"; }
# device_is 장치 : /metrics의 k3slab_infer_info device 레이블이 그 값이면 성공
device_is() {
  local m
  m=$(infer_metrics) || return 1
  grep -q "k3slab_infer_info{device=\"$1\"" <<<"$m"
}
# pod_timeline : 파드 JSON(표준입력)에서 쿠버네티스가 적은 시각을 "생성 후 몇 초"로 풀어 쓴다 (1초 단위)
pod_timeline() {
  jq -r '
    (.metadata.creationTimestamp | fromdateiso8601) as $c
    | ((.status.conditions // []) | map(select(.status == "True") | {key: .type, value: ((.lastTransitionTime | fromdateiso8601) - $c)}) | from_entries) as $cond
    | ((.status.containerStatuses // []) | .[0].state.running.startedAt // null) as $st
    | "생성 \(.metadata.creationTimestamp) → 스케줄 +\($cond.PodScheduled // "-")s → 컨테이너 시작 +\(if $st then (($st | fromdateiso8601) - $c) else "-" end)s → Ready +\($cond.Ready // "-")s"'
}
# pods_overview 라벨 : 그 라벨 파드의 이름·상태·노드·재시작 횟수 표 (보고서용)
pods_overview() {
  kf get pods -l "$1" -o json | jq -r '.items[]
    | "\(.metadata.name)  \(.status.phase)  node=\(.spec.nodeName // "-")  restarts=\([.status.containerStatuses[]?.restartCount] | add // 0)  \(.metadata.deletionTimestamp // "" | if . == "" then "" else "Terminating" end)"'
}

# prom_q 쿼리 : Prometheus 즉시 쿼리 결과("레이블<TAB>값" 줄들)를 출력한다. 쿼리는 쿠버네티스 API의 서비스 프록시로 보내므로
#   포트 포워딩이 필요 없다. --prom이 없으면 아무것도 하지 않고 return 1.
prom_q() {
  [[ -n "$PROM_PROXY" ]] || return 1
  local ns=${PROM_PROXY%%/*} svc=${PROM_PROXY#*/} q
  q=$(jq -rn --arg q "$1" '$q | @uri')
  k get --raw "/api/v1/namespaces/$ns/services/$svc/proxy/api/v1/query?query=$q" 2>/dev/null |
    jq -r '.data.result[]? | "\(.metric | to_entries | map("\(.key)=\(.value)") | join(","))\t\(.value[1])"'
}
# prom_window : 실험 시작부터 지금까지의 초 (Prometheus 범위 쿼리의 [구간])
prom_window() { printf '%ss' "$(($(date +%s) - EXP_START + 30))"; }
# prom_report "제목" 쿼리 : 쿼리 결과를 보고서에 남긴다. 설정이 없으면 한 번만 "미설정" 안내를 남긴다.
prom_report() {
  local out
  if [[ -z "$PROM_PROXY" ]]; then
    grep -q 'Prometheus: 미설정' "$REPORT" 2>/dev/null || md "" "- Prometheus: 미설정(--prom 없음). 이 보고서는 시각 기록과 프로버 로그만 근거로 한다."
    return 0
  fi
  out=$(prom_q "$2" || true)
  block "Prometheus: $1  (쿼리: $2)" "${out:-(결과 없음: 지표가 아직 수집되지 않았거나 레이블이 다르다)}"
}
# prom_settle : Prometheus 수집 간격(보통 15~30초)만큼 기다려 마지막 값이 들어오게 한다 (--prom을 줬을 때만)
prom_settle() { [[ -z "$PROM_PROXY" ]] || sleep 30; }

# --- 7) 실험 목록과 --dry-run 절차 출력 ---

# list_experiments : 실험 표를 출력한다
list_experiments() {
  cat <<'EOF'
ID  명령           장애                              파괴하는 것          GPU    기존 시험 재사용
F1  infer-kill     추론 파드 강제 종료               추론 파드 1개        선택   -
F2  train-kill     학습 파드 중단 → 체크포인트 재개  학습 파드 1개        사용   scripts/train-resume-test.sh
F3  node-stop      worker VM 정지 → 파드 재배치      VM 1대(hard 정지)    -      scripts/k3s-lab.sh 5번(방식)
F4  mysql-down     MySQL 중단                        MySQL 파드(replicas 0) 선택 scripts/job-db-test.sh(--with-training)
F5  gpu-busy       GPU 사용 불가 → CPU 대체 경로     GPU 점유 파드        사용   -
F6  registry-down  레지스트리 중단                    레지스트리 파드      -      -
F7  overload       과부하 → 429와 큐 대기            (부하만, 파괴 없음)  -      scripts/infer-bench.sh ②(방식)
F8  bad-deploy     잘못된 배포(없는 이미지 태그)     추론 릴리스 갱신     선택   -
--  inspect        읽기 전용 점검(막을 수 없는 장애의 근거)
--  cleanup        끊긴 실험 뒤처리
권장 순서와 승인 방법: docs/plan-week13-verification.md 6절
EOF
}

# show_plan 실험 : --dry-run으로 절차·측정·성공 기준·되돌리기를 출력한다. 아무것도 실행하지 않는다.
show_plan() {
  local m=${MODEL_JOB:-"<--model-job 필요>"} dev=cpu lim=60 mode=${MODE:-} dn=${DOWN_SECONDS:-}
  if ((GPU > 0)); then dev=cuda; lim=120; fi
  printf '[dry-run] 아무것도 실행하지 않는다 (클러스터·VM 접속 없음, 보고서 없음)\n'
  case $1 in
    inspect) cat <<EOF
F-- inspect — 읽기 전용 점검
절차    : 노드(역할·taint·Ready·자원) → 컨트롤 플레인 수 → PV와 노드 묶임 → 복제본 1개짜리 Deployment → GPU 수와 사용 중인 파드
          → hostPath 데이터 위치. 모두 kubectl get만 쓴다. 보고서: docs/labs/fault-inspect-<날짜>.md
성공    : 항목마다 사실을 기록한다(PASS/FAIL 없음). 막을 수 없는 장애 표(설계 문서 2절)의 근거가 된다.
EOF
      ;;
    cleanup) cat <<EOF
F-- cleanup — 끊긴 실험 뒤처리 (노드 $NODE)
절차    : $FAULT_NS 안의 helm 릴리스 제거 → 네임스페이스 삭제 → default의 train-fault-* 릴리스 제거
          → MySQL·레지스트리 replicas가 0이면 1로 → VM $NODE가 꺼져 있으면 vmrun으로 켬 → 노드 상태 출력
EOF
      ;;
    infer-kill)
      mode=${mode:-force}
      cat <<EOF
F1 infer-kill — 추론 파드 강제 종료
대상    : 릴리스 $INFER_RELEASE (네임스페이스 $FAULT_NS), 모델 작업 $m, 이미지 infer-worker:$TAG, 장치 $dev(GPU $GPU), 종료 방식 $mode
자원    : 추론 파드 1개(gpu-host, requests 250m/64Mi, GPU $GPU개) + 프로버 파드 1개(10m/16Mi, limit 64Mi)
승인    : 파드 삭제 + 새 네임스페이스 배포. GPU 1이면 GPU 사용 승인도 필요
절차    : 1. 노드 4개 Ready·이전 실험 흔적 없음 확인, 승인
          2. 추론 릴리스 배포(Ready까지) → 프로버(초당 약 10회 POST /infer) 시작, 평상시가 모두 200인지 확인
          3. T0 기록 → 파드 삭제 (force: --grace-period=0 --force / graceful: SIGTERM + preStop 5초 / 이번 방식: $mode)
          4. 새 파드가 Ready 될 때까지 1초 간격으로 확인 → T1 기록, 쿠버네티스 시각으로 스케줄·시작·Ready 구간 분해
          5. 복구 뒤 10초 더 관찰 → 프로버 로그로 실패 요청 수·실패 구간 계산, /metrics의 device 확인
측정    : 복구 시간(T1-T0), 실패 요청 수와 코드, 실패 구간, 파드 시도 수·재시작 수, (--prom) 요청 수 증가량·재시작 횟수
성공    : 새 파드가 사람 개입 없이 Ready / 복구 뒤 요청이 모두 200 / 장치가 $dev / 복구 시간 ${lim}s 이내(참고 기준, 실측 뒤 조정)
되돌리기: helm uninstall $INFER_RELEASE → 네임스페이스 삭제(프로버 포함, GPU 반환) → 노드·MySQL·레지스트리 정상 확인
EOF
      ;;
    train-kill)
      mode=${mode:-graceful}
      cat <<EOF
F2 train-kill — 학습 파드 중단 → 체크포인트 재개
대상    : 학습 작업 ${JOB_ID:-fault-train-<MMDDHHMM>} (default 네임스페이스, Helm 릴리스 train-<작업번호>), 방식 $mode
자원    : 학습 파드 1개(gpu-host, requests 500m/1Gi, GPU 1개). GPU를 쓰는 다른 파드가 있으면 시작하지 않는다.
승인    : 파드 삭제 + GPU 사용
절차    : [graceful] 1. scripts/train-resume-test.sh <작업번호>를 그대로 실행 (6 에폭, 2 에폭 뒤 파드 삭제 = SIGTERM, 재시도, 같은 번호 재요청)
                     2. MySQL job_events에서 INTERRUPTED→재개 RUNNING 시각 차이와 재개 체크포인트를 읽는다 (밀리초 기록)
          [force]    1. scripts/job.sh submit train <작업번호> --epochs 8 --epoch-sleep 6 → 에폭 2 기록 뒤 T0
                     2. kubectl delete pod --grace-period=0 --force (SIGTERM 없이 SIGKILL: 종료 체크포인트가 남지 않는다)
                     3. 재시도 파드가 resumed_from을 기록할 때까지 대기 → T1, 끝까지 학습해 DONE 확인, 재개한 체크포인트의 에폭이 종료 직전 DB 에폭 이상인지 비교
측정    : 중단→재개 시간, 재개한 체크포인트(에폭·스텝), 종료 직전 DB 에폭과의 차이, attempts, 최종 상태
성공    : 재시도 파드가 마지막 체크포인트에서 재개 / 최종 DONE + model.k3sm / attempts 2 이상 / graceful은 재개 체크포인트 = INTERRUPTED 체크포인트(손실 0), force는 재개 에폭 ≥ 강제 종료 직전 DB 에폭
되돌리기: helm uninstall train-<작업번호>. DB 행과 체크포인트 폴더는 증거로 남긴다(폴더는 root 소유라 sudo 없이 못 지운다)
참고    : graceful은 기존 스크립트가 docs/labs/train-resume-<날짜>.md를 따로 만든다. 그 경로를 이 보고서에 적는다.
EOF
      ;;
    node-stop)
      cat <<EOF
F3 node-stop — worker VM 정지 → 파드 재배치
대상    : 노드 $NODE (VM, vmrun hard 정지), 실험 Deployment fault-api 3개(whoami), tolerationSeconds ${TOL:-기본 300}, 분산 배치 $([[ $SPREAD == 1 ]] && echo 켬 || echo 끔)
자원    : fault-api 파드 3개(각 10m/16Mi) + 프로버 1개. VM이 꺼지면 그 노드의 다른 파드도 함께 멈춘다 → 다른 작업자 파드가 있으면 --allow-other-pods 없이는 시작하지 않는다.
승인    : VM 정지(가장 파괴적). 실행 전 $NODE에 무엇이 떠 있는지 총괄과 확인
절차    : 1. VM이 켜져 있고(vmrun list) vmmon·vmnet 모듈이 올라와 있어 다시 켤 수 있는지 확인, 노드의 다른 파드 목록을 보고서에 남김
          2. fault-api 배포(3개 Ready), 배치 기록. 프로버를 $NODE 아닌 노드에 띄움(초당 약 10회 GET)
          3. 복구 단계(VM 기동)를 먼저 등록 → T0 기록 → vmrun -T ws stop <vmx> hard
          4. 노드가 NotReady 될 때까지(t1), fault-api 3개가 다른 노드에서 모두 Ready 될 때까지(t2) 1초 간격으로 확인 (한도 15분)
          5. vmrun -T ws start <vmx> nogui → 노드가 Ready 될 때까지(t3). 프로버 로그로 실패 요청 수·구간 계산, 파드가 원래 노드로 돌아오는지 관찰
측정    : t1(NotReady), t2(재배치 완료), t3(VM 기동→Ready), 실패 요청 수·구간, 배치 전후 노드 분포, (--prom) 노드 Ready 지표
성공    : 노드 NotReady 감지 / 3개가 사람 개입 없이 다른 노드에서 Ready / 노드가 다시 Ready / 정리 후 4노드 Ready
되돌리기: vmrun으로 VM 기동(실행이 끊겨도 자동 실행) → 노드 Ready 확인 → 네임스페이스 삭제. VM이 안 켜지면 중단하고 총괄에게 알린다(entry.sh는 플랫폼 담당).
참고    : 이전 기록 docs/labs/k3s-lab-20261030-1646.md 5절: NotReady 44초, 재배치 완료까지 합계 352초(기본 toleration 300초)
EOF
      ;;
    mysql-down)
      dn=${dn:-30}
      cat <<EOF
F4 mysql-down — MySQL 중단 (${dn}초)
대상    : $DB_NS/mysql (replicas 1→0→1). 추론 지속 확인용 릴리스 $INFER_RELEASE는 --model-job이 있을 때만(모델 작업 $m)
자원    : (--model-job 있으면 추론 파드 + 프로버). MySQL 파드는 원래 것(requests 100m/512Mi)이 다시 뜬다.
승인    : DB 중단. 다른 작업자가 DB를 쓰는 중인지 확인(Jenkins·Argo CD·모니터링은 DB를 쓰지 않는 것으로 알고 있다)
절차    : 1. jobs·job_events 행 수 기록, 복구 단계 등록(replicas 1)
          2. (선택) 추론 배포 + 프로버 시작
          3. T0 → kubectl scale deploy/mysql --replicas=0 → 파드가 사라질 때까지
          4. 중단 중: ① scripts/job.sh submit train fault-db-<번호> 가 실패하고 Job·Helm 릴리스가 만들어지지 않는지 ② 추론 요청이 계속 200인지
          5. ${dn}초 뒤 replicas 1 → 쿼리에 다시 답할 때까지(t_db) → 행 수가 그대로인지, job.sh list가 되는지
          6. --with-training: scripts/job-db-test.sh를 이어서 실행(학습 중 DB 중단, 기록 보류 후 채움 — GPU 사용)
측정    : DB 없음 구간 길이, 복구 시간(t_db), 등록 요청 결과(종료 코드·메시지), 추론 실패 요청 수, 행 수 전후
성공    : 중단 중 등록이 실패하고 새 Job이 없음 / 추론 요청 실패 0 / 복구 뒤 행 수 동일 + PVC Bound / MySQL 1/1 Ready
되돌리기: replicas 1 (실행이 끊겨도 자동 실행) → 추론 릴리스·네임스페이스 삭제
참고    : 학습 중 DB 중단은 docs/labs/job-db-20261107-1258.md 4절에 이미 있다 (에폭 3→5 진행, 못 쓴 기록은 DB가 돌아온 뒤 채워짐)
EOF
      ;;
    gpu-busy) cat <<EOF
F5 gpu-busy — GPU 사용 불가 → CPU 대체 경로
대상    : 릴리스 $INFER_RELEASE, 모델 작업 $m, 이미지 infer-worker:$TAG, GPU 점유용 파드 fault-gpu-hold(busybox sleep, GPU 1개)
자원    : GPU 점유 파드(10m/8Mi, GPU 1개) → 추론 파드(250m/64Mi) + 프로버. GPU는 한 번에 한 파드만 쓴다(점유 → 반환 → 추론 순서).
승인    : GPU 사용 + 파드 배포. GPU를 쓰는 다른 파드가 있으면 시작하지 않는다.
절차    : 1. GPU가 비어 있는지 확인 → fault-gpu-hold 실행(GPU 점유)
          2. GPU 1개를 요청하는 추론 배포(기다리지 않음) → 파드가 Pending이고 사유가 Insufficient nvidia.com/gpu인지 확인 (자동으로 CPU가 되지 않는다)
          3. 같은 릴리스를 gpu=0, DEVICE=auto로 다시 배포(= 대체 경로, scripts/job.sh submit infer --device cpu와 같은 설정) → Ready까지 시간(t_fb)
          4. /metrics의 device가 cpu인지, 응답이 200인지 확인
          5. 프로버 시작 → GPU 점유 파드 삭제 → gpu=1, DEVICE=cuda로 다시 배포 → device가 cuda인지, 전환 중 요청 실패 수·구간
측정    : Pending 사유, t_fb(대체 배포→Ready), 장치 값, GPU 복귀 시간과 전환 중 실패 요청 수
성공    : GPU 요청 파드는 Pending / gpu=0 + auto 배포는 CPU로 응답(device=cpu) / GPU가 비면 cuda로 복귀
되돌리기: 점유 파드·추론 릴리스·네임스페이스 삭제 → GPU 반환 확인
EOF
      ;;
    registry-down)
      dn=${dn:-60}
      cat <<EOF
F6 registry-down — 레지스트리 중단 (${dn}초)
대상    : $DB_NS/registry (replicas 1→0→1), 확인용 파드는 worker-cpu-2(role=app)에서 infer-worker:$TAG 이미지로 실행(명령 sleep)
자원    : 확인용 파드(각 10m/16Mi, 동시에 2~3개). 이미지는 작다(Debian slim 기반).
승인    : 레지스트리 중단. 그동안 Kaniko 빌드·Jenkins 이미지 push는 실패한다 → CICD 작업자와 시간을 맞춘다.
절차    : 1. 레지스트리가 정상인지 확인, 복구 단계 등록
          2. 예열: pull 정책 IfNotPresent 파드를 worker-cpu-2에 띄워 이미지를 노드에 받아 둠 → 삭제
          3. T0 → replicas 0 → 파드가 사라질 때까지
          4. 중단 중: ① IfNotPresent 파드(이미지가 노드에 있음)는 Running이 되는가 ② Always 파드(레지스트리 확인 필요)는 ErrImagePull/ImagePullBackOff가 되는가
          5. ${dn}초 뒤 replicas 1 → Ready(t_reg) → Always 파드가 Running이 될 때까지(t_pull, ImagePullBackOff 재시도 간격 때문에 걸린다)
          6. 복구 뒤 /v2/_catalog에 infer-worker가 있는지(local-path 데이터 보존)
측정    : 중단 중 두 파드 결과와 대기 사유, t_reg, t_pull(복구→Running), 카탈로그 확인
성공    : 노드에 이미지가 있으면 중단 중에도 시작 / 없으면 실패 / 레지스트리 복구 뒤 자동으로 받아 Running(사람 개입 없음) / 카탈로그 유지
되돌리기: replicas 1 (실행이 끊겨도 자동 실행) → 확인용 파드·네임스페이스 삭제
EOF
      ;;
    overload) cat <<EOF
F7 overload — 과부하 → 429와 큐 대기
대상    : 릴리스 $INFER_RELEASE (CPU, 큐 20, 배치 4, 스레드 1, WORK_MS 50 — scripts/infer-bench.sh ②와 같은 조건), 모델 작업 $m
부하    : 요청 $REQUESTS개, 동시 $CONC개 (curl Job, 요청마다 새 연결) + 0.2초마다 큐 길이 기록
자원    : 추론 파드 1개(gpu-host CPU, 250m/64Mi) + 부하 Job(10m 이하)
승인    : 새 네임스페이스 배포(파괴 없음). 부하가 gpu-host CPU를 잠깐 쓴다.
절차    : 1. 추론 배포 → 이전 /metrics 기록 → 부하 Job 실행 → 끝날 때까지 대기
          2. 응답 코드별 개수, 코드별 응답 시간(중앙값·95%), 샘플링한 큐 길이 최댓값, 받아들인 요청의 평균 대기(metrics 증가량)
          3. 부하 뒤 큐가 비고 파드 재시작이 0이며 일반 요청이 200인지 확인
측정    : 코드별 개수, 429 응답 시간 vs 200 응답 시간, 큐 길이 최댓값(용량 20), 평균 대기
성공    : 429가 발생 / 200·429 외 응답(000, 5xx)이 없음 / 429의 중앙값 응답 시간이 200보다 짧음(즉시 거절) / 큐 길이 ≤ 용량 / 부하 뒤 정상
되돌리기: 부하 Job·추론 릴리스·네임스페이스 삭제
참고    : 같은 조건의 이전 기록 docs/labs/infer-bench-20261107-1257.md ②: 300개 중 211개가 429
EOF
      ;;
    bad-deploy) cat <<EOF
F8 bad-deploy — 잘못된 배포(없는 이미지 태그)
대상    : 릴리스 $INFER_RELEASE, 모델 작업 $m, 정상 태그 $TAG → 없는 태그 $MISSING_TAG, 장치 $dev(GPU $GPU)
자원    : 추론 파드 1개(+ 새 파드 1개가 잠깐 ImagePullBackOff) + 프로버
승인    : 배포 갱신. GPU 1이면 GPU 사용 승인도 필요(이 경우 서비스가 끊길 것으로 예상: maxSurge 0)
절차    : 1. 정상 배포 + 프로버 시작, helm 리비전 기록
          2. helm upgrade 로 없는 태그 배포(기다리지 않음) → 새 파드가 ErrImagePull/ImagePullBackOff가 되는 시각, 예전 파드가 계속 Ready인지
          3. 30초 관찰 → helm rollback <기록한 리비전> --wait → Ready까지 시간
          4. 프로버 요약(배포 중 실패 요청 수), helm history 기록
측정    : 이상 감지까지(파드 상태 확인 기준), 배포 중 실패 요청 수, 롤백 시간
성공    : 새 파드가 Ready가 되지 않음 / CPU: 배포 중 실패 요청 0 (GPU는 관찰만) / 롤백 뒤 Ready 1/1, 요청 200
되돌리기: helm rollback → 릴리스·네임스페이스 삭제
EOF
      ;;
  esac
}

# --- 8) 실험 구현 ---

# run_inspect : 읽기 전용 점검 — 막을 수 없는 장애의 근거를 모은다. 클러스터에는 get만 한다.
run_inspect() {
  [[ -f "$KUBECONFIG_FILE" ]] || die "missing $KUBECONFIG_FILE"
  api_reachable || die "cannot reach the Kubernetes API server within 5 seconds: the cluster looks down"
  k get nodes --request-timeout=10s >/dev/null 2>&1 || die "cannot read the nodes (is the cluster up?)"
  begin_report "장애 영역 점검 (읽기 전용)"
  md "" "클러스터에는 \`kubectl get\`만 했다. 막을 수 없는 장애 표(설계 문서 2절)의 근거다."
  block "노드: 이름 / 상태 / 역할 레이블 / taint / CPU·메모리 할당 가능량 / GPU" "$(k get nodes -o json | jq -r '.items[]
    | "\(.metadata.name)  \(.status.conditions[] | select(.type == "Ready") | .status)  role=\(.metadata.labels["k3slab.io/role"] // "-")  control-plane=\(.metadata.labels | has("node-role.kubernetes.io/control-plane"))  taints=\([.spec.taints[]? | "\(.key)=\(.value // ""):\(.effect)"] | join(","))  cpu=\(.status.allocatable.cpu) mem=\(.status.allocatable.memory) gpu=\(.status.allocatable["nvidia.com/gpu"] // "0")"')"
  local cp
  cp=$(k get nodes -l node-role.kubernetes.io/control-plane --no-headers | wc -l)
  note "컨트롤 플레인 노드: **${cp}개**. 1개면 그 VM이 멈출 때 새 스케줄링과 자동 복구가 모두 멈춘다."
  block "PV: 이름 / 저장소 클래스 / 연결된 PVC / 묶인 노드(nodeAffinity)" "$(k get pv -o json | jq -r '.items[]
    | "\(.metadata.name)  \(.spec.storageClassName)  \(.spec.claimRef.namespace // "-")/\(.spec.claimRef.name // "-")  node=\([.spec.nodeAffinity.required.nodeSelectorTerms[]?.matchExpressions[]?.values[]?] | join(","))"')"
  block "복제본 1개짜리 Deployment (한 파드가 죽으면 새 파드가 뜰 때까지 서비스가 없다)" "$(k get deploy -A -o json | jq -r '.items[] | select(.spec.replicas == 1) | "\(.metadata.namespace)/\(.metadata.name)"')"
  block "GPU를 요청하는 파드" "$(gpu_pods || true)"
  block "노드별 파드 수" "$(k get pods -A -o json | jq -r '[.items[] | select(.status.phase == "Running" or .status.phase == "Pending")] | group_by(.spec.nodeName) | .[] | "\(.[0].spec.nodeName // "미배치")  \(length)개"')"
  note "gpu-host의 \`$CKPT_ROOT\`(체크포인트·모델)와 \`/var/lib/k3slab/datasets\`는 이 PC 디스크의 폴더 하나뿐이다(복제 없음)."
  md "" "## 결과 요약" "" "점검 항목만 기록했다(PASS/FAIL 없음)."
  log "inspect done (report: $REPORT)"
}

# run_cleanup : 끊긴 실험 뒤처리 — 남은 릴리스·네임스페이스를 지우고, 멈춘 MySQL·레지스트리를 올리고, 꺼진 VM을 켠다
run_cleanup() {
  [[ -f "$KUBECONFIG_FILE" ]] || die "missing $KUBECONFIG_FILE"
  api_reachable || die "cannot reach the Kubernetes API server within 5 seconds: the cluster looks down"
  local r vmx
  if k get namespace "$FAULT_NS" >/dev/null 2>&1; then
    for r in $(h list -n "$FAULT_NS" -q 2>/dev/null); do h uninstall "$r" -n "$FAULT_NS" >/dev/null 2>&1 || true; done
    k delete namespace "$FAULT_NS" --wait=false >/dev/null 2>&1 || true
    log "removed namespace $FAULT_NS (deleting)"
  fi
  for r in $(h list -q 2>/dev/null | grep '^train-fault-' || true); do h uninstall "$r" >/dev/null 2>&1 || true; log "removed release $r"; done
  for r in mysql registry; do
    if [[ "$(k -n "$DB_NS" get deploy "$r" -o jsonpath='{.spec.replicas}' 2>/dev/null)" == 0 ]]; then
      log "scaling $r back to 1"
      k -n "$DB_NS" scale "deploy/$r" --replicas=1 >/dev/null
    fi
  done
  vmx=$(vmx_path "$NODE" 2>/dev/null || true)
  if [[ -n "$vmx" ]] && ! vm_running "$vmx"; then
    log "VM $NODE is off: starting it with vmrun"
    vmrun -T ws start "$vmx" nogui
  fi
  k get nodes
}

# --- VM 도구 (node-stop, cleanup) ---
# vmx_path 노드 : VM의 .vmx 경로. 기본 위치($LAB_VM_DIR/<이름>/<이름>.vmx)에 없으면 Terraform output(읽기 전용)에서 찾는다.
vmx_path() {
  local v="$LAB_VM_DIR/$1/$1.vmx"
  if [[ -f "$v" ]]; then printf '%s\n' "$v"; return 0; fi
  "$REPO_ROOT/scripts/tf.sh" output -json nodes | jq -r --arg n "$1" '.[$n].path // empty'
}
# vm_running vmx경로 : vmrun이 그 VM을 실행 중으로 보면 성공
vm_running() { local l; l=$(vmrun -T ws list 2>/dev/null) || return 1; grep -qxF "$1" <<<"$l"; }
# vm_modules_loaded : VMware 커널 모듈(vmmon, vmnet)이 올라와 있으면 성공 (없으면 꺼진 VM을 다시 켤 수 없다)
vm_modules_loaded() { local m; m=$(lsmod | awk '{print $1}'); grep -qx vmmon <<<"$m" && grep -qx vmnet <<<"$m"; }

# ---------------------------------------------------------------------------------------------------------------------
# F1 infer-kill : 추론 파드 강제 종료
# ---------------------------------------------------------------------------------------------------------------------
run_infer_kill() {
  local mode=${MODE:-force} dev=cpu lim=60 old old_node t0 t1 recovered=0 dev_ok=0 newp sumr failed tl log_file
  if ((GPU > 0)); then dev=cuda; lim=120; fi
  [[ "$mode" == force || "$mode" == graceful ]] || die "--mode must be force or graceful for infer-kill"
  need_model
  if ((GPU > 0)); then gpu_free || die "GPU is in use by: $(gpu_pods | tr '\n' ' ')"; fi
  confirm "F1 infer-kill: $FAULT_NS 네임스페이스에 추론 파드($dev)를 띄우고 $mode 방식으로 지웁니다(GPU $GPU)."
  begin_report "F1 추론 파드 강제 종료 시험"
  md "- 대상: 릴리스 \`$INFER_RELEASE\`(네임스페이스 \`$FAULT_NS\`), 모델 작업 \`$MODEL_JOB\`, 이미지 \`infer-worker:$TAG\`, 장치 \`$dev\`(GPU $GPU), 종료 방식 \`$mode\`"

  # 복구 단계는 만들기 전에 등록한다 (역순 실행: 릴리스 제거 → 네임스페이스 삭제)
  ensure_ns
  push_restore restore_ns
  push_restore restore_infer
  log "deploying $INFER_RELEASE (device $dev, tag $TAG, model $MODEL_JOB)"
  infer_deploy "$GPU" "$dev" || die "$INFER_RELEASE did not become ready (GPU 1: is the GPU free?)"
  probe_start "$PROBE" "$(infer_url)/infer" 1
  wait_for 180 probe_ready "$PROBE" || die "baseline requests are not all 200 (kubectl -n $FAULT_NS logs $PROBE)"
  old=$(infer_pod)
  old_node=$(kf get pod "$old" -o jsonpath='{.spec.nodeName}')
  md "" "## 1. 평상시" "" "- 추론 파드 \`$old\`(노드 $old_node)가 Ready이고, 프로버 요청이 모두 200이다."
  sleep 5

  # 장애 주입: force는 SIGKILL(유예 0, preStop 건너뜀), graceful은 SIGTERM + preStop 5초 + 종료
  t0=$(now)
  log "killing $old ($mode)"
  if [[ "$mode" == force ]]; then
    kf delete pod "$old" --grace-period=0 --force --wait=false >/dev/null 2>&1
  else
    kf delete pod "$old" --wait=false >/dev/null
  fi
  md "" "## 2. 장애" "" "- 파드 삭제 시각 T0 = $(date '+%H:%M:%S')"
  if wait_for 600 ready_pod_other_than "$old"; then
    t1=$(now)
    recovered=1
  else
    t1=$(now)
  fi
  metric "복구 시간 (T0 → 새 파드 Ready)" "$(elapsed "$t0" "$t1")초$([[ $recovered == 1 ]] || echo ' (10분 안에 복구되지 않음)')"
  sleep 10

  # 결과 모으기
  newp=$(infer_pod)
  if [[ -n "$newp" ]]; then
    tl=$(kf get pod "$newp" -o json | pod_timeline)
    block "새 파드 $newp 의 시각 (쿠버네티스 기록, 1초 단위)" "$tl"
    metric "컨트롤러가 새 파드를 만들기까지 (T0 → 생성)" "$(awkc -v c="$(epoch_of "$(kf get pod "$newp" -o jsonpath='{.metadata.creationTimestamp}')")" -v t="$t0" 'BEGIN { printf "%.0f", c - int(t) }')초 안팎(1초 단위)"
  fi
  block "파드 목록 (시도한 파드 수와 상태)" "$(pods_overview "app.kubernetes.io/instance=$INFER_RELEASE")"
  block "관련 이벤트 (최근 15개)" "$(kf get events --sort-by=.lastTimestamp 2>/dev/null | tail -15)"
  device_is "$dev" && dev_ok=1
  log_file=$(mktemp)
  probe_stop "$PROBE" "$log_file"
  sumr=$(probe_report "$log_file" "$t0")
  failed=$(kv "$sumr" failed)
  metric "실패한 요청 수" "${failed:-?} / $(kv "$sumr" total) (코드별 $(kv "$sumr" codes))"
  metric "실패 구간 (첫 실패 ~ 마지막 실패)" "$(window_text "$sumr")"
  prom_settle
  prom_report "요청 결과별 증가량" "sum by (result) (increase(k3slab_infer_requests_total{namespace=\"$FAULT_NS\"}[$(prom_window)]))"
  prom_report "컨테이너 재시작 횟수" "max(kube_pod_container_status_restarts_total{namespace=\"$FAULT_NS\"})"

  md "" "## 3. 판정"
  check "새 파드가 사람 개입 없이 Ready" is_true "$recovered"
  check "복구 뒤 마지막 30개 요청이 모두 200" probe_tail_ok "$log_file" 30
  check "새 파드의 계산 장치가 $dev (/metrics의 device)" is_true "$dev_ok"
  check "복구 시간이 ${lim}초 이내 (참고 기준, 실측 뒤 조정)" le "$(elapsed "$t0" "$t1")" "$lim"
  rm -f "$log_file"

  md "" "## 4. 되돌리기"
  run_restores
  verify_restored
  finish
}

# ---------------------------------------------------------------------------------------------------------------------
# F2 train-kill : 학습 파드 중단 → 체크포인트 재개
# ---------------------------------------------------------------------------------------------------------------------

# restore_train : 이 실험의 학습 릴리스 제거 (DB 행과 체크포인트 폴더는 증거로 남긴다)
restore_train() { h uninstall "train-$JOB_ID" >/dev/null 2>&1 || true; }
# job_timeline 작업번호 : job_events를 "에폭초<TAB>상태<TAB>에폭<TAB>체크포인트<TAB>resumed_from" 줄로 (시각은 UNIX_TIMESTAMP, 밀리초)
job_timeline() {
  db "SELECT UNIX_TIMESTAMP(at), status, COALESCE(JSON_UNQUOTE(JSON_EXTRACT(detail, '\$.epoch')), '-'),
        COALESCE(checkpoint_path, '-'), COALESCE(JSON_UNQUOTE(JSON_EXTRACT(detail, '\$.resumed_from')), '-')
      FROM job_events WHERE job_id = '$1' ORDER BY id"
}
# field 작업번호 컬럼식 : jobs 행의 값 하나
field() { db "SELECT $2 FROM jobs WHERE job_id = '$1'"; }
# job_pod Job이름 : 삭제 중이 아닌 가장 최근 파드
job_pod() {
  k get pods -l job-name="$1" -o json |
    jq -r '[.items[] | select(.metadata.deletionTimestamp == null)] | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty'
}
# epoch_at_least 작업번호 N : DB에 기록된 에폭이 N 이상이면 성공
epoch_at_least() { local e; e=$(field "$1" "COALESCE(JSON_EXTRACT(detail, '\$.epoch'), 0)"); ((${e:-0} >= $2)); }
# has_resumed 작업번호 : 재개 기록(resumed_from이 있는 RUNNING 이력)이 있으면 성공
has_resumed() { [[ "$(db "SELECT COUNT(*) FROM job_events WHERE job_id = '$1' AND status = 'RUNNING' AND JSON_EXTRACT(detail, '\$.resumed_from') IS NOT NULL")" -ge 1 ]]; }
# job_status_is 작업번호 상태 : jobs.status가 그 값이면 성공
job_status_is() { [[ "$(field "$1" status)" == "$2" ]]; }

run_train_kill() {
  local mode=${MODE:-graceful} id=${JOB_ID:-fault-train-$(date +%m%d%H%M)} jobsh="$REPO_ROOT/scripts/job.sh" tl t_i t_r rc=0
  [[ "$mode" == force || "$mode" == graceful ]] || die "--mode must be graceful or force for train-kill"
  JOB_ID=$id
  [[ "$id" =~ $ID_RE ]] || die "job id '$id' is not valid"
  gpu_free || die "GPU is in use by: $(gpu_pods | tr '\n' ' ')"
  mysql_answers || die "MySQL does not answer: training status needs the job database (scripts/job.sh list)"
  confirm "F2 train-kill($mode): 학습 Job($id)을 GPU로 실행하고 파드를 일부러 지웁니다."
  begin_report "F2 학습 파드 중단 → 체크포인트 재개 ($mode)"
  md "- 작업 번호 \`$id\`, 방식 \`$mode\` ($([[ $mode == graceful ]] && echo 'SIGTERM: 기존 scripts/train-resume-test.sh 재사용' || echo 'SIGKILL: --grace-period=0 --force'))"
  push_restore restore_train

  if [[ "$mode" == graceful ]]; then
    # 기존 시험 그대로: 6 에폭, 2 에폭 뒤 SIGTERM 삭제, 재시도 재개, 같은 번호 재요청. 출력은 파일로 받아 보고서에 붙인다.
    local out
    out=$(mktemp)
    "$REPO_ROOT/scripts/train-resume-test.sh" "$id" >"$out" 2>&1 || rc=$?
    block "scripts/train-resume-test.sh $id 출력 (끝 20줄)" "$(tail -20 "$out")"
    note "기존 스크립트가 만든 자체 보고서: \`$(ls -t "$REPO_ROOT"/docs/labs/train-resume-*.md 2>/dev/null | head -1 | sed "s|^$REPO_ROOT/||")\` (이 보고서의 판정은 아래 DB 이력으로 따로 한다)"
    rm -f "$out"
    check "기존 시험 train-resume-test.sh가 통과 (종료 코드 0)" is_true "$((rc == 0))"
  else
    "$jobsh" submit train "$id" --epochs 8 --epoch-sleep 6 >/dev/null
    wait_for 600 epoch_at_least "$id" 2 || die "$id did not reach epoch 2 (scripts/job.sh status $id)"
    local pod ep t0 t1 resumed ck_epoch
    pod=$(job_pod "train-$id")
    ep=$(field "$id" "COALESCE(JSON_EXTRACT(detail, '\$.epoch'), 0)")
    t0=$(now)
    log "force-killing $pod at DB epoch $ep"
    k delete pod "$pod" --grace-period=0 --force --wait=false >/dev/null 2>&1
    md "" "- 파드 \`$pod\`를 DB 에폭 $ep 기록 뒤 강제 삭제(SIGKILL), $(date '+%H:%M:%S')"
    wait_for 300 has_resumed "$id" || log "no resume record within 5 minutes"
    t1=$(now)
    metric "중단 → 재개 기록 (T0 → resumed_from, 확인 간격 1~2초)" "$(elapsed "$t0" "$t1")초"
    wait_for 900 job_status_is "$id" DONE || log "job did not reach DONE"
    # 재개한 체크포인트 이름(ckpt-e<에폭>-s<스텝>.pt)에서 에폭을 읽어, 강제 종료 직전에 DB에 기록된 에폭과 비교한다
    resumed=$(db "SELECT JSON_UNQUOTE(JSON_EXTRACT(detail, '\$.resumed_from')) FROM job_events WHERE job_id = '$id' AND JSON_EXTRACT(detail, '\$.resumed_from') IS NOT NULL ORDER BY id LIMIT 1")
    ck_epoch=$(sed -n 's|.*ckpt-e0*\([0-9][0-9]*\)-s.*|\1|p' <<<"$resumed")
    metric "재개한 체크포인트 / 종료 직전 DB 에폭" "\`${resumed:-?}\` / 에폭 $ep"
    check "재개한 체크포인트의 에폭(${ck_epoch:-?})이 종료 직전 DB 에폭($ep) 이상 (진행이 되돌아가지 않음)" is_true "$([[ -n "$ck_epoch" && "$ck_epoch" -ge "$ep" ]] && echo 1 || echo 0)"
  fi

  # DB 이력에서 중단·재개 시각과 체크포인트를 읽는다 (graceful은 INTERRUPTED 행이 있고, force는 없다)
  tl=$(job_timeline "$id")
  block "상태 이력 (UNIX 시각, 상태, 에폭, 체크포인트, resumed_from)" "$tl"
  t_i=$(awkc -F'\t' '$2 == "INTERRUPTED" { print $1; exit }' <<<"$tl")
  t_r=$(awkc -F'\t' '$2 == "RUNNING" && $5 != "-" { print $1; exit }' <<<"$tl")
  if [[ -n "$t_i" && -n "$t_r" ]]; then
    metric "중단(INTERRUPTED 기록) → 재개(resumed_from 기록)" "$(elapsed "$t_i" "$t_r")초 (DB 시각, 밀리초 기록)"
    check "재개한 체크포인트가 중단 시점 체크포인트와 같음 (손실 0)" same_ckpt "$tl"
  elif [[ -n "$t_r" ]]; then
    note "INTERRUPTED 기록 없음: SIGKILL은 종료 신호를 못 받아 마지막 에폭 체크포인트에서 재개한다. 재개 체크포인트: \`$(awkc -F'\t' '$2 == "RUNNING" && $5 != "-" { print $5; exit }' <<<"$tl")\`"
  fi
  check "재개 기록(resumed_from)이 DB에 있음" has_resumed "$id"
  check "최종 상태 DONE" job_status_is "$id" DONE
  check "attempts가 2 이상 (재시도로 파드가 다시 시작됨)" is_true "$([[ "$(field "$id" attempts)" -ge 2 ]] && echo 1 || echo 0)"
  check "추론용 model.k3sm이 만들어짐" model_exists "$id"
  prom_report "학습 파드 재시작·상태" "kube_pod_status_phase{namespace=\"default\",pod=~\"train-$id-.*\"}"

  md "" "## 되돌리기"
  run_restores
  note "학습 릴리스만 지웠다. DB 행(\`scripts/job.sh status $id\`)과 \`$CKPT_ROOT/$id\`는 증거로 남긴다(폴더는 root 소유)."
  check "노드 ${EXPECT_NODES}개 모두 Ready" all_nodes_ready
  finish
}
# same_ckpt 이력 : INTERRUPTED의 체크포인트와 첫 재개 행의 resumed_from이 같으면 성공 (경로는 컨테이너 안 /checkpoints/... 기준)
same_ckpt() {
  local a b
  a=$(awkc -F'\t' '$2 == "INTERRUPTED" { print $4; exit }' <<<"$1")
  b=$(awkc -F'\t' '$2 == "RUNNING" && $5 != "-" { print $5; exit }' <<<"$1")
  [[ -n "$a" && "$a" != - && "$a" == "$b" ]]
}

# ---------------------------------------------------------------------------------------------------------------------
# F3 node-stop : worker VM 정지 → 파드 재배치
# ---------------------------------------------------------------------------------------------------------------------

# fault_api_manifest : 실험용 API 대역(whoami 3개 + Service). 기본은 대상 노드를 "선호"하고(제안서의 API 파드 배치처럼 한 노드에 몰림),
#   --spread면 노드마다 하나씩 흩어 놓는다. --toleration-seconds가 있으면 NotReady 노드에서 떠나기까지의 유예(기본 300초)를 줄인다.
fault_api_manifest() {
  local tol="" place
  if [[ -n "$TOL" ]]; then
    tol="      tolerations:
        - key: node.kubernetes.io/not-ready
          operator: Exists
          effect: NoExecute
          tolerationSeconds: $TOL
        - key: node.kubernetes.io/unreachable
          operator: Exists
          effect: NoExecute
          tolerationSeconds: $TOL"
  fi
  if ((SPREAD)); then
    # ScheduleAnyway: 멈춘 노드도 분산 계산에 들어가므로 DoNotSchedule이면 대체 파드가 Pending에 걸릴 수 있다
    place="      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: fault-api"
  else
    place="      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: In
                    values: [\"$NODE\"]"
  fi
  cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fault-api
  namespace: $FAULT_NS
spec:
  replicas: 3
  selector:
    matchLabels:
      app: fault-api
  template:
    metadata:
      labels:
        app: fault-api
    spec:
$tol
$place
      containers:
        - name: whoami
          image: $WHOAMI_IMAGE
          ports:
            - containerPort: 80
          readinessProbe:
            tcpSocket:
              port: 80
            periodSeconds: 2
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
---
apiVersion: v1
kind: Service
metadata:
  name: fault-api
  namespace: $FAULT_NS
spec:
  selector:
    app: fault-api
  ports:
    - port: 80
      targetPort: 80
EOF
}
# api_ready_count : fault-api의 Ready 파드 수 / api_ready_off 노드 : Ready가 3개이고 모두 그 노드가 아니면 성공
api_ready_count() {
  kf get pods -l app=fault-api -o json | jq '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length'
}
api_ready_off() {
  kf get pods -l app=fault-api -o json | jq -e --arg n "$1" '
    [.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] as $r
    | ($r | length) == 3 and all($r[]; .spec.nodeName != $n)' >/dev/null
}
# api_placement : fault-api 파드의 노드 분포 ("노드 N개")
api_placement() {
  kf get pods -l app=fault-api -o json | jq -r '.items[] | select(.metadata.deletionTimestamp == null) | .spec.nodeName // "미배치"' | sort | uniq -c | awk '{printf "%s %s개  ", $2, $1} END {print ""}'
}
# on_target N : 대상 노드에서 도는 fault-api 파드가 N개 이상이면 성공
on_target() {
  local c
  c=$(kf get pods -l app=fault-api -o json | jq --arg n "$NODE" '[.items[] | select(.spec.nodeName == $n)] | length')
  ((c >= $1))
}
# spread_ok : fault-api 파드가 서로 다른 노드 3곳에 있으면 성공
spread_ok() { [[ "$(kf get pods -l app=fault-api -o json | jq '[.items[].spec.nodeName] | unique | length')" -ge 3 ]]; }
# other_pods_on_node : 대상 노드에서 돌거나 기다리는 파드 중 시스템·DaemonSet·실험용이 아닌 것의 목록 (다른 작업자의 파드일 수 있다)
other_pods_on_node() {
  k get pods -A --field-selector "spec.nodeName=$NODE" -o json | jq -r --arg ns "$FAULT_NS" '.items[]
    | select(.status.phase == "Running" or .status.phase == "Pending")
    | select(.metadata.namespace != "kube-system" and .metadata.namespace != $ns)
    | select(all(.metadata.ownerReferences[]?; .kind != "DaemonSet"))
    | "\(.metadata.namespace)/\(.metadata.name)"'
}
# vm_start_restore : (복구 단계) VM이 꺼져 있으면 vmrun으로 켠다
vm_start_restore() { vm_running "$VMX" || vmrun -T ws start "$VMX" nogui; }

run_node_stop() {
  local t0 t1 t2 t3 t4 sumr log_file others replaced=0 back=0 seen_nr=0 s_before
  VMX=$(vmx_path "$NODE") || true
  [[ -n "${VMX:-}" && -f "$VMX" ]] || die "no .vmx for $NODE (looked in $LAB_VM_DIR/$NODE and the Terraform output)"
  command -v vmrun >/dev/null || die "vmrun not found"
  vm_modules_loaded || die "VMware kernel modules (vmmon, vmnet) are not loaded: a stopped VM could not be started again. Not stopping $NODE"
  vm_running "$VMX" || die "VM $NODE is not running according to vmrun"
  node_ready "$NODE" || die "node $NODE is not Ready"
  others=$(other_pods_on_node || true)
  if [[ -n "$others" && $ALLOW_OTHER == 0 ]]; then
    die "other pods run on $NODE: $(tr '\n' ' ' <<<"$others"). Tell their owners, then re-run with --allow-other-pods"
  fi
  confirm "F3 node-stop: VM $NODE 의 전원을 강제로 끊습니다(vmrun stop hard). 그 노드의 파드가 모두 멈춥니다."
  begin_report "F3 worker VM 정지 시험 ($NODE)"
  md "- 노드 \`$NODE\` (\`$VMX\`), tolerationSeconds \`${TOL:-기본 300}\`, 분산 배치 \`$([[ $SPREAD == 1 ]] && echo 켬 || echo 끔)\`, 정지 방식 \`vmrun stop hard\`(전원 강제 차단)"
  block "$NODE 에서 도는 다른 파드 (정지하면 함께 멈춘다)" "${others:-(없음)}"

  ensure_ns
  push_restore restore_ns
  kf apply -f - >/dev/null < <(fault_api_manifest)
  wait_for 180 api_ready_count_is 3 || die "fault-api did not become ready (3 replicas)"
  if ((SPREAD)); then
    wait_for 60 spread_ok || die "--spread did not place the 3 pods on 3 different nodes: $(api_placement)"
  else
    wait_for 60 on_target 1 || die "no fault-api pod landed on $NODE: $(api_placement)"
  fi
  s_before=$(api_placement)
  probe_start "$PROBE" "http://fault-api/" 0 "$NODE"
  wait_for 120 probe_ready "$PROBE" || die "baseline requests are not all 200"
  md "" "## 1. 평상시" "" "- fault-api 배치: $s_before" "- 프로버가 $NODE 가 아닌 노드에서 초당 약 10번 GET 요청을 보낸다."
  block "정지 전 노드 상태" "$(k get nodes)"
  sleep 10

  # 장애 주입: 복구(VM 기동)를 먼저 등록한 뒤 정지한다. 그래야 이 스크립트가 중간에 끊겨도 VM이 켜진다.
  push_restore vm_start_restore
  t0=$(now)
  log "stopping VM $NODE (hard)"
  vmrun -T ws stop "$VMX" hard
  md "" "## 2. 장애" "" "- VM 정지 시각 T0 = $(date '+%H:%M:%S')"
  if wait_for 300 node_not_ready "$NODE"; then
    seen_nr=1
    t1=$(now)
    metric "VM 정지 → 노드 NotReady (t1)" "$(elapsed "$t0" "$t1")초"
  else
    t1=$(now)
    note "5분 안에 NotReady가 되지 않았다."
  fi
  if wait_for 900 api_ready_off "$NODE"; then
    t2=$(now)
    replaced=1
    metric "VM 정지 → fault-api 3개가 다른 노드에서 모두 Ready (t2)" "$(elapsed "$t0" "$t2")초 (NotReady 이후 $(elapsed "$t1" "$t2")초)"
  else
    t2=$(now)
    note "15분 안에 3개가 다른 노드에서 Ready가 되지 않았다."
  fi
  block "재배치 뒤 파드" "$(kf get pods -l app=fault-api -o wide 2>/dev/null)"

  # 복구: VM 기동 → 노드 Ready
  md "" "## 3. 복구"
  t3=$(now)
  vmrun -T ws start "$VMX" nogui
  if wait_for 600 node_ready "$NODE"; then
    t4=$(now)
    back=1
    metric "VM 기동 → 노드 Ready (t3)" "$(elapsed "$t3" "$t4")초"
  else
    note "10분 안에 노드가 Ready가 되지 않았다. 플랫폼 담당에게 알린다(scripts/entry.sh는 그 담당이 실행)."
  fi
  sleep 20
  block "복구 뒤 파드 (원래 노드로 돌아오지 않는다: 자동 재균형 없음)" "$(kf get pods -l app=fault-api -o wide 2>/dev/null)"
  note "복구 뒤 배치: $(api_placement)"
  log_file=$(mktemp)
  probe_stop "$PROBE" "$log_file"
  sumr=$(probe_report "$log_file" "$t0")
  metric "실패한 요청 수" "$(kv "$sumr" failed) / $(kv "$sumr" total) (코드별 $(kv "$sumr" codes))"
  metric "실패 구간 (첫 실패 ~ 마지막 실패)" "$(window_text "$sumr")"
  prom_settle
  prom_report "노드 Ready 지표 (정지 동안 0)" "min_over_time(kube_node_status_condition{node=\"$NODE\",condition=\"Ready\",status=\"true\"}[$(prom_window)])"

  md "" "## 4. 판정"
  check "VM 정지 뒤 노드가 NotReady로 감지됨" is_true "$seen_nr"
  check "fault-api 3개가 사람 개입 없이 다른 노드에서 Ready" is_true "$replaced"
  check "VM을 켠 뒤 노드가 다시 Ready" is_true "$back"
  rm -f "$log_file"

  md "" "## 5. 되돌리기"
  run_restores
  verify_restored
  finish
}
# api_ready_count_is N : fault-api Ready 파드가 정확히 N개면 성공
api_ready_count_is() { [[ "$(api_ready_count)" -eq "$1" ]]; }

# ---------------------------------------------------------------------------------------------------------------------
# F4 mysql-down : MySQL 중단
# ---------------------------------------------------------------------------------------------------------------------
# no_mysql_pod : MySQL 파드가 하나도 없으면 성공 / mysql_answers : 앱 계정 쿼리에 답하면 성공
no_mysql_pod() { [[ -z "$(k -n "$DB_NS" get pods -l app=mysql -o name 2>/dev/null)" ]]; }
mysql_answers() { [[ "$(db 'SELECT 1')" == 1 ]]; }

run_mysql_down() {
  local down=${DOWN_SECONDS:-30} rows_before rows_after ev_before id sub_rc=0 sub_out t0 t1 t2 sumr log_file with_infer=0 jobsh="$REPO_ROOT/scripts/job.sh"
  if [[ -n "$MODEL_JOB" ]]; then with_infer=1; need_model; fi
  mysql_answers || die "MySQL does not answer (scripts/job.sh list)"
  rows_before=$(db 'SELECT COUNT(*) FROM jobs')
  ev_before=$(db 'SELECT COUNT(*) FROM job_events')
  confirm "F4 mysql-down: MySQL($DB_NS/mysql)을 ${down}초 동안 내립니다(replicas 0). 그동안 작업 등록과 상태 기록이 멈춥니다."
  begin_report "F4 MySQL 중단 시험 (${down}초)"
  md "- 대상 \`$DB_NS/mysql\` (replicas 1→0→1), 중단 ${down}초, $( ((with_infer)) && echo "추론 지속 확인(모델 작업 \`$MODEL_JOB\`, CPU)" || echo '추론 확인은 건너뜀(--model-job 없음)')"
  md "- 시작 전 jobs ${rows_before}행, job_events ${ev_before}행"
  block "진행 중인 작업 (RUNNING·PENDING)" "$(db "SELECT job_id, job_type, status FROM jobs WHERE status IN ('RUNNING','PENDING')")"

  if ((with_infer)); then
    ensure_ns
    push_restore restore_ns
    push_restore restore_infer
    infer_deploy 0 cpu || die "$INFER_RELEASE did not become ready"
    probe_start "$PROBE" "$(infer_url)/infer" 1
    wait_for 180 probe_ready "$PROBE" || die "baseline requests are not all 200"
  fi
  id="fault-db-$(date +%m%d%H%M%S)"

  push_restore restore_mysql
  t0=$(now)
  k -n "$DB_NS" scale deploy/mysql --replicas=0 >/dev/null
  wait_for 120 no_mysql_pod || die "MySQL pod did not stop"
  t1=$(now)
  md "" "## 1. DB가 없는 동안" "" "- MySQL 중단 $(date '+%H:%M:%S') (replicas 0 → 파드가 사라지기까지 $(elapsed "$t0" "$t1")초)"
  # 등록 요청: DB가 없으면 PENDING을 못 넣으므로 실패해야 하고, Job·릴리스가 만들어지면 안 된다 (GPU를 쓰는 Job이 뜨면 바로 지운다)
  sub_out=$("$jobsh" submit train "$id" --epochs 1 2>&1) || sub_rc=$?
  block "scripts/job.sh submit train $id (DB 없음) — 종료 코드 $sub_rc" "$(tail -8 <<<"$sub_out")"
  check "DB가 없으면 등록 요청이 실패한다 (종료 코드 ≠ 0)" is_true "$((sub_rc != 0))"
  check "실패한 요청으로 Helm 릴리스·Job이 만들어지지 않음" no_train_release "$id"
  h uninstall "train-$id" >/dev/null 2>&1 || true
  sleep "$down"
  t2=$(now)
  md "" "- DB 없음 구간: $(elapsed "$t1" "$t2")초"

  # 복구: replicas 1 → rollout → 쿼리에 답할 때까지
  md "" "## 2. 복구"
  restore_mysql
  wait_for 300 mysql_answers || log "MySQL did not answer within 5 minutes"
  metric "replicas 1 → 쿼리에 답할 때까지 (t_db, rollout 대기 포함)" "$(elapsed "$t2" "$(now)")초"
  rows_after=$(db 'SELECT COUNT(*) FROM jobs' || echo '?')
  md "- 복구 뒤 jobs ${rows_after}행 (전 ${rows_before}행)"
  if ((with_infer)); then
    sleep 5
    log_file=$(mktemp)
    probe_stop "$PROBE" "$log_file"
    sumr=$(probe_report "$log_file" "$t0")
    metric "DB 중단 동안 추론 요청 실패 수" "$(kv "$sumr" failed) / $(kv "$sumr" total) (코드별 $(kv "$sumr" codes))"
    check "추론 요청이 DB와 무관하게 계속 200 (실패 0)" is_true "$([[ "$(kv "$sumr" failed)" == 0 ]] && echo 1 || echo 0)"
    rm -f "$log_file"
  fi
  prom_settle
  prom_report "MySQL 준비된 복제본 (중단 동안 0)" "min_over_time(kube_deployment_status_replicas_available{namespace=\"$DB_NS\",deployment=\"mysql\"}[$(prom_window)])"

  md "" "## 3. 판정"
  check "복구 뒤 jobs 행 수가 그대로 (데이터 보존)" same_value "$rows_after" "$rows_before"
  check "복구 뒤 job_events가 줄지 않음" is_true "$([[ "$(db 'SELECT COUNT(*) FROM job_events' || echo 0)" -ge "$ev_before" ]] && echo 1 || echo 0)"
  check "MySQL PVC가 Bound" is_true "$([[ "$(k -n "$DB_NS" get pvc mysql-data -o jsonpath='{.status.phase}')" == Bound ]] && echo 1 || echo 0)"
  check "복구 뒤 scripts/job.sh list가 동작" "$jobsh" list 3
  if ((WITH_TRAINING)); then
    md "" "## 4. 학습 중 DB 중단 (기존 시험 재사용)"
    "$REPO_ROOT/scripts/job-db-test.sh" "fdb-$(date +%m%d%H%M)" >/dev/null 2>&1 || true
    note "scripts/job-db-test.sh를 실행했다. 결과는 그 스크립트가 만든 \`$(ls -t "$REPO_ROOT"/docs/labs/job-db-*.md 2>/dev/null | head -1 | sed "s|^$REPO_ROOT/||")\`에 있다(4절 학습 중 DB 중단)."
  fi

  md "" "## 되돌리기"
  run_restores
  verify_restored
  finish
}
# no_train_release 작업번호 : train-<번호> Helm 릴리스가 없으면 성공 / same_value A B : 두 값이 같으면 성공
no_train_release() { ! h status "train-$1" >/dev/null 2>&1; }
same_value() { [[ "$1" == "$2" ]]; }

# ---------------------------------------------------------------------------------------------------------------------
# F5 gpu-busy : GPU 사용 불가 → CPU 대체 경로
# ---------------------------------------------------------------------------------------------------------------------
# gpu_hold_manifest : GPU 1개를 잡고 놀기만 하는 파드. 실제 GPU 작업(학습 Job)이 GPU를 쥔 상황을 흉내 낸다.
gpu_hold_manifest() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: fault-gpu-hold
  namespace: $FAULT_NS
  labels:
    app: fault-gpu-hold
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  runtimeClassName: nvidia
  nodeSelector:
    k3slab.io/role: gpu
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: hold
      image: $BUSYBOX_IMAGE
      command: ["sleep", "3600"]
      env:
        - name: NVIDIA_DRIVER_CAPABILITIES
          value: compute,utility
      resources:
        requests:
          cpu: 10m
          memory: 8Mi
        limits:
          memory: 32Mi
          nvidia.com/gpu: 1
EOF
}
# pod_running 이름 : 파드가 Running이면 성공 / pod_gone 이름 : 파드가 없으면 성공
pod_running() { [[ "$(kf get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null)" == Running ]]; }
pod_gone() { ! kf get pod "$1" >/dev/null 2>&1; }
# infer_pod_exists : 실험용 추론 파드가 있으면 성공
infer_pod_exists() { [[ -n "$(infer_pod)" ]]; }
# infer_pending_for_gpu : 최근 추론 파드가 "GPU 부족"으로 스케줄되지 못한 상태면 성공
infer_pending_for_gpu() {
  local p
  p=$(infer_pod)
  [[ -n "$p" ]] || return 1
  kf get pod "$p" -o json | jq -e '(.status.conditions // []) | any(.type == "PodScheduled" and .status == "False" and ((.message // "") | test("Insufficient nvidia.com/gpu")))' >/dev/null
}
# infer_answers : 프로버 파드 안에서 추론 요청을 한 번 보내 200이 오면 성공 (본문의 device를 보고서용으로 출력)
infer_answers() {
  kf exec "$PROBE" -- sh -c "curl -s -o /tmp/r.json -w '%{http_code}' --max-time 5 -X POST --data @/tmp/body.json $(infer_url)/infer | grep -qx 200 && cat /tmp/r.json"
}

# run_gpu_busy : F5 — GPU 점유 → GPU 추론 Pending 확인 → gpu=0 대체 배포 → 점유 해제 뒤 GPU로 복귀
run_gpu_busy() {
  local t0 t1 t2 sumr log_file pending=0 cpu_ok=0 gpu_back=0 ans pend_msg
  need_model
  gpu_free || die "GPU is in use by: $(gpu_pods | tr '\n' ' ')"
  confirm "F5 gpu-busy: GPU를 점유하는 파드를 띄우고 추론 파드를 GPU 있음/없음으로 번갈아 배포합니다(GPU 사용)."
  begin_report "F5 GPU 사용 불가 → CPU 대체 경로 시험"
  md "- 릴리스 \`$INFER_RELEASE\`, 모델 작업 \`$MODEL_JOB\`, 이미지 \`infer-worker:$TAG\`. GPU 점유 파드 \`fault-gpu-hold\`가 GPU 1개를 쥐고 있는 상황을 만든다."

  ensure_ns
  push_restore restore_ns
  push_restore restore_infer
  kf apply -f - >/dev/null < <(gpu_hold_manifest)
  wait_for 180 pod_running fault-gpu-hold || die "the GPU holder did not start (kubectl -n $FAULT_NS describe pod fault-gpu-hold)"
  md "" "## 1. GPU를 점유한 상태에서 GPU 추론을 배포"
  infer_helm 1 auto
  wait_for 60 infer_pod_exists || die "no inference pod was created"
  if wait_for 90 infer_pending_for_gpu; then pending=1; fi
  pend_msg=$(kf get pod "$(infer_pod)" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].message}' 2>/dev/null || true)
  sleep 15
  block "GPU 요청 추론 파드의 스케줄 메시지" "$pend_msg"
  block "파드 목록" "$(pods_overview "app.kubernetes.io/instance=$INFER_RELEASE")"
  check "GPU를 요청한 추론 파드는 Pending (Insufficient nvidia.com/gpu) — CPU로 저절로 넘어가지 않는다" is_true "$pending"
  check "15초가 지나도 Pending (자동 대체 경로 없음)" infer_pending_for_gpu

  md "" "## 2. 대체 경로: GPU를 요청하지 않고(gpu=0) DEVICE=auto로 다시 배포"
  t1=$(now)
  if infer_deploy 0 auto; then cpu_ok=1; fi
  t2=$(now)
  metric "대체 배포 시작 → 파드 Ready (t_fb, Service 대기 5초 포함)" "$(elapsed "$t1" "$t2")초"
  probe_start "$PROBE" "$(infer_url)/infer" 1
  wait_for 120 probe_ready "$PROBE" || log "probe baseline not ready"
  ans=$(infer_answers || true)
  block "POST /infer 응답" "${ans:-(응답 없음)}"
  block "추론 워커 시작 로그 (장치 선택 줄)" "$(kf logs "$(infer_pod)" 2>/dev/null | grep -E 'GPU not used|device=' | head -3)"
  check "대체 배포가 Ready" is_true "$cpu_ok"
  check "/metrics의 device가 cpu" device_is cpu
  check "응답에 \"device\":\"cpu\"" grep -q '"device":"cpu"' <<<"$ans"

  md "" "## 3. GPU 복귀: 점유 파드를 지우고 gpu=1, DEVICE=cuda로 다시 배포"
  kf delete pod fault-gpu-hold --wait=true >/dev/null 2>&1 || true
  wait_for 60 pod_gone fault-gpu-hold || log "GPU holder still present"
  t0=$(now)
  if infer_deploy 1 cuda; then gpu_back=1; fi
  t1=$(now)
  metric "GPU 배포 시작 → Ready (전환 시간)" "$(elapsed "$t0" "$t1")초"
  wait_for 60 device_is cuda || log "device is not cuda"
  log_file=$(mktemp)
  probe_stop "$PROBE" "$log_file"
  sumr=$(probe_report "$log_file" "$t0")
  metric "전환(CPU→GPU) 중 실패 요청 수" "$(kv "$sumr" failed) / $(kv "$sumr" total) (코드별 $(kv "$sumr" codes))"
  note "전환 구간 실패는 예상한 값이다: GPU 배포는 maxSurge 0이라 예전 파드를 먼저 내린다(charts/k3slab-workload/templates/infer-deployment.yaml)."
  prom_settle
  prom_report "Pending 파드 (GPU 점유 구간)" "max_over_time(kube_pod_status_phase{namespace=\"$FAULT_NS\",phase=\"Pending\"}[$(prom_window)])"
  check "GPU가 비면 GPU 경로(cuda)로 복귀" is_true "$gpu_back"
  rm -f "$log_file"

  md "" "## 4. 되돌리기"
  run_restores
  check "GPU를 쓰는 파드가 남아 있지 않음" gpu_free
  verify_restored
  finish
}

# ---------------------------------------------------------------------------------------------------------------------
# F6 registry-down : 레지스트리 중단
# ---------------------------------------------------------------------------------------------------------------------
# pull_pod 이름 정책 : worker-cpu-2에서 infer-worker 이미지를 받아 sleep만 하는 파드. 정책 Always는 시작 때마다 레지스트리에 확인한다.
pull_pod() {
  kf apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  labels:
    app: fault-pull
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  nodeSelector:
    k3slab.io/role: app
  containers:
    - name: c
      image: registry.k3slab.local:5000/infer-worker:$TAG
      imagePullPolicy: $2
      command: ["sleep", "600"]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 64Mi
EOF
}
# pull_wait_reason 이름 : 파드 컨테이너의 대기 사유(ErrImagePull, ImagePullBackOff, ...)를 출력
pull_wait_reason() { kf get pod "$1" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true; }
# pull_failing 이름 : 대기 사유가 이미지 받기 실패면 성공
pull_failing() { [[ "$(pull_wait_reason "$1")" =~ ^(ErrImagePull|ImagePullBackOff)$ ]]; }
# registry_has_infer : 레지스트리 카탈로그에 infer-worker가 있으면 성공 (실험 네임스페이스에서 curl 파드로 확인)
registry_has_infer() {
  local out
  out=$(kf run fault-catalog --rm -i --restart=Never --quiet --image="$CURL_IMAGE" -- curl -s --max-time 5 "http://registry.$DB_NS:5000/v2/_catalog" 2>/dev/null) || return 1
  grep -q 'infer-worker' <<<"$out"
}

# run_registry_down : F6 — 이미지 예열 → 레지스트리 replicas 0 → 파드 두 종류 관찰 → 복구와 재시도 시간 → 카탈로그 확인
run_registry_down() {
  local down=${DOWN_SECONDS:-60} t0 t1 t2 t3 cached_ok=0 uncached_fail=0 recovered=0 t_cached=""
  confirm "F6 registry-down: 레지스트리($DB_NS/registry)를 ${down}초 동안 내립니다. 그동안 Kaniko 빌드와 이미지 push는 실패합니다."
  begin_report "F6 레지스트리 중단 시험 (${down}초)"
  md "- 대상 \`$DB_NS/registry\`, 확인용 이미지 \`registry.k3slab.local:5000/infer-worker:$TAG\`, 확인용 파드는 worker-cpu-2(role=app)"

  ensure_ns
  push_restore restore_ns
  # 예열: 이미지를 worker-cpu-2에 받아 둔다 (레지스트리가 정상일 때). 이 단계가 실패하면 이미지가 레지스트리에 없는 것이다.
  pull_pod fault-pull-warm IfNotPresent
  wait_for 300 pod_running fault-pull-warm || die "warm-up pod did not start: is infer-worker:$TAG in the registry? ($(pull_wait_reason fault-pull-warm))"
  kf delete pod fault-pull-warm --wait=true >/dev/null 2>&1 || true

  push_restore restore_registry
  t0=$(now)
  k -n "$DB_NS" scale deploy/registry --replicas=0 >/dev/null
  wait_for 120 no_registry_pod || die "registry pod did not stop"
  t1=$(now)
  md "" "## 1. 레지스트리가 없는 동안" "" "- 레지스트리 중단 $(date '+%H:%M:%S') (파드가 사라지기까지 $(elapsed "$t0" "$t1")초)"
  pull_pod fault-pull-cached IfNotPresent
  pull_pod fault-pull-always Always
  if wait_for 60 pod_running fault-pull-cached; then cached_ok=1; t_cached=$(elapsed "$t1" "$(now)"); fi
  if wait_for 90 pull_failing fault-pull-always; then uncached_fail=1; fi
  block "확인용 파드 상태" "$(kf get pods -l app=fault-pull -o wide 2>/dev/null)
Always 파드 대기 사유: $(pull_wait_reason fault-pull-always)"
  block "Always 파드 이벤트" "$(kf get events --field-selector involvedObject.name=fault-pull-always --sort-by=.lastTimestamp 2>/dev/null | tail -6)"
  [[ -z "$t_cached" ]] || metric "이미지가 노드에 있을 때(IfNotPresent) 중단 시작 → Running" "${t_cached}초 (레지스트리 없이도 시작)"
  sleep "$down"

  md "" "## 2. 복구"
  t2=$(now)
  restore_registry
  t3=$(now)
  metric "replicas 1 → 레지스트리 Ready (t_reg, rollout 대기 포함)" "$(elapsed "$t2" "$t3")초"
  # ImagePullBackOff는 재시도 간격이 10초부터 두 배씩 늘어(최대 300초) 복구 뒤에도 바로 시작하지 않을 수 있다
  if wait_for 600 pod_running fault-pull-always; then recovered=1; fi
  metric "레지스트리 Ready → Always 파드 Running (t_pull, 재시도 간격 포함)" "$(elapsed "$t3" "$(now)")초$([[ $recovered == 1 ]] || echo ' (10분 안에 시작하지 않음)')"
  check "이미지가 노드에 있으면 레지스트리 없이도 파드가 시작 (IfNotPresent)" is_true "$cached_ok"
  check "레지스트리 확인이 필요한 파드는 이미지 받기 실패 (ErrImagePull/ImagePullBackOff)" is_true "$uncached_fail"
  check "레지스트리 복구 뒤 사람 개입 없이 파드가 Running" is_true "$recovered"
  check "복구 뒤 카탈로그에 infer-worker가 있음 (local-path 데이터 보존)" registry_has_infer
  prom_settle
  prom_report "레지스트리 준비된 복제본 (중단 동안 0)" "min_over_time(kube_deployment_status_replicas_available{namespace=\"$DB_NS\",deployment=\"registry\"}[$(prom_window)])"
  prom_report "이미지 받기 대기 파드" "max_over_time(kube_pod_container_status_waiting_reason{namespace=\"$FAULT_NS\",reason=~\"ErrImagePull|ImagePullBackOff\"}[$(prom_window)])"

  md "" "## 3. 되돌리기"
  run_restores
  verify_restored
  finish
}
# no_registry_pod : 레지스트리 파드가 하나도 없으면 성공
no_registry_pod() { [[ -z "$(k -n "$DB_NS" get pods -l app=registry -o name 2>/dev/null)" ]]; }

# ---------------------------------------------------------------------------------------------------------------------
# F7 overload : 과부하 → 429와 큐 대기
# ---------------------------------------------------------------------------------------------------------------------
# metric_value 지표 : 프로버 파드에서 읽은 /metrics 한 줄의 값 (표준입력으로 받은 /metrics 텍스트에서 정확히 일치하는 이름)
metric_value() { awkc -v n="$1" '$1 == n { print $2; exit }'; }
# percentile 코드 퍼센트 : 부하 로그(표준입력)에서 그 코드 응답 시간의 퍼센트 분위수(초). 없으면 -
percentile() {
  awkc -v c="$1" -v p="$2" '$1 == "R" && $2 == c { print $3 }' | sort -n | awkc -v p="$2" '
    { a[NR] = $1 } END { if (NR == 0) { print "-"; exit } i = int(NR * p / 100 + 0.999999); if (i < 1) i = 1; if (i > NR) i = NR; printf "%.3f", a[i] }'
}
# load_job_done : 부하 Job이 끝났으면(성공 또는 실패) 성공
load_job_done() {
  local s f
  s=$(kf get job fault-load -o jsonpath='{.status.succeeded}' 2>/dev/null)
  f=$(kf get job fault-load -o jsonpath='{.status.failed}' 2>/dev/null)
  [[ "${s:-0}" -ge 1 || "${f:-0}" -ge 1 ]]
}
# load_job : 요청 REQUESTS개를 동시 CONC개로 보내고 "R 코드 응답시간"을 요청마다, "Q 큐길이"를 0.2초마다, "E 걸린초"를 한 번 출력하는 Job
#   요청마다 새 연결(curl 한 번씩)이라 kube-proxy가 요청마다 백엔드를 고른다. infer-bench.sh의 load()와 같은 방식.
load_job() {
  kf apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: fault-load
  namespace: $FAULT_NS
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: curl
          image: $CURL_IMAGE
          command:
            - sh
            - -c
            - |
              awk 'BEGIN { srand(1); printf "{\"x\":["; for (i = 0; i < 64; i++) printf "%s%.4f", (i ? "," : ""), rand() * 2 - 1; print "]}" }' > /tmp/body.json
              ( while :; do curl -s --max-time 2 $(infer_url)/metrics | sed -n 's/^k3slab_infer_queue_length \([0-9][0-9]*\).*/Q \1/p'; sleep 0.2; done ) > /tmp/q.log &
              sampler=\$!
              start=\$(cut -d' ' -f1 /proc/uptime)
              seq $REQUESTS | xargs -P $CONC -I{} curl -s --connect-timeout 3 --max-time 30 -o /dev/null -w 'R %{http_code} %{time_total}\n' -X POST --data @/tmp/body.json $(infer_url)/infer
              end=\$(cut -d' ' -f1 /proc/uptime)
              kill \$sampler
              echo "E \$(echo "\$end \$start" | awk '{printf "%.2f", \$1 - \$2}')"
              cat /tmp/q.log
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 128Mi
EOF
}

# run_overload : F7 — 큐 20 추론 배포 → 부하 Job → 코드별 통계·큐 길이 → 부하 뒤 상태 확인
run_overload() {
  local m_before m_after rej_before rej_after ok_before ok_after sum_before sum_after cnt_before cnt_after load codes c429 other qmax cap mean_wait restarts after_q ans
  need_model
  confirm "F7 overload: $FAULT_NS 에 추론 파드를 띄우고 요청 ${REQUESTS}개를 동시 ${CONC}개로 보내 큐를 일부러 넘칩니다."
  begin_report "F7 과부하 시험 (429와 큐 대기)"
  md "- 릴리스 \`$INFER_RELEASE\` (CPU, 큐 20, 배치 4, 스레드 1, WORK_MS 50: \`scripts/infer-bench.sh\` ②와 같은 조건), 모델 작업 \`$MODEL_JOB\`"
  md "- 부하: 요청 $REQUESTS개, 동시 $CONC개 (curl Job, 요청마다 새 연결), 큐 길이는 0.2초마다 샘플링"

  ensure_ns
  push_restore restore_ns
  push_restore restore_infer
  infer_deploy 0 cpu --set infer.queueSize=20 --set infer.maxBatch=4 --set infer.threads=1 --set infer.workMs=50 || die "$INFER_RELEASE did not become ready"
  # 요청을 보내지 않는 확인용 파드: 부하 전후에 /metrics를 읽고, 부하가 끝난 뒤 일반 요청 한 번을 보내는 데만 쓴다
  idle_probe_start
  ans=$(infer_answers || true)
  [[ -n "$ans" ]] || die "baseline request failed"
  m_before=$(infer_metrics)
  ok_before=$(metric_value 'k3slab_infer_requests_total{result="ok"}' <<<"$m_before")
  rej_before=$(metric_value 'k3slab_infer_requests_total{result="rejected"}' <<<"$m_before")
  sum_before=$(metric_value k3slab_infer_request_seconds_sum <<<"$m_before")
  cnt_before=$(metric_value k3slab_infer_request_seconds_count <<<"$m_before")
  cap=$(metric_value k3slab_infer_queue_capacity <<<"$m_before")

  md "" "## 1. 부하"
  load_job
  wait_for 600 load_job_done || die "the load job did not finish"
  load=$(kf logs job/fault-load 2>/dev/null)
  codes=$(awkc '$1 == "R" { c[$2]++ } END { for (k in c) printf "%s:%d\n", k, c[k] }' <<<"$load" | sort | paste -sd, -)
  c429=$(awkc '$1 == "R" && $2 == 429 { n++ } END { print n + 0 }' <<<"$load")
  other=$(awkc '$1 == "R" && $2 != 200 && $2 != 429 { n++ } END { print n + 0 }' <<<"$load")
  qmax=$(awkc '$1 == "Q" { if ($2 > m) m = $2 } END { print m + 0 }' <<<"$load")
  block "부하 Job 출력 요약 (E = 걸린 초)" "$codes
$(grep '^E ' <<<"$load")"
  metric "응답 코드별 개수" "$codes"
  metric "429 응답 시간 (중앙값 / 95%)" "$(percentile 429 50 <<<"$load")초 / $(percentile 429 95 <<<"$load")초"
  metric "200 응답 시간 (중앙값 / 95%)" "$(percentile 200 50 <<<"$load")초 / $(percentile 200 95 <<<"$load")초"
  metric "샘플링한 큐 길이 최댓값 (용량 ${cap:-?})" "$qmax"

  md "" "## 2. 부하 뒤"
  sleep 5
  m_after=$(infer_metrics || true)
  ok_after=$(metric_value 'k3slab_infer_requests_total{result="ok"}' <<<"$m_after")
  rej_after=$(metric_value 'k3slab_infer_requests_total{result="rejected"}' <<<"$m_after")
  sum_after=$(metric_value k3slab_infer_request_seconds_sum <<<"$m_after")
  cnt_after=$(metric_value k3slab_infer_request_seconds_count <<<"$m_after")
  after_q=$(metric_value k3slab_infer_queue_length <<<"$m_after")
  mean_wait=$(awkc -v s1="${sum_before:-0}" -v s2="${sum_after:-0}" -v c1="${cnt_before:-0}" -v c2="${cnt_after:-0}" 'BEGIN { if (c2 > c1) printf "%.3f", (s2 - s1) / (c2 - c1); else print "-" }')
  metric "워커가 센 처리 완료 / 거절 (증가량)" "$((${ok_after:-0} - ${ok_before:-0})) / $((${rej_after:-0} - ${rej_before:-0}))"
  metric "받아들인 요청의 평균 대기+계산 시간 (metrics 증가량)" "${mean_wait}초"
  restarts=$(kf get pods -l "app.kubernetes.io/instance=$INFER_RELEASE" -o json | jq '[.items[].status.containerStatuses[]?.restartCount] | add // 0')
  ans=$(kf exec "$PROBE" -- sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST --data @/tmp/body.json $(infer_url)/infer" 2>/dev/null || true)
  prom_settle
  prom_report "큐 길이 최댓값" "max_over_time(k3slab_infer_queue_length{namespace=\"$FAULT_NS\"}[$(prom_window)])"
  prom_report "요청 결과별 증가량" "sum by (result) (increase(k3slab_infer_requests_total{namespace=\"$FAULT_NS\"}[$(prom_window)]))"

  md "" "## 3. 판정"
  check "큐가 넘치면 429로 거절된다 (429가 1개 이상)" is_true "$((c429 > 0))"
  check "200과 429 말고 다른 응답이 없음 (000·5xx·504 없음)" is_true "$((other == 0))"
  check "거절(429)이 처리된 요청(200)보다 빠르다 (중앙값)" p429_faster "$load"
  check "큐 길이가 용량을 넘지 않음 (샘플 최댓값 ≤ ${cap:-20})" le "$qmax" "${cap:-20}"
  check "부하 뒤 큐가 비어 있음" is_true "$([[ "${after_q:-x}" == 0 ]] && echo 1 || echo 0)"
  check "파드 재시작 0" is_true "$([[ "$restarts" == 0 ]] && echo 1 || echo 0)"
  check "부하 뒤 일반 요청이 200" is_true "$([[ "$ans" == 200 ]] && echo 1 || echo 0)"

  md "" "## 4. 되돌리기"
  run_restores
  verify_restored
  finish
}
# idle_probe_start : 요청은 보내지 않고 sleep만 하는 curl 파드($PROBE)를 띄운다 (/metrics 읽기와 일반 요청 한 번용). 본문 파일도 만든다.
idle_probe_start() {
  kf apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $PROBE
  labels:
    app: fault-probe
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  containers:
    - name: probe
      image: $CURL_IMAGE
      command:
        - sh
        - -c
        - |
          awk 'BEGIN { srand(1); printf "{\"x\":["; for (i = 0; i < 64; i++) printf "%s%.4f", (i ? "," : ""), rand() * 2 - 1; print "]}" }' > /tmp/body.json
          sleep 3600
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 64Mi
EOF
  wait_for 120 pod_running "$PROBE" || die "$PROBE did not start"
  sleep 2
}
# p429_faster 부하로그 : 429 응답 시간의 중앙값이 200 응답 시간의 중앙값보다 작으면 성공
p429_faster() {
  local a b
  a=$(percentile 429 50 <<<"$1")
  b=$(percentile 200 50 <<<"$1")
  [[ "$a" != - && "$b" != - ]] && awkc -v a="$a" -v b="$b" 'BEGIN { exit !(a + 0 < b + 0) }'
}

# ---------------------------------------------------------------------------------------------------------------------
# F8 bad-deploy : 잘못된 배포(없는 이미지 태그)
# ---------------------------------------------------------------------------------------------------------------------
# new_pod_pull_failing : 삭제 중이 아닌 추론 파드 중 이미지 받기에 실패하는(ErrImagePull/ImagePullBackOff) 것이 있으면 성공
new_pod_pull_failing() {
  kf get pods -l "app.kubernetes.io/instance=$INFER_RELEASE" -o json |
    jq -e '[.items[] | select(.metadata.deletionTimestamp == null) | .status.containerStatuses[]?.state.waiting.reason // empty] | any(. == "ErrImagePull" or . == "ImagePullBackOff")' >/dev/null
}
# old_pod_ready : Ready인(삭제 중이 아닌) 추론 파드가 있으면 성공
old_pod_ready() {
  kf get pods -l "app.kubernetes.io/instance=$INFER_RELEASE" -o json |
    jq -e '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length > 0' >/dev/null
}
# helm_revision : 이 릴리스의 현재 helm 리비전 번호
helm_revision() { h history "$INFER_RELEASE" -n "$FAULT_NS" -o json | jq -r 'last | .revision'; }

run_bad_deploy() {
  local dev=cpu rev0 t0 t1 t2 detect=0 served=0 rolled=0 sumr log_file
  if ((GPU > 0)); then dev=cuda; fi
  need_model
  if ((GPU > 0)); then gpu_free || die "GPU is in use by: $(gpu_pods | tr '\n' ' ')"; fi
  confirm "F8 bad-deploy: 동작 중인 추론 릴리스를 없는 이미지 태그로 갱신한 뒤 롤백합니다(장치 $dev)."
  begin_report "F8 잘못된 배포 시험 (없는 이미지 태그, 장치 $dev)"
  md "- 릴리스 \`$INFER_RELEASE\`: 정상 태그 \`$TAG\` → 없는 태그 \`$MISSING_TAG\` → helm rollback. 장치 \`$dev\`(GPU $GPU)"

  ensure_ns
  push_restore restore_ns
  push_restore restore_infer
  infer_deploy "$GPU" "$dev" || die "$INFER_RELEASE did not become ready"
  probe_start "$PROBE" "$(infer_url)/infer" 1
  wait_for 180 probe_ready "$PROBE" || die "baseline requests are not all 200"
  rev0=$(helm_revision)
  md "" "## 1. 평상시" "" "- helm 리비전 $rev0 (정상), 파드 $(infer_pod)"
  sleep 5

  md "" "## 2. 잘못된 배포"
  t0=$(now)
  infer_helm "$GPU" "$dev" --set image.tag="$MISSING_TAG"
  md "" "- 없는 태그 배포 $(date '+%H:%M:%S')"
  if wait_for 180 new_pod_pull_failing; then
    detect=1
    t1=$(now)
    metric "배포 → 새 파드가 이미지 받기 실패 상태 (확인 간격 1초)" "$(elapsed "$t0" "$t1")초"
  fi
  sleep 30
  if old_pod_ready; then served=1; fi
  block "배포 30초 뒤 파드 (예전 파드가 서비스를 이어 가는가)" "$(pods_overview "app.kubernetes.io/instance=$INFER_RELEASE")"
  block "새 파드 이벤트" "$(kf get events --sort-by=.lastTimestamp 2>/dev/null | grep -E 'Failed|BackOff|Pulling' | tail -5)"

  md "" "## 3. 롤백"
  t1=$(now)
  if h rollback "$INFER_RELEASE" "$rev0" -n "$FAULT_NS" --wait --timeout 5m >/dev/null 2>&1; then rolled=1; fi
  t2=$(now)
  metric "helm rollback → 정상 Ready" "$(elapsed "$t1" "$t2")초"
  sleep 10
  block "helm 이력" "$(h history "$INFER_RELEASE" -n "$FAULT_NS" 2>/dev/null)"
  log_file=$(mktemp)
  probe_stop "$PROBE" "$log_file"
  sumr=$(probe_report "$log_file" "$t0")
  metric "배포~롤백 동안 실패한 요청 수" "$(kv "$sumr" failed) / $(kv "$sumr" total) (코드별 $(kv "$sumr" codes))"
  prom_settle
  prom_report "이미지 받기 대기 파드" "max_over_time(kube_pod_container_status_waiting_reason{namespace=\"$FAULT_NS\",reason=~\"ErrImagePull|ImagePullBackOff\"}[$(prom_window)])"

  md "" "## 4. 판정"
  check "새 파드가 Ready가 되지 못하고 이미지 받기 실패로 멈춤" is_true "$detect"
  if ((GPU > 0)); then
    note "GPU 변형: 이 차트는 GPU 배포에서 예전 파드를 먼저 내린다(maxSurge 0). 배포 중 예전 파드가 살아 있었는가: $([[ $served == 1 ]] && echo 예 || echo 아니오) — 관찰만 하고 판정하지 않는다."
  else
    check "배포 중에도 예전 파드가 Ready로 서비스를 이어 감" is_true "$served"
    check "배포~롤백 동안 실패한 요청이 0" is_true "$([[ "$(kv "$sumr" failed)" == 0 ]] && echo 1 || echo 0)"
  fi
  check "롤백 뒤 Ready 1/1" is_true "$rolled"
  check "롤백 뒤 마지막 30개 요청이 모두 200" probe_tail_ok "$log_file" 30
  rm -f "$log_file"

  md "" "## 5. 되돌리기"
  run_restores
  verify_restored
  finish
}

# --- 9) 진입점 ---

# run_experiment 이름 : 실행 모드 공통 흐름 (점검 → 실험). 복구 단계가 남은 채 끝나면 on_exit가 되돌린다.
run_experiment() {
  trap on_exit EXIT
  trap 'exit 130' INT TERM
  case $EXP in
    inspect) run_inspect ;;
    cleanup) run_cleanup ;;
    *)
      preflight_common
      "run_${EXP//-/_}"
      ;;
  esac
}

# main 인자... : 첫 인자는 실험 이름, 나머지는 옵션
main() {
  [[ $# -ge 1 ]] || usage 1
  [[ "$1" == -h || "$1" == --help ]] && usage 0
  EXP=$1
  shift
  ARGS_ECHO="$EXP $*"
  parse_args "$@"
  validate_args
  case $EXP in
    list) list_experiments ;;
    inspect | cleanup | infer-kill | train-kill | node-stop | mysql-down | gpu-busy | registry-down | overload | bad-deploy)
      if ((DRY)); then
        show_plan "$EXP"
      else
        run_experiment
      fi
      ;;
    *) die "unknown experiment '$EXP' (see: scripts/fault-test.sh list)" ;;
  esac
}

# 이 파일을 source하면(시험용) main을 실행하지 않는다
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
