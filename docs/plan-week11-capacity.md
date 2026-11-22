# 11주차 자원 예산: Jenkins · Argo CD · Prometheus/Grafana

2026-11-22 15:14에 클러스터를 다시 띄우고 같은 시각에 잰 값으로 정했다.
연구제안서 일정으로 Jenkins(10–12주), Argo CD(11–13주), Prometheus·Grafana(12–14주)가 차례로 들어온다.
각 설치 작업이 같은 기준으로 배포하게 하려고, 노드마다 얼마나 쓸 수 있는지와 컴포넌트마다 얼마를 줄지 정한다.

- 측정은 `scripts/capacity-report.sh`(읽기 전용)로 했고, 값은 `kubectl describe node`와 같은 것을 확인했다.
- 노드 4대는 모두 한 대의 물리 PC 위에 있다(gpu-host가 그 PC 자신이다).
- 4절의 예산은 각 세션이 보낸 값을 그대로 쓰고, 실측으로 들어가는지만 판정했다. 배포 뒤 `kubectl top`으로 다시 맞춘다.
- **총괄 결정 (2026-11-22):** B안(아래 권하는 배치)으로 확정했다. VM은 증설하지 않는다. 5절의 증설안은 필요해지면 쓸 대안으로만 남긴다. 시험용 릴리스 13개는 지금 지우지 않는다(6절).

## 1. 결론 (먼저)

**VM 메모리를 늘리지 않아도 들어간다. 단, 모니터링의 Prometheus 묶음을 worker-cpu-1에 둔다.**

| 노드 (VM 메모리) | 두는 것 | 메모리 requests 합계 | 메모리 limits 합계 | 판정 |
|---|---|---|---|---|
| worker-cpu-1 (6 GB) | registry, MySQL(지금), **Jenkins 컨트롤러, Prometheus·Grafana·kube-state-metrics**, node-exporter | 2,016 MiB (allocatable의 36%) | 약 3,650 MiB (안전 한도 4,840 MiB의 75%) | 들어간다 |
| worker-cpu-2 (3 GB) | **Argo CD + Gitea**, node-exporter | 656 MiB (24%) | 1,728 MiB (안전 한도 1,860 MiB의 93%) | 들어간다. 단 여유가 132 MiB뿐이다 |
| k3s-server (3 GB) | 제어 평면(지금), node-exporter | 172 MiB (6%) | 234 MiB | 들어간다. 새로 올리는 것은 node-exporter뿐이다 |
| gpu-host (물리 PC) | **Jenkins 에이전트(동시 1개)**, dcgm-exporter, node-exporter, 학습·추론·Kaniko(필요할 때) | 최악 약 5.3 GiB | — | 들어간다. 요청 합계 8 GiB 안으로 둔다 |

- 요청대로 Argo CD(+Gitea)와 모니터링을 모두 worker-cpu-2에 두면 **안 들어간다**. 메모리 limits 합계가 3,008 MiB로 안전 한도(약 1,860 MiB)의 162%다. requests는 1,296 MiB(48%)라 스케줄은 되지만, 메모리가 한꺼번에 차면 OOM으로 파드가 죽는다. 4.3절과 4.5절에 계산이 있다.
- 그래서 모니터링(Prometheus·Grafana·kube-state-metrics, 요청 170m/640Mi, limits 1280Mi, PVC 3Gi)을 worker-cpu-1로 옮긴다. worker-cpu-1은 role=platform 노드이고 지금 메모리를 16%만 쓴다.
- 요청대로 두려면 worker-cpu-2를 늘려야 한다(5절). 필요해지면 쓸 대안이고 적용하지 않았다.
- 디스크도 들어간다. worker-cpu-1 디스크 여유는 30 GB이고, 계획한 증가분은 최악 약 16 GB다(4.7절).
- **주의할 것 세 가지:**
  - worker-cpu-2는 limits 합계가 안전 한도의 93%로 빠듯하다(여유 132 MiB). Argo CD나 Gitea의 limits를 올리면 한도를 넘는다. 올려야 하면 5절의 증설을 먼저 검토한다(4.5절).
  - gpu-host의 node-exporter는 기본값(hostNetwork)이면 ufw에 막혀 Prometheus가 못 읽을 가능성이 높다(4.8절).
  - Jenkins 컨트롤러 limit 1Gi는 빠듯하다. OOMKilled가 나면 1280Mi까지 올려도 노드 합계는 안전하다(4.8절).
- 시험용 릴리스 13개는 지금 CPU·메모리를 잡지 않는다. 총괄 결정으로 **지금은 지우지 않고**, '정리 후보, 사용자 결정 대기'로 둔다(6절).

## 2. 기동 기록

### 2.1 막힘과 해결

| 막힘 | 원인 | 해결 |
|---|---|---|
| VMware 커널 모듈 없음 | 커널이 7.0.0-43-generic으로 올라간 뒤 `vmmon`·`vmnet`이 빌드되지 않았다 | 사용자가 `sudo vmware-modconfig --console --install-all`을 실행했다. 이후 preflight 모듈 항목이 모두 PASS |
| Rocky ISO 확인 실패 (2/9단계) | Rocky 9.9가 pub 경로에 올라오면서 9.8이 pub의 CHECKSUM 목록에서 빠졌다 | `scripts/fetch-rocky-iso.sh`의 `CHECKSUM_BASE_URL`을 vault 경로로 바꿨다(총괄 승인). 서명 키 지문(`21CB256A…D275D`) 일치, `gpgv` Good signature, `PIN_ROCKY_ISO_SHA256` 일치를 확인한 뒤 적용했다 |
| preflight FAIL 1건: `Terraform state exists but output 'nodes' cannot be read` | Orca 작업 공간(git worktree)에는 gitignore 대상인 `infra/terraform/.terraform/`이 없어 `terraform init`이 필요했다. `entry.sh`는 init이 5단계, preflight가 3단계라 init 전에 멈춘다 | 총괄 승인으로 `scripts/tf.sh init`을 한 번 실행했다(`entry.sh` 5단계와 같은 명령, state 변경 없음). 이후 preflight 0 FAIL, 0 WARN |

### 2.2 `scripts/entry.sh` 결과

- 9단계 모두 통과, 총 1분 51초. Ansible `changed=0`.

| 단계 | 시간 |
|---|---|
| 1/9 vmrest 시작 | 0s |
| 2/9 Rocky ISO 확인 | 13s |
| 3/9 사전 점검 | 19s |
| 4/9 기준 이미지 | 0s |
| 5/9 Terraform 준비 | 0s |
| 6/9 VM 상태 + UI 목록 | 2s |
| 7/9 IP 목록 생성 | 46s |
| 8/9 SSH 확인 | 2s |
| 9/9 OS + K3s | 29s |

### 2.3 노드 4개 Ready

```console
$ kubectl get nodes -L k3slab.io/role
NAME           STATUS   ROLES           AGE   VERSION        ROLE
gpu-host       Ready    <none>          46d   v1.36.4+k3s1   gpu
k3s-server     Ready    control-plane   64d   v1.36.4+k3s1   
worker-cpu-1   Ready    <none>          64d   v1.36.4+k3s1   platform
worker-cpu-2   Ready    <none>          64d   v1.36.4+k3s1   app
```

- `k3slab-system`의 registry, mysql가 Running이다. PVC `registry-data`(20Gi), `mysql-data`(5Gi)가 Bound다.
- `kube-system`의 nvidia-device-plugin(gpu-host), metrics-server, traefik, coredns, local-path-provisioner가 Running이다.
- RESTARTS 값(1~20)은 지난 재부팅들의 누적이고 기동 뒤에는 모두 Running이다.

## 3. 현재 측정값 (2026-11-22 15:17)

### 3.1 물리 PC

| 항목 | 값 | 근거 |
|---|---|---|
| CPU 코어 | 16 | `nproc` |
| 메모리 전체 | 31,996 MiB | `free -m` |
| 메모리 사용 (VM 3대 포함) | 10,599 MiB | `free -m` |
| 메모리 가용 | 21,396 MiB | `free -m`의 available |
| VM 3대에 나눠 준 메모리 | 12,288 MiB (3,072 + 6,144 + 3,072) | `infra/terraform/variables.tf` |
| VM 프로세스가 지금 쓰는 메모리 | 약 6,000 MiB (2,466 + 2,065 + 1,450) | `ps`의 `vmware-vmx` RSS |
| 디스크 가용 (`/`) | 198 GB | preflight |
| GPU | RTX 3090, 24,576 MiB 중 1,056 MiB 사용 | `nvidia-smi` |

- VM 메모리는 쓰는 만큼만 물리 메모리를 잡는다. 지금은 배정 12,288 MiB 중 약 6,000 MiB만 잡혀 있다.
  VM이 배정량을 모두 쓰면 가용은 약 15 GB로 줄어든다. 그 안에서 데스크톱 등 호스트 사용분이 7 GB까지 늘 수 있다는 점(기동 전 사용량 7,055 MiB)을 넣으면 최악 약 12.5 GB다.
- gpu-host 노드의 allocatable은 물리 PC 전체(31,997 MiB)다. 스케줄러는 VM이 잡은 메모리를 모른다. 그래서 gpu-host 파드의 requests 합계는 우리가 8 GiB 안으로 지켜야 한다(4.6절).
- `kubectl top nodes`의 gpu-host 15,264 MiB는 물리 PC 전체 사용량이다(VM 포함). 쿠버네티스 파드가 쓰는 값이 아니다.

### 3.2 노드별 allocatable 대비 requests·limits

| 노드 | 역할 | 파드 | CPU allocatable | CPU requests | 메모리 allocatable | 메모리 requests | 메모리 limits | limit 없는 컨테이너 |
|---|---|---|---|---|---|---|---|---|
| gpu-host | gpu | 2 | 16,000m | 0m | 31,997 MiB | 0 | 0 | 3 |
| k3s-server | control-plane | 5 | 2,000m | 200m | 2,712 MiB | 140 MiB (5.2%) | 170 MiB | 5 |
| worker-cpu-1 | platform | 3 | 2,000m | 150m | 5,665 MiB | 576 MiB (10.2%) | 1,024 MiB | 3 |
| worker-cpu-2 | app | 4 | 2,000m | 30m | 2,712 MiB | 48 MiB (1.8%) | 0 | 5 |

- 이 표는 `kubectl describe node`의 "Allocated resources"와 같은 값이다(예: worker-cpu-1 CPU 150m, 메모리 576Mi/1Gi).
- 노드에 `kube-reserved`·`system-reserved` 설정이 없어서 allocatable이 곧 VM 메모리와 같다(worker-cpu-1 5,800,940Ki 둘 다). 운영체제와 k3s가 쓰는 메모리를 스케줄러가 따로 빼 주지 않는다.
- VM에는 swap이 없다(`swapon --show` 결과 없음). 메모리가 모자라면 바로 OOM이나 쫓겨남이 일어난다.

### 3.3 실제 사용량 (`kubectl top`, metrics-server 1/1 ready)

| 노드 | CPU | 메모리 | 게스트 `free -m` (전체 / 사용 / 가용) |
|---|---|---|---|
| k3s-server | 48m (2%) | 1,449 MiB (53%) | 2,711 / 1,240 / 1,471 |
| worker-cpu-1 | 32m (1%) | 939 MiB (16%) | 5,664 / 886 / 4,778 |
| worker-cpu-2 | 18m (0%) | 589 MiB (21%) | 2,711 / 579 / 2,132 |

메모리를 많이 쓰는 파드: mysql 292 MiB, traefik 178 MiB, metrics-server 91 MiB, coredns 89 MiB, registry 68 MiB, local-path-provisioner 60 MiB, nvidia-device-plugin 20 MiB. 나머지는 16 MiB 이하다.

**운영체제 기준선**(게스트 사용량에서 파드 사용량을 뺀 값, 추정): k3s-server 약 820 MiB, worker-cpu-1 약 520 MiB, worker-cpu-2 약 550 MiB. 파드를 올리기 전에도 이만큼은 노드가 쓴다.

### 3.4 디스크

| 항목 | 값 | 근거 |
|---|---|---|
| VM 루트 디스크 (3대 모두 같은 39 GB) | k3s-server 사용 5.8 GB / 가용 33 GB, worker-cpu-1 사용 8.9 GB / **가용 30 GB**, worker-cpu-2 사용 4.4 GB / 가용 34 GB | 각 VM의 `df -h /` |
| 레지스트리 데이터 | **3.1 GB** 사용 (이미지 2개: infer-worker, train-worker) | registry 파드의 `du -sh /var/lib/registry` |
| 레지스트리 PVC 남은 공간 | 이름상 20Gi 중 16.9Gi. 실제 한계는 worker-cpu-1 디스크 여유 30 GB다 | 아래 설명 |
| MySQL 데이터 | 209 MB | mysql 파드의 `du -sh /var/lib/mysql` |

- local-path PVC는 크기를 강제하지 않는다. `registry-data 20Gi`는 이름일 뿐이고, 실제로는 worker-cpu-1 디스크(여유 30 GB)를 레지스트리, MySQL, 이미지 캐시가 함께 쓴다.
- registry 파드와 mysql 파드가 보는 파일시스템은 둘 다 worker-cpu-1의 루트 디스크다(`/dev/mapper/rl_k3slab--golden-root`, 39 GB).

### 3.5 이미 있는 시험용 릴리스

`helm list -A`에 default 네임스페이스의 시험용 릴리스 13개가 있다. 파드는 모두 Completed 또는 Error라서 지금 CPU·메모리·GPU를 잡지 않는다. 자세한 표는 6절이다.

## 4. 컴포넌트별 예산안

### 4.1 차트와 버전 (모두 고정, `latest` 금지)

Helm 차트는 2026-11-21에 공개 Helm 저장소에서 확인한 최신 안정 버전이다. 설치 작업이 시작할 때 한 번 더 확인하고, 바꾸면 이 표도 고친다.
Argo CD는 Helm 차트가 아니라 공식 `install.yaml`을 kustomize로 패치해서 배포한다(CICD_ArgoCD의 `infra/k8s/argocd/`).

| 구성 요소 | 차트 (저장소) | 차트 버전 | 앱 버전 / 이미지 |
|---|---|---|---|
| Jenkins | `jenkins` (https://charts.jenkins.io) | 5.13.3 | `jenkins/jenkins:2.580.2-jdk25`, 에이전트 `jenkins/inbound-agent:3395.v6e5377b_0fb_3c-5-jdk25` |
| Argo CD | Helm 차트 아님. 공식 `install.yaml` + kustomize 패치 | v3.6.2 | `quay.io/argoproj/argocd:v3.6.2`, redis `public.ecr.aws/docker/library/redis:8.10.1-alpine` (CICD_ArgoCD가 고정) |
| Gitea (Argo CD의 내부 Git 서버) | 매니페스트 `gitea.yaml` | — | `docker.io/gitea/gitea:28.3.0-rootless` (CICD_ArgoCD가 고정) |
| Prometheus | `prometheus` (https://prometheus-community.github.io/helm-charts) | 29.48.0 | `quay.io/prometheus/prometheus:v3.16.0`, config-reloader `v0.95.2` |
| node-exporter | `prometheus` 차트에 포함 (`prometheus-node-exporter`) | 5.2.0 | `quay.io/prometheus/node-exporter:v1.13.1` |
| kube-state-metrics | `prometheus` 차트에 포함 | 9.0.1 | `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0` |
| Grafana | `grafana` (https://grafana.github.io/helm-charts) | 10.5.15 | `docker.io/grafana/grafana:12.3.1` |
| GPU 메트릭 | `dcgm-exporter` (https://nvidia.github.io/dcgm-exporter/helm-charts) | 4.9.0 | `nvcr.io/nvidia/k8s/dcgm-exporter:4.9.0` |

### 4.2 차트 기본값 (그대로 쓰면 안 되는 이유)

`helm show values <차트> --version <버전>`으로 읽은 값이다.

| 구성 요소 | 기본 requests / limits | 문제 |
|---|---|---|
| Jenkins 컨트롤러 | 50m / 256Mi, limits 2000m / **4096Mi** | limit이 worker-cpu-1 메모리(5.6 GiB)의 72%다 |
| Jenkins 에이전트 파드 | 512m / 512Mi (requests = limits) | 빌드 컨테이너가 따로 필요하다 |
| Argo CD (공식 `install.yaml` v3.6.2) | 없음 (컨테이너 10개 모두 `resources` 비어 있음, BestEffort) | 메모리가 모자라면 가장 먼저 쫓겨난다. 그래서 kustomize 패치로 값을 준다 |
| Prometheus, Grafana, kube-state-metrics, node-exporter | 없음 (BestEffort) | 위와 같다 |
| dcgm-exporter | 100m / 128Mi, limits 200m / 512Mi | 그대로 써도 된다 |

### 4.3 판정 규칙

실측에서 얻은 두 가지로 판정한다. 노드에 시스템 예약이 없고 swap이 없기 때문이다.

- **규칙 A (스케줄):** 노드의 메모리 requests 합계가 allocatable의 70% 이하다.
- **규칙 B (OOM 방지):** 메모리 limits 합계가 `allocatable − 운영체제 기준선(3.3절) − 여유 300 MiB` 이하다. limits는 보통 동시에 차지 않지만, 한꺼번에 차도 노드가 죽지 않게 하는 선이다.

| 노드 | allocatable | 기준선 | 규칙 A 한도 (70%) | 규칙 B 한도 |
|---|---|---|---|---|
| worker-cpu-1 | 5,665 MiB | 약 520 | 3,965 MiB | 약 4,840 MiB |
| worker-cpu-2 | 2,712 MiB | 약 550 | 1,898 MiB | 약 1,860 MiB |
| k3s-server | 2,712 MiB | 약 820 | 1,898 MiB | 약 1,590 MiB |

### 4.4 요청받은 예산 (세 세션이 보낸 값)

| 구성 요소 | 요청 세션 | 네임스페이스 | 노드 | 개수 | CPU requests | 메모리 requests | 메모리 limits | PVC |
|---|---|---|---|---|---|---|---|---|
| Jenkins 컨트롤러 | CICD_Jenkins | jenkins | worker-cpu-1 | 1 | 250m (limit 1 CPU) | 768 MiB | 1,024 MiB | 5 Gi |
| Jenkins 에이전트 (동시 1개) | CICD_Jenkins | jenkins | gpu-host | 1 | 1,050m 또는 1,100m | 1,152 MiB 또는 2,240 MiB | 미정 | 없음 (emptyDir) |
| 레지스트리 이미지 추가 (2개) | CICD_Jenkins | k3slab-system | worker-cpu-1 | — | — | — | — | 기존 `registry-data`에 약 6–7 GB 추가 |
| Argo CD (dex·notifications·ApplicationSet 없이, 패치 합계) | CICD_ArgoCD | argocd | **worker-cpu-2** | 4개 파드 | 225m | 480 MiB | 1,408 MiB | 없음 |
| Gitea (Argo CD의 내부 Git 서버) | CICD_ArgoCD | k3slab-system | **worker-cpu-2** | 1 | 50m | 96 MiB | 256 MiB | 1 Gi |
| Prometheus + Grafana + kube-state-metrics | 관측_모니터링 | monitoring | **worker-cpu-2 (요청)** | 각 1 | 170m | 640 MiB | 1,280 MiB | 3 Gi |
| node-exporter | 관측_모니터링 | monitoring | 4노드 전부 (DaemonSet) | 4 | 노드당 10m | 노드당 32 MiB | 노드당 64 MiB | 없음 |
| dcgm-exporter | 관측_모니터링 | monitoring | gpu-host | 1 | 25m | 128 MiB | 512 MiB | 없음 |

### 4.5 판정과 권하는 배치

**요청대로(Argo CD와 모니터링 모두 worker-cpu-2): 안 들어간다.**

| 항목 | 값 | 한도 | 판정 |
|---|---|---|---|
| worker-cpu-2 메모리 requests | 기존 48 + Argo CD 480 + Gitea 96 + 모니터링 640 + node-exporter 32 = 1,296 MiB (48%) | 규칙 A 1,898 | 통과 |
| worker-cpu-2 메모리 limits | Argo CD 1,408 + Gitea 256 + 모니터링 1,280 + node-exporter 64 = 3,008 MiB | 규칙 B 약 1,860 | **실패 (162%, allocatable 2,712보다도 큼)** |

**권하는 배치(모니터링 묶음을 worker-cpu-1로): 들어간다. VM 증설 필요 없음.**

| 노드 | 메모리 requests 합계 | 규칙 A | 메모리 limits 합계 | 규칙 B | CPU requests 합계 |
|---|---|---|---|---|---|
| worker-cpu-1 | 기존 576 + Jenkins 768 + 모니터링 640 + node-exporter 32 = **2,016 MiB** (36%) | 통과 (한도 3,965) | 기존 mysql 1,024 + registry 256(지금 limit이 없어 가정) + Jenkins 1,024 + 모니터링 1,280 + node-exporter 64 = **약 3,650 MiB** | 통과 (한도 4,840, 75%) | 150 + 250 + 170 + 10 = 580m (29%) |
| worker-cpu-2 | 기존 48 + Argo CD 480 + Gitea 96 + node-exporter 32 = **656 MiB** (24%) | 통과 | Argo CD 1,408 + Gitea 256 + node-exporter 64 = **1,728 MiB** | 통과하지만 빠듯함 (한도 1,860, **93%**, 여유 132 MiB) | 30 + 225 + 50 + 10 = 315m (16%) |
| k3s-server | 기존 140 + node-exporter 32 = **172 MiB** (6%) | 통과 | 170 + 64 = **234 MiB** | 통과 (한도 1,590) | 200 + 10 = 210m |

- 노드별 예상 실제 사용량(기준선 + 기존 파드 + 새 컴포넌트의 일반적인 사용량, 추정): worker-cpu-1 약 2.4 GiB(5.5 GiB 중), worker-cpu-2 약 1.2 GiB(2.6 GiB 중). 둘 다 절반 안팎이다. 이 추정은 배포 뒤 `kubectl top`으로 확인한다.
- **worker-cpu-2는 여유가 많지 않다(규칙 B 93%, 132 MiB).** 총괄이 정한 값(Argo CD 패치 합계 requests 480Mi / limits 1,408Mi, Gitea 96Mi / 256Mi, 합쳐 576Mi / 1,664Mi)으로 계산했다. node-exporter 64 MiB를 빼면 1,664 MiB로 한도의 89%다. 이 노드에 `k3slab-lab`의 echo-api 3개(10-30 실습, limit 없음, 실사용 약 24 MiB)도 있다. Argo CD·Gitea의 limits를 올려야 하면 한도를 넘으므로, 그때는 5절의 증설을 먼저 검토한다.
- 참고(값이 조금 다르다): 이 작업 공간에서 CICD_ArgoCD의 `infra/k8s/argocd`를 `kubectl kustomize`로 렌더링해 합산하면 Argo CD 4개 파드는 225m / 448Mi / 1,280Mi, Gitea는 50m / 96Mi / 256Mi, 합계 275m / 544Mi / 1,536Mi였다(그 README의 표와 같다). 위 480/1,408은 총괄이 준 값이라 이쪽이 32 MiB / 128 MiB 더 크다. 둘 다 들어가므로(limits 합계 1,728 MiB = 93% 또는 1,600 MiB = 86%) 큰 값으로 판정했다. 어느 쪽이 맞는지는 CICD_ArgoCD가 확정한다.
- Argo CD는 Helm 차트가 아니라 공식 `install.yaml`(v3.6.2)을 kustomize로 패치해서 쓴다. dex·notifications·ApplicationSet은 `patches/remove-unused.yaml`로 뺀다. 이 문서는 ApplicationSet을 끄는 방법을 정하지 않고, CICD_ArgoCD가 `install.yaml` 기준으로 정한다.

### 4.6 gpu-host (물리 PC)

gpu-host는 VM과 달리 스케줄러가 보는 allocatable(31,997 MiB)이 실제 여유보다 크다. VM이 잡은 메모리와 데스크톱 사용분을 모르기 때문이다. 그래서 **gpu-host 파드의 메모리 requests 합계를 8 GiB 안으로** 둔다(최악 가용 12.5 GB에서 데스크톱·페이지 캐시용 4 GB 이상을 남기는 값이고, 우리가 정한 기준이다).

| 파드 | CPU requests | 메모리 requests | 언제 |
|---|---|---|---|
| node-exporter | 10m | 32 MiB | 항상 |
| dcgm-exporter | 25m | 128 MiB (limit 512) | 항상 |
| Jenkins 에이전트 | 1,100m | 2,240 MiB | 빌드할 때, 동시 1개 |
| 학습 Job (기존 `values-train.yaml`) | 500m | 1,024 MiB | GPU 1장 |
| Kaniko 이미지 빌드 (기존 `scripts/image-build.sh`) | 1,000m | 2,048 MiB | 필요할 때 |
| **최악 합계** | **2,635m** | **5,472 MiB (약 5.3 GiB)** | 8 GiB 한도의 67% |

- GPU는 1장이다. 학습과 추론은 한 번에 하나만 올라간다. **dcgm-exporter는 `nvidia.com/gpu`를 요청하지 않는다**(요청하면 학습이 못 올라간다). 대신 `runtimeClassName: nvidia`를 줘서 GPU 메트릭을 읽는다. 차트 기본값은 `runtimeClassName: ""`이다.
- 동시에 두 Kaniko 빌드나 에이전트 2개를 올리면 한도를 넘는다. Jenkins 에이전트 동시 실행 수는 1로 둔다.

### 4.7 PVC와 디스크

| PVC / 데이터 | 노드 | 크기(요청) | 예상 실제 사용 |
|---|---|---|---|
| `registry-data` (기존) | worker-cpu-1 | 20 Gi | 3.1 GB → Jenkins 이미지 2개 추가로 약 10 GB |
| `mysql-data` (기존) | worker-cpu-1 | 5 Gi | 0.2 GB |
| Jenkins 컨트롤러 | worker-cpu-1 | 5 Gi | 1–2 GB |
| 모니터링 (Prometheus + Grafana) | worker-cpu-1 | 3 Gi | 최대 3 GB |
| Gitea | worker-cpu-2 | 1 Gi | 1 GB 이하 |

- **worker-cpu-1 디스크 (여유 30 GB):** 최악 증가분은 레지스트리 +6.5, Jenkins 5, 모니터링 3, 새 이미지 캐시 약 1.5(추정)로 합쳐 약 16 GB. 남는 여유는 약 14 GB(디스크 전체의 36%)다.
- **worker-cpu-2 디스크 (여유 34 GB):** Argo CD 이미지와 Gitea를 합쳐 2 GB 안쪽이라 문제없다.
- 레지스트리가 15 GB를 넘으면 정리를 검토한다. `REGISTRY_STORAGE_DELETE_ENABLED`가 켜져 있어서 태그를 지울 수 있다(지우는 것은 총괄 확인 뒤).

### 4.8 배포할 때 지킬 점 (실제 차트 값을 읽고 찾은 것)

1. **Jenkins JVM 힙.** 컨트롤러 limit이 1 GiB이면 힙은 `-Xms256m -Xmx640m` 정도로 묶는다. 안 묶으면 컨테이너 메모리의 25%(256 MiB)만 힙으로 잡히거나, 반대로 힙이 limit을 넘어 OOMKilled가 난다. OOMKilled가 나면 limit을 1,280 MiB까지 올려도 worker-cpu-1은 규칙 B를 통과한다(limits 합계 약 3,900 MiB).
2. **gpu-host의 node-exporter.** 차트 기본값은 `hostNetwork: true`, `hostPID: true`다. 이 PC의 ufw는 INPUT 기본 DROP이고 vmnet8에서는 10250/tcp와 8472/udp만 허용한다(`infra/ansible/roles/gpu_host_prep/tasks/main.yml`). VM의 Prometheus가 `172.16.133.1:9100`을 읽으면 막힐 가능성이 높다(배포해 보지는 않았다). 물리 PC 설정(ufw)을 바꾸지 않고, gpu-host의 node-exporter를 `hostNetwork: false`로 두면 파드 IP(10.42.x.x)로 읽을 수 있다. 대신 호스트 네트워크 카드 지표는 빠진다.
3. **dcgm-exporter.** 위처럼 `runtimeClassName: nvidia`, `nodeSelector: k3slab.io/role: gpu`, toleration `nvidia.com/gpu`가 필요하고 GPU 자원은 요청하지 않는다. 호스트의 NVIDIA 드라이버는 580.178.04, kubelet 경로는 기본값(`/var/lib/kubelet/pod-resources`)이다. 이미지(4.9.0)가 드라이버 580과 맞는지는 배포 때 확인한다.
4. **이미지는 한 번에 하나씩.** 새 이미지를 받으면 노드 CPU·디스크가 잠깐 오른다. 같은 노드에 Jenkins, Prometheus, Grafana를 동시에 배포하지 않는다(일정이 이미 주 단위로 나뉘어 있다).
5. **Prometheus 보관.** PVC 3 Gi에 맞춰 `retention: 7d`, `retentionSize: 2GB`로 둔다(차트 기본은 15d).
6. **비밀값.** Jenkins·Grafana·Gitea 관리자 비밀번호는 `~/.config/k3s-vmware-lab/secrets/<이름>.env`(권한 600)와 클러스터 Secret에만 둔다(`scripts/mysql-deploy.sh` 방식).

## 5. VM 메모리 증설안 (필요해지면 쓸 대안, 적용하지 않음)

총괄이 B안(4.5절)으로 확정했으므로 **지금은 증설하지 않는다.** 아래는 다음 경우에 쓸 대안이다.

- Argo CD·Gitea의 limits를 올려야 해서 worker-cpu-2가 한도(약 1,860 MiB)를 넘을 때 → 4096으로 충분하다(한도 약 2,890 MiB).
- 모니터링을 worker-cpu-2에 두어야 할 때(요청대로의 배치) → 5120이 필요하다.

| 항목 | 내용 |
|---|---|
| 대상 VM | worker-cpu-2 |
| 값 | `infra/terraform/variables.tf`의 `nodes["worker-cpu-2"].memory_mb`: 3072 → **4096**(Argo CD·Gitea만 늘 때) 또는 **5120**(모니터링도 올릴 때) |
| 이유 | 4096이면 allocatable이 약 3,740 MiB, 규칙 B 한도가 약 2,890 MiB다. 지금 계획의 limits 1,728 MiB는 60%이지만, 모니터링까지 올린 3,008 MiB는 한도를 넘는다. 5120이면 allocatable 약 4,760 MiB, 한도 약 3,910 MiB라 3,008 MiB가 77%다 |
| 물리 PC 영향 | 4096이면 VM 배정 합계 12,288 → 13,312 MiB(최악 가용 약 12.5 → 11.5 GB). 5120이면 14,336 MiB(최악 가용 약 10.5 GB)이고 gpu-host 파드 한도 8 GiB를 6 GiB로 낮추는 것이 안전하다 |

`scripts/tf.sh plan`으로 값을 바꿔 봤다(`-var`로만 시뮬레이션, 파일·상태 변경 없음). worker-cpu-2를 4096으로 한 계획은 `1 to change`, `memory 3072 -> 4096`, **`update in-place`** 이고 교체·삭제는 없다. 5120도 같은 종류의 변경이다(5120은 plan을 따로 돌리지 않았다).

재기동 절차(제안, 적용 전에 총괄 승인 필요):

1. `kubectl cordon worker-cpu-2`, `kubectl drain worker-cpu-2 --ignore-daemonsets --delete-emptydir-data`. worker-cpu-2에는 PVC를 쓰는 파드가 없어서 다른 노드로 옮길 수 있다. worker-cpu-1이면 registry·mysql 파드가 PVC 때문에 옮겨 가지 못하고 노드가 돌아올 때까지 멈춘다.
2. `variables.tf`를 고치고 `scripts/tf.sh plan`으로 `1 to change`인지 확인한다.
3. `scripts/cluster-apply.sh`를 실행한다. `infra/terraform/main.tf`의 주석에 따르면 업데이트가 VM 전원을 강제로 끈다. 끝난 뒤 VM이 꺼져 있으면 같은 명령을 한 번 더 실행한다(2단계가 원하는 전원 상태 `on`을 적용한다). 이 동작은 직접 확인하지 않았다.
4. `kubectl get nodes`로 Ready를 확인하고 `kubectl uncordon worker-cpu-2`. 필요하면 `scripts/entry.sh`를 다시 돌려 `changed=0`을 확인한다.
5. 예상 중단 시간은 노드 하나 재부팅 시간이다(이번 기동에서 VM 상태·IP 확인이 약 50초).

## 6. default 네임스페이스의 시험용 릴리스 (정리 후보, 사용자 결정 대기)

**총괄 결정 (2026-11-22): 지금은 지우지 않는다.** 이유는 두 가지다. 이 릴리스들은 자원을 잡지 않고, 파드 로그가 이전 보고서의 근거라서 13주차 일에 필요하지 않다. 마지막에 총괄이 사용자에게 지울지 묻는다. 그래서 아래 표는 **정리 후보** 목록이고, 아무것도 지우지 않았다.

`helm list -n default`로 13개가 있다. 모두 `k3slab-workload-0.1.0` 차트의 학습 Job이다(2026-10-30과 11-07 시험에서 만든 것).

| 릴리스 | job-id | 배포 시각 (KST) | 파드 상태 | 체크포인트 폴더 (gpu-host) |
|---|---|---|---|---|
| train-bench-large | bench-large | 11-07 12:23 | Completed | **522 MB** |
| train-db-1107a-train | db-1107a-train | 11-07 12:19 | Completed | 464 KB |
| train-db-1107a-npz | db-1107a-npz | 11-07 12:20 | Completed | 64 KB |
| train-db-1107a-bad | db-1107a-bad | 11-07 12:20 | Error (의도한 실패 시험) | 8 KB |
| train-db-1107b-train | db-1107b-train | 11-07 12:21 | Completed | 464 KB |
| train-db-1107b-npz | db-1107b-npz | 11-07 12:23 | Completed | 64 KB |
| train-db-1107b-bad | db-1107b-bad | 11-07 12:23 | Error (의도한 실패 시험) | 8 KB |
| train-db-1107c-train | db-1107c-train | 11-07 12:58 | Completed | 464 KB |
| train-db-1107c-npz | db-1107c-npz | 11-07 13:00 | Completed | 64 KB |
| train-db-1107c-bad | db-1107c-bad | 11-07 12:59 | Error (의도한 실패 시험) | 8 KB |
| train-resume-11071253 | resume-11071253 | 11-07 12:57 | Completed | 464 KB |
| train-resume-demo | resume-demo | 10-30 17:17 | Completed | 464 KB |
| train-resume-demo2 | resume-demo2 | 10-30 17:16 | Completed | 464 KB |

- **지금 잡고 있는 자원: CPU 0, 메모리 0, GPU 0.** 파드가 끝났기 때문이다. 실행 중에는 각각 500m / 1Gi와 `nvidia.com/gpu: 1`을 요청했다.
- 남아 있는 것: Helm 릴리스 Secret 13개, Job 13개, 파드 13개(Completed 10, Error 3), gpu-host의 체크포인트 폴더 합계 약 525 MB(`/var/lib/k3slab/checkpoints`).
- 비슷한 이름의 `k3slab-lab` 네임스페이스(echo-api 3개, 10-30 실습)는 default가 아니라서 이번 정리 대상이 아니다.

**나중에 지운다면 생기는 일 (후보: 13개 모두 `helm uninstall -n default <릴리스>`)**

| 항목 | 영향 |
|---|---|
| 자원 | CPU·메모리 변화 없음. 목록(`kubectl get pods`, `helm list`)만 깨끗해진다 |
| 체크포인트 폴더 | `helm uninstall`은 hostPath를 지우지 않는다. **지우지 않는다.** 특히 `bench-large`(522 MB)는 `scripts/infer-gpu-bench.sh`가 읽는 큰 모델(`model.k3sm`)이고 `docs/labs/infer-gpu-bench-20261107-1246.md`의 시험 재현에 필요하다 |
| MySQL `jobs` 표 | 지워지지 않는다. 같은 job-id로 다시 `submit`하면 새로 실행하지 않고 기존 DONE/FAILED를 돌려준다 |
| 실행 로그 | 파드가 지워지면 `scripts/job.sh result`의 로그 끝부분이 사라진다. 기록은 `docs/labs/*.md`에 남아 있다 |

지금까지 아무것도 지우지 않았다. 사용자가 지우기로 정하면 위 표의 릴리스만 지우고, 체크포인트 폴더와 MySQL은 그대로 둔다.

## 7. 근거 파일과 한계

- 측정 도구: `scripts/capacity-report.sh` (이번에 새로 만든 읽기 전용 스크립트). 가짜 `kubectl`/`helm` 데이터로 표 형식을 시험했고, 실제 클러스터 출력은 `kubectl describe node`와 같았다.
- 노드 크기와 VM 메모리: `infra/terraform/variables.tf`, 변경 방식: `infra/terraform/main.tf`
- 기존 requests: `infra/k8s/registry.yaml`, `infra/k8s/mysql.yaml`, `charts/k3slab-workload/values.yaml`, `scripts/image-build.sh`(Kaniko 1 CPU / 2Gi)
- 방화벽: `infra/ansible/roles/gpu_host_prep/tasks/main.yml`, `docs/gpu-host-join-prep.md`
- 차트 기본값: `helm show values <차트> --version <버전>`, 구성: `helm template`(배포하지 않음). Argo CD는 차트가 아니라서 해당하지 않는다.
- Argo CD 값: 다른 작업 공간(읽기만 함)의 `infra/k8s/argocd/`(`kustomization.yaml`, `gitea.yaml`, `README.md`)를 `kubectl kustomize`로 렌더링해 합산했다. 공식 `install.yaml`의 컨테이너 `resources`가 모두 비어 있는 것도 확인했다.
- 한계:
  - 4.4절의 요청값은 각 세션이 보낸 추정치이고, Jenkins 에이전트 limits는 아직 없다.
  - 운영체제 기준선과 "예상 실제 사용량"은 추정이다. 배포 뒤 `kubectl top`으로 확인한다.
  - 측정은 기동 3분 뒤(15:14–15:17)의 한가한 상태다. 빌드나 학습이 도는 동안의 값은 아니다.
  - gpu-host 한도 8 GiB는 우리가 정한 기준이지 측정값이 아니다.
  - ufw에 막힌다는 판단(4.8절 2번)은 규칙을 읽고 추정한 것이고, 실제로 확인하지 않았다.
