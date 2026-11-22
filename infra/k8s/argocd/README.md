# Argo CD 배포 자동화 (제안서 11–13주차)

Git에 적힌 배포 상태(Helm 차트 + values)를 Argo CD가 클러스터와 맞춘다. 대상은 **추론 서비스 하나**다
(`charts/k3slab-workload`, `kind: infer`). Git에서 값을 바꾸면 새 리비전이 배포되고, 손으로 바꾼 값은 되돌려진다.

> 상태: 2026-11-22 클러스터에 배포하고 `scripts/argocd-test.sh`로 확인했다. **PASS 23, FAIL 0**
> (sync, self-heal, 새 리비전, rollback 모두 통과). 보고서: `docs/labs/argocd-20261122-1612.md`. Argo CD와 Gitea는 켜 두었고, 추론 파드(GPU)는 내렸다.

## 1. 파일

| 파일 | 역할 |
|---|---|
| `install.yaml` | Argo CD **v3.6.2** 공식 설치 파일 그대로(수정 금지). 출처 `https://raw.githubusercontent.com/argoproj/argo-cd/v3.6.2/manifests/install.yaml` |
| `install.yaml.sha256` | 위 파일의 SHA-256 (`c948064d…a2a2`). `scripts/argocd-deploy.sh`가 매번 검증한다 |
| `kustomization.yaml`, `patches/remove-unused.yaml`, `namespace.yaml` | 최소 구성(dex·notifications·ApplicationSet 컨트롤러 제거), 메모리 limits, 노드 배치, 설정 |
| `gitea.yaml` | Argo CD가 차트를 읽어 갈 연구실 내부 Git 서버(Gitea 28.3.0 rootless, SQLite, PVC 1Gi) |
| `application-infer.yaml` | AppProject `k3slab`과 Application `infer` |
| `../../../charts/k3slab-workload/values-infer-argocd.yaml` | Argo CD가 읽는 배포 값. **Jenkins가 만든 이미지 태그는 여기에 넣는다**(7절) |
| `../../../scripts/argocd-deploy.sh` | 설치·Application 적용·정리 |
| `../../../scripts/argocd-source.sh` | Git 저장소 준비, 작업 폴더 → Git 반영, 커밋·되돌리기, (Jenkins 연결) `ci-init`·`tree`·`log`·`show` |
| `../../../scripts/argocd-test.sh` | sync·self-heal·새 리비전·롤백 시험과 보고서 |

설치 이미지는 모두 버전이 고정돼 있다: `quay.io/argoproj/argocd:v3.6.2`, `public.ecr.aws/docker/library/redis:8.10.1-alpine`
(둘 다 install.yaml에 있는 것), `docker.io/gitea/gitea:28.3.0-rootless`.

## 2. 자원 (배포 승인 요청용)

모두 **worker-cpu-2**(role=app, 3 GB)에 둔다. worker-cpu-1(6 GB)에는 레지스트리·MySQL이 있고 Jenkins·모니터링도 올라올 예정이라 빠듯하다.
platform 노드로 옮기려면 `kustomization.yaml`의 `nodeSelector` 네 곳과 `gitea.yaml`의 `app`을 `platform`으로 바꾼다.

| 파드 | 네임스페이스 | 노드 | CPU requests | 메모리 requests | 메모리 limits |
|---|---|---|---|---|---|
| argocd-application-controller (StatefulSet) | argocd | worker-cpu-2 | 100m | 192Mi | 512Mi |
| argocd-repo-server | argocd | worker-cpu-2 | 50m | 128Mi | 384Mi |
| argocd-server | argocd | worker-cpu-2 | 50m | 96Mi | 256Mi |
| argocd-redis | argocd | worker-cpu-2 | 25m | 32Mi | 128Mi |
| gitea (+ PVC 1Gi, local-path) | k3slab-system | worker-cpu-2 | 50m | 96Mi | 256Mi |
| **합계** | | | **275m** | **544Mi** | **1536Mi** |
| infer (Argo CD가 배포, 시험 때만) | k3slab-apps | gpu-host | 250m | 64Mi | 제한 없음, `nvidia.com/gpu: 1` |

- 시작할 때만 도는 init 컨테이너(`copyutil`, `secret-init`)는 각각 requests 10m/16Mi, limits 64Mi다.
- **측정한 사용량**(2026-11-22, `kubectl top`, 한 번 읽은 값이며 최대값이 아니다): Application 없이 controller 26, redis 9, repo-server 24, server 42, gitea 104 MiB.
  추론 서비스를 동기화하고 시험을 마친 직후에는 controller 139, redis 9, repo-server 32, server 46 MiB(Argo CD 합계 226 MiB), gitea 109 MiB.
  limits(controller 512 / repo-server 384 / server 256 / redis 128 / gitea 256)에는 모두 여유가 있다. 시험 직후 worker-cpu-2는 requests 624Mi(23%), limits 1600Mi(59%)였다(echo-api 포함).
- CPU limits는 두지 않는다(제한하면 helm 렌더링이 느려진다). 메모리 limits 합계 1536Mi는 최악의 경우이고, 평소 사용량은 시험에서 측정한다.
- Go 프로그램에는 `GOMEMLIMIT`(controller 450MiB, repo-server 256MiB, server 220MiB)를 줘서 limit에 닿기 전에 GC가 더 자주 돌게 했다.
- 추가한 설정: repo-server는 차트 렌더링을 동시에 1개만(`reposerver.parallelism.limit=1`), controller 동시 처리 수 축소, redis `maxmemory 80mb`.
- 새 네임스페이스는 `argocd`, `k3slab-apps` 둘이다. Gitea는 기존 `k3slab-system`에 넣고 이 스크립트가 만든 gitea 객체만 지운다.
- 이미지는 quay.io, public.ecr.aws, docker.io에서 받는다(약 300MB). 노드가 이 주소에 못 나가면 `ImagePullBackOff`가 되고, 그때는 레지스트리에 옮겨 담아야 한다.

## 3. 학습 Job은 Argo CD 대상에서 뺀다

Application은 `values-infer.yaml`만 읽어 Deployment와 Service만 만든다. 학습 Job(`kind: train`)은 `scripts/job.sh`가 계속 맡는다. 이유:

1. **MySQL 등록이 먼저다.** `job.sh submit`은 `jobs` 테이블에 PENDING을 넣는 데 성공했을 때만 Helm으로 Job을 만든다.
   같은 작업 번호가 이미 있으면 새로 실행하지 않는다(PRIMARY KEY). Argo CD가 Git의 Job을 만들면 이 기록과 중복 방지를 거치지 않는다.
2. **Job은 요청마다 다르다.** `train.jobId`는 필수이고 작업 번호 하나가 Job 하나, 체크포인트 폴더 하나다. 요청이 올 때마다 Git에 커밋해야 하고,
   같은 번호를 다시 만들면 이어서 학습(resume)하는 동작이 "같은 번호는 두 번 학습하지 않는다"는 약속과 부딪친다.
3. **Job은 끝나는 객체다.** Argo CD의 prune은 Git에서 사라진 Job(과 로그)을 지우고, self-heal은 `retry`로 Job을 지웠다 다시 만드는 흐름과 싸운다.

프로젝트 `k3slab`이 Deployment와 Service만 허용하므로, 학습 Job이 이 경로에 들어가도 Argo CD가 거부한다(조용히 실행되지 않는다).

## 4. Git 소스: 무엇을 Argo CD가 읽게 할까

Argo CD는 Git에서 읽는다. 처음에는 GitHub에 9–11주차 작업이 없고 push가 금지여서 시험할 방법을 비교했다.
그 뒤 사용자가 develop을 GitHub에 올리도록 허락했지만(올리는 일은 총괄이 한다), **Gitea를 그대로 쓴다.**
GitHub 저장소는 공개이고, Jenkins가 태그 커밋을 push하려면 클러스터에 GitHub 쓰기 자격증명을 둬야 하기 때문이다. Gitea는 쓰기가 클러스터 안에서 끝난다.

| 방법 | 장점 | 단점 | 결정 |
|---|---|---|---|
| **A. 클러스터 안 Gitea** (버전 고정) | 진짜 Git이라 커밋·되돌리기·이력이 그대로 된다. Jenkins가 같은 방식으로 태그 커밋을 push할 수 있다. GitHub로 옮길 때는 `repoURL`만 바꾼다 | 파드 1개(256Mi limit) 추가, 관리자 비밀번호·토큰 관리 | **선택** |
| B. `file://` 로컬 경로 | Argo CD는 `file://` 저장소를 읽을 수 있다(소스의 e2e 시험이 쓴다, `test/e2e/fixture`). 파드 추가 없음 | 경로가 repo-server **파드 안**에 있어야 한다 → 노드 디스크에 복사하고 hostPath로 마운트(노드 설정 변경). 커밋을 만들려면 그 안에 Git 저장소를 따로 관리. Jenkins가 push할 곳이 없다 | 제외 |
| C. 정적 HTTP(nginx 등)로 읽기 전용 제공 | 가볍다 | push 불가 → 새 리비전·롤백 시험을 Git 흐름 없이 흉내 내야 한다. Jenkins 연동 불가 | 제외 |
| D. GitHub | 최종 형태, 별도 서버 없음 | 저장소가 공개이고, 태그 커밋을 넣으려면 클러스터(Jenkins)에 GitHub 쓰기 토큰이 필요하다. 읽기만 하는 Argo CD는 공개 저장소라 토큰이 필요 없다 | 쓰지 않음 (바꾸는 방법은 아래) |

**A를 쓰는 방법**
- `scripts/argocd-deploy.sh up`이 Gitea를 올리고, `scripts/argocd-source.sh init`이 관리자 계정(`k3slab`)과 비공개 저장소 `k3slab/k3s-vmware-lab`을 만든 뒤
  Argo CD용 **읽기 전용 토큰**을 `argocd` 네임스페이스의 Secret `repo-k3slab-git`에 등록한다.
- 저장소에는 `charts/`만 넣는다(`argocd-source.sh push`: 작업 폴더의 charts/ 전체를 한 커밋으로). 폴더 구조가 프로젝트와 같아서 Application의 `path`는 GitHub에서도 그대로다.
- 비밀번호·토큰은 `~/.config/k3s-vmware-lab/secrets/gitea.env`(권한 600)와 클러스터 Secret에만 있다. Git에 없다.

**나중에 GitHub로 바꾸려면** (지금은 필요 없다)
- `application-infer.yaml`의 `repoURL`(Application과 AppProject `sourceRepos` 두 곳)을 GitHub 주소로 바꾼다. 공개 저장소를 읽기만 하면 Secret은 필요 없다.
- GitHub는 Git 서버가 클러스터 밖이라 Argo CD가 인터넷으로 나가야 한다(노드의 외부 접속은 이미 이미지 pull에 쓰고 있다).
- 이미지 태그 커밋은 사람이나 Jenkins가 GitHub에 push해야 하므로 그쪽에서는 쓰기 자격증명이 따로 필요하다.

## 5. 사용 순서

```bash
export KUBECONFIG=~/.config/k3s-vmware-lab/secrets/kubeconfig K3S_CONFIG_FILE=/dev/null
scripts/argocd-deploy.sh up        # Gitea + Argo CD + Git 저장소 (GPU 없음)
scripts/argocd-deploy.sh app       # AppProject + Application → 추론 파드(GPU 1개)가 뜬다 (승인 필요)
scripts/argocd-test.sh             # sync · self-heal · 새 리비전 · 롤백 시험, 끝나면 GPU 파드를 내린다
scripts/argocd-deploy.sh app-down  # Application과 배포된 객체 삭제 (GPU 반환)
scripts/argocd-deploy.sh down      # Argo CD까지 정리 (--with-git이면 Gitea도)
```

화면이 필요하면 `kubectl -n argocd port-forward svc/argocd-server 8080:80` 후 `http://127.0.0.1:8080`
(계정 `admin`, 초기 비밀번호는 `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`).

## 6. 추론 서비스 Application이 하는 일

| 항목 | 값 |
|---|---|
| 소스 | `charts/k3slab-workload`, values `values-infer.yaml` → `values-infer-argocd.yaml` (뒤 파일이 이긴다) |
| 대상 | 네임스페이스 `k3slab-apps`, 릴리스 이름 `infer` → Deployment·Service 이름도 `infer`, 주소 `infer.k3slab-apps.svc:8080` |
| 모델 | `infer.modelJobId: db-1107b-train` (gpu-host `/var/lib/k3slab/checkpoints/db-1107b-train/model.k3sm`, 11/07 시험에 쓴 것) |
| 동기화 | 자동, `prune`, `selfHeal`, 실패하면 10초부터 두 배씩 늘려 5번 재시도 |
| 확인 주기 | 30초(`argocd-cm`의 `timeout.reconciliation`). 웹훅이 없어서 폴링이다 |
| 삭제 | Application을 지우면 파이널라이저로 Deployment·Service도 함께 지워진다(GPU 반환) |

GPU 한 장 때문에 생기는 일: 차트가 GPU 파드에는 `maxSurge: 0`(예전 파드를 먼저 내림)을 쓴다. 그래서 값을 바꾼 새 리비전은 잠깐 서비스가 끊겼다가 새 파드가 뜬다.
학습 Job이 GPU를 쓰는 중이면 추론 파드는 Pending이고 Application은 Progressing에 머문다.

## 6-1. 시험 결과 (`scripts/argocd-test.sh`, 2026-11-22, PASS 23 / FAIL 0)

| 시험 | 결과 |
|---|---|
| 처음 sync | Application 생성 21초 만에 Synced + Healthy. 추론 파드는 gpu-host, `/healthz`·`/infer` 응답(`device: cuda`). 이번에는 이미지가 gpu-host에 이미 있었다 |
| self-heal | 손으로 `replicas` 1→2: 2초 만에 1로 되돌림(원래 파드는 재시작 없음). 손으로 Service 삭제: 1초 만에 다시 만들고 응답 |
| 새 리비전 | `infer.maxBatch` 8→4 커밋: 55초 만에 새 파드(`MAX_BATCH=4`)가 배포되고 배포 이력에 두 리비전이 남음 |
| rollback | `argocd app rollback`(자동 동기화를 잠시 끔): 22초 만에 이전 값(`MAX_BATCH=8`)의 새 파드. Git은 그대로라 OutOfSync로 표시됨. 이어서 Git revert 커밋으로 Git과 다시 맞추고 자동 동기화를 켬(파드는 다시 만들어지지 않음) |
| 정리 | Application 삭제로 추론 파드 0개, gpu-host GPU 할당 0 |

참고: `repoURL`이 점 4개짜리 긴 서비스 이름이라 클러스터 DNS 검색 도메인 문제로 첫 sync와 새 리비전 시간에 약 10초 지연이 들어 있을 수 있다고 적었다.
**DNS 수정 뒤 다시 쟀다** (CICD_연결 시험, `docs/labs/cicd-e2e-20261122-2141.md` 6절, 각각 한 번 잰 값): 처음 sync(Application 생성 → Synced + Healthy, 이미지가 노드에 있을 때)는 21초 → **3.9초**.
새 리비전(값 커밋 → 새 파드 Ready)은 55초 → 성공 경로 25.7초, 되돌림 경로 9.5초. 새 리비전 쪽에는 Argo CD의 30초 확인 주기에서 오는 0~30초의 우연이 들어 있어서 전부를 DNS 탓으로 돌릴 수는 없다. 매니페스트는 바꾸지 않았다.

## 7. "CICD_연결": Jenkins가 만든 이미지 태그를 넣는 곳

> 연결은 끝났다. Jenkins의 배포 값 단계가 아래 `image.tag` 한 줄을 새 태그로 커밋한다(`scripts/cicd-set-tag.sh`). 전체 흐름·결정·시험 결과는
> `infra/k8s/jenkins/README.md` "코드 변경에서 배포까지"와 `docs/labs/cicd-e2e-*.md`에 있다. 아래는 이 파일 쪽에서 알아 둘 것이다.
> - 이 파일의 `image.tag`는 이제 **CI가 쓰는 값**이다. 사람이 `scripts/argocd-source.sh push`로 `charts/` 전체를 올리면 작업 폴더의 옛 태그가 CI가 넣은 태그를 되돌린다.
>   CI가 돌기 시작한 뒤에는 `push` 대신 `tree <폴더> <메시지> <경로>... --keep charts/k3slab-workload/values-infer-argocd.yaml`을 쓴다(그 파일만 저장소 것을 그대로 둔다).
> - 이 파일만 바뀐 커밋은 Jenkins가 폴링에서 제외한다(그래서 태그 커밋이 다시 빌드를 부르지 않는다). 사람이 이 파일을 고쳐도(예: `replicas: 0`으로 GPU 놓기) 빌드는 돌지 않는다.
> - Jenkins용 Gitea 계정은 `scripts/argocd-source.sh ci-init`이 만든다(관리자가 아닌 제한된 계정 `k3slab-ci`, 이 저장소 write 협력자, 토큰 범위 `write:repository`).

- **파일**: `charts/k3slab-workload/values-infer-argocd.yaml`
- **키**: `image.tag` (파일 안에서 `image:` 아래 `  tag: …` 한 줄. 이 줄이 파일에서 `tag:`로 시작하는 유일한 줄이다)
- 저장소 `registry.k3slab.local:5000/infer-worker`는 그대로 두고 **태그만** 바꾼다. 태그는 덮어쓰지 않는다(빌드마다 새 태그).
- 태그를 바꾼 커밋이 Git의 `main`에 들어가면 Argo CD가 30~90초 안에 새 리비전을 배포한다(확인 주기 30초 + 렌더링).
- Git에 넣는 명령(지금은 연구실 Git 서버, GitHub로 바꾸면 그 저장소에 같은 커밋을 push):
  ```bash
  scripts/argocd-source.sh edit charts/k3slab-workload/values-infer-argocd.yaml \
    's|^  tag: .*|  tag: v0.3|' "infer-worker v0.3"
  ```
  성공하면 새 커밋 번호를 출력한다. 바뀐 것이 없으면(같은 태그) 실패한다.
- 이 파일을 바꿔도 `scripts/job.sh`, `infer-bench.sh`, `infer-gpu-bench.sh`, `job-db-test.sh`, `train-resume-test.sh`는 영향이 없다.
  그 스크립트들은 `values-infer.yaml`·`values-train.yaml`과 `--set`만 쓰고, 이 파일을 읽지 않는다.
- 모델을 바꿀 때는 같은 파일의 `infer.modelJobId`와 `model.version`을 함께 바꾼다.

## 8. 차트 호환성 확인 (helm template 비교)

차트 템플릿(`templates/*`, `_helpers.tpl`, `Chart.yaml`, `values.yaml`, `values-infer.yaml`, `values-train.yaml`)은 **바꾸지 않았다.**
새 파일은 `values-infer-argocd.yaml` 하나뿐이다. 그래도 기존 사용처가 쓰는 helm 인자로 변경 전후 `helm template`(Helm 4.3.1)을 비교했다.

| 사용처 | 비교한 호출 | 결과 |
|---|---|---|
| `job.sh submit train` | 기본값, 큰 모델·`npz` 데이터·epoch-sleep 3 (2가지) | 변경 전후 출력 동일 |
| `job.sh submit infer` | GPU(`gpu=1`, `auto`), CPU(`gpu=0`, `cpu`) (2가지) | 동일 |
| `infer-bench.sh` | `queueSize=20 maxBatch=8 threads=2 workMs=20 timeoutMs=10000` | 동일 |
| `infer-gpu-bench.sh` | `cuda`+큰 모델, `cpu`+작은 모델 (2가지) | 동일 |
| `train-resume-test.sh` | `image.tag=v0.4 epochs=6 epochSleep=3` | 동일 |
| `job-db-test.sh` | `job.sh`를 거치므로 위 두 호출과 같다 | — |

8가지 모두 바이트 단위로 같다. Argo CD가 쓰는 렌더링(`helm template infer … -f values-infer.yaml -f values-infer-argocd.yaml`)은
Service와 Deployment 두 객체만 만든다(프로젝트 허용 목록과 같다). Argo CD 3.6.2에 들어 있는 Helm은 4.3.2라서 호스트의 4.3.1과 같은 계열이다.

## 9. 알려진 한계와 아직 확인하지 못한 것

- 시험은 한 번만 돌렸다(PASS 23). 시간은 모두 한 번 잰 값이고, 메모리는 최대값이 아니다. DNS 수정 뒤의 sync·새 리비전 시간은 CICD_연결 시험에서 다시 쟀다(6-1절 아래).
- `argocd app rollback`은 서버 파드 안에서 `argocd` CLI(`login --plaintext`, 설정 파일은 `/tmp`)로 실행한다. 동작을 확인했다.
- ApplicationSet 컨트롤러는 replicas 0이 아니라 kustomize 삭제 패치로 **아예 뺐다**(dex, notifications와 함께). 설치 파일의 객체가 60개에서 39개(네임스페이스 1개 포함)로, 파드가 7개에서 4개로 줄었다.
  빠진 구성요소의 메모리는 직접 띄워 보지 않아 측정하지 않았다. ApplicationSet CRD 3개 중 하나는 남아 있지만 컨트롤러가 없어서 ApplicationSet은 동작하지 않는다.
- `kubectl apply` 때 Application의 파이널라이저 이름에 "도메인 이름 형식 권장" 경고가 나온다. Argo CD 공식 이름이라 그대로 두었다.
- `argocd app rollback`은 자동 동기화가 켜져 있으면 거부된다. 시험은 자동 동기화를 잠시 끄고 롤백한 뒤, Git revert로 Git과 클러스터를 다시 맞추고 자동 동기화를 켠다.
  운영에서는 Git revert 한 번이 롤백이다(이력이 Git에 남는다).
- 확인 주기가 폴링 30초라서 커밋이 반영되기까지 최대 약 1분 걸린다. 웹훅을 쓰면 줄일 수 있지만 지금은 쓰지 않는다.
- Gitea 데이터는 worker-cpu-2 디스크(local-path)에 있다. VM을 다시 만들면 저장소 이력은 사라지고 `argocd-source.sh push`로 작업 폴더에서 다시 채운다.
- Argo CD 관리자 계정(`admin`)을 그대로 쓴다(SSO 없음). 클러스터 밖으로는 열지 않는다(port-forward만).

## 10. 버전 올릴 때

1. 새 `install.yaml`을 `https://raw.githubusercontent.com/argoproj/argo-cd/<버전>/manifests/install.yaml`에서 받아 `install.yaml`로 바꾼다.
2. `cd infra/k8s/argocd && sha256sum install.yaml > install.yaml.sha256`
3. `kubectl kustomize infra/k8s/argocd`가 에러 없이 나오는지 본다(`patches/remove-unused.yaml`의 이름이 새 버전에도 있어야 한다).
4. `scripts/argocd-deploy.sh up`으로 적용하고 `scripts/argocd-test.sh`로 다시 확인한다.
