#!/usr/bin/env bash
# Verifies the monitoring stack (infra/k8s/monitoring) end to end and writes docs/labs/monitoring-<date>.md:
# every scrape target is up, the metrics exist, Grafana has both data sources and the three dashboards without
# anyone clicking, every dashboard query runs, the MySQL account is read-only, and - under inference load - the
# inference metrics and the GPU metrics really change. Prints PASS/FAIL per check; exits 1 if any FAIL.
# Usage: scripts/monitoring-test.sh [--no-load] [--with-gpu] [--model-job ID] [--image-tag TAG] [--duration S] [--concurrency N]
#   --with-gpu  the inference pod asks for the GPU (needs approval; one GPU, so no training Job may hold it)
#
# [한국어 설명] 모니터링을 처음부터 끝까지 확인하고 결과를 보고서로 남긴다 (제안서 12–14주, 검증 실험 13–16주의 측정 근거).
#   ① 파드 상태: monitoring 네임스페이스의 모든 파드 Ready, 재시작 0, OOMKilled 없음
#   ② 수집 대상: Prometheus targets가 전부 up (job별 up/전체 표). 추론 워커는 파드가 있을 때만 대상에 들어간다.
#   ③ 지표 존재: GPU(DCGM), 노드, kube-state-metrics, cAdvisor, 추론 워커 지표가 실제로 들어와 있는지
#   ④ Grafana: 데이터소스 둘 정상, 대시보드 셋이 자동으로 들어 있음(파일로 넣은 것, 손으로 만든 것 없음)
#   ⑤ 대시보드 쿼리: 모든 패널 쿼리를 Grafana를 거쳐 실행해 오류가 없는지 확인 (변수는 All/기본값으로 대체)
#   ⑥ MySQL 읽기 전용 계정: SELECT는 되고 INSERT/DELETE/UPDATE와 다른 테이블 조회는 거부되는지
#   ⑦ 부하 시험(--no-load로 건너뜀): 추론 파드를 띄워 (a) 쉬는 상태 (b) 보통 부하 (c) 과부하(큐 20)를 차례로 보내며
#      Prometheus 값이 변하는지 확인한다. 부하 클라이언트가 센 200/429 개수와 Prometheus 카운터 증가량이 같은지도 비교한다.
#      GPU 값(사용률·메모리)은 --with-gpu를 줄 때만 시험한다(GPU 1장 사용 → 총괄 승인 필요, 끝나면 바로 내린다).
#   ⑧ 메모리 사용: monitoring 파드별 실사용(cAdvisor)과 requests/limits, kubectl top, TSDB 크기
#   알려진 한계(NOTE, PASS/FAIL에 넣지 않음): 추론 워커는 지연의 합계·개수만 내보내서 p50/p95를 구할 수 없다.
#   [준비] scripts/monitoring-deploy.sh를 실행해 둘 것. 이미지(infer-worker)와 모델(기본 bench-large)이 있어야 부하 시험이 된다.
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 인자와 상수 ---
# sed -n '2,7s/^# \{0,1\}//p' "$0" : 이 파일 2~7번째 줄(영문 설명)을 도움말로 출력
usage() {
  sed -n '2,7s/^# \{0,1\}//p' "$0"
  exit "${1:-0}"
}
LOAD=1
WITH_GPU=0
MODEL_JOB="bench-large"   # 서빙할 모델(학습 작업 번호). infer-gpu-bench.sh의 큰 모델(64→4096→4096→10)이 gpu-host에 있다
TAG="v0.2"                # infer-worker 이미지 태그
DURATION=60               # 보통 부하를 보내는 시간(초)
CONCURRENCY=100           # 보통 부하의 curl --parallel-max(최대 동시 전송 수). 실제 연결 수는 부하 중에 따로 센다
OVERLOAD_SECONDS=30       # 과부하 시간(초)
OVERLOAD_CONCURRENCY=300  # 과부하의 curl --parallel-max (큐 20보다 훨씬 많게). curl이 허용하는 최대값 근처다
while (($#)); do
  case "$1" in
    -h | --help) usage 0 ;;
    --no-load) LOAD=0 ;;
    --with-gpu) WITH_GPU=1 ;;
    --model-job) MODEL_JOB=${2:?--model-job needs a value}; shift ;;
    --image-tag) TAG=${2:?--image-tag needs a value}; shift ;;
    --duration) DURATION=${2:?--duration needs a value}; shift ;;
    --concurrency) CONCURRENCY=${2:?--concurrency needs a value}; shift ;;
    *) usage 1 ;;
  esac
  shift
done
[[ "$MODEL_JOB" =~ ^[a-z0-9]([-a-z0-9]{0,40}[a-z0-9])?$ ]] || die "--model-job must be lowercase letters, digits and '-'"
[[ "$TAG" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "--image-tag has unsupported characters"
[[ "$DURATION" =~ ^[0-9]+$ && "$CONCURRENCY" =~ ^[0-9]+$ ]] || die "--duration and --concurrency must be numbers"

NS="monitoring"
REL="monitoring-infer"                       # 부하 시험용 추론 Helm 릴리스 (끝나면 지운다)
LOAD_JOB="monitoring-load"
CHART="$REPO_ROOT/charts/k3slab-workload"
KUBECONFIG_FILE="$LAB_SECRETS_DIR/kubeconfig"
LOCAL_COPY="$LAB_SECRETS_DIR/monitoring.env"
REPORT="$REPO_ROOT/docs/labs/monitoring-$(date +%Y%m%d-%H%M).md"
PASS=0
FAIL=0
GF_PID=""
mkdir -p "$(dirname "$REPORT")"

# k / h : 이 클러스터용 kubectl·helm (K3S_CONFIG_FILE=/dev/null은 k3s 링크의 권한 경고 제거)
k() { K3S_CONFIG_FILE=/dev/null KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"; }
h() { KUBECONFIG="$KUBECONFIG_FILE" helm "$@"; }
# md 줄... : 보고서 끝에 줄 추가 / block "제목" 내용 : 제목과 코드 블록을 추가
md() { printf '%s\n' "$@" >>"$REPORT"; }
block() { md "" "**$1**" "" '```text' "$2" '```'; }
# check "설명" 명령... : 성공하면 PASS, 아니면 FAIL로 집계해 보고서에 남김 (job-db-test.sh와 같은 방식)
check() {
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1)); md "" "- ✅ **PASS** — $desc"; log "PASS $desc"
  else
    FAIL=$((FAIL + 1)); md "" "- ❌ **FAIL** — $desc"; log "FAIL $desc"
  fi
}
# note "설명" : 집계하지 않는 참고(알려진 한계 등). PASS/FAIL 수에 들어가지 않는다
note() { md "" "- ℹ️ **NOTE** — $1"; log "NOTE $1"; }
# fcmp 값1 연산자 값2 : 실수 비교(>, >=, <, <=). 값이 NaN이거나 비어 있으면 거짓
fcmp() {
  [[ -n "$1" && "$1" != NaN && -n "$3" && "$3" != NaN ]] || return 1
  awk -v a="$1" -v op="$2" -v b="$3" 'BEGIN { exit !((op == ">" && a > b) || (op == ">=" && a >= b) || (op == "<" && a < b) || (op == "<=" && a <= b)) }'
}
# fnum 값 [소수 자릿수] : 보기 좋게 반올림 (NaN은 그대로)
fnum() { [[ "$1" == NaN || -z "$1" ]] && echo "n/a" || awk -v v="$1" -v d="${2:-2}" 'BEGIN { printf "%.*f", d, v }'; }

# --- 2) Prometheus·Grafana 접근 ---
# pq 'PromQL' [유닉스시각] : 즉시 쿼리의 첫 값(없으면 NaN). API 서버의 서비스 프록시를 거치므로 포트포워드가 필요 없다.
pq() {
  local q
  q=$(jq -rn --arg q "$1" '$q | @uri')
  k get --raw "/api/v1/namespaces/$NS/services/prometheus:9090/proxy/api/v1/query?query=$q${2:+&time=$2}" |
    jq -r '.data.result[0].value[1] // "NaN"'
}
# pq_count 'PromQL' : 결과 시계열 수
pq_count() {
  local q
  q=$(jq -rn --arg q "$1" '$q | @uri')
  k get --raw "/api/v1/namespaces/$NS/services/prometheus:9090/proxy/api/v1/query?query=$q" | jq -r '.data.result | length'
}
# pq_label 'PromQL' 라벨 : 첫 결과 시계열의 라벨 값(없으면 ?)
pq_label() {
  local q
  q=$(jq -rn --arg q "$1" '$q | @uri')
  k get --raw "/api/v1/namespaces/$NS/services/prometheus:9090/proxy/api/v1/query?query=$q" | jq -r --arg l "$2" '.data.result[0].metric[$l] // "?"'
}
# prom_now : Prometheus 서버의 현재 시각(초). 시각 기준을 한 곳(Prometheus)에 두어 호스트와 VM의 시계 차이를 피한다
prom_now() { pq 'vector(time())' | awk '{ printf "%d", $1 }'; }   # time() 자체는 스칼라라 .value가 없어서 vector()로 감싼다
# gf 메서드 경로 [JSON] : Grafana API 호출. 비밀번호는 curl 설정을 표준입력으로 넘겨 프로세스 목록에 남기지 않는다
gf() {
  local method=$1 path=$2 body=${3:-}
  printf 'user = "admin:%s"\n' "$GRAFANA_ADMIN_PASSWORD" |
    curl -sS --max-time 60 --config - -X "$method" -H 'Content-Type: application/json' ${body:+--data "$body"} "http://127.0.0.1:$GF_PORT$path"
}
# start_grafana_forward : Grafana를 로컬 포트로 포워딩하고 응답할 때까지 기다린다
start_grafana_forward() {
  GF_PORT=$((20000 + RANDOM % 10000))
  k -n "$NS" port-forward svc/grafana "$GF_PORT:3000" >/dev/null 2>&1 &
  GF_PID=$!
  local i
  for i in $(seq 30); do
    curl -s --max-time 2 "http://127.0.0.1:$GF_PORT/api/health" >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "Grafana did not answer through port-forward (port $GF_PORT)"
}
# cleanup : 어떤 이유로 끝나든 포트포워드를 닫고, 시험용 추론 릴리스와 부하 Job을 지운다(GPU를 바로 돌려준다)
cleanup() {
  [[ -n "$GF_PID" ]] && kill "$GF_PID" 2>/dev/null || true
  [[ -n "${CONN_PID:-}" ]] && kill "$CONN_PID" 2>/dev/null || true
  if [[ "${LOAD_STARTED:-0}" == 1 ]]; then
    k delete job "$LOAD_JOB" --ignore-not-found >/dev/null 2>&1 || true
    h uninstall "$REL" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# --- 3) 준비 ---
[[ -f "$LOCAL_COPY" ]] || die "missing $LOCAL_COPY: run scripts/monitoring-deploy.sh first"
[[ "$(stat -c %a "$LOCAL_COPY")" == "600" ]] || die "$LOCAL_COPY must be mode 600"
# shellcheck disable=SC1090
source "$LOCAL_COPY"
: "${GRAFANA_ADMIN_PASSWORD:?}"
k get nodes >/dev/null 2>&1 || die "the cluster does not answer (kubectl get nodes failed)"
k get namespace "$NS" >/dev/null 2>&1 || die "namespace $NS does not exist: run scripts/monitoring-deploy.sh"
NODES=$(k get nodes --no-headers | wc -l)
start_grafana_forward

{
  printf '# 모니터링 시험 (%s)\n\n' "$(date '+%Y-%m-%d %H:%M')"
  printf -- '- 생성: `scripts/monitoring-test.sh%s`\n' "$([[ $LOAD == 0 ]] && echo ' --no-load')$([[ $WITH_GPU == 1 ]] && echo ' --with-gpu')"
  printf -- '- 대상: `infra/k8s/monitoring`(네임스페이스 `%s`), 노드 %s대\n' "$NS" "$NODES"
  printf -- '- 이미지: Prometheus v3.16.0, Grafana 13.3.1, kube-state-metrics v2.20.0, node-exporter v1.13.1, dcgm-exporter 4.6.1-4.8.4\n'
} >"$REPORT"
block "노드" "$(k get nodes -o wide | cut -c1-140)"

# --- 4) 파드 상태 ---
md "" "## 1. 파드 상태" ""
block "파드 (monitoring)" "$(k -n "$NS" get pods -o wide)"
block "PVC" "$(k -n "$NS" get pvc)"
not_ready=$(k -n "$NS" get pods -o json | jq '[.items[] | select(([.status.containerStatuses[]?.ready] | all | not) or .status.phase != "Running")] | length')
restarts=$(k -n "$NS" get pods -o json | jq '[.items[].status.containerStatuses[]?.restartCount] | add // 0')
oom=$(k -n "$NS" get pods -o json | jq '[.items[].status.containerStatuses[]? | select(.lastState.terminated.reason == "OOMKilled")] | length')
check "monitoring의 모든 파드가 Running·Ready (준비 안 된 파드 $not_ready개)" test "$not_ready" -eq 0
check "컨테이너 재시작 0회 (실제 $restarts회)" test "$restarts" -eq 0
check "OOMKilled 컨테이너 없음 (실제 $oom개)" test "$oom" -eq 0
# DCGM 파드는 GPU를 요청하지 않아야 한다 (nvidia.com/gpu가 requests/limits에 없음 → device plugin이 GPU를 세지 않는다)
dcgm_gpu_req=$(k -n "$NS" get pods -l app.kubernetes.io/name=dcgm-exporter -o json | jq '[.items[].spec.containers[].resources | (.requests // {}), (.limits // {}) | has("nvidia.com/gpu")] | any')
check "dcgm-exporter 파드는 nvidia.com/gpu를 요청하지 않는다 (GPU 1장을 점유하지 않음)" test "$dcgm_gpu_req" == false
check "dcgm-exporter가 gpu-host에서 돈다" test "$(k -n "$NS" get pods -l app.kubernetes.io/name=dcgm-exporter -o jsonpath='{.items[0].spec.nodeName}')" == gpu-host

# --- 5) 수집 대상 ---
# targets_table : job별 up/전체 표와 대상별 상태 (Prometheus /api/v1/targets)
targets_json() { k get --raw "/api/v1/namespaces/$NS/services/prometheus:9090/proxy/api/v1/targets?state=active"; }
# job_up job : 그 job의 "up개수/전체"를 출력
job_up() { targets_json | jq -r --arg j "$1" '[.data.activeTargets[] | select(.labels.job == $j)] | "\(map(select(.health == "up")) | length)/\(length)"'; }
# expect_job job 기대개수 : 그 job의 대상이 기대 개수만큼 있고 전부 up이면 성공
expect_job() { [[ "$(job_up "$1")" == "$2/$2" ]]; }

md "" "## 2. 수집 대상 (Prometheus targets)" ""
sleep 20 # 새로 뜬 대상이 첫 수집을 마칠 시간
for spec in "prometheus 1" "kube-state-metrics 1" "node-exporter $NODES" "cadvisor $NODES" "dcgm-exporter 1"; do
  read -r job want <<<"$spec"
  check "수집 대상 $job: $want개 모두 up (실제 $(job_up "$job"))" expect_job "$job" "$want"
done
block "수집 대상 목록 (job · node · 주소 · 상태)" "$(targets_json | jq -r '.data.activeTargets | sort_by(.labels.job, .labels.node // "") | .[] | [.labels.job, (.labels.node // "-"), .scrapeUrl, .health, (.lastScrapeDuration | . * 1000 | floor | tostring + "ms")] | @tsv' | column -t -s$'\t')"

# --- 6) 지표 존재 ---
md "" "## 3. 지표가 실제로 들어오는가" ""
for m in DCGM_FI_DEV_GPU_UTIL DCGM_FI_DEV_FB_USED DCGM_FI_DEV_FB_FREE DCGM_FI_DEV_POWER_USAGE DCGM_FI_DEV_GPU_TEMP \
  node_cpu_seconds_total node_memory_MemAvailable_bytes node_filesystem_avail_bytes node_load1 node_uname_info \
  kube_node_status_condition kube_pod_status_phase kube_pod_info kube_pod_container_status_restarts_total \
  container_cpu_usage_seconds_total container_memory_working_set_bytes container_network_receive_bytes_total; do
  check "지표 $m 시계열 $(pq_count "$m")개" test "$(pq_count "$m")" -gt 0
done
check "노드마다 node-exporter 지표가 있다 (node 라벨 $(pq_count 'count by (node)(node_uname_info)')개 = 노드 $NODES개)" test "$(pq_count 'count by (node)(node_uname_info)')" -eq "$NODES"
# 디스크 지표는 노드마다 루트(/) 파일시스템이 있어야 한다(SELinux 때문에 VM 노드에서만 빠졌던 적이 있다)
check "노드마다 루트(/) 디스크 지표가 있다 (node 라벨 $(pq_count 'count by (node)(node_filesystem_avail_bytes{mountpoint="/"})')개 = 노드 $NODES개)" test "$(pq_count 'count by (node)(node_filesystem_avail_bytes{mountpoint="/"})')" -eq "$NODES"
gpu_now=$(pq 'DCGM_FI_DEV_GPU_UTIL')
md "" "- 지금 GPU 사용률: ${gpu_now}% (gpu-host는 사용자의 데스크톱이기도 해서 부하가 없어도 0이 아닐 수 있다)"

# --- 7) Grafana 데이터소스·대시보드 ---
md "" "## 4. Grafana (손으로 만든 것 없이 자동으로 들어갔는가)" ""
for uid in prometheus mysql-k3slab; do
  st=$(gf GET "/api/datasources/uid/$uid/health" | jq -r '.status + ": " + .message')
  check "데이터소스 $uid 상태 ($st)" test "${st%%:*}" == OK
done
dash_list=$(gf GET "/api/search?type=dash-db")
for spec in "k3slab-infer 추론 워커" "k3slab-training 학습 작업" "k3slab-nodes 노드"; do
  read -r uid title <<<"$spec"
  check "대시보드 $uid '$title'가 폴더 k3s-vmware-lab에 들어 있다" jq -e --arg u "$uid" --arg t "$title" '.[] | select(.uid == $u and .title == $t and .folderTitle == "k3s-vmware-lab")' <<<"$dash_list"
done
block "대시보드 목록 (uid · 제목 · 폴더 · 패널 수)" "$(for uid in $(jq -r '.[].uid' <<<"$dash_list"); do gf GET "/api/dashboards/uid/$uid" | jq -r '[.dashboard.uid, .dashboard.title, .meta.folderTitle, (.dashboard.panels | length | tostring) + "개"] | @tsv'; done | column -t -s$'\t')"
check "대시보드는 화면에서 고칠 수 없다(프로비저닝, Git의 JSON이 기준)" test "$(gf GET /api/dashboards/uid/k3slab-infer | jq -r '.meta.provisioned')" == true

# dash_queries 대시보드uid : 그 대시보드의 모든 패널 쿼리를 Grafana(/api/ds/query)로 실행한다.
#   템플릿 변수는 손으로 바꾼다($release/$node → .*, $win → 30s, $job_type → train). $__rate_interval과 SQL 매크로는 Grafana가 처리한다.
#   한 줄에 "패널 제목|refId|오류(없으면 빈칸)|행 수"를 출력한다.
dash_queries() {
  local uid=$1 line body res
  gf GET "/api/dashboards/uid/$uid" | jq -c '
      .dashboard.panels[] | .title as $t | .targets[] |
      {t: $t, q: (. + {intervalMs: 15000, maxDataPoints: 600} |
        if has("expr") then .expr |= (gsub("\\$release"; ".*") | gsub("\\$node"; ".*") | gsub("\\$win"; "30s"))
        else .rawSql |= gsub("\\$job_type"; "train") end)}' |
    while read -r line; do
      body=$(jq -c '{queries: [.q], from: "now-30m", to: "now"}' <<<"$line")
      res=$(gf POST /api/ds/query "$body" || echo '{"results":{}}')
      jq -r --argjson l "$line" '[$l.t, $l.q.refId, ((.results // {} | to_entries | map(.value.error // empty) | first) // ""),
        ((.results // {} | [to_entries[].value.frames[]?.data.values[0] | length] | add) // 0)] | join("|")' <<<"$res"
    done
}
md "" "## 5. 대시보드 쿼리 (모든 패널 쿼리를 Grafana를 거쳐 실행)" ""
total_q=0
total_err=0
for uid in k3slab-infer k3slab-training k3slab-nodes; do
  out=$(dash_queries "$uid")
  n=$(wc -l <<<"$out")
  e=$(awk -F'|' '$3 != ""' <<<"$out" | wc -l)
  total_q=$((total_q + n))
  total_err=$((total_err + e))
  check "대시보드 $uid: 쿼리 $n개 모두 오류 없이 실행 (오류 $e개)" test "$e" -eq 0
  [[ "$e" -eq 0 ]] || block "오류가 난 쿼리 ($uid)" "$(awk -F'|' '$3 != ""' <<<"$out")"
done
md "" "- 쿼리 합계 $total_q개, 오류 $total_err개"

# --- 8) MySQL 읽기 전용 계정 ---
md "" "## 6. MySQL 읽기 전용 계정 (k3slab_ro)" ""
# ro_sql SQL : 읽기 전용 계정으로 MySQL 파드 안에서 SQL 실행. 비밀번호는 표준입력의 첫 줄로만 넘긴다(프로세스 목록에 안 남김)
ro_sql() {
  printf '%s\n%s\n' "$MYSQL_RO_PASSWORD" "$1" |
    k -n k3slab-system exec -i deploy/mysql -- sh -c 'read -r MYSQL_PWD; export MYSQL_PWD; exec mysql -u'"${MYSQL_RO_USER:-k3slab_ro}"' -N -B k3slab'
}
check "SELECT jobs 가능" ro_sql "SELECT COUNT(*) FROM jobs"
check "SELECT job_events 가능" ro_sql "SELECT COUNT(*) FROM job_events"
check "DELETE 거부" bash -c '! "$@"' _ ro_sql "DELETE FROM jobs"
check "UPDATE 거부" bash -c '! "$@"' _ ro_sql "UPDATE jobs SET status = 'DONE'"
check "INSERT 거부" bash -c '! "$@"' _ ro_sql "INSERT INTO jobs (job_id, job_type, model_version, status) VALUES ('ro-test', 'train', 'v0', 'DONE')"
check "DROP 거부" bash -c '! "$@"' _ ro_sql "DROP TABLE job_events"
check "다른 테이블(mysql.user) 조회 거부" bash -c '! "$@"' _ ro_sql "SELECT COUNT(*) FROM mysql.user"

# --- 9) 부하 시험 ---
# deploy_infer 큐크기 [cpu] : 시험용 추론 릴리스를 배포하고 새 파드가 준비될 때까지 기다린다 (infer-gpu-bench.sh와 같은 방식)
#   두 번째 인자로 cpu를 주면 --with-gpu여도 GPU를 요청하지 않고 CPU로 계산한다. 과부하 단계가 이렇게 쓴다:
#   GPU는 배치 하나를 0.5ms쯤에 끝내서(2026-11-22 GPU 시험 0.48ms) 이 부하 도구로는 큐 20을 채울 수 없었다(보고서 1634·1641).
#   과부하 단계의 목적은 GPU가 아니라 "모니터링이 429와 큐 길이를 잡아내는가"이므로 CPU 워커(배치당 약 88ms)로 시험한다.
#   --with-gpu가 없으면 GPU를 요청하지 않고 CPU로 계산한다(gpu=0, DEVICE=cpu). 파드는 그래도 gpu-host에 뜬다(차트의 nodeSelector).
deploy_infer() {
  local gpu=0 device=cpu i
  ((WITH_GPU)) && [[ "${2:-}" != cpu ]] && { gpu=1; device=cuda; }
  h upgrade --install "$REL" "$CHART" -f "$CHART/values-infer.yaml" \
    --set infer.modelJobId="$MODEL_JOB" --set image.tag="$TAG" --set gpu="$gpu" --set-string infer.device="$device" \
    --set infer.queueSize="$1" --set infer.maxBatch=8 --set infer.threads=2 --set infer.workMs=0 \
    --set infer.timeoutMs=30000 --wait --timeout 5m >/dev/null
  # 예전 파드가 완전히 사라질 때까지 기다린 뒤 5초 더 쉰다(kube-proxy가 Service에서 예전 파드를 뺄 시간, infer-bench.sh와 같음)
  for i in $(seq 60); do
    k get pods -l app.kubernetes.io/instance="$REL" -o json |
      jq -e '(.items | length) == 1 and all(.items[]; .metadata.deletionTimestamp == null)' >/dev/null && break
    sleep 2
  done
  sleep 5
  POD=$(k get pods -l app.kubernetes.io/instance="$REL" -o jsonpath='{.items[0].metadata.name}')
}
# wait_target_up : 새 추론 파드가 Prometheus에서 up이 될 때까지(최대 90초) 기다린다
wait_target_up() {
  local i
  for i in $(seq 45); do
    [[ "$(pq "up{job=\"k3slab-infer\",pod=\"$POD\"}")" == 1 ]] && return 0
    sleep 2
  done
  return 1
}
# start_conn_sampler : 추론 파드($POD)의 포트 8080 ESTABLISHED 연결 수를 3초마다 세어 임시 파일에 적는다(/proc/net/tcp를 읽는다. 포트 8080=0x1F90).
#   curl의 --parallel-max는 "최대" 동시 전송 수일 뿐이라, 부하가 실제로 몇 개 연결로 들어갔는지는 따로 잰다.
#   run_load는 $(...) 안에서 돌아서 변수를 못 넘기므로 샘플러는 run_load 밖에서 시작·종료한다.
start_conn_sampler() {
  CONN_LOG=$(mktemp)
  (
    while :; do
      k exec "$POD" -- sh -c 'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null' 2>/dev/null |
        awk '$2 ~ /:1F90$/ && $4 == "01" { c++ } END { print c + 0 }' >>"$CONN_LOG" || true
      sleep 3
    done
  ) &
  CONN_PID=$!
}
# stop_conn_sampler : 샘플러를 멈추고 측정한 최대 연결 수를 CONN_MAX에 담는다(측정 못 하면 빈 값)
stop_conn_sampler() {
  [[ -n "${CONN_PID:-}" ]] && { kill "$CONN_PID" 2>/dev/null || true; wait "$CONN_PID" 2>/dev/null || true; }
  CONN_PID=
  CONN_MAX=$(sort -n "$CONN_LOG" 2>/dev/null | tail -1 || true)
  rm -f "$CONN_LOG"
}
# load_shape 부하Job출력 parallel-max : 부하가 실제로 어떻게 들어갔는지 보고서에 적는다(설정값과 측정값을 구분한다)
load_shape() {
  local total other
  total=$(awk '$1 == "load_code" { n += $3 } END { print n + 0 }' <<<"$1")
  other=$(awk '$1 == "load_code" && $2 != 200 && $2 != 429 { printf "%s=%s ", $2, $3 }' <<<"$1")
  md "- 실제 요청 수: **${total}개** (curl 한 번에 2000개씩 보내고, 시간이 다 될 때까지 되풀이해서 2000의 배수다. 200·429 이외 응답: ${other:-없음}. 000은 연결 실패)"
  md "- 동시 수: 설정은 curl \`--parallel-max $2\`(최대 동시 전송 수). **실제 연결 수**는 추론 파드의 포트 8080 ESTABLISHED를 3초마다 센 값으로 최대 **${CONN_MAX:-측정 못 함}개**(Prometheus 수집 연결 1개 포함)"
}
# run_load 제목 동시연결 초 : curl Job이 keep-alive 연결로 요청을 계속 보내고, 끝나면 응답 코드별 개수를 출력한다
#   curl --parallel은 한 프로세스에서 연결을 재사용해서 요청마다 새 curl을 띄우는 방식보다 훨씬 빠르다(로컬 시험에서 초당 수천 건).
#   본문은 시드 고정 64개 숫자(infer-bench.sh와 같음). 결과: "load_code 코드 개수" 줄들. 끝나면 Job은 지우지 않고 로그만 읽는다(cleanup이 지움).
run_load() {
  local conc=$1 secs=$2
  k delete job "$LOAD_JOB" --ignore-not-found --wait=true >/dev/null
  k apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $LOAD_JOB
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: curl
          image: docker.io/curlimages/curl:8.23.0
          resources:
            requests:
              cpu: 200m
              memory: 128Mi
            limits:
              memory: 256Mi
          command:
            - sh
            - -c
            - |
              awk 'BEGIN { srand(1); printf "{\"x\":["; for (i = 0; i < 64; i++) printf "%s%.4f", (i ? "," : ""), rand() * 2 - 1; print "]}" }' > /tmp/body.json
              awk -v n=2000 'BEGIN { for (i = 1; i <= n; i++) { if (i > 1) print "next"; print "url = \"http://$REL:8080/infer\""; print "data = \"@/tmp/body.json\""; print "output = \"/dev/null\""; print "write-out = \"%{http_code}\\\\n\"" } }' > /tmp/reqs.cfg
              end=\$((\$(date +%s) + $secs))
              while [ \$(date +%s) -lt \$end ]; do curl -s --parallel --parallel-max $conc -K /tmp/reqs.cfg; done | sort | uniq -c | awk '{ print "load_code", \$2, \$1 }'
EOF
  k wait --for=condition=complete "job/$LOAD_JOB" --timeout=$((secs + 240))s >/dev/null || {
    k logs "job/$LOAD_JOB" 2>&1 | tail -5
    return 1
  }
  k logs "job/$LOAD_JOB"
}
# codes 로그 코드 : run_load 출력에서 그 응답 코드의 개수(없으면 0)
codes() { awk -v c="$2" '$1 == "load_code" && $2 == c { n += $3 } END { print n + 0 }' <<<"$1"; }
# cnt result 시각 : 추론 파드의 요청 카운터(result별) 값을 그 시각에 읽는다
cnt() { pq "sum(k3slab_infer_requests_total{pod=\"$POD\",result=\"$1\"})" "$2"; }
# diff 끝값 시작값 : 카운터 증가량 (시작값이 NaN=아직 시계열 없음이면 0으로 본다)
diff() { awk -v a="$1" -v b="$2" 'BEGIN { if (b == "NaN") b = 0; printf "%d", a - b }'; }
# within 값1 값2 : 두 개수가 1%(최소 3) 안에서 같으면 성공 (마지막 수집이 최대 5초 늦을 수 있어 약간의 여유를 둔다)
within() { awk -v a="$1" -v b="$2" 'BEGIN { d = a - b; if (d < 0) d = -d; t = (b * 0.01 > 3) ? b * 0.01 : 3; exit !(d <= t) }'; }

if ((LOAD)); then
  LOAD_STARTED=1
  md "" "## 7. 부하 시험 (추론 워커 + GPU)" ""
  md "- 추론 파드: Helm 릴리스 \`$REL\`, 이미지 \`infer-worker:$TAG\`, 모델 \`$MODEL_JOB\`, MAX_BATCH 8, 스레드 2, WORK_MS 0 (흉내 비용 없이 실제 계산)"
  md "- GPU: $([[ $WITH_GPU == 1 ]] && echo '요청함(nvidia.com/gpu 1, DEVICE=cuda)' || echo '요청하지 않음(CPU 계산). GPU 지표 변화는 시험하지 않았다(--with-gpu 없음)')"
  md "- 부하: 보통 = curl --parallel-max $CONCURRENCY(최대 동시 전송 수)로 ${DURATION}초, 과부하 = 큐 20, curl --parallel-max ${OVERLOAD_CONCURRENCY}(최대 동시 전송 수), 시간 ${OVERLOAD_SECONDS}초 (keep-alive curl --parallel). 과부하 단계는 --with-gpu여도 CPU 워커로 돈다(GPU가 너무 빨라 큐가 차지 않는다)"
  md "- 워커의 HTTP 스레드 풀은 큐 크기 + 스레드×배치 + 16개다(\`apps/infer/main.cpp\` 128행). 큐 500이면 532개, 큐 20이면 52개라서, 연결이 이보다 많으면 나머지는 기다린다(큐 20에서 한 번에 처리되는 요청은 최대 52개)"

  # (a) 추론 파드가 없을 때의 GPU 메모리 (모델·CUDA 컨텍스트가 올라오기 전)
  sleep 20
  T0=$(prom_now)
  fb_before=$(pq 'avg_over_time(DCGM_FI_DEV_FB_USED[20s])')
  util_before=$(pq 'avg_over_time(DCGM_FI_DEV_GPU_UTIL[20s])')
  log "no inference pod yet: GPU memory ${fb_before} MiB, utilization ${util_before}%"

  # (b) 추론 파드 배포 → 수집 대상에 들어오는지
  deploy_infer 500
  check "추론 파드($POD)가 수집 대상(k3slab-infer)에 들어와 up" wait_target_up
  check "추론 워커 수집 대상 up (실제 $(job_up k3slab-infer))" expect_job k3slab-infer 1
  for m in k3slab_infer_info k3slab_infer_queue_length k3slab_infer_queue_capacity k3slab_infer_worker_threads k3slab_infer_requests_total \
    k3slab_infer_batch_size_count k3slab_infer_batch_compute_seconds_count k3slab_infer_request_seconds_count; do
    check "추론 지표 $m (pod=$POD) 시계열 $(pq_count "$m{pod=\"$POD\"}")개" test "$(pq_count "$m{pod=\"$POD\"}")" -gt 0
  done
  dev=$(pq_label "k3slab_infer_info{pod=\"$POD\"}" device)
  md "" "- 워커 장치(k3slab_infer_info): \`$dev\`"
  if ((WITH_GPU)); then
    check "워커가 GPU(cuda)에서 계산한다 (device=$dev)" test "$dev" == cuda
    sleep 15
    fb_idle=$(pq 'avg_over_time(DCGM_FI_DEV_FB_USED[10s])')
    check "추론 파드가 모델을 올린 뒤 GPU 메모리가 늘었다 (${fb_before} → ${fb_idle} MiB)" fcmp "$fb_idle" ">=" "$(awk -v b="$fb_before" 'BEGIN { print b + 50 }')"
  fi

  # (c) 쉬는 상태 30초 (비교 기준)
  sleep 30
  T1=$(prom_now)
  util_idle_avg=$(pq 'avg_over_time(DCGM_FI_DEV_GPU_UTIL[30s])' "$T1")
  util_idle_max=$(pq 'max_over_time(DCGM_FI_DEV_GPU_UTIL[30s])' "$T1")
  power_idle=$(pq 'avg_over_time(DCGM_FI_DEV_POWER_USAGE[30s])' "$T1")
  power_idle_max=$(pq 'max_over_time(DCGM_FI_DEV_POWER_USAGE[30s])' "$T1")
  ok0=$(cnt ok "$T1")
  rej0=$(cnt rejected "$T1")

  # (d) 보통 부하
  log "load phase 1: concurrency $CONCURRENCY for ${DURATION}s"
  S1=$(prom_now)
  start_conn_sampler
  load1=$(run_load "$CONCURRENCY" "$DURATION") || { stop_conn_sampler; die "load Job failed"; }
  stop_conn_sampler
  sleep 10 # 마지막 수집(5초 간격)이 끝나기를 기다린다
  E1=$(prom_now)
  W1=$((E1 - S1))
  block "부하 Job 출력 (보통 부하)" "$load1"
  load_shape "$load1" "$CONCURRENCY"
  c200=$(codes "$load1" 200)
  ok1=$(cnt ok "$E1")
  d_ok=$(diff "$ok1" "$ok0")
  d_rate=$(awk -v n="$d_ok" -v w="$DURATION" 'BEGIN { printf "%.1f", n / w }')
  load_util_avg=$(pq "avg_over_time(DCGM_FI_DEV_GPU_UTIL[${W1}s])" "$E1")
  load_util_max=$(pq "max_over_time(DCGM_FI_DEV_GPU_UTIL[${W1}s])" "$E1")
  load_power=$(pq "avg_over_time(DCGM_FI_DEV_POWER_USAGE[${W1}s])" "$E1")
  fb_load=$(pq "max_over_time(DCGM_FI_DEV_FB_USED[${W1}s])" "$E1")
  q_max=$(pq "max_over_time(k3slab_infer_queue_length{pod=\"$POD\"}[${W1}s])" "$E1")
  b_sum=$(pq "increase(k3slab_infer_batch_size_sum{pod=\"$POD\"}[${W1}s])" "$E1")
  b_cnt=$(pq "increase(k3slab_infer_batch_size_count{pod=\"$POD\"}[${W1}s])" "$E1")
  avg_batch=$(awk -v s="$b_sum" -v c="$b_cnt" 'BEGIN { if (c > 0) printf "%.2f", s / c; else print "NaN" }')
  lat_s=$(pq "increase(k3slab_infer_request_seconds_sum{pod=\"$POD\"}[${W1}s])" "$E1")
  lat_c=$(pq "increase(k3slab_infer_request_seconds_count{pod=\"$POD\"}[${W1}s])" "$E1")
  avg_lat_ms=$(awk -v s="$lat_s" -v c="$lat_c" 'BEGIN { if (c > 0) printf "%.2f", s / c * 1000; else print "NaN" }')
  comp_s=$(pq "increase(k3slab_infer_batch_compute_seconds_sum{pod=\"$POD\"}[${W1}s])" "$E1")
  comp_c=$(pq "increase(k3slab_infer_batch_compute_seconds_count{pod=\"$POD\"}[${W1}s])" "$E1")
  avg_comp_ms=$(awk -v s="$comp_s" -v c="$comp_c" 'BEGIN { if (c > 0) printf "%.3f", s / c * 1000; else print "NaN" }')
  # (d2) 부하가 끝난 뒤 쉬는 구간 30초 (부하 전과 함께 "쉬는 상태의 흔들림" 범위를 정한다)
  sleep 30
  T2=$(prom_now)
  util_after_max=$(pq 'max_over_time(DCGM_FI_DEV_GPU_UTIL[30s])' "$T2")
  power_after_max=$(pq 'max_over_time(DCGM_FI_DEV_POWER_USAGE[30s])' "$T2")

  check "추론 지표가 변했다: ok 요청 카운터 +$d_ok (초당 $d_rate)" test "$d_ok" -gt 0
  check "Prometheus 카운터 증가량($d_ok)이 부하 클라이언트가 센 200 응답($c200)과 같다(±1%)" within "$d_ok" "$c200"
  check "배치가 묶였다: 평균 배치 크기 $avg_batch > 1" fcmp "$avg_batch" ">" 1
  check "배치 계산 시간이 기록됐다 (배치당 평균 ${avg_comp_ms} ms)" fcmp "$avg_comp_ms" ">" 0
  if ((WITH_GPU)); then
    # gpu-host는 사용자의 데스크톱이라 GPU가 쉬는 동안에도 사용률이 흔들린다(로컬 확인: 9~41%). 그래서 "부하 중 평균이
    # 쉬는 상태의 평균보다 크다"가 아니라 "부하 중 평균이 부하 전·후 쉬는 구간의 **최댓값**보다 크다"로 판정한다.
    # (판정 기준은 시험 전에 정했고, 결과를 본 뒤 바꾸지 않는다.)
    idle_util_top=$(awk -v a="$util_idle_max" -v b="$util_after_max" 'BEGIN { print (a > b) ? a : b }')
    idle_power_top=$(awk -v a="$power_idle_max" -v b="$power_after_max" 'BEGIN { print (a > b) ? a : b }')
    check "GPU 사용률이 변했다: 부하 중 평균 $(fnum "$load_util_avg")% > 부하 전·후 쉬는 구간의 최댓값 $(fnum "$idle_util_top")%" fcmp "$load_util_avg" ">" "$idle_util_top"
    check "GPU 전력이 변했다: 부하 중 평균 $(fnum "$load_power") W > 부하 전·후 쉬는 구간의 최댓값 $(fnum "$idle_power_top") W" fcmp "$load_power" ">" "$idle_power_top"
    check "GPU 메모리는 부하 중에도 모델을 올린 상태로 유지된다 (부하 중 최대 $(fnum "$fb_load" 0) MiB ≥ 파드 없을 때 $(fnum "$fb_before" 0) MiB + 50)" fcmp "$fb_load" ">=" "$(awk -v b="$fb_before" 'BEGIN { print b + 50 }')"
  else
    note "GPU 사용률·메모리 변화는 시험하지 않았다(--with-gpu 없이 CPU로 계산). GPU 시험은 승인 뒤 \`--with-gpu\`로 다시 실행한다."
  fi

  # (e) 과부하: 큐 20 → 429가 즉시 나와야 한다
  log "load phase 2 (overload, CPU worker): queue 20, curl --parallel-max $OVERLOAD_CONCURRENCY for ${OVERLOAD_SECONDS}s"
  deploy_infer 20 cpu
  wait_target_up || die "the new inference pod did not become a scrape target"
  sleep 15
  S2=$(prom_now)
  ok2_0=$(cnt ok "$S2")
  rej2_0=$(cnt rejected "$S2")
  start_conn_sampler
  load2=$(run_load "$OVERLOAD_CONCURRENCY" "$OVERLOAD_SECONDS") || { stop_conn_sampler; die "overload Job failed"; }
  stop_conn_sampler
  sleep 10
  E2=$(prom_now)
  W2=$((E2 - S2))
  block "부하 Job 출력 (과부하, 큐 20)" "$load2"
  load_shape "$load2" "$OVERLOAD_CONCURRENCY"
  c200b=$(codes "$load2" 200)
  c429=$(codes "$load2" 429)
  d_rej=$(diff "$(cnt rejected "$E2")" "$rej2_0")
  d_ok2=$(diff "$(cnt ok "$E2")" "$ok2_0")
  ratio=$(awk -v r="$d_rej" -v o="$d_ok2" 'BEGIN { t = r + o; if (t > 0) printf "%.4f", r / t; else print "NaN" }')
  q_max2=$(pq "max_over_time(k3slab_infer_queue_length{pod=\"$POD\"}[${W2}s])" "$E2")
  check "429 거절이 늘었다: rejected 카운터 +$d_rej (거절 비율 $(awk -v r="$ratio" 'BEGIN { printf "%.1f", r * 100 }')%)" test "$d_rej" -gt 0
  check "Prometheus rejected 증가량($d_rej)이 부하 클라이언트가 센 429 응답($c429)과 같다(±1%)" within "$d_rej" "$c429"
  check "과부하 중 큐 길이가 올랐다 (최대 $(fnum "$q_max2" 0) / 용량 20)" fcmp "$q_max2" ">" 0
  check "성공(200) 응답도 계속 나왔다: Prometheus ok +$d_ok2, 클라이언트 200 응답 $c200b" within "$d_ok2" "$c200b"

  # (f) 부하 뒤 추론 대시보드: 값이 있는 패널 확인 (p50/p95는 알려진 한계)
  out=$(dash_queries k3slab-infer)
  empty=$(awk -F'|' '$3 == "" && $4 == 0 { print $1 "/" $2 }' <<<"$out" | sort -u)
  empty_other=$(grep -vE '^지연 p50 / p95/' <<<"$empty" || true)
  check "추론 대시보드의 모든 패널이 값을 보여 준다 (비어 있는 패널: ${empty_other:-없음}; p50/p95 제외)" test -z "$empty_other"
  if grep -q '^지연 p50 / p95/' <<<"$empty"; then
    note "지연 p50/p95 패널은 비어 있다: 추론 워커(apps/infer/metrics.cpp)가 k3slab_infer_request_seconds_sum/_count만 내보내고 히스토그램 버킷은 내보내지 않는다. 평균 지연은 보인다. p50/p95가 필요하면 워커에 버킷을 더해야 한다(CICD/추론 담당 협의)."
  fi

  # (g) 측정값 표
  md "" "### 측정값 (Prometheus에서 읽은 값)" ""
  md "| 지표 | 파드 없음 / 쉬는 상태 | 보통 부하 (${DURATION}s, parallel-max $CONCURRENCY) | 과부하 (큐 20, CPU, parallel-max $OVERLOAD_CONCURRENCY) |" "|---|---|---|---|"
  md "| 성공 요청 수 증가 (초당) | 0 | $d_ok ($d_rate/s) | $d_ok2 |"
  md "| 거절(429) 증가 | 0 | $(diff "$(cnt rejected "$E1")" "$rej0") | $d_rej (비율 $(awk -v r="$ratio" 'BEGIN { printf "%.1f", r * 100 }')%) |"
  md "| 큐 길이 최대 | 0 | $(fnum "$q_max" 0) | $(fnum "$q_max2" 0) / 20 |"
  md "| 평균 배치 크기 | - | $avg_batch | - |"
  md "| 평균 지연 (큐 대기 + 계산) | - | ${avg_lat_ms} ms | - |"
  md "| 배치당 계산 시간 | - | ${avg_comp_ms} ms | - |"
  if ((WITH_GPU)); then
    md "| GPU 사용률 평균 / 최대 (%) | $(fnum "$util_idle_avg") / $(fnum "$util_idle_max") (부하 후 쉬는 구간 최대 $(fnum "$util_after_max")) | $(fnum "$load_util_avg") / $(fnum "$load_util_max") | - |"
    md "| GPU 전력 평균 (W) | $(fnum "$power_idle") (최대 $(fnum "$power_idle_max"), 부하 후 최대 $(fnum "$power_after_max")) | $(fnum "$load_power") | - |"
    md "| 워커가 잰 계산 시간 / 경과 시간 (스레드 합) | - | $(awk -v c="$comp_s" -v w="$W1" 'BEGIN { printf "%.2f", c / w }') | - |"
    md "| GPU 메모리 사용 (MiB) | 추론 파드 전 $(fnum "$fb_before" 0) → 모델 로드 후 $(fnum "${fb_idle:-NaN}" 0) | 최대 $(fnum "$fb_load" 0) | - |"
  fi
  md "" "- 보통 부하 클라이언트 응답 코드: $(awk '$1 == "load_code" { printf "%s=%s ", $2, $3 }' <<<"$load1")"
  md "- 과부하 클라이언트 응답 코드: $(awk '$1 == "load_code" { printf "%s=%s ", $2, $3 }' <<<"$load2")"

  # 정리: 부하 Job과 추론 릴리스를 바로 지운다 (GPU를 돌려준다)
  k delete job "$LOAD_JOB" --ignore-not-found >/dev/null
  h uninstall "$REL" >/dev/null
  LOAD_STARTED=0
  log "inference release and load Job removed (GPU released)"
fi

# --- 10) 메모리 사용 ---
md "" "## 8. 메모리 사용 (monitoring 파드)" ""
sleep 5
block "kubectl top pods -n $NS" "$(k top pods -n "$NS" 2>&1 || echo 'metrics-server has no data')"
block "kubectl top nodes" "$(k top nodes 2>&1 || echo 'metrics-server has no data')"
mem_table=$(k -n "$NS" get pods -o json | jq -r '.items[] | .metadata.name as $p | .spec.nodeName as $n | .spec.containers[] | [$p, $n, .name, (.resources.requests.memory // "-"), (.resources.limits.memory // "-")] | @tsv' | column -t -s$'\t')
block "파드 · 노드 · 컨테이너 · memory requests · limits" "$mem_table"
used=$(k get --raw "/api/v1/namespaces/$NS/services/prometheus:9090/proxy/api/v1/query?query=$(jq -rn --arg q "sum by (pod)(container_memory_working_set_bytes{namespace=\"$NS\",container!=\"\"})" '$q|@uri')" |
  jq -r '.data.result[] | [.metric.pod, (.value[1] | tonumber / 1048576 | floor | tostring + " MiB")] | @tsv' | sort | column -t -s$'\t')
block "실사용 메모리 (cAdvisor working set, Prometheus 쿼리)" "$used"
total_mib=$(pq "sum(container_memory_working_set_bytes{namespace=\"$NS\",container!=\"\"})" | awk '{ printf "%d", $1 / 1048576 }')
md "" "- monitoring 네임스페이스 실사용 합계: **${total_mib} MiB** (requests 합계는 위 표, VM 노드는 worker-cpu-1 하나에 Prometheus·Grafana·kube-state-metrics가 모인다)"
md "- Prometheus: 시계열 $(pq 'prometheus_tsdb_head_series') 개, 블록+WAL $(pq 'prometheus_tsdb_storage_blocks_bytes + prometheus_tsdb_wal_storage_size_bytes' | awk '{ printf "%.1f", $1 / 1048576 }') MiB, 프로세스 메모리 $(pq 'process_resident_memory_bytes{job="prometheus"}' | awk '{ printf "%.0f", $1 / 1048576 }') MiB, 보존 7일·상한 2GB"
check "monitoring 파드가 memory limit 안에서 돈다 (OOMKilled 없음, 재시작 0)" test "$(k -n "$NS" get pods -o json | jq '[.items[].status.containerStatuses[]? | select(.restartCount > 0)] | length')" -eq 0

# --- 11) 요약 ---
md "" "## 요약" "" "- PASS $PASS · FAIL $FAIL" "- 보고서: \`${REPORT#"$REPO_ROOT"/}\`"
log "monitoring test: PASS $PASS, FAIL $FAIL (report: $REPORT)"
((FAIL == 0)) || exit 1
