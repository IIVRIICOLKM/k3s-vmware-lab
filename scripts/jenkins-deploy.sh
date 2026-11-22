#!/usr/bin/env bash
# Installs Jenkins in namespace "ci" with the official Helm chart pinned to version 5.13.3 (infra/k8s/jenkins/values.yaml).
# Creates the admin password on the first run (random, kept in the cluster Secret jenkins-admin and in
# ~/.config/k3s-vmware-lab/secrets/jenkins.env, never in Git). Safe to re-run: the password and the Jenkins data stay.
# Usage: scripts/jenkins-deploy.sh            install or upgrade (needs the cluster)
#        scripts/jenkins-deploy.sh --render   offline check: chart checksum, helm lint and helm template (no cluster needed)
#
# [한국어 설명] Jenkins를 클러스터에 올린다 (제안서 10~12주 "Jenkins 빌드·테스트 자동화").
#   1) 차트: 공식 Jenkins Helm 차트 5.13.3의 tgz를 GitHub 릴리스에서 받아 SHA-256이 고정값과 같은지 확인하고 쓴다
#      (~/.local/share/k3s-vmware-lab/charts/에 보관). 해시가 다르면 지우고 중단한다. 이미지·플러그인 버전은 values.yaml에 고정돼 있다.
#   2) 네임스페이스 ci와 에이전트 권한(infra/k8s/jenkins/ci-base.yaml)을 적용한다.
#   3) 관리자 비밀번호: 처음 한 번만 무작위로 만든다. 클러스터 Secret jenkins-admin과
#      ~/.config/k3s-vmware-lab/secrets/jenkins.env(권한 600)에 같이 둔다. 둘 중 하나만 있으면 있는 쪽으로 다른 쪽을 채운다.
#      둘 다 있는데 값이 다르면 아무것도 덮어쓰지 않고 중단한다. 비밀번호는 화면에 출력하지 않는다.
#   4) helm upgrade --install로 올리고 컨트롤러 파드가 Ready가 될 때까지 기다린다 (첫 시작은 플러그인 73개를 받느라 약 10분: 2026-11-22 실측).
#   4-1) 코드와 배포 값의 출처는 클러스터 안 Gitea다 (CICD_연결). 컨트롤러는 Secret ci/gitea-ci(Gitea 계정 k3slab-ci의 토큰)를 마운트하므로
#      이 Secret이 먼저 있어야 한다: scripts/argocd-source.sh ci-init (없으면 배포 전에 멈춘다. Secret 없이 helm을 돌리면 파드가 안 뜬다).
#      JCasC가 이 토큰으로 Jenkins 자격증명 gitea-ci와 운영 작업 k3slab-ci(Gitea main을 1분마다 폴링)를 만든다.
#   5) 확인: 로그인 화면(200), JCasC가 만든 운영 작업 k3slab-ci와 자격증명 gitea-ci, 파드 자원. 배포 전 worker-cpu-1 메모리를 한 번 기록해 둔다
#      (~/.local/state/k3s-vmware-lab/jenkins-memory-before.txt, scripts/jenkins-ci-test.sh가 변화를 계산한다).
#   --render: 클러스터 없이 하는 점검. 차트 해시 확인, helm lint, helm template, 렌더링 결과의 핵심 값(이미지 태그, 노드 배치, 자원) 확인.
#   Jenkins 화면: kubectl -n ci port-forward svc/jenkins 8080:8080 → http://127.0.0.1:8080 (계정 admin, 비밀번호는 jenkins.env)
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 도움말과 상수 ---
# sed -n '2,6s/^# \{0,1\}//p' "$0" : 이 파일 2~6번째 줄(영문 설명)을 도움말로 출력
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  sed -n '2,6s/^# \{0,1\}//p' "$0"
  exit 0
fi
RENDER_ONLY=false
case "${1:-}" in
  "") ;;
  --render) RENDER_ONLY=true ;;
  *) die "usage: scripts/jenkins-deploy.sh [--render] (see --help)" ;;
esac
NS="ci"
RELEASE="jenkins"
CHART_VERSION="5.13.3"
CHART_SHA256="90ba804e982aa2c413b88a76c62980d33838282a4200a1b2720f0a9d489287e7"
CHART_URL="https://github.com/jenkinsci/helm-charts/releases/download/jenkins-${CHART_VERSION}/jenkins-${CHART_VERSION}.tgz"
CHART_DIR="$LAB_DATA_DIR/charts"
CHART_TGZ="$CHART_DIR/jenkins-${CHART_VERSION}.tgz"
MANIFESTS="$REPO_ROOT/infra/k8s/jenkins"
KUBECONFIG_FILE="$LAB_SECRETS_DIR/kubeconfig"
LOCAL_COPY="$LAB_SECRETS_DIR/jenkins.env"
MEMORY_BEFORE="$LAB_STATE_DIR/jenkins-memory-before.txt"

# k / h : 이 클러스터용 kubectl·helm (K3S_CONFIG_FILE=/dev/null은 k3s 링크의 권한 경고 제거)
k() { K3S_CONFIG_FILE=/dev/null KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"; }
h() { KUBECONFIG="$KUBECONFIG_FILE" helm "$@"; }
# rand_pw : 영문·숫자 32자 무작위 비밀번호 (특수문자를 빼서 셸·YAML 따옴표 문제를 피함)
#   head가 32자를 읽고 끝나면 tr이 SIGPIPE(141)로 끝나는데, pipefail이면 이것이 실패로 잡혀 set -e가 스크립트를 조용히 끝낸다.
#   그래서 파이프 상태는 무시(|| true)하고 대신 길이가 32인지 직접 확인한다.
rand_pw() {
  local s
  s=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)
  [[ ${#s} -eq 32 ]] || return 1
  printf '%s' "$s"
}

# --- 2) 차트 내려받기와 해시 확인 ---
# 이미 있어도 해시를 다시 확인한다. 다르면 지우고 중단 (손상되었거나 바뀐 파일을 쓰지 않는다).
mkdir -p "$CHART_DIR"
if [[ ! -f "$CHART_TGZ" ]]; then
  log "downloading Jenkins chart $CHART_VERSION"
  curl -fsSL --retry 3 --retry-delay 2 -o "$CHART_TGZ.part" "$CHART_URL" || { rm -f "$CHART_TGZ.part"; die "cannot download $CHART_URL"; }
  mv "$CHART_TGZ.part" "$CHART_TGZ"
fi
if ! echo "$CHART_SHA256  $CHART_TGZ" | sha256sum -c - >/dev/null 2>&1; then
  rm -f "$CHART_TGZ"
  die "Jenkins chart $CHART_VERSION does not match the pinned SHA-256 (file removed; check $CHART_URL)"
fi
log "chart jenkins-$CHART_VERSION OK (SHA-256 matches the pin)"

# --- 3) 클러스터 없이 하는 점검 (--render) ---
if [[ "$RENDER_ONLY" == true ]]; then
  out=$(mktemp)
  trap 'rm -f "$out"' EXIT
  helm lint "$CHART_TGZ" -f "$MANIFESTS/values.yaml" >/dev/null || die "helm lint failed"
  helm template "$RELEASE" "$CHART_TGZ" -n "$NS" -f "$MANIFESTS/values.yaml" >"$out" || die "helm template failed"
  # 렌더링 결과의 핵심 값 확인: 고정 이미지, 컨트롤러 배치와 자원, 영구 저장소, 사이드카 없음
  grep -q 'image: "docker.io/jenkins/jenkins:2.580.2-jdk25"' "$out" || die "controller image is not pinned to 2.580.2-jdk25"
  grep -q 'k3slab.io/role: platform' "$out" || die "controller is not placed on the platform node"
  grep -q 'storage: "5Gi"' "$out" || die "PVC size is not 5Gi"
  ! grep -q 'k8s-sidecar' "$out" || die "the config-reload sidecar should be off"
  # Gitea 토큰: Secret gitea-ci의 키 token이 gitea-ci-token 파일로 마운트되고, JCasC가 그 값으로 자격증명 gitea-ci와 Gitea를 보는 작업을 만든다
  grep -q 'path: gitea-ci-token' "$out" || die "the Secret gitea-ci (key token) is not mounted as gitea-ci-token"
  grep -q 'gitea.k3slab-system.svc.cluster.local:3000/k3slab/k3s-vmware-lab.git' "$out" || die "the job k3slab-ci does not read the in-cluster Gitea"
  ! grep -q 'github.com/IIVRIICOLKM' "$out" || die "the job k3slab-ci still reads GitHub"
  ! grep -Eq 'image: .*:(latest)"?$' "$out" || die "an image uses the latest tag"
  # 모든 매니페스트가 YAML로 읽히는지 (ci-base.yaml 포함)
  python3 -I -c 'import sys, yaml; [d for f in sys.argv[1:] for d in yaml.safe_load_all(open(f))]' "$out" "$MANIFESTS/ci-base.yaml" ||
    die "a manifest is not valid YAML"
  log "PASS: helm lint and helm template OK; controller 2.580.2-jdk25 on the platform node, PVC 5Gi, no sidecar, no latest tags, Gitea token mounted"
  exit 0
fi

# --- 4) 준비 확인과 배포 전 메모리 기록 ---
[[ -f "$KUBECONFIG_FILE" ]] || die "missing $KUBECONFIG_FILE (the cluster is not set up)"
k get nodes >/dev/null 2>&1 || die "the cluster is not reachable (is it running?)"
k get nodes -l k3slab.io/role=platform -o name | grep -q . || die "no node with k3slab.io/role=platform"
mkdir -p "$LAB_STATE_DIR"
if [[ ! -f "$MEMORY_BEFORE" ]] && ! k -n "$NS" get statefulset "$RELEASE" >/dev/null 2>&1; then
  # 처음 배포하기 전 상태만 기록한다 (metrics-server가 없으면 기록하지 않고 넘어간다)
  { date '+%F %T'; k top nodes 2>&1; } >"$MEMORY_BEFORE" || true
  log "recorded node memory before the first deploy -> ${MEMORY_BEFORE#"$HOME/"}"
fi

# --- 5) 네임스페이스와 에이전트 권한 ---
k apply -f "$MANIFESTS/ci-base.yaml" >/dev/null
log "namespace $NS and agent permissions applied"

# --- 5-1) Gitea 토큰 Secret (CICD_연결) ---
# 컨트롤러가 이 Secret을 마운트한다(values.yaml의 additionalExistingSecrets). 없으면 파드가 ContainerCreating에서 멈추므로 여기서 먼저 확인한다.
k -n "$NS" get secret gitea-ci >/dev/null 2>&1 ||
  die "Secret $NS/gitea-ci is missing (the Jenkins job reads the in-cluster Gitea with it). Run: scripts/argocd-source.sh ci-init"
log "Secret $NS/gitea-ci exists (token of the Gitea user k3slab-ci)"

# --- 6) 관리자 비밀번호 (처음 한 번만 생성) ---
# 클러스터 Secret과 로컬 파일을 맞춘다. MySQL과 달리 Jenkins는 시작할 때마다 Secret을 읽어 계정을 만들기 때문에
# 비밀번호를 바꿔도 데이터가 깨지지는 않지만, 두 곳이 어긋나면 사용자가 로그인하지 못하므로 어긋남을 허용하지 않는다.
mkdir -p "$LAB_SECRETS_DIR"
have_secret=false
k -n "$NS" get secret jenkins-admin >/dev/null 2>&1 && have_secret=true
if [[ "$have_secret" == true && -f "$LOCAL_COPY" ]]; then
  cluster_pw=$(k -n "$NS" get secret jenkins-admin -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)
  local_pw=$(sed -n 's/^JENKINS_ADMIN_PASSWORD=//p' "$LOCAL_COPY")
  [[ "$cluster_pw" == "$local_pw" ]] || die "Secret $NS/jenkins-admin and $LOCAL_COPY hold different passwords; fix one of them (nothing was changed)"
elif [[ "$have_secret" == true ]]; then
  cluster_pw=$(k -n "$NS" get secret jenkins-admin -o jsonpath='{.data.jenkins-admin-password}' | base64 -d)
  (umask 077 && printf 'JENKINS_ADMIN_USER=admin\nJENKINS_ADMIN_PASSWORD=%s\n' "$cluster_pw" >"$LOCAL_COPY")
  log "saved a copy of the Secret's password to $LOCAL_COPY (mode 600)"
else
  if [[ -f "$LOCAL_COPY" ]]; then
    pw=$(sed -n 's/^JENKINS_ADMIN_PASSWORD=//p' "$LOCAL_COPY")
    [[ -n "$pw" ]] || die "$LOCAL_COPY has no JENKINS_ADMIN_PASSWORD"
    log "restoring Secret $NS/jenkins-admin from $LOCAL_COPY"
  else
    pw=$(rand_pw)
    (umask 077 && printf 'JENKINS_ADMIN_USER=admin\nJENKINS_ADMIN_PASSWORD=%s\n' "$pw" >"$LOCAL_COPY")
    log "created the admin password; saved to $LOCAL_COPY (mode 600) and Secret $NS/jenkins-admin"
  fi
  k -n "$NS" create secret generic jenkins-admin --from-literal=jenkins-admin-user=admin --from-literal=jenkins-admin-password="$pw" >/dev/null
fi
chmod 600 "$LOCAL_COPY"

# --- 7) Helm 설치 ---
# --wait: StatefulSet의 파드가 Ready(readinessProbe = 로그인 화면 응답)가 될 때까지. 첫 시작은 플러그인을 받느라 오래 걸린다.
log "helm upgrade --install $RELEASE (chart $CHART_VERSION); the first start downloads 73 plugins, about 10 minutes"
h upgrade --install "$RELEASE" "$CHART_TGZ" -n "$NS" -f "$MANIFESTS/values.yaml" --wait --timeout 12m >/dev/null ||
  die "helm upgrade --install failed (kubectl -n $NS describe pod jenkins-0 / logs jenkins-0 -c init)"

# --- 8) 확인 ---
# 로그인 화면은 파드 안에서 확인한다 (호스트에서 Service 주소로 접속하지 않는다)
code=$(k -n "$NS" exec jenkins-0 -c jenkins -- curl -sS -o /dev/null -w '%{http_code}' http://localhost:8080/login)
[[ "$code" == 200 ]] || die "Jenkins /login answered HTTP $code"
log "Jenkins login page: HTTP 200"
# 플러그인이 values.yaml의 고정 목록대로 모두 로드됐는지: "이름:버전"이 하나라도 빠지거나 다르면 중단한다.
#   로드에 실패한 플러그인은 목록에서 빠진다. 의존 플러그인 버전이 어긋나면 Declarative Pipeline이 빠진 채로 Jenkins가 뜨고
#   파이프라인이 단계 없이 SUCCESS로 끝난다 (2026-11-22 첫 배포에서 겪음). 로그인 화면은 이 경우에도 200이라 직접 비교해야 한다.
plugins=$(k -n "$NS" exec jenkins-0 -c jenkins -- sh -c 'curl -sS -u "$(cat /run/secrets/additional/chart-admin-username):$(cat /run/secrets/additional/chart-admin-password)" "http://localhost:8080/pluginManager/api/json?depth=1&tree=plugins%5BshortName,version,active%5D"')
expected=$(sed -n 's/^    - \([a-z0-9-]*:[A-Za-z0-9._-]*\)$/\1/p' "$MANIFESTS/values.yaml" | LC_ALL=C sort)
[[ -n "$expected" ]] || die "no pinned plugins found in $MANIFESTS/values.yaml"
loaded=$(jq -r '.plugins[] | select(.active == true) | "\(.shortName):\(.version)"' <<<"$plugins" | LC_ALL=C sort)
missing=$(LC_ALL=C comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$loaded") | tr '\n' ' ')
[[ -z "$missing" ]] || die "plugins not loaded (or loaded with another version): $missing (kubectl -n $NS logs jenkins-0 -c jenkins | grep 'Failed Loading plugin')"
log "plugins: all $(wc -l <<<"$expected") pinned plugins are loaded"
# 운영 작업 k3slab-ci는 JCasC(job-dsl)가 만든다
jobs=$(k -n "$NS" exec jenkins-0 -c jenkins -- sh -c 'curl -sS -u "$(cat /run/secrets/additional/chart-admin-username):$(cat /run/secrets/additional/chart-admin-password)" "http://localhost:8080/api/json?tree=jobs%5Bname%5D"')
[[ "$jobs" == *'"k3slab-ci"'* ]] || die "JCasC did not create the job k3slab-ci: $jobs"
log "job k3slab-ci exists (created by JCasC)"
# Gitea 자격증명 gitea-ci (JCasC가 Secret의 토큰으로 만든다). 이 id로 작업이 코드를 받고 Jenkinsfile이 태그 커밋을 올린다.
cred=$(k -n "$NS" exec jenkins-0 -c jenkins -- sh -c 'curl -sS -o /dev/null -w "%{http_code}" -u "$(cat /run/secrets/additional/chart-admin-username):$(cat /run/secrets/additional/chart-admin-password)" "http://localhost:8080/credentials/store/system/domain/_/credential/gitea-ci/api/json"')
[[ "$cred" == 200 ]] || die "Jenkins credential gitea-ci does not exist (HTTP $cred); check the Secret $NS/gitea-ci and kubectl -n $NS logs jenkins-0 -c jenkins | grep -i casc"
log "credential gitea-ci exists (loaded from Secret $NS/gitea-ci)"
k -n "$NS" get pods -o wide
k top pod -n "$NS" 2>/dev/null || true
log "done. Jenkins UI: kubectl -n $NS port-forward svc/jenkins 8080:8080  (user admin, password in ${LOCAL_COPY/#$HOME/~})"
