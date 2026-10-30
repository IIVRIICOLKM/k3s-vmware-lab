#!/usr/bin/env bash
# Builds a container image inside the cluster with Kaniko and pushes it to the in-cluster registry
# (infra/k8s/registry.yaml). The build context is shipped as a ConfigMap, so no host Docker daemon is needed.
# Tags are immutable: an existing tag is never rebuilt. Each build is recorded in docs/image-builds.md.
# Usage: scripts/image-build.sh <context-dir> <image-name> <tag>   e.g. scripts/image-build.sh apps/train train-worker v0.1
#
# [한국어 설명] 클러스터 안에서 Kaniko로 컨테이너 이미지를 빌드하고 클러스터 내부 레지스트리에 push한다.
#   - 호스트 Docker를 쓰지 않는다. Docker는 꺼져 있고, 쓰려면 sudo나 docker 그룹이 필요하다.
#     빌드 폴더(Dockerfile + 파일들)를 ConfigMap으로 클러스터에 넘기고, 빌드 Job이 그걸 읽는다.
#   - 빌드는 gpu-host에서 한다. CUDA 베이스 이미지를 풀면 약 8GB라 VM 디스크(40GB)보다 호스트가 낫다.
#     그래서 빌드 Job은 gpu-host의 nvidia.com/gpu taint를 견디도록(toleration) 만든다.
#   - 태그는 불변: 레지스트리에 이미 있는 태그면 빌드하지 않고 멈춘다(새 태그를 쓴다).
#   - 빌드마다 docs/image-builds.md에 한 줄 기록: 시각 · 이미지:태그 · digest · git 커밋 · 빌드 폴더 해시
#     (제안서 9번: Dockerfile·이미지 태그·values를 한 묶음으로 남긴다)
#   [인자] 빌드 폴더(하위 폴더 없이 파일만, 합계 900KB 이하 — ConfigMap 한도 1MiB), 이미지 이름, 태그
#   [로그] ~/.local/state/k3s-vmware-lab/logs/image-build-<이름>-<태그>.log
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 인자 검사 ---
# sed -n '2,5s/^# \{0,1\}//p' "$0" : 이 파일 2~5번째 줄(영문 설명)을 도움말로 출력
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  sed -n '2,5s/^# \{0,1\}//p' "$0"
  exit 0
fi
(($# == 3)) || die "usage: scripts/image-build.sh <context-dir> <image-name> <tag> (see --help)"
CTX=$(cd "$1" && pwd)
NAME=$2
TAG=$3
[[ -f "$CTX/Dockerfile" ]] || die "$CTX has no Dockerfile"
# 이미지 이름은 소문자·숫자·'-', 태그는 영문·숫자·'_' '.' '-' (Docker 규칙의 안전한 부분집합)
[[ "$NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "image name must be lowercase letters, digits and '-'"
[[ "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$ ]] || die "invalid tag '$TAG'"
# 하위 폴더는 ConfigMap에 들어가지 않으므로 거부, 크기는 ConfigMap 한도(1MiB)보다 여유 있게 900KB로 제한
[[ -z "$(find "$CTX" -mindepth 1 -type d -print -quit)" ]] || die "$CTX has subdirectories; a ConfigMap context holds files only"
ctx_bytes=$(find "$CTX" -maxdepth 1 -type f -printf '%s\n' | awk '{s += $1} END {print s + 0}')
((ctx_bytes <= 900000)) || die "$CTX is $ctx_bytes bytes; keep the build context under 900 KB"

# --- 2) 상수 ---
# NS: 플랫폼 구성요소 네임스페이스 / REGISTRY_NAME: 노드들이 쓰는 레지스트리 이름(registries.yaml에서 IP로 연결)
# KANIKO_IMAGE: 원래 Google 프로젝트가 보관(archived)된 뒤 이어서 관리되는 커뮤니티 포크
NS="k3slab-system"
REGISTRY_NAME="registry.k3slab.local:5000"
REGISTRY_IP="10.43.0.50"
REGISTRY_URL="http://$REGISTRY_IP:5000"
KANIKO_IMAGE="docker.io/martizih/kaniko:v1.28.6"
KUBECONFIG_FILE="$LAB_SECRETS_DIR/kubeconfig"
# Job 이름: build-<이름>-<태그>, 태그의 '.'과 '_'는 '-'로 바꾼다 (쿠버네티스 이름 규칙)
JOB="build-$NAME-${TAG//[._]/-}"
JOB=${JOB,,}
CM="build-ctx-$NAME"
DEST="$REGISTRY_NAME/$NAME:$TAG"
mkdir -p "$LAB_LOG_DIR"
LOG="$LAB_LOG_DIR/image-build-$NAME-$TAG.log"
RECORD="$REPO_ROOT/docs/image-builds.md"

# k [kubectl 인자...] : 이 클러스터용 kubectl (K3S_CONFIG_FILE=/dev/null은 k3s 링크의 권한 경고 제거)
k() { K3S_CONFIG_FILE=/dev/null KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"; }

# --- 3) 레지스트리 확인 ---
# 호스트도 K3s 노드라 kube-proxy 규칙 덕분에 ClusterIP(10.43.0.50)에 바로 접속할 수 있다
curl -fsS -m 5 "$REGISTRY_URL/v2/" >/dev/null || die "registry $REGISTRY_URL is not reachable (kubectl apply -f infra/k8s/registry.yaml)"
# 태그 불변 원칙: 매니페스트가 이미 있으면(HTTP 200) 중단
code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 \
  -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
  "$REGISTRY_URL/v2/$NAME/manifests/$TAG")
[[ "$code" != 200 ]] || die "$DEST already exists; tags are immutable, use a new tag"

# --- 4) 빌드 폴더 → ConfigMap ---
# --dry-run=client -o yaml | apply : 있으면 갱신, 없으면 생성 (create만 쓰면 두 번째 실행에서 실패)
log "build context $CTX -> configmap $NS/$CM ($ctx_bytes bytes)"
k -n "$NS" create configmap "$CM" --from-file="$CTX" --dry-run=client -o yaml | k apply -f - >/dev/null

# --- 5) Kaniko 빌드 Job 실행 ---
# 같은 이름의 이전 Job(실패한 시도 등)은 지우고 새로 만든다
k -n "$NS" delete job "$JOB" --ignore-not-found --wait=true >/dev/null
log "kaniko job $NS/$JOB -> $DEST (log: $LOG)"
# hostAliases: 빌드 파드 안에서 registry.k3slab.local을 레지스트리 ClusterIP로 연결 (파드는 노드의 registries.yaml을 모름)
# --insecure: 레지스트리가 클러스터 내부 HTTP라서 / --digest-file=/dev/termination-log: 결과 digest를 파드 상태로 남김
# initContainer "context": ConfigMap 볼륨의 파일은 실제 파일이 아니라 ..data/<파일>을 가리키는 심볼릭 링크다.
#   Kaniko가 이걸 그대로 COPY하면 이미지에 깨진 링크가 들어간다(2026-10-30 train-worker:v0.1에서 실제로 발생).
#   그래서 cp -L(링크를 따라가 실제 내용 복사)로 빈 폴더(emptyDir)에 옮긴 뒤 그 폴더를 빌드 컨텍스트로 쓴다.
k apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
  namespace: $NS
  labels:
    app: image-build
    k3slab.io/image: $NAME
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        app: image-build
        k3slab.io/image: $NAME
    spec:
      restartPolicy: Never
      nodeSelector:
        k3slab.io/role: gpu
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      hostAliases:
        - ip: "$REGISTRY_IP"
          hostnames: ["${REGISTRY_NAME%%:*}"]
      initContainers:
        - name: context
          image: docker.io/library/busybox:1.37.0
          command: ["sh", "-c", "cp -L /context-src/* /workspace/ && ls -l /workspace"]
          volumeMounts:
            - name: context-src
              mountPath: /context-src
            - name: workspace
              mountPath: /workspace
      containers:
        - name: kaniko
          image: $KANIKO_IMAGE
          args:
            - --context=dir:///workspace
            - --dockerfile=Dockerfile
            - --destination=$DEST
            - --insecure
            - --digest-file=/dev/termination-log
            - --snapshot-mode=redo
          resources:
            requests:
              cpu: "1"
              memory: 2Gi
          volumeMounts:
            - name: workspace
              mountPath: /workspace
      volumes:
        - name: context-src
          configMap:
            name: $CM
        - name: workspace
          emptyDir: {}
EOF

# --- 6) 빌드 로그 따라가기 ---
# 파드가 만들어지고 컨테이너가 시작(또는 이미 종료)될 때까지 기다린 뒤 logs -f로 끝까지 출력 (화면 + 로그 파일)
# Kaniko 이미지 pull + CUDA 베이스(3.3GB) pull·압축 해제가 있어 첫 빌드는 10분 이상 걸릴 수 있다
for _ in $(seq 120); do
  state=$(k -n "$NS" get pods -l job-name="$JOB" -o jsonpath='{.items[0].status.containerStatuses[0].state}' 2>/dev/null || true)
  [[ "$state" == *running* || "$state" == *terminated* ]] && break
  sleep 5
done
k -n "$NS" logs -f "job/$JOB" 2>&1 | tee "$LOG" || true
# logs -f가 끝난 뒤 Job이 Complete인지 Failed인지 판정
k -n "$NS" wait --for=condition=complete "job/$JOB" --timeout=120s >/dev/null ||
  die "build failed: $(k -n "$NS" get pods -l job-name="$JOB" -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.reason}') (log: $LOG)"

# --- 7) 결과 확인과 기록 ---
# digest: 빌드 파드 종료 메시지(--digest-file)에서 읽음 / 레지스트리 태그 목록으로 push를 다시 확인
digest=$(k -n "$NS" get pods -l job-name="$JOB" -o jsonpath='{.items[0].status.containerStatuses[0].state.terminated.message}')
curl -fsS "$REGISTRY_URL/v2/$NAME/tags/list" | jq -e --arg t "$TAG" '.tags | index($t)' >/dev/null ||
  die "registry does not list $NAME:$TAG after the build"
# 깨진 링크 검사: 50MB 미만 레이어(= COPY 등으로 우리가 추가한 작은 레이어)를 받아서
# ConfigMap 링크(-> ..data/...)가 남아 있으면 실패 처리한다. 베이스 이미지의 큰 레이어는 받지 않는다.
check_dir=$(mktemp -d)
curl -fsS -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
  "$REGISTRY_URL/v2/$NAME/manifests/$TAG" >"$check_dir/manifest.json"
while IFS= read -r layer; do
  curl -fsS -o "$check_dir/layer.tgz" "$REGISTRY_URL/v2/$NAME/blobs/$layer"
  # 목록을 먼저 변수에 받는다: tar | grep -q 로 바로 이으면 grep이 일찍 끝날 때 tar가 SIGPIPE로 실패하고,
  # pipefail 때문에 "찾았다"가 "실패"로 뒤집혀 깨진 링크를 놓친다. tar -tvf는 gzip 여부를 스스로 판별한다.
  listing=$(tar -tvf "$check_dir/layer.tgz")
  if grep -q -- '-> \.\.data/' <<<"$listing"; then
    rm -rf "$check_dir"
    die "$DEST contains ConfigMap symlinks (-> ..data/); the build context was not dereferenced"
  fi
done < <(jq -r '.layers[] | select(.size < 52428800) | .digest' "$check_dir/manifest.json")
rm -rf "$check_dir"
# 빌드 폴더 해시: 파일 이름순으로 각 파일 sha256을 모은 뒤 다시 sha256 (폴더 내용이 같으면 같은 값)
ctx_hash=$(cd "$CTX" && find . -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)
# git 커밋: 작업 트리에 커밋 안 된 변경이 있으면 "+dirty"를 붙인다
commit=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo none)
[[ -z "$(git -C "$REPO_ROOT" status --porcelain -- "$CTX" 2>/dev/null)" ]] || commit="$commit+dirty"
if [[ ! -f "$RECORD" ]]; then
  printf '# 이미지 빌드 기록\n\n`scripts/image-build.sh`가 빌드마다 한 줄씩 추가한다. 실행 기록(Helm values)과 함께 보면 어떤 코드와 설정으로 돌린 결과인지 추적할 수 있다.\n\n| 시각 | 이미지 | digest | git 커밋 | 빌드 폴더 | 폴더 해시 |\n|---|---|---|---|---|---|\n' >"$RECORD"
fi
printf '| %s | `%s` | `%s` | `%s` | `%s` | `%s` |\n' "$(date '+%F %T')" "$DEST" "${digest:-unknown}" "$commit" "${CTX#"$REPO_ROOT/"}" "$ctx_hash" >>"$RECORD"
log "pushed $DEST ($digest); recorded in ${RECORD#"$REPO_ROOT/"}"
