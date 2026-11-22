#!/usr/bin/env bash
# Deploys MySQL for job status (infra/k8s/mysql.yaml) and applies the schema (infra/k8s/mysql-schema.sql).
# Creates the passwords on the first run (random, kept in the cluster and in ~/.config/k3s-vmware-lab/secrets/mysql.env,
# never in Git) and the Secret k3slab-db that training Jobs read. Safe to re-run: existing data and passwords stay.
# Usage: scripts/mysql-deploy.sh
#
# [한국어 설명] 작업 상태를 기록할 MySQL을 클러스터에 올리고 테이블을 만든다 (제안서 11번 슬라이드).
#   1) 비밀번호: 처음 실행할 때만 무작위로 만든다. 클러스터 Secret(k3slab-db-root)과
#      로컬 파일(~/.config/k3s-vmware-lab/secrets/mysql.env, 권한 600)에 같이 둔다. Git에는 절대 올리지 않는다.
#   2) 학습 Job이 읽을 접속 정보 Secret(k3slab-db, default 네임스페이스)을 만든다. 앱 계정만 들어 있고 root는 없다.
#   3) MySQL Deployment·PVC·Service를 적용하고 준비될 때까지 기다린다. 위치는 worker-cpu-1(platform 노드).
#   4) 스키마(jobs, job_events)를 적용한다. CREATE TABLE IF NOT EXISTS라서 다시 실행해도 기존 행은 그대로다.
#   다시 실행해도 안전하다(멱등). 데이터와 비밀번호는 바뀌지 않는다.
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 도움말과 상수 ---
# sed -n '2,5s/^# \{0,1\}//p' "$0" : 이 파일 2~5번째 줄(영문 설명)을 도움말로 출력
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  sed -n '2,5s/^# \{0,1\}//p' "$0"
  exit 0
fi
(($# == 0)) || die "scripts/mysql-deploy.sh takes no arguments (see --help)"
NS="k3slab-system"       # MySQL이 사는 네임스페이스 (레지스트리와 같음)
WORKLOAD_NS="default"    # 학습·추론 Helm 릴리스가 설치되는 네임스페이스
KUBECONFIG_FILE="$LAB_SECRETS_DIR/kubeconfig"
LOCAL_COPY="$LAB_SECRETS_DIR/mysql.env"
DB_HOST="mysql.$NS.svc.cluster.local"

# k [kubectl 인자...] : 이 클러스터용 kubectl (K3S_CONFIG_FILE=/dev/null은 k3s 링크의 권한 경고 제거)
k() { K3S_CONFIG_FILE=/dev/null KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"; }
# rand_pw : 영문·숫자 32자 무작위 비밀번호 (특수문자를 빼서 셸·YAML 따옴표 문제를 피함)
rand_pw() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32; }

# --- 2) 비밀번호 Secret (처음 한 번만 생성) ---
# 이미 있으면 그대로 쓴다: MySQL은 데이터 폴더를 처음 만들 때만 비밀번호를 읽으므로, 나중에 바꾸면 접속이 깨진다.
k get namespace "$NS" >/dev/null 2>&1 || k create namespace "$NS" >/dev/null
if ! k -n "$NS" get secret k3slab-db-root >/dev/null 2>&1; then
  log "creating passwords (Secret $NS/k3slab-db-root)"
  k -n "$NS" create secret generic k3slab-db-root \
    --from-literal=root-password="$(rand_pw)" --from-literal=app-password="$(rand_pw)" >/dev/null
fi
# 클러스터 Secret에서 앱 비밀번호를 읽는다 (base64로 저장돼 있음)
APP_PW=$(k -n "$NS" get secret k3slab-db-root -o jsonpath='{.data.app-password}' | base64 -d)
[[ -n "$APP_PW" ]] || die "Secret $NS/k3slab-db-root has no app-password"
# 로컬 사본: VM을 다시 만들어 클러스터 Secret이 사라져도 접속 정보를 잃지 않게 (권한 600, Git 제외 경로)
mkdir -p "$LAB_SECRETS_DIR"
if [[ ! -f "$LOCAL_COPY" ]]; then
  ROOT_PW=$(k -n "$NS" get secret k3slab-db-root -o jsonpath='{.data.root-password}' | base64 -d)
  (umask 077 && printf 'MYSQL_ROOT_PASSWORD=%s\nMYSQL_APP_USER=k3slab\nMYSQL_APP_PASSWORD=%s\n' "$ROOT_PW" "$APP_PW" >"$LOCAL_COPY")
  log "saved a copy of the passwords to $LOCAL_COPY (mode 600)"
fi

# --- 3) 워크로드용 접속 정보 Secret (매번 갱신) ---
# 학습 Job은 이 Secret을 환경변수로 받는다 (charts/k3slab-workload의 db.secretName). root 비밀번호는 넣지 않는다.
k -n "$WORKLOAD_NS" create secret generic k3slab-db \
  --from-literal=DB_HOST="$DB_HOST" --from-literal=DB_PORT=3306 --from-literal=DB_NAME=k3slab \
  --from-literal=DB_USER=k3slab --from-literal=DB_PASSWORD="$APP_PW" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
log "Secret $WORKLOAD_NS/k3slab-db -> $DB_HOST:3306/k3slab"

# --- 4) MySQL 배포와 준비 대기 ---
# rollout status: 새 파드가 readinessProbe(앱 계정으로 SELECT 1)를 통과할 때까지 기다린다.
# 처음에는 이미지 pull(약 250MB)과 데이터 폴더 초기화가 있어 1~2분 걸린다.
k apply -f "$REPO_ROOT/infra/k8s/mysql.yaml" >/dev/null
log "waiting for MySQL (first start pulls the image and initialises the data directory)"
k -n "$NS" rollout status deploy/mysql --timeout=5m

# --- 5) 스키마 적용 ---
# 파일을 표준입력으로 넘겨 파드 안 mysql 클라이언트로 실행한다. MYSQL_PWD = 명령줄에 비밀번호를 남기지 않는 방법.
k -n "$NS" exec -i deploy/mysql -- sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysql -uk3slab k3slab' \
  <"$REPO_ROOT/infra/k8s/mysql-schema.sql"
tables=$(k -n "$NS" exec deploy/mysql -- sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" mysql -uk3slab -N -e "SHOW TABLES" k3slab' | tr '\n' ' ')
log "schema applied; tables: $tables"
