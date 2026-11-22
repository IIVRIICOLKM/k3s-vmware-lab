#!/usr/bin/env bash
# Deploys (or removes) the monitoring stack in infra/k8s/monitoring: Prometheus, Grafana, kube-state-metrics,
# node-exporter and dcgm-exporter in the `monitoring` namespace. On `apply` it first creates the passwords (random,
# kept in the cluster Secret grafana-secrets and in ~/.config/k3s-vmware-lab/secrets/monitoring.env, never in Git) and
# the read-only MySQL account k3slab_ro that Grafana uses for the job-status panels. Safe to re-run.
# Usage: scripts/monitoring-deploy.sh [apply|status|remove]   (default: apply)
#
# [한국어 설명] 모니터링(Prometheus·Grafana·exporter)을 클러스터에 올리거나 내린다 (제안서 12–14주).
#   apply  (기본) 1) 점검: 클러스터 응답, MySQL 배포·테이블 존재, 대시보드 ConfigMap 크기
#                 2) 비밀번호: Grafana 관리자·MySQL 읽기 전용 비밀번호를 처음 한 번만 무작위로 만든다.
#                    클러스터 Secret(monitoring/grafana-secrets)과 로컬 파일(monitoring.env, 권한 600)에 같이 둔다.
#                 3) MySQL 읽기 전용 계정 k3slab_ro 생성(jobs·job_events 테이블에 SELECT만, 동시 접속 5개).
#                    infra/k8s/mysql.yaml은 고치지 않고, MySQL 파드 안의 root로 SQL만 실행한다.
#                 4) kubectl apply -k infra/k8s/monitoring → 모든 파드가 준비될 때까지 기다린다.
#   status 파드·PVC·메모리 사용(kubectl top)을 보여 준다.
#   remove monitoring 네임스페이스(PVC 포함)와 ClusterRole·ClusterRoleBinding을 지우고 MySQL 계정을 삭제한다.
#          자기가 만든 것만 지운다(default 네임스페이스·레지스트리·MySQL·nvidia-device-plugin은 건드리지 않는다).
#   비밀번호는 화면에 출력하지 않는다. 다시 실행해도 비밀번호와 데이터는 그대로다(멱등).
#   [준비] 클러스터가 켜져 있고 scripts/mysql-deploy.sh를 한 번 실행해 둘 것.
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 상수 ---
NS="monitoring"                       # 모니터링이 사는 네임스페이스
DB_NS="k3slab-system"                 # MySQL이 사는 네임스페이스 (mysql-deploy.sh와 같음)
MANIFEST_DIR="$REPO_ROOT/infra/k8s/monitoring"
KUBECONFIG_FILE="$LAB_SECRETS_DIR/kubeconfig"
LOCAL_COPY="$LAB_SECRETS_DIR/monitoring.env"
SECRET_NAME="grafana-secrets"
RO_USER="k3slab_ro"                   # Grafana가 쓰는 MySQL 읽기 전용 계정
MAX_DASH_BYTES=200000                 # 대시보드 ConfigMap 크기 경고선 (kubectl apply 주석 한도 약 256 KB)

# k [kubectl 인자...] : 이 클러스터용 kubectl (K3S_CONFIG_FILE=/dev/null은 k3s 링크의 권한 경고 제거)
k() { K3S_CONFIG_FILE=/dev/null KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"; }
# usage : 이 파일 2~6번째 줄(영문 사용법)을 출력하고 종료
usage() {
  sed -n '2,6s/^# \{0,1\}//p' "$0"
  exit "${1:-0}"
}
# rand_pw : 영문·숫자 32자 무작위 비밀번호 (특수문자를 빼서 셸·SQL·YAML 따옴표 문제를 피함. mysql-deploy.sh와 같음)
#   head가 32자를 읽고 닫으면 tr이 SIGPIPE(종료 코드 141)로 끝난다. pipefail과 set -e 아래에서 변수에 바로 대입하면
#   그 141 때문에 스크립트가 멈추므로, 파이프 결과를 `|| true`로 받아 길이만 확인한다.
rand_pw() {
  local pw
  pw=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)
  [[ ${#pw} -eq 32 ]] || die "could not read 32 random characters from /dev/urandom"
  printf '%s' "$pw"
}
# mysql_root : MySQL 파드 안의 root로 SQL을 실행한다(표준입력으로 받음).
#   root 비밀번호는 파드의 환경변수에 이미 있다(mysql.yaml). 명령줄에 비밀번호를 남기지 않는다.
mysql_root() { k -n "$DB_NS" exec -i deploy/mysql -- sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot -N -B'; }

# --- 2) 점검 ---
# preflight : 클러스터 응답, MySQL 준비, 매니페스트 렌더링과 대시보드 크기를 확인한다. 하나라도 어긋나면 멈춘다.
preflight() {
  [[ -f "$KUBECONFIG_FILE" ]] || die "missing $KUBECONFIG_FILE (is the cluster built? see README)"
  k get nodes >/dev/null 2>&1 || die "the cluster does not answer (kubectl get nodes failed); start it first"
  k -n "$DB_NS" get deploy mysql >/dev/null 2>&1 || die "MySQL is not deployed in $DB_NS; run scripts/mysql-deploy.sh first"
  k -n "$DB_NS" rollout status deploy/mysql --timeout=60s >/dev/null || die "MySQL is not ready"
  # 읽기 전용 계정이 SELECT 권한을 받을 두 테이블이 있어야 한다 (없으면 GRANT가 실패한다)
  local tables
  tables=$(mysql_root <<<"SELECT table_name FROM information_schema.tables WHERE table_schema = 'k3slab' AND table_name IN ('jobs', 'job_events') ORDER BY 1" | tr '\n' ' ')
  [[ "$tables" == "job_events jobs " ]] || die "tables jobs/job_events missing in MySQL database k3slab (found: '$tables'); run scripts/mysql-deploy.sh"
  k kustomize "$MANIFEST_DIR" >/dev/null || die "kubectl kustomize $MANIFEST_DIR failed"
  local bytes
  bytes=$(cat "$MANIFEST_DIR"/dashboards/*.json | wc -c)
  ((bytes < MAX_DASH_BYTES)) || die "dashboards are $bytes bytes (limit $MAX_DASH_BYTES): split the ConfigMap grafana-dashboards"
  log "preflight ok (cluster answers, MySQL ready with jobs/job_events, dashboards $bytes bytes)"
}

# --- 3) 비밀번호 ---
# secret_value 키 : 클러스터 Secret의 값 하나(없으면 빈 문자열)
secret_value() { k -n "$NS" get secret "$SECRET_NAME" -o "jsonpath={.data.$1}" 2>/dev/null | base64 -d 2>/dev/null || true; }

# ensure_secrets : 비밀번호를 정하고 클러스터 Secret과 로컬 사본에 둔다.
#   우선순위: 이미 있는 클러스터 Secret → 로컬 사본(VM을 다시 만든 경우) → 새로 무작위 생성
#   결과는 전역 변수 GRAFANA_PW, RO_PW에 담는다(출력하지 않는다).
ensure_secrets() {
  GRAFANA_PW=$(secret_value grafana-admin-password)
  RO_PW=$(secret_value mysql-ro-password)
  if [[ -z "$GRAFANA_PW" || -z "$RO_PW" ]]; then
    if [[ -f "$LOCAL_COPY" ]]; then
      [[ "$(stat -c %a "$LOCAL_COPY")" == "600" ]] || die "$LOCAL_COPY must be mode 600"
      # shellcheck disable=SC1090
      source "$LOCAL_COPY"
      GRAFANA_PW=${GRAFANA_ADMIN_PASSWORD:-}
      RO_PW=${MYSQL_RO_PASSWORD:-}
    fi
  fi
  [[ -n "$GRAFANA_PW" ]] || GRAFANA_PW=$(rand_pw)
  [[ -n "$RO_PW" ]] || RO_PW=$(rand_pw)
  # 로컬 사본: 클러스터를 다시 만들어도 같은 비밀번호를 쓰도록 (권한 600, Git 제외 경로)
  mkdir -p "$LAB_SECRETS_DIR"
  if [[ ! -f "$LOCAL_COPY" ]]; then
    (umask 077 && printf 'GRAFANA_ADMIN_USER=admin\nGRAFANA_ADMIN_PASSWORD=%s\nMYSQL_RO_USER=%s\nMYSQL_RO_PASSWORD=%s\n' \
      "$GRAFANA_PW" "$RO_USER" "$RO_PW" >"$LOCAL_COPY")
    log "saved a copy of the passwords to $LOCAL_COPY (mode 600)"
  fi
  # 클러스터 Secret(매번 같은 값으로 갱신). 네임스페이스가 먼저 있어야 한다.
  k apply -f "$MANIFEST_DIR/namespace.yaml" >/dev/null
  k -n "$NS" create secret generic "$SECRET_NAME" \
    --from-literal=grafana-admin-password="$GRAFANA_PW" --from-literal=mysql-ro-password="$RO_PW" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  log "Secret $NS/$SECRET_NAME ready"
}

# --- 4) MySQL 읽기 전용 계정 ---
# ensure_ro_account : k3slab_ro를 만들고(있으면 비밀번호를 맞추고) jobs·job_events에 SELECT만 준다.
#   비밀번호는 표준입력(SQL 본문)으로만 넘어간다 → 프로세스 목록에 보이지 않는다.
#   WITH MAX_USER_CONNECTIONS 5 : 이 계정이 연결을 다 써서 MySQL(최대 100개)을 막지 못하게 한다.
ensure_ro_account() {
  mysql_root <<SQL >/dev/null
CREATE USER IF NOT EXISTS '$RO_USER'@'%' IDENTIFIED BY '$RO_PW' WITH MAX_USER_CONNECTIONS 5;
ALTER USER '$RO_USER'@'%' IDENTIFIED BY '$RO_PW' WITH MAX_USER_CONNECTIONS 5;
GRANT SELECT ON k3slab.jobs TO '$RO_USER'@'%';
GRANT SELECT ON k3slab.job_events TO '$RO_USER'@'%';
SQL
  log "MySQL account $RO_USER ready (SELECT on k3slab.jobs and k3slab.job_events only)"
}

# --- 5) 배포 ---
# do_apply : 위 단계를 차례로 실행하고 kubectl apply -k로 올린 뒤 준비를 기다린다.
do_apply() {
  preflight
  ensure_secrets
  ensure_ro_account
  k apply -k "$MANIFEST_DIR" >/dev/null
  log "applied infra/k8s/monitoring; waiting for the pods (first start pulls the images)"
  # rollout status: 준비 검사(readinessProbe)를 통과할 때까지 기다린다. 실패하면 우회하지 않고 멈춘다.
  local r
  for r in deploy/prometheus deploy/grafana deploy/kube-state-metrics ds/node-exporter ds/dcgm-exporter; do
    k -n "$NS" rollout status "$r" --timeout=5m || die "$r did not become ready (see: kubectl -n $NS describe $r; kubectl -n $NS logs $r)"
  done
  do_status
  log "Grafana: kubectl -n $NS port-forward svc/grafana 3000:3000  → http://localhost:3000 (user admin, password in $LOCAL_COPY)"
}

# do_status : 파드·PVC와 실제 메모리 사용을 보여 준다
do_status() {
  k -n "$NS" get pods -o wide
  k -n "$NS" get pvc
  # kubectl top은 k3s에 기본으로 들어 있는 metrics-server를 쓴다(몇 십 초 뒤부터 값이 나온다)
  k top pods -n "$NS" 2>/dev/null || log "kubectl top has no data yet (metrics-server needs ~1 minute)"
}

# --- 6) 제거 ---
# do_remove : 이 스택이 만든 것만 지운다. 네임스페이스를 지우면 PVC(Prometheus 데이터)도 함께 사라진다.
do_remove() {
  k delete -k "$MANIFEST_DIR" --ignore-not-found >/dev/null
  k delete namespace "$NS" --ignore-not-found --wait=true >/dev/null
  # MySQL 읽기 전용 계정 삭제 (MySQL이 떠 있을 때만)
  if k -n "$DB_NS" get deploy mysql >/dev/null 2>&1; then
    mysql_root <<<"DROP USER IF EXISTS '$RO_USER'@'%'" >/dev/null
    log "dropped MySQL account $RO_USER"
  fi
  log "removed namespace $NS and the cluster-scoped roles (kept: $LOCAL_COPY, so a re-deploy reuses the passwords)"
}

# --- 7) 진입점 ---
# main [apply|status|remove] : 인자에 따라 실행. 파일을 source로 불러오면(시험용) 실행하지 않는다.
main() {
  case "${1:-apply}" in
    -h | --help) usage 0 ;;
    apply) do_apply ;;
    status) do_status ;;
    remove) do_remove ;;
    *) usage 1 ;;
  esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
