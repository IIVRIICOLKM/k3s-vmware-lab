#!/usr/bin/env bash
# Git source for Argo CD: sets up the lab Git server in the cluster (infra/k8s/argocd/gitea.yaml) and moves commits in and out.
# Usage: scripts/argocd-source.sh init                 admin user, repository and Argo CD read access (safe to re-run)
#        scripts/argocd-source.sh push [message]       copy charts/ from the working tree into the repository (one commit)
#        scripts/argocd-source.sh edit <file> <sed-script> <message>   change one file in the repository, commit, push
#        scripts/argocd-source.sh revert <sha>  |  head  |  url
#
# [한국어 설명] Argo CD가 읽어 갈 Git 저장소를 클러스터 안 Gitea에 만들고, 커밋을 넣고 빼는 스크립트.
#   왜 필요한가: Argo CD는 Git에서 읽는다. GitHub 저장소는 공개이고 클러스터에 GitHub 쓰기 자격증명을 두지 않기 위해
#     Jenkins가 태그 커밋을 넣고 Argo CD가 읽는 저장소를 클러스터 안 Gitea에 둔다(infra/k8s/argocd/README.md "Git 소스").
#   명령:
#     init   : Gitea 관리자 계정(k3slab)·저장소(k3slab/k3s-vmware-lab, 비공개)를 만들고, Argo CD용 읽기 전용 토큰을 만들어
#              argocd 네임스페이스에 저장소 Secret(repo-k3slab-git)으로 등록한다. 여러 번 실행해도 안전하다.
#     push   : 작업 폴더의 charts/ 전체를 저장소 main에 한 커밋으로 반영한다(바뀐 게 없으면 커밋하지 않는다). 새 커밋 번호를 출력한다.
#     edit   : 저장소의 파일 하나를 sed로 고쳐 커밋·push한다. "CICD_연결"이 Jenkins가 만든 새 이미지 태그를 넣을 때도 이걸 쓴다:
#              scripts/argocd-source.sh edit charts/k3slab-workload/values-infer-argocd.yaml 's|^  tag: .*|  tag: v0.3|' "infer-worker v0.3"
#     revert : 커밋 하나를 되돌리는 새 커밋을 만든다(GitOps 방식 롤백).
#     head   : 저장소 main의 최신 커밋 번호.  url : 클러스터 안에서 쓰는 저장소 주소.
#   접속: kubectl port-forward로 Gitea에 잠깐 연결한다(끝나면 자동으로 닫힘). 비밀번호는 명령줄에 올리지 않는다.
#   비밀값: ~/.config/k3s-vmware-lab/secrets/gitea.env (권한 600: 관리자 비밀번호, Argo CD 읽기 토큰). Git에는 없다.
#   시험용: 환경변수 ARGOCD_SOURCE_REMOTE=<Git 주소>를 주면 클러스터 대신 그 저장소(예: file:///tmp/x.git)를 쓴다(init 제외).
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 인자와 상수 ---
# sed -n '2,6s/^# \{0,1\}//p' "$0" : 이 파일 2~6번째 줄(영문 설명)을 도움말로 출력
if [[ "${1:-}" == -h || "${1:-}" == --help || $# -lt 1 ]]; then
  sed -n '2,6s/^# \{0,1\}//p' "$0"
  exit $(($# < 1 ? 1 : 0))
fi
CMD=$1
shift
GIT_NS="k3slab-system"        # Gitea가 사는 네임스페이스 (레지스트리·MySQL과 같음)
ARGO_NS="argocd"
GIT_USER="k3slab"             # Gitea 관리자 계정이자 저장소 소유자
GIT_REPO="k3s-vmware-lab"
BRANCH="main"
CRED_FILE="$LAB_SECRETS_DIR/gitea.env"
KUBECONFIG_FILE="$LAB_SECRETS_DIR/kubeconfig"
REPO_SECRET="repo-k3slab-git" # Argo CD가 저장소 접속 정보로 읽는 Secret 이름
IN_CLUSTER_URL="http://gitea.$GIT_NS.svc.cluster.local:3000/$GIT_USER/$GIT_REPO.git"
AUTHOR_NAME="k3slab argocd source"
AUTHOR_EMAIL="argocd-source@k3slab.local"
WORK=$(mktemp -d)             # 임시 작업 폴더 (끝날 때 지운다)
PF_PID=""
REMOTE="${ARGOCD_SOURCE_REMOTE:-}"
BASE=""
AUTH_B64=""
GITEA_ADMIN_PASSWORD=""
GITEA_READ_TOKEN=""

# k : 이 클러스터용 kubectl (K3S_CONFIG_FILE=/dev/null은 k3s 링크의 권한 경고 제거)
k() { K3S_CONFIG_FILE=/dev/null KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"; }
# info : 진행 메시지는 표준 에러로 (표준 출력은 커밋 번호처럼 다른 명령이 받아 쓰는 값만)
info() { log "$@" >&2; }
# cleanup : 종료할 때 port-forward를 닫고 임시 폴더를 지운다
cleanup() {
  [[ -z "$PF_PID" ]] || kill "$PF_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- 2) 비밀값 파일과 Gitea 연결 ---
# load_creds : gitea.env에서 관리자 비밀번호(·읽기 토큰)를 읽는다. 권한이 600이 아니면 중단한다.
load_creds() {
  [[ -f "$CRED_FILE" ]] || die "missing $CRED_FILE (run: scripts/argocd-source.sh init)"
  [[ "$(stat -c %a "$CRED_FILE")" == "600" ]] || die "$CRED_FILE must be mode 600"
  # shellcheck disable=SC1090
  source "$CRED_FILE"
  : "${GITEA_ADMIN_PASSWORD:?}"
  AUTH_B64=$(printf '%s:%s' "$GIT_USER" "$GITEA_ADMIN_PASSWORD" | base64 -w0)
}
# save_creds : 관리자 비밀번호와 읽기 토큰을 gitea.env에 쓴다 (umask 077 = 소유자만 읽기·쓰기)
save_creds() {
  mkdir -p "$LAB_SECRETS_DIR"
  (umask 077 && printf 'GITEA_ADMIN_USER=%s\nGITEA_ADMIN_PASSWORD=%s\nGITEA_READ_TOKEN=%s\n' \
    "$GIT_USER" "$GITEA_ADMIN_PASSWORD" "$GITEA_READ_TOKEN" >"$CRED_FILE")
}
# open_git : Git 주소(REMOTE)를 정한다. 시험용 주소가 없으면 Gitea에 port-forward를 열고 준비될 때까지 기다린다.
open_git() {
  [[ -z "$REMOTE" ]] || return 0
  local port i ok=0
  # 비어 있는 포트를 운영체제에서 받아 온다
  port=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  # k 함수가 아니라 kubectl을 직접 백그라운드로 실행한다: 그래야 $!가 kubectl의 PID라서 kill이 port-forward를 정말 끝낸다
  K3S_CONFIG_FILE=/dev/null KUBECONFIG="$KUBECONFIG_FILE" kubectl -n "$GIT_NS" port-forward svc/gitea "$port:3000" \
    >"$WORK/port-forward.log" 2>&1 &
  PF_PID=$!
  for i in $(seq 30); do
    if curl -fs -o /dev/null "http://127.0.0.1:$port/api/healthz"; then ok=1; break; fi
    sleep 1
  done
  ((ok)) || die "cannot reach Gitea through port-forward (is the gitea pod running? see $WORK/port-forward.log)"
  BASE="http://127.0.0.1:$port"
  REMOTE="$BASE/$GIT_USER/$GIT_REPO.git"
}
# api 메서드 경로 [json] : Gitea API 호출. HTTP 상태 코드를 출력하고 본문은 $WORK/api.out에 둔다.
#   자격증명은 curl 설정을 표준입력으로 넘겨서 ps 명령에 비밀번호가 보이지 않게 한다(common.sh의 vmrest_api와 같은 방법)
api() {
  local method=$1 path=$2 data=${3:-}
  printf 'user = "%s:%s"\n' "$GIT_USER" "$GITEA_ADMIN_PASSWORD" |
    curl -sS --config - -X "$method" -H 'Content-Type: application/json' ${data:+--data "$data"} \
      -o "$WORK/api.out" -w '%{http_code}' "$BASE$path"
}
# g [git 인자...] : git 실행. 관리자 계정을 HTTP 헤더로 붙이고(명령줄에 남지 않음), 커밋 작성자를 지정하고,
#   비밀번호를 묻지 않게 한다. 시험용 주소(ARGOCD_SOURCE_REMOTE)에는 인증을 붙이지 않는다.
g() {
  if [[ -n "$AUTH_B64" && -z "${ARGOCD_SOURCE_REMOTE:-}" ]]; then
    GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader \
      GIT_CONFIG_VALUE_0="Authorization: Basic $AUTH_B64" \
      git -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" -c credential.helper= -c advice.detachedHead=false "$@"
  else
    GIT_TERMINAL_PROMPT=0 git -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" -c advice.detachedHead=false "$@"
  fi
}
# clone_repo 폴더 : 저장소를 받는다. 비어 있는 저장소(처음)여도 main 브랜치에서 시작하게 맞춘다.
clone_repo() {
  g clone -q "$REMOTE" "$1" 2>/dev/null || die "cannot clone $GIT_USER/$GIT_REPO (run: scripts/argocd-source.sh init)"
  g -C "$1" symbolic-ref HEAD "refs/heads/$BRANCH"
}
# commit_push 폴더 메시지 : 바뀐 게 있으면 커밋하고 main에 push한다. 커밋했으면 성공(0), 바뀐 게 없으면 1
commit_push() {
  local dir=$1 msg=$2
  g -C "$dir" diff --cached --quiet && return 1
  g -C "$dir" commit -q -m "$msg"
  g -C "$dir" push -q origin "HEAD:refs/heads/$BRANCH"
}

# --- 3) init : 관리자 계정 · 저장소 · Argo CD 읽기 권한 ---
cmd_init() {
  [[ -z "${ARGOCD_SOURCE_REMOTE:-}" ]] || die "init works on the cluster's Gitea only (unset ARGOCD_SOURCE_REMOTE)"
  k -n "$GIT_NS" rollout status deploy/gitea --timeout=5m >&2
  # 비밀번호: 처음 한 번만 무작위로 만든다(영문·숫자 32자). 이미 있으면 그대로 쓴다.
  if [[ -f "$CRED_FILE" ]]; then
    load_creds
  else
    GITEA_ADMIN_PASSWORD=$(openssl rand -hex 16)
    save_creds
    info "created $CRED_FILE (mode 600)"
    load_creds
  fi
  open_git
  # 관리자 계정이 이 비밀번호로 로그인되면 그대로 둔다. 아니면(처음이거나 Gitea 데이터가 새로 만들어졌으면) 만들거나 비밀번호를 맞춘다.
  if [[ "$(api GET /api/v1/user)" != 200 ]]; then
    local users
    users=$(k -n "$GIT_NS" exec deploy/gitea -- gitea admin user list)
    # 비밀번호는 표준입력으로 넘긴다(컨테이너 명령줄에 남지 않음). sh -c 뒤의 마지막 인자가 $0이 된다
    if awk 'NR > 1 {print $2}' <<<"$users" | grep -qx "$GIT_USER"; then
      printf '%s\n' "$GITEA_ADMIN_PASSWORD" | k -n "$GIT_NS" exec -i deploy/gitea -- sh -c \
        'read -r PW; gitea admin user change-password --username "$0" --password "$PW" --must-change-password=false' "$GIT_USER" >&2
      info "reset the password of Gitea user $GIT_USER"
    else
      printf '%s\n' "$GITEA_ADMIN_PASSWORD" | k -n "$GIT_NS" exec -i deploy/gitea -- sh -c \
        'read -r PW; gitea admin user create --admin --username "$0" --email "$0@k3slab.local" --password "$PW" --must-change-password=false' "$GIT_USER" >&2
      info "created Gitea admin user $GIT_USER"
    fi
    [[ "$(api GET /api/v1/user)" == 200 ]] || die "cannot log in to Gitea as $GIT_USER after creating the account"
  fi
  # 저장소(비공개, 기본 브랜치 main)
  if [[ "$(api GET "/api/v1/repos/$GIT_USER/$GIT_REPO")" != 200 ]]; then
    [[ "$(api POST /api/v1/user/repos "{\"name\":\"$GIT_REPO\",\"private\":true,\"default_branch\":\"$BRANCH\"}")" == 201 ]] ||
      die "could not create repository $GIT_USER/$GIT_REPO: $(cat "$WORK/api.out")"
    info "created repository $GIT_USER/$GIT_REPO"
  fi
  # Argo CD용 읽기 전용 토큰: 저장된 토큰이 아직 저장소를 읽을 수 있으면 다시 만들지 않는다.
  local token_ok=0
  if [[ -n "$GITEA_READ_TOKEN" ]]; then
    [[ "$(printf 'user = "%s:%s"\n' "$GIT_USER" "$GITEA_READ_TOKEN" |
      curl -sS --config - -o /dev/null -w '%{http_code}' "$BASE/api/v1/repos/$GIT_USER/$GIT_REPO")" == 200 ]] && token_ok=1
  fi
  if ((!token_ok)); then
    GITEA_READ_TOKEN=$(k -n "$GIT_NS" exec deploy/gitea -- gitea admin user generate-access-token \
      --username "$GIT_USER" --token-name "argocd-read-$(date +%Y%m%d%H%M%S)" --scopes read:repository --raw)
    [[ -n "$GITEA_READ_TOKEN" ]] || die "Gitea returned no access token"
    save_creds
    info "created a read-only token for Argo CD (saved in $CRED_FILE)"
  fi
  # Argo CD 저장소 Secret: 라벨 argocd.argoproj.io/secret-type=repository 가 붙은 Secret을 Argo CD가 저장소 등록으로 읽는다.
  #   YAML을 표준입력으로 넘겨서 토큰이 명령줄에 남지 않는다.
  if k get namespace "$ARGO_NS" >/dev/null 2>&1; then
    k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $REPO_SECRET
  namespace: $ARGO_NS
  labels:
    argocd.argoproj.io/secret-type: repository
    app.kubernetes.io/part-of: k3slab-argocd
type: Opaque
stringData:
  type: git
  url: $IN_CLUSTER_URL
  username: $GIT_USER
  password: $GITEA_READ_TOKEN
EOF
    info "Argo CD repository Secret $ARGO_NS/$REPO_SECRET -> $IN_CLUSTER_URL"
  else
    info "namespace $ARGO_NS does not exist yet; run scripts/argocd-deploy.sh up to register the repository in Argo CD"
  fi
}

# --- 4) push : 작업 폴더의 charts/를 저장소에 반영 ---
# 저장소에는 charts/ 만 넣는다(Argo CD가 읽는 경로). 구조는 프로젝트와 같아서 나중에 GitHub로 바꿀 때 repoURL만 바꾸면 된다.
cmd_push() {
  local msg=${1:-"sync charts/ from the working tree"} dir="$WORK/repo"
  [[ -z "${ARGOCD_SOURCE_REMOTE:-}" ]] && load_creds
  open_git
  clone_repo "$dir"
  rm -rf "$dir/charts"
  cp -a "$REPO_ROOT/charts" "$dir/charts"
  g -C "$dir" add -A charts
  if commit_push "$dir" "$msg"; then
    info "pushed: $msg"
  else
    info "charts/ is already up to date in the repository (no new commit)"
  fi
  g -C "$dir" rev-parse HEAD
}

# --- 5) edit : 저장소의 파일 하나를 고쳐 커밋 ---
# edit <저장소 안 경로> <sed 스크립트> <커밋 메시지> : sed -E로 파일을 고친다. 바뀐 게 없으면 실패(잘못된 키를 조용히 넘기지 않음).
cmd_edit() {
  (($# == 3)) || die "usage: edit <file> <sed-script> <message>"
  local file=$1 script=$2 msg=$3 dir="$WORK/repo"
  [[ "$file" =~ ^[A-Za-z0-9._/-]+$ && "$file" != /* && "$file" != *..* ]] || die "file must be a relative path inside the repository: '$file'"
  [[ -z "${ARGOCD_SOURCE_REMOTE:-}" ]] && load_creds
  open_git
  clone_repo "$dir"
  [[ -f "$dir/$file" ]] || die "no file $file in the repository"
  sed -E -i "$script" "$dir/$file"
  g -C "$dir" add -A "$file"
  commit_push "$dir" "$msg" || die "the sed script changed nothing in $file"
  info "committed to $file: $msg"
  g -C "$dir" rev-parse HEAD
}

# --- 6) revert / head / url ---
# revert <커밋> : 그 커밋을 되돌리는 새 커밋을 main에 올린다 (기록은 지우지 않는다)
cmd_revert() {
  (($# == 1)) || die "usage: revert <sha>"
  [[ "$1" =~ ^[0-9a-f]{7,40}$ ]] || die "revert takes a commit id (hex): '$1'"
  local dir="$WORK/repo"
  [[ -z "${ARGOCD_SOURCE_REMOTE:-}" ]] && load_creds
  open_git
  clone_repo "$dir"
  g -C "$dir" revert --no-edit "$1" >/dev/null
  g -C "$dir" push -q origin "HEAD:refs/heads/$BRANCH"
  info "reverted $1"
  g -C "$dir" rev-parse HEAD
}
# head : main의 최신 커밋 번호
cmd_head() {
  [[ -z "${ARGOCD_SOURCE_REMOTE:-}" ]] && load_creds
  open_git
  g ls-remote "$REMOTE" "refs/heads/$BRANCH" | cut -f1
}

# --- 7) 명령 실행 ---
case "$CMD" in
  init) cmd_init ;;
  push) cmd_push "$@" ;;
  edit) cmd_edit "$@" ;;
  revert) cmd_revert "$@" ;;
  head) cmd_head ;;
  url) printf '%s\n' "$IN_CLUSTER_URL" ;;
  *) die "unknown command '$CMD' (see --help)" ;;
esac
