#!/usr/bin/env bash
# Job front door (proposal slide 5 user scenario, slide 11 status table): registers a job in MySQL, starts it from the
# Helm template, and answers status/result questions by job id. The same job id is never run twice.
# Usage: scripts/job.sh submit train <id> [--version V] [--epochs N] [--dataset S] [--hidden H] [--epoch-sleep S]
#        scripts/job.sh submit infer <id> --model-job <train-id> [--device auto|cpu]  |  stop <id>  |  retry <id>
#        scripts/job.sh status <id>  |  result <id>  |  list [N]  |  upload <file.npz>
#
# [한국어 설명] 작업 번호 하나로 학습·추론을 등록·실행·조회하는 입구 스크립트 (제안서 5번 사용자 시나리오, 11번 상태 표).
#   제안서의 여섯 단계와 명령의 대응:
#     템플릿 선택 → submit train|infer (charts/k3slab-workload의 values-train / values-infer)
#     모델 버전 지정 → --version (이미지 태그와 함께 DB model_version 컬럼에 남는다)
#     입력 파일 등록 → upload <파일.npz> (gpu-host /var/lib/k3slab/datasets에 복사, 학습은 --dataset npz:/data/<파일>)
#     실행 요청 → submit (DB에 PENDING을 먼저 넣고, 성공했을 때만 Helm으로 Job/Deployment를 만든다)
#     진행 상태 확인 → status <작업번호> (현재 상태 + 상태 변화 이력 + 마지막 체크포인트)
#     결과 확인 → result <작업번호> (결과 파일 경로 + 실행 로그 끝부분)
#   중복 방지: jobs 테이블의 PRIMARY KEY(job_id). 이미 있는 번호로 submit하면 새로 실행하지 않고 기존 상태를 보여 준다.
#   retry: FAILED가 된 학습만 다시 실행한다. 같은 작업 번호라서 마지막 체크포인트부터 이어서 학습한다.
#   DB 접속: MySQL 파드 안의 mysql 클라이언트를 kubectl exec로 쓴다(호스트에 클라이언트 설치 불필요).
#   [준비] scripts/mysql-deploy.sh를 한 번 실행해 둘 것
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 상수와 도구 함수 ---
CHART="$REPO_ROOT/charts/k3slab-workload"
KUBECONFIG_FILE="$LAB_SECRETS_DIR/kubeconfig"
DB_NS="k3slab-system"
DATASET_DIR="/var/lib/k3slab/datasets"   # gpu-host 경로. 학습 파드에는 /data로 읽기 전용 마운트된다
# 입력값 검사 규칙: SQL·Helm에 그대로 들어가므로 안전한 문자만 허용한다 (작업 번호 규칙은 Helm 차트와 같다)
ID_RE='^[a-z0-9]([-a-z0-9]{0,40}[a-z0-9])?$'
VERSION_RE='^[A-Za-z0-9._-]{1,64}$'
FILE_RE='^[A-Za-z0-9._-]{1,100}\.npz$'

# k / h : 이 클러스터용 kubectl·helm (K3S_CONFIG_FILE=/dev/null은 k3s 링크의 권한 경고 제거)
k() { K3S_CONFIG_FILE=/dev/null KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"; }
h() { KUBECONFIG="$KUBECONFIG_FILE" helm "$@"; }
# usage : 이 파일 2~6번째 줄(영문 사용법)을 출력하고 종료
usage() {
  sed -n '2,6s/^# \{0,1\}//p' "$0"
  exit "${1:-0}"
}
# sql "쿼리" : MySQL 파드 안에서 앱 계정으로 쿼리 실행. -N 머리글 없음 · -B 탭 구분 · -r 문자열 이스케이프 안 함(JSON 그대로)
sql() { k -n "$DB_NS" exec -i deploy/mysql -- sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" exec mysql -uk3slab -N -B -r k3slab' <<<"$1"; }
# kst 컬럼 : UTC로 저장된 시각을 한국 시간 문자열로 (시간대 테이블 없이 +09:00 오프셋으로 변환)
kst() { printf "DATE_FORMAT(CONVERT_TZ(%s, '+00:00', '+09:00'), '%%Y-%%m-%%d %%H:%%i:%%s')" "$1"; }
# row_json 작업번호 : jobs 행 하나를 JSON 한 줄로 (없으면 빈 출력)
row_json() {
  sql "SELECT JSON_OBJECT('job_id', job_id, 'job_type', job_type, 'model_version', model_version, 'status', status,
         'checkpoint_path', checkpoint_path, 'result_path', result_path, 'attempts', attempts,
         'created_at', $(kst created_at), 'updated_at', $(kst updated_at), 'detail', detail)
       FROM jobs WHERE job_id = '$1'"
}
# check_id 작업번호 : 작업 번호 형식 검사
check_id() { [[ "$1" =~ $ID_RE ]] || die "job id must be lowercase letters, digits and '-' (max 42 chars): '$1'"; }
# register 작업번호 종류 버전 : PENDING 행을 넣는다. INSERT IGNORE + ROW_COUNT()로 "새로 넣었나(1) / 이미 있었나(0)"를
#   한 번에 판정한다 → 동시에 두 번 요청해도 PRIMARY KEY 때문에 하나만 1을 받는다
#   ROW_COUNT()는 바로 앞 문장 기준이라 변수(@n)에 먼저 담아 두고 이력 추가와 출력에 쓴다
register() {
  sql "INSERT IGNORE INTO jobs (job_id, job_type, model_version, status) VALUES ('$1', '$2', '$3', 'PENDING');
       SET @n = ROW_COUNT();
       INSERT INTO job_events (job_id, status, detail)
         SELECT '$1', 'PENDING', JSON_OBJECT('by', 'scripts/job.sh') FROM DUAL WHERE @n = 1;
       SELECT @n;"
}
# set_status 작업번호 상태 [오류문구] : 스크립트가 직접 바꾸는 상태(추론 RUNNING/DONE, 실패) 기록 + 이력 추가
set_status() {
  local detail="NULL"
  [[ -n "${3:-}" ]] && detail="JSON_OBJECT('error', '${3//\'/}')"
  sql "UPDATE jobs SET status = '$2', detail = COALESCE($detail, detail) WHERE job_id = '$1';
       INSERT INTO job_events (job_id, status, detail) VALUES ('$1', '$2', $detail);"
}
# show_existing 작업번호 : 중복 요청일 때 기존 상태를 보여 준다
show_existing() {
  log "job $1 already exists; not starting it again (status below)"
  row_json "$1" | jq .
}

# --- 2) submit train : DB에 PENDING 등록 → Helm으로 학습 Job 생성 ---
# 옵션은 Helm values로 옮긴다. --hidden의 쉼표는 Helm --set에서 값 구분자라서 '\,'로 바꿔 넘긴다.
submit_train() {
  local id=$1 version=v0 epochs=10 dataset=synthetic hidden=128 sleep_s=0
  shift
  while (($#)); do
    case $1 in
      --version) version=$2 ;;
      --epochs) epochs=$2 ;;
      --dataset) dataset=$2 ;;
      --hidden) hidden=$2 ;;
      --epoch-sleep) sleep_s=$2 ;;
      *) die "unknown option $1 for submit train" ;;
    esac
    shift 2
  done
  [[ "$version" =~ $VERSION_RE ]] || die "--version must match $VERSION_RE"
  [[ "$epochs" =~ ^[1-9][0-9]{0,4}$ ]] || die "--epochs must be a positive number"
  [[ "$hidden" =~ ^[1-9][0-9]{0,4}(,[1-9][0-9]{0,4}){0,7}$ ]] || die "--hidden must look like 128 or 2048,2048"
  [[ "$sleep_s" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--epoch-sleep must be a number of seconds"
  if [[ "$dataset" != synthetic ]]; then
    [[ "$dataset" == npz:/data/* && "${dataset#npz:/data/}" =~ $FILE_RE ]] ||
      die "--dataset must be synthetic or npz:/data/<file>.npz (upload the file first)"
  fi
  if [[ "$(register "$id" train "$version")" != 1 ]]; then
    show_existing "$id"
    return 0
  fi
  log "registered $id (PENDING); starting Job train-$id"
  if ! h upgrade --install "train-$id" "$CHART" -f "$CHART/values-train.yaml" \
    --set train.jobId="$id" --set-string model.version="$version" --set train.epochs="$epochs" \
    --set-string train.dataset="$dataset" --set-string train.hidden="${hidden//,/\\,}" \
    --set-string train.epochSleep="$sleep_s" >/dev/null; then
    set_status "$id" FAILED "helm install failed"
    die "could not start train-$id (status set to FAILED)"
  fi
  log "started; follow it with: scripts/job.sh status $id"
}

# --- 3) submit infer : 학습 결과(model.k3sm)를 서빙하는 추론 워커 배포 ---
# 상태: PENDING → (Helm --wait로 파드 Ready) RUNNING → stop 하면 DONE. 실패하면 FAILED.
# model_version은 서빙하는 학습 작업의 버전을 그대로 쓴다(어떤 모델로 응답했는지 추적).
submit_infer() {
  local id=$1 model_job="" device=auto
  shift
  while (($#)); do
    case $1 in
      --model-job) model_job=$2 ;;
      --device) device=$2 ;;
      *) die "unknown option $1 for submit infer" ;;
    esac
    shift 2
  done
  check_id "$model_job"
  [[ "$device" == auto || "$device" == cpu ]] || die "--device must be auto or cpu"
  local model
  model=$(row_json "$model_job")
  [[ "$(jq -r '.status // empty' <<<"$model")" == DONE ]] || die "training job $model_job is not DONE"
  local version
  version=$(jq -r .model_version <<<"$model")
  if [[ "$(register "$id" infer "$version")" != 1 ]]; then
    show_existing "$id"
    return 0
  fi
  # CPU로 돌리면 GPU를 요청하지 않는다 → 학습 Job이 GPU를 쓰는 중에도 추론을 띄울 수 있다
  local gpu=1
  [[ "$device" == cpu ]] && gpu=0
  log "registered $id (PENDING); deploying infer-$id (model $model_job, device $device)"
  if ! h upgrade --install "infer-$id" "$CHART" -f "$CHART/values-infer.yaml" \
    --set infer.modelJobId="$model_job" --set-string model.version="$version" \
    --set gpu="$gpu" --set-string infer.device="$device" --wait --timeout 5m >/dev/null; then
    set_status "$id" FAILED "deployment did not become ready"
    die "infer-$id did not become ready (status set to FAILED)"
  fi
  sql "UPDATE jobs SET status = 'RUNNING', result_path = 'http://infer-$id.default.svc:8080/infer',
         detail = JSON_OBJECT('model_job', '$model_job', 'device', '$device') WHERE job_id = '$id';
       INSERT INTO job_events (job_id, status, detail) VALUES ('$id', 'RUNNING', JSON_OBJECT('model_job', '$model_job'));"
  log "serving at http://infer-$id.default.svc:8080/infer (stop with: scripts/job.sh stop $id)"
}

# --- 4) stop / retry ---
# stop : 추론 워커를 내리고 DONE으로 기록
stop_job() {
  local id=$1 type
  type=$(row_json "$id" | jq -r '.job_type // empty')
  [[ "$type" == infer ]] || die "stop is for inference jobs (job $id is '${type:-missing}')"
  h uninstall "infer-$id" >/dev/null || true
  set_status "$id" DONE
  log "infer-$id removed; status DONE"
}
# retry : FAILED인 학습만. Job은 수정할 수 없는 객체라 릴리스를 지우고 같은 값으로 다시 만든다.
#   같은 작업 번호 → 같은 체크포인트 폴더 → train.py가 마지막 체크포인트부터 이어서 학습한다.
retry_job() {
  local id=$1 row
  row=$(row_json "$id")
  [[ "$(jq -r '.job_type // empty' <<<"$row")" == train ]] || die "retry is for training jobs"
  [[ "$(jq -r .status <<<"$row")" == FAILED ]] || die "job $id is $(jq -r .status <<<"$row"); only FAILED jobs are retried"
  local values
  values=$(mktemp)
  h get values "train-$id" -o yaml >"$values" || die "no Helm release train-$id to retry"
  h uninstall "train-$id" --wait >/dev/null
  set_status "$id" PENDING
  h install "train-$id" "$CHART" -f "$CHART/values-train.yaml" -f "$values" >/dev/null
  rm -f "$values"
  log "train-$id restarted; it resumes from $(jq -r '.checkpoint_path // "the start"' <<<"$row")"
}

# --- 5) status / result / list ---
# status : 현재 행 + 상태 변화 이력(시각 · 상태 · 에폭 · 체크포인트) + 쿠버네티스 쪽 실제 상태
status_job() {
  local id=$1 row
  row=$(row_json "$id")
  [[ -n "$row" ]] || die "no job $id"
  jq . <<<"$row"
  echo "events:"
  sql "SELECT $(kst at), status, COALESCE(JSON_UNQUOTE(JSON_EXTRACT(detail, '$.epoch')), '-'),
         COALESCE(checkpoint_path, '-') FROM job_events WHERE job_id = '$id' ORDER BY id" |
    awk -F'\t' '{printf "  %s  %-11s epoch %-4s %s\n", $1, $2, $3, $4}'
  if [[ "$(jq -r .job_type <<<"$row")" == train ]]; then
    echo "kubernetes: $(k get job "train-$id" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type} {end}' 2>/dev/null || echo 'no Job')" \
      "pods: $(k get pods -l job-name="train-$id" --no-headers 2>/dev/null | awk '{printf "%s(%s) ", $1, $3}')"
  else
    echo "kubernetes: $(k get deploy "infer-$id" -o jsonpath='{.status.readyReplicas}/{.spec.replicas} ready' 2>/dev/null || echo 'no Deployment')"
  fi
}
# result : 결과 경로와 로그 끝부분. 학습은 model.pt(PyTorch)와 model.k3sm(추론 워커용) 경로를 함께 보여 준다
result_job() {
  local id=$1 row
  row=$(row_json "$id")
  [[ -n "$row" ]] || die "no job $id"
  # 마지막 에폭의 loss·accuracy는 DONE 행이 아니라 그 직전 RUNNING 이력에 있다 → 이력에서 가장 최근 값을 가져온다
  local last
  last=$(sql "SELECT detail FROM job_events WHERE job_id = '$id' AND JSON_EXTRACT(detail, '$.loss') IS NOT NULL
              ORDER BY id DESC LIMIT 1")
  jq --argjson last "${last:-null}" '{job_id, status, model_version, result_path, export_path: .detail.export_path,
      dataset: .detail.dataset, hidden: .detail.hidden, last_epoch: $last.epoch, loss: $last.loss, accuracy: $last.accuracy}' <<<"$row"
  echo "log (last 5 lines):"
  if [[ "$(jq -r .job_type <<<"$row")" == train ]]; then
    k logs "job/train-$id" --tail 5 2>/dev/null | sed 's/^/  /' || echo "  (pod already removed)"
  else
    k logs "deploy/infer-$id" --tail 5 2>/dev/null | sed 's/^/  /' || echo "  (not running)"
  fi
}
# list [N] : 최근 갱신순 N개 (기본 20)
list_jobs() {
  local n=${1:-20}
  [[ "$n" =~ ^[0-9]{1,4}$ ]] || die "list takes a number"
  printf '%-24s %-6s %-12s %-11s %-8s %s\n' JOB_ID TYPE VERSION STATUS ATTEMPTS UPDATED
  sql "SELECT job_id, job_type, model_version, status, attempts, $(kst updated_at) FROM jobs ORDER BY updated_at DESC LIMIT $n" |
    awk -F'\t' '{printf "%-24s %-6s %-12s %-11s %-8s %s\n", $1, $2, $3, $4, $5, $6}'
}

# --- 6) upload : 입력 파일을 gpu-host 데이터 폴더로 복사 ---
# 호스트 폴더는 root 소유라 sudo 대신 짧은 파드를 쓴다: gpu-host에 busybox 파드를 띄워 그 폴더를 마운트하고
# kubectl cp로 넣는다. 임시 이름으로 받은 뒤 mv → 학습이 반쯤 복사된 파일을 읽지 않는다.
upload_file() {
  local src=$1 name pod="dataset-upload"
  [[ -f "$src" ]] || die "no file $src"
  name=$(basename "$src")
  [[ "$name" =~ $FILE_RE ]] || die "file name must be letters, digits, '.', '_' or '-' and end in .npz"
  k delete pod "$pod" --ignore-not-found --wait=true >/dev/null
  k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod
spec:
  restartPolicy: Never
  nodeSelector:
    k3slab.io/role: gpu
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: upload
      image: docker.io/library/busybox:1.37.0
      command: ["sleep", "600"]
      volumeMounts:
        - name: datasets
          mountPath: /data
  volumes:
    - name: datasets
      hostPath:
        path: $DATASET_DIR
        type: DirectoryOrCreate
EOF
  k wait --for=condition=Ready "pod/$pod" --timeout=120s >/dev/null
  k cp "$src" "$pod:/data/.$name.part" >/dev/null
  k exec "$pod" -- sh -c "mv /data/.$name.part /data/$name && ls -l /data/$name"
  k delete pod "$pod" --wait=false >/dev/null
  log "uploaded; train with: scripts/job.sh submit train <id> --dataset npz:/data/$name"
}

# --- 7) 명령 분기 ---
(($# >= 1)) || usage 1
cmd=$1
shift
case $cmd in
  -h | --help) usage 0 ;;
  submit)
    (($# >= 2)) || usage 1
    kind=$1 id=$2
    shift 2
    check_id "$id"
    case $kind in
      train) submit_train "$id" "$@" ;;
      infer) submit_infer "$id" "$@" ;;
      *) die "submit takes train or infer" ;;
    esac
    ;;
  status | result | stop | retry)
    (($# == 1)) || usage 1
    check_id "$1"
    case $cmd in
      status) status_job "$1" ;;
      result) result_job "$1" ;;
      stop) stop_job "$1" ;;
      retry) retry_job "$1" ;;
    esac
    ;;
  list) list_jobs "${1:-20}" ;;
  upload)
    (($# == 1)) || usage 1
    upload_file "$1"
    ;;
  *) usage 1 ;;
esac
