#!/usr/bin/env bash
# Deploys Argo CD v3.6.2 (minimal) and the lab Git server it reads from, and manages the inference Application.
# Usage: scripts/argocd-deploy.sh up          Gitea + Argo CD + chart pushed to Git (no GPU pod)
#        scripts/argocd-deploy.sh app         apply the Argo CD project and the "infer" Application (starts the GPU pod)
#        scripts/argocd-deploy.sh app-down    delete the Application and what it deployed (frees the GPU)
#        scripts/argocd-deploy.sh status  |  down [--with-git]
#
# [한국어 설명] Argo CD(최소 구성)와 Argo CD가 읽어 갈 연구실 Git 서버(Gitea)를 클러스터에 올리고, 추론 서비스 Application을 관리한다.
#   up       : ① 파일 검증(install.yaml SHA-256) ② 네임스페이스(argocd, k3slab-apps) ③ Gitea 배포 ④ Argo CD 배포
#              ⑤ Git 저장소·접속 정보 준비(scripts/argocd-source.sh init) ⑥ 작업 폴더의 charts/를 Git에 반영(push)
#              GPU 파드는 만들지 않는다. 다시 실행해도 안전하다(멱등).
#   app      : AppProject k3slab과 Application infer를 적용한다. 자동 동기화가 켜져 있어서 곧 추론 파드(GPU 1개)가 뜬다.
#   app-down : Application을 지운다. 파이널라이저 때문에 Argo CD가 배포한 Deployment·Service도 함께 지워지고 GPU가 풀린다.
#   status   : 파드·메모리 사용량·Application 상태.
#   down     : app-down 후 Argo CD와 k3slab-apps 네임스페이스를 지운다. --with-git이면 Gitea(저장소 이력 포함)도 지운다.
#   비밀값: Gitea 비밀번호·토큰은 ~/.config/k3s-vmware-lab/secrets/gitea.env(권한 600)와 클러스터 Secret에만 둔다. Git에는 없다.
#   [주의] 클러스터 기동·정지는 이 스크립트가 하지 않는다(플랫폼_클러스터 담당). 클러스터가 꺼져 있으면 중단한다.
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
ARGO_DIR="$REPO_ROOT/infra/k8s/argocd"
ARGO_NS="argocd"
GIT_NS="k3slab-system"      # Gitea가 사는 네임스페이스 (레지스트리·MySQL과 같음). 이 스크립트는 gitea 객체만 만들고 지운다
APP_NS="k3slab-apps"        # Argo CD가 추론 서비스를 배포하는 네임스페이스
APP_NAME="infer"
KUBECONFIG_FILE="$LAB_SECRETS_DIR/kubeconfig"
SOURCE_SH="$REPO_ROOT/scripts/argocd-source.sh"

# k : 이 클러스터용 kubectl (K3S_CONFIG_FILE=/dev/null은 k3s 링크의 권한 경고 제거)
k() { K3S_CONFIG_FILE=/dev/null KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"; }

# --- 2) 점검 함수 ---
# require_cluster : kubeconfig가 있고 API 서버가 답하는지 확인한다. 아니면 이유와 함께 중단한다(기동은 이 스크립트의 일이 아님).
require_cluster() {
  [[ -f "$KUBECONFIG_FILE" ]] || die "missing $KUBECONFIG_FILE (the cluster has not been built)"
  k get nodes --request-timeout=10s >/dev/null 2>&1 || die "the cluster does not answer (is it started? ask 플랫폼_클러스터; this script does not start VMs)"
}
# verify_install : 보관한 공식 설치 파일이 기록된 SHA-256과 같은지 확인한다 (다르면 누군가 파일을 고친 것)
verify_install() {
  (cd "$ARGO_DIR" && sha256sum -c --status install.yaml.sha256) ||
    die "infra/k8s/argocd/install.yaml does not match install.yaml.sha256 (do not edit the upstream file; use kustomization.yaml patches)"
}
# ensure_namespace 이름 : 없으면 만들고, 이 스크립트가 만든 것에는 part-of 라벨을 붙여 둔다(down이 그 라벨로 구분)
ensure_namespace() {
  if ! k get namespace "$1" >/dev/null 2>&1; then
    k create namespace "$1" >/dev/null
    k label namespace "$1" app.kubernetes.io/part-of=k3slab-argocd >/dev/null
    log "created namespace $1"
  fi
}
# wait_rollout 종류/이름 네임스페이스 : 파드가 모두 Ready가 될 때까지 기다린다. 이미지 pull이 오래 걸리면 5분 안에 안 끝날 수 있다.
wait_rollout() {
  k -n "$2" rollout status "$1" --timeout=5m ||
    die "$1 in $2 is not ready after 5 minutes (see: kubectl -n $2 describe pods; an ImagePullBackOff means the node cannot reach the image registry)"
}

# --- 3) up : Gitea + Argo CD + Git 저장소 ---
cmd_up() {
  require_cluster
  verify_install
  ensure_namespace "$GIT_NS"
  ensure_namespace "$APP_NS"

  # Gitea: SECRET_KEY는 처음 한 번만 무작위로 만든다(바꾸면 저장된 비밀값을 못 읽는다). 파드가 환경변수로 받는다.
  if ! k -n "$GIT_NS" get secret gitea-secret >/dev/null 2>&1; then
    log "creating Secret $GIT_NS/gitea-secret"
    k -n "$GIT_NS" create secret generic gitea-secret --from-literal=secret-key="$(openssl rand -hex 24)" >/dev/null
    k -n "$GIT_NS" label secret gitea-secret app.kubernetes.io/part-of=k3slab-argocd >/dev/null
  fi
  k apply -f "$ARGO_DIR/gitea.yaml" >/dev/null
  log "waiting for Gitea (first start pulls the image and creates the database)"
  wait_rollout deploy/gitea "$GIT_NS"

  # Argo CD: 서버 측 적용(--server-side). Application CRD가 256 KiB 주석 한도를 넘어서 일반 apply는 실패한다.
  #   --force-conflicts: 다시 실행할 때 필드 소유권 충돌을 이 스크립트가 가져온다.
  log "applying Argo CD (kustomize: infra/k8s/argocd)"
  k apply --server-side --force-conflicts --field-manager=k3slab-argocd -k "$ARGO_DIR" >/dev/null
  wait_rollout deploy/argocd-redis "$ARGO_NS"
  wait_rollout deploy/argocd-repo-server "$ARGO_NS"
  wait_rollout deploy/argocd-server "$ARGO_NS"
  wait_rollout statefulset/argocd-application-controller "$ARGO_NS"

  # Git 저장소와 접속 정보, 그리고 작업 폴더의 차트
  "$SOURCE_SH" init
  rev=$("$SOURCE_SH" push "sync charts/ from the working tree (argocd-deploy.sh up)")
  log "Git repository $("$SOURCE_SH" url) is at $rev"
  log "Argo CD is up. Next: scripts/argocd-deploy.sh app (starts the GPU inference pod; needs approval)"
  cmd_status
}

# --- 4) app / app-down : 추론 서비스 Application ---
# app : CRD가 준비된 것을 확인하고 프로젝트와 Application을 적용한다. 이후는 Argo CD가 Git과 맞춘다.
cmd_app() {
  require_cluster
  k wait --for=condition=established crd/applications.argoproj.io crd/appprojects.argoproj.io --timeout=60s >/dev/null ||
    die "Argo CD CRDs are missing (run scripts/argocd-deploy.sh up first)"
  # 이미 같은 이름의 Application이 있으면 apply가 그 설정으로 되돌린다(자동 동기화를 꺼 둔 경우도 다시 켠다)
  k apply -f "$ARGO_DIR/application-infer.yaml" >/dev/null
  log "applied AppProject k3slab and Application $APP_NAME (auto-sync + self-heal); Argo CD now deploys it to $APP_NS"
}
# app_down : Application 삭제 → 파이널라이저가 배포된 객체를 지운 뒤 풀린다. 추론 파드가 사라질 때까지 기다린다.
cmd_app_down() {
  require_cluster
  if k -n "$ARGO_NS" get application "$APP_NAME" >/dev/null 2>&1; then
    k -n "$ARGO_NS" delete application "$APP_NAME" --wait=true --timeout=180s >/dev/null ||
      die "Application $APP_NAME was not deleted in 3 minutes (is argocd-application-controller running?)"
  fi
  local i
  for i in $(seq 60); do
    [[ -z "$(k -n "$APP_NS" get pods -l app.kubernetes.io/instance="$APP_NAME" --no-headers 2>/dev/null)" ]] && break
    sleep 2
  done
  [[ -z "$(k -n "$APP_NS" get pods -l app.kubernetes.io/instance="$APP_NAME" --no-headers 2>/dev/null)" ]] ||
    die "inference pods are still present in $APP_NS (GPU not released)"
  log "Application $APP_NAME and its pods are gone (GPU released)"
}

# --- 5) status / down ---
# status : 파드, 메모리 사용량(측정값), Application 상태
cmd_status() {
  require_cluster
  echo "== Argo CD pods ($ARGO_NS)"
  k -n "$ARGO_NS" get pods -o wide 2>&1 || true
  echo "== Gitea ($GIT_NS)"
  k -n "$GIT_NS" get pods -l app.kubernetes.io/name=gitea -o wide 2>&1 || true
  echo "== memory in use (kubectl top; empty if metrics-server is not ready)"
  k -n "$ARGO_NS" top pods 2>&1 || true
  k -n "$GIT_NS" top pods -l app.kubernetes.io/name=gitea 2>&1 || true
  echo "== Application"
  k -n "$ARGO_NS" get applications 2>&1 || true
  k -n "$APP_NS" get pods -o wide 2>&1 || true
}
# down : app-down → Argo CD 삭제 → (--with-git이면 Gitea 삭제) → k3slab-apps 네임스페이스 삭제
#   이 스크립트가 만든 것만 지운다. k3slab-system 네임스페이스(레지스트리·MySQL)와 default의 릴리스는 건드리지 않는다.
cmd_down() {
  local with_git=0
  [[ "${1:-}" != --with-git ]] || with_git=1
  cmd_app_down
  log "deleting Argo CD"
  k delete -k "$ARGO_DIR" --ignore-not-found --wait=true >/dev/null
  if ((with_git)); then
    log "deleting Gitea (repository history is lost)"
    k delete -f "$ARGO_DIR/gitea.yaml" --ignore-not-found --wait=true >/dev/null
    k -n "$GIT_NS" delete secret gitea-secret --ignore-not-found >/dev/null
  fi
  # 네임스페이스는 이 스크립트가 만든 것(part-of 라벨)만 지운다
  if [[ "$(k get namespace "$APP_NS" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null)" == k3slab-argocd ]]; then
    k delete namespace "$APP_NS" --wait=true >/dev/null
  fi
  log "down done"
}

# --- 6) 명령 실행 ---
case "$CMD" in
  up) cmd_up ;;
  app) cmd_app ;;
  app-down) cmd_app_down ;;
  status) cmd_status ;;
  down) cmd_down "$@" ;;
  *) die "unknown command '$CMD' (see --help)" ;;
esac
