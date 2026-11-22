# 최종 보고서 (뼈대): 연구실 GPU 서버로 만드는 모델 학습·추론 실습 플랫폼

2026학년도 2학기 개별연구 2 · 최종 보고(제안서 일정 15–16주)를 미리 준비한 뼈대다. 마지막 갱신 2026-11-21(11주차).

- **끝난 부분**(인프라~작업 DB)은 측정값과 근거 파일 링크로 채웠다. 수치는 모두 `docs/labs/`의 실행 기록이나 해당 소스 파일에서 가져왔다.
- **진행 중인 부분**(CI/CD, 모니터링, 검증 실험)은 `[진행 중]` 표시와 "채울 것" 목록만 두었다. 결과가 나오면 그 자리를 채운다.
- 제안서와 달라진 점은 [4절](#4-제안서와-달라진-점)에 표로 모았다.

## 작성 상태

| 절 | 내용 | 상태 |
|---|---|---|
| 1 | 배경과 목표 | 작성 |
| 2 | 전체 구성 | 작성 |
| 3.1 | 인프라 코드화 (Packer · Terraform · Ansible) | 작성 |
| 3.2 | K3s 클러스터와 GPU 호스트 | 작성 |
| 3.3 | 이미지 · 레지스트리 · Helm | 작성 |
| 3.4 | 학습 Job | 작성 |
| 3.5 | 추론 워커 | 작성 |
| 3.6 | 작업 상태 DB | 작성 |
| 3.7 | CI/CD (Jenkins · Argo CD) | **[진행 중]** 자리만 |
| 3.8 | 모니터링 (Prometheus · Grafana) | **[진행 중]** 자리만 |
| 4 | 제안서와 달라진 점 | 작성 (3.7·3.8 결과가 나오면 보완) |
| 5 | 검증 실험 | **[진행 중]** 항목만. 사전 시험 근거는 적어 둠 |
| 6 | 결과 | 끝난 구현의 수치만 작성. 나머지 자리만 |
| 7 | 한계 | 작성 (검증 뒤 보완) |
| 8 | 결론 | 잠정 작성. 검증 뒤 확정 |
| 부록 | 일정 대비 실제, 근거 파일 | 작성 |

## 1. 배경과 목표

### 1.1 문제 (제안서 3번)

모델을 한 번 돌리는 시간보다, 그 모델을 돌릴 환경을 매번 다시 만드는 시간이 더 길다. 제안서는 이를 세 가지로 정리했다.

- 환경이 매번 다르다. 파이썬·라이브러리·CUDA 버전이 조금씩 달라서 다음 학기에는 그대로 재현되지 않는다.
- 손으로 옮기고 손으로 돌린다. 누가 어떤 버전을 올렸는지 기록이 남지 않는다.
- 멈추면 처음부터 다시 한다. 학습이 중간에 끊기면 어디까지 진행됐는지 알 수 없다.

이 연구는 모델 성능을 올리는 대신, 모델을 반복해서 돌릴 수 있는 환경을 처음부터 끝까지 직접 만들어 보는 데 초점을 둔다.

### 1.2 목표와 범위 (제안서 4번)

| 목표 | 이 보고서의 해당 절 |
|---|---|
| ① 직접 구축한다: 데스크톱 한 대 위에 가상머신 3대를 띄우고, 호스트까지 K3s 노드로 묶어 GPU 노드와 CPU 노드를 나눈다 | 3.1, 3.2 |
| ② 자동으로 반영한다: 코드를 고치면 빌드·테스트·이미지 생성·배포까지 사람이 명령어를 치지 않아도 반영된다 | 3.3, 3.7 |
| ③ 눈으로 확인한다: 정상 동작과 일부러 만든 중단 상황을 재현하고, 대시보드와 DB 기록으로 결과를 남긴다 | 3.6, 3.8, 5 |

범위는 가상머신 3대와 호스트로 이루어진 4노드 K3s 클러스터, 학습·추론 이미지와 Helm 양식, 요청 큐를 가진 C++ 추론 워커와 Python 학습 스크립트, 작업 상태·체크포인트의 DB 기록과 이어서 실행, Jenkins·Argo CD·Prometheus·Grafana 연동, 정상 실행과 중단 상황 재현 실험이다.

### 1.3 사용자 시나리오와 구현 (제안서 5번)

연구실의 실험 주제가 아직 정해지지 않았으므로 특정 모델에 맞춘 기능 대신, 모델 버전·입력·작업 상태·결과를 똑같은 방식으로 다루는 공통 흐름을 만들었다. 사용자가 밟는 여섯 단계는 `scripts/job.sh` 하나로 묶었다.

| 단계 | 구현 | 상태 |
|---|---|---|
| 템플릿 선택 | `job.sh submit train\|infer` → `charts/k3slab-workload`의 `values-train.yaml` / `values-infer.yaml` | 완료 |
| 모델 버전 지정 | `--version` (이미지 태그와 함께 DB `model_version`에 남음) | 완료 |
| 입력 파일 등록 | `job.sh upload <파일.npz>` → 학습은 `--dataset npz:/data/<파일>` | 완료 |
| 실행 요청 | `job.sh submit` (DB에 PENDING을 먼저 넣고, 성공했을 때만 Helm으로 실행) | 완료 |
| 진행 상태 확인 | `job.sh status <작업 번호>` (현재 상태 + 상태 이력 + 마지막 체크포인트) | 완료 |
| 결과 확인 | `job.sh result <작업 번호>` (결과 파일 경로 + 로그 끝부분) | 완료 |

## 2. 전체 구성

<p align="center">
  <img src="assets/architecture.svg" alt="k3s-vmware-lab 구성도" width="100%">
</p>

### 2.1 노드

| 노드 | 형태 | OS | 자원 | 역할 라벨 | 맡은 일 |
|---|---|---|---|---|---|
| k3s-server | VM | Rocky Linux 9.8 Server (GUI 없음) | 2 vCPU / 3 GB | (없음) | K3s 제어 노드 |
| worker-cpu-1 | VM | Rocky Linux 9.8 | 2 vCPU / 6 GB | `k3slab.io/role=platform` | 레지스트리, MySQL. Jenkins·Argo CD·모니터링 배치 예정 |
| worker-cpu-2 | VM | Rocky Linux 9.8 | 2 vCPU / 3 GB | `k3slab.io/role=app` | API 대역 파드(echo-api), 노드 중단 실험 대상 |
| gpu-host | 물리 데스크톱(호스트 OS) | Ubuntu 26.04.1 LTS | Ryzen 7 5700X 8C/16T, RTX 3090 24 GB, 호스트 전체 32 GB | `k3slab.io/role=gpu` + taint `nvidia.com/gpu=present:NoSchedule` | 학습·추론, 이미지 빌드(Kaniko) |

- VM 3대의 설정 합계는 6 vCPU / 12 GB다(`infra/terraform/variables.tf`). 네트워크는 VMware NAT `vmnet8` = 172.16.133.0/24이고, gpu-host의 노드 IP는 vmnet8 주소 172.16.133.1이다.
- GPU는 VM에 넘기지 않고 물리 호스트에서 직접 쓴다. 호스트와 노드는 1대 1이다.

### 2.2 버전

| 구분 | 버전 | 정해 둔 곳 |
|---|---|---|
| K3s | v1.36.4+k3s1 | `infra/ansible/inventories/lab/group_vars/all.yml` |
| VMware Workstation Pro / vmrest | 26.0.0 / 1.3.1 | `scripts/lib/pinned-versions.env` |
| Terraform / provider | 1.16.3 / elsudano/vmworkstation 2.0.1 | `infra/terraform/versions.tf` |
| Packer / 플러그인 | 1.16.0 / hashicorp/vmware 2.1.6 | `infra/packer/templates/rocky-golden.pkr.hcl`, `infra/packer/plugins.sha256` |
| ansible-core, Helm | 2.21.4, 4.3.1 | `scripts/lib/pinned-versions.env` |
| NVIDIA 드라이버 / Container Toolkit / device plugin | 580.178.04 (CUDA 13.0) / 1.20.1-1 / v0.20.1 | `docs/gpu-host-join-prep.md` |
| 레지스트리 / Kaniko | registry 3.1.2 / martizih/kaniko v1.28.6 | `scripts/lib/pinned-versions.env` |
| 학습 베이스 이미지 | pytorch 2.14.1 + CUDA 13.0 + cuDNN 9 (runtime) | `apps/train/Dockerfile` |
| MySQL | 8.4.13 | `infra/k8s/mysql.yaml` |

### 2.3 작업이 흐르는 길

```text
scripts/job.sh submit ──▶ MySQL jobs (PENDING) ──▶ Helm (charts/k3slab-workload) ──▶ 학습 Job / 추론 Deployment (gpu-host)
        ▲                       ▲                                                        │
        └── status / result ────┴────────── 상태·체크포인트 기록 ◀──────────────────────┘

이미지: scripts/image-build.sh (Kaniko, 클러스터 안) ──▶ registry.k3slab.local:5000 (worker-cpu-1) ──▶ 각 노드가 pull
```

[진행 중] 3.7이 끝나면 위 흐름의 앞쪽(Git push → Jenkins → 레지스트리 → Argo CD)을 그림으로 추가한다.

## 3. 구현

### 3.1 인프라 코드화 (Packer → Terraform → Ansible)

<p align="center">
  <img src="assets/iac-workflow.svg" alt="Packer → Terraform → Ansible 워크플로우" width="100%">
</p>

| 단계 | 도구 | 하는 일 |
|---|---|---|
| 기준 이미지 | Packer | Rocky 9.8 DVD ISO로 무인 설치(Kickstart)해 GUI 없는 Server 골든 이미지를 만든다. 완료 뒤 VMX·VMDK의 SHA-256을 기록하고 읽기 전용(0444)으로 잠근다 |
| VM 생성 | Terraform | 골든 이미지를 복제해 VM 3대를 만들고 전원을 켠다. 상태 파일로 관리한다 |
| UI 등록 | `scripts/register-vms.sh` | provider 복제만으로는 Workstation 목록에 안 나오는 VM을 vmrest 등록 API로 중복 없이 등록한다 |
| 노드 구성 | Ansible | Terraform 출력에서 인벤토리를 만들어 공통 설정, SELinux enforcing 유지, K3s 설치·조인, 노드 라벨을 적용한다 |
| 한 번에 실행 | `scripts/entry.sh` | 9단계(vmrest 시작 → Rocky ISO 확인 → 사전 점검 → 골든 이미지 → Terraform 준비 → VM 생성·전원·UI 등록 → IP 목록(인벤토리) 생성 → SSH 확인 → OS + K3s)를 순서대로 부르고 단계별 시간을 표로 낸다 |

**재현성을 위한 규칙**

- 도구·provider·ISO·이미지 버전을 고정하고 `scripts/preflight.sh`(14개 항목)가 어긋나면 FAIL로 멈춘다. 필수 파일과 Bash 문법은 `scripts/verify-project.sh`가 점검한다.
- 골든 이미지는 불변이다. 같은 버전 폴더가 있으면 다시 빌드하지 않는다.
- 모든 단계는 다시 실행해도 같은 결과가 되도록(멱등) 만들었다. 정상 상태에서 다시 돌리면 Terraform `No changes`, Ansible `changed=0`이다.
- 비밀값(vmrest 자격증명, SSH 키, 콘솔 비밀번호 해시, K3s 토큰, kubeconfig)과 Terraform 상태는 저장소 밖(`~/.config/k3s-vmware-lab/secrets`, `~/.local/state/k3s-vmware-lab`)에 두고 권한을 0600/0700으로 한다. 상태 파일은 변경 명령 전에 30개까지 순환 백업한다.
- provider 2.0.1의 제약은 Terraform 안에서 피했다. 부모 VM의 NIC를 `custom/vmnet8`로 두고, VM을 꺼진 채로 만든 뒤 두 번째 apply에서 켠다.

**측정값**

| 항목 | 값 | 근거 |
|---|---|---|
| 골든 이미지 빌드(첫 성공) | 10분 45초 | `docs/vmware-iac-handoff.md` 13.7 |
| 처음부터 구축(ISO 첫 다운로드 제외) | 약 16분 (이 중 골든 이미지 약 11분) | `docs/vmware-iac-handoff.md` 13.11 |
| 정상 상태에서 `entry.sh` 재실행 | 1분 59초 (Terraform No changes, UI 등록 0 added/3 already present, Ansible changed=0) | `docs/vmware-iac-handoff.md` 13.11 |
| 꺼진 VM 3대를 다시 켜고 재실행 | 2분 53초 (10/6) | `docs/plan-week05-06.md` |

근거: [`docs/vmware-iac-handoff.md`](vmware-iac-handoff.md), [`docs/README.md`](README.md)(스크립트 단계별 흐름), [`README.md`](../README.md)의 워크플로우.

### 3.2 K3s 클러스터와 GPU 호스트

**물리 GPU 호스트 합류 (2026-10-06)**

- `playbooks/gpu-host.yml`이 NVIDIA Container Toolkit 1.20.1-1(키 해시 고정, 버전 hold), NetworkManager 예외, ufw 규칙, k3s-agent, NVIDIA device plugin v0.20.1을 설치한다. 호스트 네트워크를 바꾸므로 `-e host_changes_allowed=true -K`를 주고 호스트 콘솔에서만 실행하도록 막아 두었다(없으면 sudo를 쓰기 전에 멈춘다).
- 노드 IP와 flannel 인터페이스를 vmnet8로 고정했다. 기본 경로가 LAN이라 그대로 두면 VM과의 통신이 꼬이기 때문이다.
- 스모크 테스트에서 파드 안의 `nvidia-smi`가 RTX 3090(드라이버 580.178.04, CUDA 13.0)을 보여 주었고 클러스터 DNS 조회도 성공했다.
- Ubuntu 26.04 대응: sudo-rs 프롬프트 문제는 `sudo.ws`로, HashiCorp 저장소 키 교체로 apt 전체 갱신이 실패하는 문제는 NVIDIA 저장소만 갱신하게 해서 피했다.
- 근거: [`docs/gpu-host-join-prep.md`](gpu-host-join-prep.md)

**K3s 실습 5개: PASS 11/11 (2026-10-30)**

| 실습 | 수행 내용 | 결과 |
|---|---|---|
| 노드 조인 | `kubectl get nodes` | 4대 모두 Ready (VM 3대 Rocky 9.8, gpu-host Ubuntu 26.04) |
| 작업 배치 | gpu-host taint, GPU 파드 2개 + 일반 파드 4개 | GPU 파드 a는 gpu-host에서 RTX 3090 인식. GPU가 1개뿐이라 b는 `Insufficient nvidia.com/gpu`로 Pending. 일반 파드는 gpu-host를 피함 |
| 복제본 조정 | echo-api replicas 1 → 3, 요청 60개 | 1개일 때 한 파드가 60개 응답, 3개일 때 30/12/18개로 나뉨 |
| 파드 재시작 | 파드 강제 삭제 / 컨테이너 강제 종료 | 2초 뒤 새 파드로 3개 복구 / 같은 파드에서 RESTARTS 1 |
| 노드 중단 | worker-cpu-2를 `vmrun ... hard`로 강제 종료 → `entry.sh`로 복구 | 44초 뒤 NotReady, 이어서 308초 뒤 다른 노드에서 Ready(합계 352초), 복구 뒤 다시 Ready |

- 노드 중단에서 자동으로 되는 것: NotReady 표시와 taint, toleration 시간이 지난 뒤 남은 노드에 파드 다시 띄우기, 복구된 노드를 Ready로 받아들이기.
- 자동으로 안 되는 것: 꺼진 VM 켜기(`entry.sh`), `tolerationSeconds` 결정(기본 300초가 대부분의 지연), 노드가 돌아온 뒤 파드를 원래 노드로 되돌리기(자동 재균형 없음).
- 근거: [`docs/labs/k3s-lab-20261030-1646.md`](labs/k3s-lab-20261030-1646.md), 매니페스트 `infra/k8s/labs/`, 실행 `scripts/k3s-lab.sh`

### 3.3 이미지 · 레지스트리 · Helm

- **레지스트리**: registry 3.1.2를 worker-cpu-1에 올렸다(`infra/k8s/registry.yaml`, 20 Gi PVC). 노드 IP가 DHCP라 바뀔 수 있어서 Service의 ClusterIP를 10.43.0.50으로 고정했다. 노드는 `registry.k3slab.local:5000`을 `/etc/rancher/k3s/registries.yaml`로 이 주소에 연결한다. 클러스터 안에서만 열려 있고 HTTP다. 노드 4대에서 pull을 확인했다.
- **빌드**: 호스트 Docker는 sudo가 필요해서 쓰지 않고, `scripts/image-build.sh`가 Kaniko Job으로 클러스터 안에서 빌드해 push한다(gpu-host에서 실행, CUDA 베이스 이미지가 약 8 GB라서). 빌드 폴더는 ConfigMap으로 넘기므로 하위 폴더 없이 900 KB 이하여야 한다.
- **태그는 덮어쓰지 않는다.** 이미 있는 태그면 빌드를 거부한다. 결함이 있던 태그는 지우고 사유를 남긴 뒤 새 태그로 빌드한다. 빌드마다 digest·git 커밋·빌드 폴더 해시를 기록한다.
- **Helm 차트** `charts/k3slab-workload`: `kind: train`은 Job, `kind: infer`는 Deployment + Service가 된다. 값 파일은 `values-train.yaml`, `values-infer.yaml`이고 작업 번호·모델 버전·이미지 태그·배치 크기만 `--set`으로 바꿔 같은 템플릿을 다시 쓴다. Dockerfile·이미지 태그·values를 한 묶음으로 기록한다(제안서 9번).

| 이미지 | 빌드일 | 상태 | 비고 |
|---|---|---|---|
| train-worker:v0.1 | 10/30 | 삭제 | `train.py`가 ConfigMap 심볼릭 링크로 들어가 실행 불가. 빌드 전 실제 파일로 복사하게 수정 |
| train-worker:v0.2 | 10/30 | 삭제 | GPU에서 이어서 학습할 때 난수 상태 복원 실패. 체크포인트를 CPU로 읽게 수정 |
| infer-worker:v0.1 | 10/30 | 삭제 표시 없음 | CPU 계산 + 배치당 고정 비용(WORK_MS) |
| train-worker:v0.3 | 10/30 | 삭제 표시 없음 | 중단·재개 시험 통과 |
| infer-worker:v0.2 | 11/7 | **현재 사용** (`values-infer.yaml`) | 모듈 분리 + CUDA 경로 |
| train-worker:v0.4 | 11/7 | **현재 사용** (`values-train.yaml`) | Dataset 인터페이스 분리, PyMySQL 해시 고정 설치 |

- 이미지 안의 구성요소도 버전을 고정했다. 추론 빌드는 `gcc:15.3.0-trixie`(cpp-httplib v0.64.0을 SHA-256으로 확인) → `nvidia/cuda:13.0.3-devel-ubuntu24.04`로 컴파일 → `debian:trixie-20261027-slim`에서 실행한다. 학습 이미지의 PyMySQL 1.2.3은 `--require-hashes`로 설치한다.
- 근거: [`docs/image-builds.md`](image-builds.md), `infra/k8s/registry.yaml`, `scripts/image-build.sh`, `charts/k3slab-workload/`

### 3.4 학습 Job

- `apps/train/train.py`는 특정 모델이 아니라 플랫폼의 약속을 따른다: 작업 번호 하나가 Job 하나이고, 끝난 작업 번호로 다시 요청하면 학습하지 않는다.
- 에폭마다 체크포인트를 저장하고(원자적 쓰기, 최근 3개 유지) SIGTERM을 받으면 그 시점의 체크포인트를 남기고 `INTERRUPTED`로 끝난다. Job이 새 파드로 다시 시도하면 마지막 체크포인트에서 이어서 학습한다(`resumed_from`).
- 체크포인트에는 모델, 옵티마이저, 난수 상태가 들어 있다. 로컬(CPU) 비교에서 끊었다가 이어서 학습한 모델이 한 번에 학습한 모델과 비트 단위로 같았다.
- 체크포인트와 내보낸 모델은 gpu-host의 `/var/lib/k3slab/checkpoints/<작업 번호>/`에 둔다(hostPath, 파드가 죽어도 남음). 내보내는 `model.k3sm`은 float32 가중치 파일이라 추론 워커가 PyTorch 없이 읽는다.
- 데이터는 `apps/train/datasets.py`로 분리했다. 학습 코드는 `batch()`만 부르므로 실험 주제가 정해지면 Dataset 하나를 추가하면 된다. 지금은 `synthetic`(시드 고정 10클래스 합성 데이터)과 `npz:/data/<파일>`(업로드한 표 데이터)이 있다. 모델 크기는 `--hidden`으로 바꾼다.
- 잘못된 요청(없는 데이터 파일)은 재시도 없이 바로 실패하도록 `podFailurePolicy`를 걸었다.

| 시험 | 이미지 | 결과 | 근거 |
|---|---|---|---|
| 중단·재개 (GPU) | v0.2 | **실패**: 재시도 파드가 `RNG state must be a torch.ByteTensor`로 모두 실패. 원인은 체크포인트를 GPU로 읽은 것 | [`train-resume-20261030-1702.md`](labs/train-resume-20261030-1702.md) |
| 중단·재개 (GPU) | v0.3 | PASS 6/6. 4 에폭 1번째 스텝의 체크포인트를 남기고 INTERRUPTED → 이어서 GPU에서 DONE → 같은 번호 재요청은 학습하지 않음 | [`train-resume-20261030-1716.md`](labs/train-resume-20261030-1716.md) |
| 중단·재개 (GPU) | v0.4 | PASS 6/6. 3 에폭 1번째 스텝에서 INTERRUPTED → 이어서 DONE | [`train-resume-20261107-1253.md`](labs/train-resume-20261107-1253.md) |

### 3.5 추론 워커 (C++)

- **API**: `POST /infer`(64개 숫자 입력 → 클래스·확률·배치 크기·대기 시간·장치·모델 버전), `GET /healthz`, `GET /metrics`(Prometheus 형식).
- **정책** (제안서 10번): 큐가 차면 새 요청을 HTTP 429로 즉시 거절하고, 큐에서 여러 요청을 한 번에 꺼내 배치로 계산하고, 대기 시간이 상한(`TIMEOUT_MS`)을 넘으면 504로 실패 처리하고, 워커 스레드 수를 설정값으로 고정한다. 기본값은 큐 100, 배치 8, 스레드 2, 타임아웃 2000 ms다(`values.yaml`).
- **구조**: 한 파일 404줄이던 `main.cpp`를 역할별 파일(설정, 모델, 큐, CPU/GPU 계산, 워커 스레드, 메트릭, HTTP)로 나눴다. 빌드 폴더가 ConfigMap으로 넘어가서 하위 폴더를 쓸 수 없으므로 `apps/infer/` 한 폴더에 둔다.
- **GPU 계산**: 직접 작성한 CUDA 커널이다(출력 뉴런 하나를 워프 하나가 맡는 방식). 가중치는 시작할 때 한 번만 GPU로 올린다. CUDA 런타임을 정적으로 링크해서 실행 이미지에는 CUDA 라이브러리가 없다. GPU가 없으면 CPU로 계산한다(`DEVICE=auto`).
- **정확도 점검**: 시작할 때 같은 입력 8개를 GPU와 CPU로 계산해 비교한다. 최대 상대 오차는 작은 모델 4.19e-07, 큰 모델 1.33e-06이었다.
- **Deployment 설정**: GPU를 쓰는 Deployment는 하나뿐인 GPU를 놓지 않는 문제 때문에 예전 파드를 먼저 내린다(`maxSurge: 0`). 롤링 재배포 때 종료된 파드로 연결이 가는 문제는 `preStop sleep 5`로 줄였다.

**시험 결과**

| 시험 | 조건 | 결과 | 근거 |
|---|---|---|---|
| 배치 처리 | 요청 400개, 동시 100개, MAX_BATCH 1 vs 8, WORK_MS 20 | 8.08 s vs **1.28 s** (약 6.3배). 10/30 v0.1은 8.05 s vs 1.31 s | [`infer-bench-20261107-1257.md`](labs/infer-bench-20261107-1257.md), [`infer-bench-20261030-1720.md`](labs/infer-bench-20261030-1720.md) |
| 과부하 거절 | 큐 20, 요청 300개(동시 150개) | **211개가 즉시 HTTP 429**, 89개 성공. 10/30 v0.1은 207개 거절 | 같은 파일 |
| CPU vs GPU, 작은 모델 (64→128→10, 요청당 곱셈 9,472) | 요청 400개, 동시 100개, MAX_BATCH 8, WORK_MS 0 | CPU 1.27 s (배치 계산 시간 합 0.003 s), GPU 1.21 s (0.076 s). 작은 모델에서는 GPU가 계산 시간이 더 길다 | [`infer-gpu-bench-20261107-1246.md`](labs/infer-gpu-bench-20261107-1246.md) |
| CPU vs GPU, 큰 모델 (64→4096→4096→10, 요청당 곱셈 17,080,320) | 같은 조건 | CPU 2.30 s (4.488 s), GPU 1.25 s (**0.111 s**). 배치 계산 시간은 약 1/40 | 같은 파일 |

- 전체 걸린 시간이 1.2초 밑으로 내려가지 않는 것은 부하 클라이언트(curl, 요청마다 새 연결) 쪽 한계로 설명했다(`docs/progress-week09.md`). 요청 400개는 모두 성공(200)했다.
- 근거 소스: `apps/infer/`, `scripts/infer-bench.sh`, `scripts/infer-gpu-bench.sh`

### 3.6 작업 상태 DB (MySQL)

- **배치**: MySQL 8.4.13을 worker-cpu-1에 올렸다(`infra/k8s/mysql.yaml`: 요청 CPU 100m / 메모리 512 Mi, 메모리 상한 1 Gi, InnoDB 버퍼 풀 256 MB, 5 Gi PVC(local-path)). 클러스터 안에서만 접근한다.
- **배포**: `scripts/mysql-deploy.sh` 한 번으로 비밀번호 생성, 배포, 테이블 생성까지 한다. 비밀번호는 무작위로 만들어 클러스터 Secret과 `~/.config/k3s-vmware-lab/secrets/mysql.env`(권한 600)에만 둔다. 다시 실행해도 데이터와 비밀번호는 그대로다.
- **테이블** (`infra/k8s/mysql-schema.sql`):
  - `jobs`: 제안서 11번의 컬럼(job_id, job_type, model_version, status, checkpoint_path, result_path, updated_at)에 `attempts`(파드 시도 횟수)와 `detail`(에폭·loss 등 JSON), `created_at`을 더했다.
  - `job_events`: 상태가 바뀔 때마다 한 줄씩 남는 이력이다. 중단과 재개가 나중에도 보인다.
- **중복 방지**: `jobs`의 PRIMARY KEY로 한다. 등록(PENDING)이 성공했을 때만 Helm으로 Job을 만들고, 같은 번호로 다시 요청하면 새로 실행하지 않고 기존 상태를 돌려준다.
- **DB가 멈춰도 학습은 계속된다**: 못 쓴 기록은 보류해 두었다가 DB가 돌아오면 한꺼번에 채운다. 마지막 상태(DONE/FAILED)는 정해 둔 대기 시간 안에 쓰이지 않으면 오류를 낸다.
- 상태 값은 PENDING / RUNNING / INTERRUPTED / DONE / FAILED다(제안서에 INTERRUPTED를 더함, 4절).

**시험 결과: PASS 18/18** (`scripts/job-db-test.sh`, [`job-db-20261107-1258.md`](labs/job-db-20261107-1258.md))

| 시험 | 결과 |
|---|---|
| 등록 | submit 직후 PENDING이 이력의 첫 상태. 파드가 뜨면 RUNNING, attempts 1 |
| 실행 중 같은 번호로 다시 요청 | 새 Job을 만들지 않고 기존 상태를 돌려줌 (Helm 리비전 1 유지) |
| 학습 중단·재개 | 파드 삭제 → INTERRUPTED → 재시도 파드가 RUNNING + `resumed_from`, attempts 2 |
| 학습 중 DB 중단 | MySQL을 11초 내림(12:59:10~12:59:21). 학습은 멈추지 않고 에폭 3 → 5 진행, 못 쓴 기록은 DB가 돌아온 뒤 채워져 에폭 1~8 기록이 빠짐없이 남음. 최종 DONE |
| 완료된 번호로 다시 요청 | 다시 학습하지 않음, 새 파드 없음 |
| 잘못된 요청(없는 데이터 파일) | DB에 FAILED와 오류 문구. Job은 재시도 없이 바로 실패(파드 1개) |
| 입력 파일 등록 후 학습 | `.npz` 업로드 → 그 파일로 학습해 DONE, dataset이 DB에 남음 |
| 추론 작업 | 학습 결과를 서빙 → RUNNING, 응답에 클래스·모델 버전 → stop → DONE |

### 3.7 CI/CD (Jenkins · Argo CD)

**[진행 중]** 제안서 일정: Jenkins 10–12주, Argo CD 11–13주. 제안서 12번의 흐름은 `Git push → Jenkins(빌드·테스트·이미지 생성·태그) → 레지스트리 push → 배포 설정의 태그 수정 → Argo CD 동기화 → K3s 반영`이다.

채울 것 (Jenkins)

- [ ] 설치 위치와 방식: 네임스페이스, 노드, CPU·메모리 requests/limits, PVC 크기, 이미지·차트 버전
- [ ] 파이프라인 정의 파일 경로와 단계. 계획은 C++ 빌드(`make CUDA=0`)와 Python 문법·단위 검사 → 통과했을 때만 이미지 생성(지금과 같은 Kaniko 방식) → 태그 부여 → 레지스트리 push다(`docs/progress-week09.md` 다음 주 계획). 실제 구현으로 바꿔 쓴다
- [ ] 검사가 실패하면 이미지가 만들어지지 않는다는 증거(실패한 실행 1건)
- [ ] 태그 규칙과 불변 확인(이미 있는 태그는 빌드하지 않음)
- [ ] 빌드 시간(코드 push부터 이미지 push까지), 실행 중 자원 사용량
- [ ] 자격 증명(Git, 레지스트리) 처리 방법. 비밀값은 Git에 없음
- [ ] 근거 파일: `docs/labs/` 아래 실행 기록 (경로 추후)

채울 것 (Argo CD)

- [ ] 설치 위치와 방식, 자원 requests/limits, 버전
- [ ] 배포 설정(YAML)을 두는 Git 저장소 디렉터리(제안서: 별도 디렉터리)와 Argo CD 앱 정의
- [ ] "태그만 수정하면 반영" 시험: 태그 수정부터 K3s 반영까지 걸린 시간, 사람이 배포 명령을 치지 않았다는 증거
- [ ] 배포 설정과 클러스터 실제 상태가 다를 때 맞추는 동작 시험
- [ ] 잘못된 배포 시나리오(5.2의 2번)와 복구 방법
- [ ] 근거 파일 (경로 추후)

채울 것 (전체)

- [ ] 2.3의 흐름 그림에 Git → Jenkins → 레지스트리 → Argo CD 경로 추가
- [ ] Jenkins·Argo CD가 worker-cpu-1(6 GB)에 더해지는 메모리 영향(한계 7절과 연결)

### 3.8 모니터링 (Prometheus · Grafana)

**[진행 중]** 제안서 일정: 12–14주. 제안서 13번의 관측 대상 네 가지를 대시보드 한 장에 모은다. 현재 준비된 것은 추론 워커의 `/metrics`뿐이다.

| 관측 대상 | 제안서의 지표 | 지금 준비된 것 | 채울 것 |
|---|---|---|---|
| 노드·파드 | CPU·메모리 사용률, 파드 재시작 횟수 | 없음 | 수집 방법, 패널 |
| GPU | GPU 사용률, VRAM 사용량(24 GB 기준) | 없음 | 수집 방법, 패널 |
| 추론 요청 | 초당 요청 수, 성공·실패 수, 큐 길이, 처리 시간 | 워커가 `/metrics`로 노출 중: `k3slab_infer_queue_length`, `k3slab_infer_queue_capacity`, `k3slab_infer_requests_total{result=ok\|rejected\|timeout\|bad_request\|failed}`, `k3slab_infer_batch_size`, `k3slab_infer_batch_compute_seconds`, `k3slab_infer_request_seconds`, `k3slab_infer_info{device,gpu,model_version}` | 수집 설정, 패널 |
| 작업 상태 | 대기·실행·완료·실패 작업 수 | MySQL `jobs` 테이블의 `status` | 수집 방법, 패널 |

채울 것

- [ ] 설치 위치와 방식, 자원 requests/limits, 저장 기간·PVC, 버전
- [ ] 수집 대상 목록(`ServiceMonitor` 또는 scrape 설정)과 수집 주기
- [ ] 대시보드 한 장의 캡처와 패널 목록, 대시보드 정의 파일 경로
- [ ] 5절의 시나리오마다 해당 상황이 대시보드에 나타난 화면(재시작 횟수, 큐 길이·거절 수, 작업 상태 수 변화)
- [ ] 모니터링이 쓰는 자원이 클러스터에 준 영향(메모리)

## 4. 제안서와 달라진 점

### 4.1 바뀐 것

| 항목 | 제안서 | 구현 | 이유·근거 |
|---|---|---|---|
| 하이퍼바이저 | KVM / libvirt | VMware Workstation Pro 26 + vmrest + Terraform provider | 이 데스크톱에 이미 설치·사용 중이다. vmrest API와 provider로 VM 생성·전원·삭제를 코드로 관리할 수 있다. KVM 모듈과 함께 동작하는 것도 확인했다. (`docs/progress-week08.md`, 인계서 13.2) |
| 노드 중단 실험 명령 | `virsh destroy` | `vmrun -T ws stop <vmx> hard` | 하이퍼바이저 변경에 따른 대체. 복구는 `entry.sh`(Terraform이 꺼진 VM을 다시 켬) (`docs/labs/k3s-lab-20261030-1646.md`) |
| 레지스트리 위치 | 연구실 내부 레지스트리 | 클러스터 안(worker-cpu-1), 고정 ClusterIP 10.43.0.50, 클러스터 내부 HTTP | 노드 IP가 DHCP라 바뀔 수 있어서 Service IP를 고정했다. 호스트에 서비스를 추가하지 않았다 (`infra/k8s/registry.yaml`) |
| 이미지 빌드 | Jenkins가 빌드 | 지금은 `scripts/image-build.sh`가 클러스터 안 Kaniko로 빌드. Jenkins 단계에서 같은 방식을 재사용 | 호스트 Docker는 sudo가 필요하다. **[진행 중]** Jenkins 결과로 갱신 |
| 학습 데이터 | (실험 주제 미정) | 시드 고정 합성 데이터 + 업로드한 `.npz` | 네트워크 다운로드 없이 재현된다. 실험 주제가 정해지면 `datasets.py`에 Dataset 하나만 추가한다 |
| 추론 계산 | GPU | 8주차에는 CPU + 배치당 고정 비용(WORK_MS)으로 구조만 검증, 9–11주차에 CUDA(직접 작성한 커널) 경로를 추가하고 GPU가 없으면 CPU로 대체 | 큐·배치·타임아웃 구조를 먼저 검증한 뒤 GPU를 붙였다 (`docs/progress-week09.md`) |
| 작업 상태 값 | PENDING / RUNNING / DONE / FAILED | `INTERRUPTED`를 추가 | SIGTERM으로 끊긴 시도와 진짜 실패를 구분한다. 재개 판단 기준은 그대로다(다시 RUNNING) |
| DB 컬럼·테이블 | 7개 컬럼 | `attempts`, `detail`, `created_at` 컬럼 추가, 상태 이력 테이블 `job_events` 추가 | 재시도 횟수와 중단·재개 이력을 남기기 위해서다 |
| 작업 등록 창구 | 요청마다 작업 번호를 발급(구체적인 창구는 명시 없음, API 파드 구성) | `scripts/job.sh`(명령줄), 웹 API 없음 | 사용자 시나리오 여섯 단계를 명령 하나로 확인할 수 있다. 웹 API는 CI/CD 연동 뒤 필요하면 추가한다 |
| GPU 사용 | GPU 공유(학습·추론이 3090을 함께 사용하는 구성) | GPU 1개를 둘 중 하나만 쓴다 | device plugin이 GPU를 통째로 하나씩 나눠 준다. 학습 중에는 `--device cpu`로 추론을 띄운다 |
| API 파드 ×3 | 요청을 받는 API·전처리 파드 | 실제 API 구현 없이 `traefik/whoami` 기반 echo-api를 대역으로 써서 복제본·재시작·노드 중단 실습을 수행 | 실습의 목적은 클러스터 동작 확인이다 (`infra/k8s/labs/20-echo-api.yaml`) |
| 다중 파드 분배 요청 수 | 300건 | 실습에서는 60건 | 13–16주 검증 실험에서 제안서 기준(300건)으로 다시 측정할 계획이다 (5.1) |
| 학습 이미지 예시 | `python:3.11` + torch 2.x | `pytorch/pytorch:2.14.1-cuda13.0-cudnn9-runtime` | 제안서의 값은 예시였다. 호스트 드라이버 580의 최대 CUDA가 13.0이라 거기에 맞췄다 |

### 4.2 제안서에 없던 것을 추가한 것

| 추가한 것 | 이유 |
|---|---|
| 사전 점검 `preflight.sh`와 파일 점검 `verify-project.sh` | 버전·모듈·네트워크·비밀 파일이 어긋나면 이후 단계로 넘어가기 전에 멈추기 위해서 |
| 실습·시험 스크립트가 실행 기록을 `docs/labs/`에 자동 저장 (`k3s-lab.sh`, `train-resume-test.sh`, `job-db-test.sh`, `infer-*-bench.sh`) | 제안서 검증 계획의 "명령 기록" 방식을 따르고 PASS/FAIL을 남기기 위해서 |
| 학습 Job의 `podFailurePolicy` | 잘못된 요청은 재시도해도 같은 결과라서 바로 실패시키기 위해서 |
| DB 쓰기 보류와 나중 채움 | DB가 잠깐 멈춰도 학습을 멈추지 않기 위해서 |

### 4.3 일정

3~4주차(9/21~10/4)는 시험 기간과 겹쳐 진행이 없었고, 10/15~10/30에는 커널 업데이트로 VMware 모듈이 빠져 클러스터가 멈춰 있었다. 그래서 4–8주차 항목을 10/30에 몰아서 실행·검증했고, 9주차부터 원래 일정으로 돌아와 9–11주차 항목(MySQL, 추론 GPU 경로, 학습 Dataset)을 11/7에 끝냈다. 자세한 표는 [부록 A](#부록-a-일정-대비-실제)에 있다.

## 5. 검증 실험

**[진행 중]** 제안서 일정: 13–16주. 제안서 14·15번의 시험을 그대로 따른다. 아래 표의 "사전 시험"은 앞선 주차에 이미 해 본 같은 종류의 측정이다. 최종 검증이 아니며, 13–16주에 같은 방식으로 다시 측정해 기록한다.

기록 방식: 각 시험마다 명령 기록, DB의 작업 상태, Grafana 화면(3.8 완료 후)을 함께 저장하고 `docs/labs/<이름>-<날짜시각>.md`로 남긴다. 이미지 태그, git 커밋, values 파일을 같이 적는다.

### 5.1 정상 실행 시나리오 (제안서 14번 ①)

| 실험 | 방법 | 성공 기준 | 최종 검증 | 사전 시험 |
|---|---|---|---|---|
| 전체 흐름 | 템플릿 선택부터 결과 확인까지 1회 | 사람 개입 없이 결과 파일과 상태 기록이 남는다 | 예정 | `job.sh`로 submit → status → result → 추론 서빙까지 확인 ([`job-db-20261107-1258.md`](labs/job-db-20261107-1258.md) 1, 5, 7, 8절) |
| 다중 파드 분배 | API·전처리 파드 3개로 요청 300건 | 세 파드에 나뉘고 실패가 없다 | 예정 | 요청 60건: 30/12/18로 나뉨 ([`k3s-lab-20261030-1646.md`](labs/k3s-lab-20261030-1646.md) 3절) |
| 배치 처리 | 배치 크기 1과 8, 같은 요청 수 | 배치 8이 더 짧은 시간에 끝난다 | 예정 | 8.08 s vs 1.28 s ([`infer-bench-20261107-1257.md`](labs/infer-bench-20261107-1257.md)) |
| 과부하 거절 | 큐 크기를 넘는 요청을 동시에 전송 | 초과분이 지연이 아니라 거절 응답으로 돌아온다 | 예정 | 300개 중 211개가 즉시 429 (같은 파일) |

### 5.2 중단 상황 시나리오 (제안서 14번 ②)

제안서의 순서: 파드 종료 → 잘못된 배포 → 학습 중단 → 배치 추론 중단 → DB 재시작 → 워커 VM 종료. 하나씩 재현한다.

| 순서 | 실험 | 기대하는 자동 동작 | 최종 검증 | 사전 시험 |
|---|---|---|---|---|
| 1 | 파드 종료 | Deployment가 새 파드를 만든다 | 예정 | 강제 삭제 2초 뒤 3개 복구, 컨테이너 종료는 RESTARTS 1 (`k3s-lab` 4절) |
| 2 | 잘못된 배포 | 잘못된 배포가 드러나고 복구되는지(구체적인 기준은 Argo CD 이후 확정) | 예정 (Argo CD 이후) | 없음. 잘못된 *요청*(없는 데이터 파일)은 FAILED로 기록되고 재시도 없이 끝나는 것을 확인함 ([`job-db`](labs/job-db-20261107-1258.md) 6절) |
| 3 | 학습 중단 | 마지막 체크포인트부터 이어서 학습 | 예정 | PASS 6/6 (v0.3), PASS 6/6 (v0.4) |
| 4 | 배치 추론 중단 | 제안서 15번 기준: 중단된 지점 이후부터 처리가 이어진다(구체적인 기준은 아래 "채울 것") | 예정 | 없음 |
| 5 | DB 재시작 | 학습은 계속되고 기록이 나중에 채워진다 | 예정 | MySQL 11초 중단 중 학습 계속, 기록 보류 후 채워짐 ([`job-db`](labs/job-db-20261107-1258.md) 4절) |
| 6 | 워커 VM 종료 | 파드가 남은 노드로 옮겨진다 | 예정 | 44초 뒤 NotReady, 308초 뒤 다른 노드에서 Ready ([`k3s-lab`](labs/k3s-lab-20261030-1646.md) 5절) |

채울 것

- [ ] 6종 각각의 명령 기록, 작업 상태, 대시보드 화면, 걸린 시간
- [ ] 배치 추론 중단에서 "이어서 실행"이 무엇을 뜻하는지 정하기. 지금 추론 워커의 요청 큐는 메모리에만 있어서(`apps/infer/queue.h`) 워커 파드가 죽으면 큐에 있던 요청은 사라진다. 클라이언트 재요청으로 볼지, 별도 기록이 필요한지 시험 전에 정한다
- [ ] 자동으로 복구된 것과 사람이 개입해야 했던 것의 구분표 (제안서 기대 효과 3번)
- [ ] 막을 수 없는 장애와 막을 수 있는 장애의 구분: 막을 수 없는 쪽은 GPU 고장, 디스크 고장 시 local-path 데이터 손실이고, 막을 수 있는 쪽은 파드·노드 중단, DB 재시작이다 (`docs/progress-week09.md`의 정리, 한계 7절과 연결)

### 5.3 평가 기준 (제안서 15번)

| 평가 항목 | 확인 방법 | 판단 기준 | 최종 검증 | 사전 시험 |
|---|---|---|---|---|
| 재현성 | 같은 템플릿과 태그로 2회 실행 | 두 실행의 환경과 결과 구조가 같다 | 예정 | 없음 (같은 `job.sh` 명령은 같은 values로 같은 Job을 만든다) |
| 자동 배포 | 코드 수정 후 반영까지 관찰 | 사람이 배포 명령을 치지 않는다 | 예정 (3.7) | 없음 |
| 자동 복구 | 파드·노드 중단 실험 | 재시작 또는 재배치가 자동으로 일어난다 | 예정 | `k3s-lab` 4, 5절 |
| 이어서 실행 | 학습·배치 중단 실험 | 체크포인트 이후부터 처리가 이어진다 | 예정 (학습은 사전 시험 있음, 배치 추론은 없음) | `train-resume` PASS 6/6 |
| 관측 | 모든 실험 | 발생한 상황이 대시보드에 나타난다 | 예정 (3.8) | 없음 |

## 6. 결과

### 6.1 지금까지 측정한 값 (끝난 구현)

| 영역 | 항목 | 값 | 근거 |
|---|---|---|---|
| 인프라 | 처음부터 구축 / 정상 상태 재실행 | 약 16분 / 1분 59초 | 인계서 13.11 |
| 클러스터 | K3s 실습 5개 | PASS 11/11 (노드 4대 Ready) | [`k3s-lab-20261030-1646.md`](labs/k3s-lab-20261030-1646.md) |
| 클러스터 | 파드 강제 삭제 후 복구 | 2초 | 같은 파일 4절 |
| 클러스터 | 노드 강제 종료 후 NotReady / 다른 노드에서 Ready | 44초 / 이어서 308초 | 같은 파일 5절 |
| 학습 | 중단·재개 시험 | 10/30 PASS 6/6, 11/7 PASS 6/6 | [`train-resume-20261030-1716.md`](labs/train-resume-20261030-1716.md), [`train-resume-20261107-1253.md`](labs/train-resume-20261107-1253.md) |
| 추론 | 배치 1 vs 8 (요청 400개) | 8.08 s vs 1.28 s | [`infer-bench-20261107-1257.md`](labs/infer-bench-20261107-1257.md) |
| 추론 | 큐 20에 요청 300개(동시 150개) | 211개 즉시 429 | 같은 파일 |
| 추론 | 큰 모델 배치 계산 시간 합, CPU vs GPU | 4.488 s vs 0.111 s (약 1/40) | [`infer-gpu-bench-20261107-1246.md`](labs/infer-gpu-bench-20261107-1246.md) |
| 추론 | 작은 모델 배치 계산 시간 합, CPU vs GPU | 0.003 s vs 0.076 s (GPU가 더 느림) | 같은 파일 |
| 추론 | GPU vs CPU 결과 차이(최대 상대 오차) | 4.19e-07 (작은 모델), 1.33e-06 (큰 모델) | 같은 파일 |
| 작업 DB | 시험 | PASS 18/18. DB 11초 중단 중에도 학습 계속, 기록 빠짐없이 채워짐 | [`job-db-20261107-1258.md`](labs/job-db-20261107-1258.md) |

- 위 값은 모두 1회 실행 결과이고 반복 측정으로 분산을 구하지는 않았다.
- 시험 스크립트가 집계한 PASS 수는 실습 11, 학습 재개 6(10/30), 학습 재개 6(11/7), 작업 DB 18이고 FAIL은 0이다. 10/30 17:02의 학습 v0.2 시험은 재개 단계에서 실패했고(3.4), 원인을 고쳐 v0.3으로 다시 통과했다.

### 6.2 채울 결과

- [ ] CI/CD: 코드 수정부터 클러스터 반영까지 걸린 시간, 사람이 개입한 횟수 (3.7)
- [ ] 모니터링: 대시보드 캡처, 시나리오별 화면 (3.8)
- [ ] 검증 실험: 정상 실행 4종, 중단 상황 6종, 평가 기준 5개의 판정과 구분표 (5절)
- [ ] 자원 사용: Jenkins·Argo CD·모니터링을 올린 뒤 worker-cpu-1 등의 메모리 사용 (7절 "메모리"와 연결)

## 7. 한계

| 한계 | 내용 | 영향·근거 |
|---|---|---|
| 단일 물리 호스트 | VM 3대와 gpu-host가 한 데스크톱(32 GB) 위에 있다. 호스트 OS 재부팅, 절전, 커널 업데이트가 4노드를 동시에 멈춘다 | 노드 중단 실험은 VM 한 대를 끄는 것으로 한정되고, 호스트 전체 장애나 노드 사이 네트워크 분리는 재현하지 못한다. 실제로 10/15~10/30에 커널 업데이트로 VMware 모듈이 빠져 클러스터가 멈췄고(`docs/progress-week08.md`), 11/20에 커널 7.0.0-43에서 다시 모듈이 없어 기동하지 못했다 |
| 호스트 도구의 불안정 | Workstation 커널 모듈은 커널 업데이트 때 자동으로 다시 빌드되지 않는다. 복구는 sudo가 필요한 콘솔 작업이다. vmrest는 사용자 프로세스라 재부팅하면 멈춘다. provider 2.0.1은 VM 설정을 바꿀 때마다 강제 전원 차단을 한다 | 인계서 14장 위험 1, 3, 11 |
| 기준 ISO 고정 | 11/20 `entry.sh`가 2/9단계(ISO 확인)에서 멈췄다. 고정해 둔 Rocky 9.8 ISO가 공식 CHECKSUM에 더 이상 없다(9.9로 교체된 것으로 보임). 골든 이미지가 이미 있으면 빌드는 필요 없지만 확인 단계가 막는다 | 처음부터 다시 구축하려면 고정값과 확인 방식을 정해야 한다. 11/20 기준 미해결이고 해결 방식은 사용자 결정 대기다 |
| GPU 1장 | 학습과 추론이 GPU를 동시에 쓸 수 없다. 두 번째 GPU 파드는 Pending이다. 24 GB VRAM을 데스크톱의 다른 GPU 사용(게임 등)과도 나눈다 | `k3s-lab` 2절, `docs/gpu-host-join-prep.md` |
| 데이터 보존 | 레지스트리(20 Gi)와 MySQL(5 Gi)은 worker-cpu-1의 local-path 볼륨이라 파드·MySQL 재시작은 견디지만 그 VM을 다시 만들거나 디스크가 고장 나면 사라진다. 체크포인트와 입력 파일은 gpu-host의 hostPath다. 복제나 백업 구성은 저장소에 없다 | `infra/k8s/registry.yaml`, `infra/k8s/mysql.yaml`. 레지스트리는 `image-build.sh`로 다시 채울 수 있지만 DB 기록과 체크포인트는 다시 만들 수 없다 |
| 제어 노드 1대 | k3s-server가 하나다. 제안서의 중단 시나리오 6종에 제어 노드 장애는 들어 있지 않다 | 검증 범위 밖 |
| 메모리 | VM 설정 합계 12 GB. worker-cpu-1(6 GB)에 레지스트리(요청 64 Mi)와 MySQL(요청 512 Mi, 상한 1 Gi)이 있고 Jenkins·Argo CD·모니터링이 더해질 예정이다 | **[진행 중]** 3.7·3.8의 실측으로 채움 |
| 노드 IP | vmnet8 DHCP 임대라 서버 IP가 바뀔 수 있다. 바뀌면 인벤토리를 다시 만들고 gpu-host 합류를 다시 해야 한다 | 인계서 위험 5, `docs/gpu-host-join-prep.md` |
| 노드 장애 대응 지연 | 기본 toleration 300초 때문에 파드 이동까지 약 5분 걸렸고, 노드가 돌아와도 자동 재균형이 없다. `tolerationSeconds`는 바꾸지 않았다 | `k3s-lab` 5절 |
| 보안 | 레지스트리는 HTTP이고 인증이 없다(클러스터 내부 주소만). 작업 창구 `job.sh`는 kubeconfig를 가진 사용자만 쓸 수 있고, 그 밖의 사용자 인증·권한 구분은 없다. Terraform provider는 TLS 인증서를 검증하지 않는다(vmrest는 루프백 전용) | 인계서 위험 4 |
| 워크로드의 현실성 | 학습은 합성 데이터 또는 업로드한 표 데이터와 작은 MLP, 추론 입력은 64개 숫자다. 연구실의 실제 모델·데이터셋으로는 검증하지 않았다 | 교체 지점(`datasets.py`)만 만들어 두었다 |
| 측정의 한계 | 부하 도구가 curl이고 모든 값이 1회 실행 결과다. 큰 모델에서도 전체 시간이 1.2초 밑으로 줄지 않는 것은 클라이언트 쪽 한계로 설명했다 | `docs/progress-week09.md` |

## 8. 결론

**잠정 (끝난 구현 기준)**

- 데스크톱 한 대에서 VM 3대와 물리 GPU 호스트를 코드(Packer·Terraform·Ansible)로 묶어 4노드 K3s 클러스터를 만들었다. 처음부터 약 16분이면 구축되고, 정상 상태에서 다시 실행하면 1분 59초에 변경 없이 끝난다.
- 같은 Helm 템플릿으로 학습 Job과 추론 워커를 실행한다. 학습은 중간에 끊겨도 마지막 체크포인트에서 이어서 끝나고(PASS 6/6), 끝난 작업 번호는 다시 학습하지 않는다.
- 작업 상태를 MySQL 한 곳에 기록해 같은 작업 번호의 중복 실행을 막고, DB가 잠깐 멈춰도 학습이 계속되고 기록이 나중에 채워진다(PASS 18/18).
- C++ 추론 워커는 큐 크기 제한(즉시 429), 배치, 타임아웃, 고정 스레드를 갖추고 GPU에서 계산한다. 큰 모델에서 GPU 배치 계산 시간은 CPU의 약 1/40이었고, 계산이 작은 모델에서는 GPU가 이점이 없었다.
- 한계는 단일 물리 호스트, GPU 1장, 로컬 볼륨의 데이터 보존이다(7절).

**[진행 중] 확정할 때 채울 것**

- [ ] 자동 배포와 모니터링까지 포함해 "코드 수정 → 반영 → 관측"이 사람 개입 없이 이어졌는가 (3.7, 3.8)
- [ ] 중단 상황 6종에서 자동으로 복구된 것과 수동 개입이 필요했던 것 (5.2)
- [ ] 제안서 기대 효과 4가지(인수인계 간소화, 플랫폼·모델 계층 분리, 자동 복구 범위와 수동 개입 지점의 구분, 자원 포화 지점의 실측)에 대한 판정
- [ ] 이후 과제: 실제 모델·데이터셋 적용, 데이터 백업·복제, 호스트 장애 대비

## 부록 A. 일정 대비 실제

1주차 = 9/7. 11주차 = 11/16~11/22.

| 일정 항목 | 계획 주차 | 실제 | 비고 |
|---|---|---|---|
| 요구사항 정리·전체 구성도 설계 | 1–2 | 완료 (2주차 진행보고) | |
| 가상머신 3대·호스트 노드 등록 | 2–4 | VM 3대 9/18, 물리 호스트 합류 10/6 | 3~4주차 진행 없음 |
| K3s 클러스터 구축·노드 조인 | 4–6 | 10/30 (실습 PASS 11/11) | 10/15~10/30 클러스터 정지 |
| Docker 이미지·레지스트리·Helm | 5–7 | 10/30 | |
| Python 학습 흐름·체크포인트 저장 | 6–9 | 핵심 10/30, 데이터 로더 분리 11/7 | |
| C++ 추론 워커 (큐·배치·타임아웃) | 8–11 | 큐·배치·타임아웃 10/30, GPU 경로 11/7 | |
| MySQL 작업 상태 연동·중복 방지 | 9–11 | 11/7 (PASS 18/18) | |
| Jenkins 빌드·테스트 자동화 | 10–12 | **[진행 중]** | |
| Argo CD 배포 자동화 | 11–13 | **[진행 중]** | |
| Prometheus·Grafana 대시보드 | 12–14 | **[진행 중]** | |
| 정상 실행·중단 상황 검증 실험 | 13–16 | **[진행 중]** 준비 | 11/20 클러스터 기동 막힘(7절) |
| 결과 정리·보고서 및 발표 준비 | 15–16 | 이 문서(뼈대) | |

## 부록 B. 근거 파일

| 구분 | 파일 |
|---|---|
| 요약 | [`README.md`](../README.md), [`progress-week08.md`](progress-week08.md), [`progress-week09.md`](progress-week09.md), [`progress-week11.md`](progress-week11.md) |
| 인프라 | [`vmware-iac-handoff.md`](vmware-iac-handoff.md), [`gpu-host-join-prep.md`](gpu-host-join-prep.md), [`plan-week05-06.md`](plan-week05-06.md), [`README.md`](README.md)(스크립트 단계별 흐름) |
| 이미지 | [`image-builds.md`](image-builds.md) |
| 실행 기록 | [`labs/k3s-lab-20261030-1646.md`](labs/k3s-lab-20261030-1646.md), [`labs/train-resume-20261030-1702.md`](labs/train-resume-20261030-1702.md), [`labs/train-resume-20261030-1716.md`](labs/train-resume-20261030-1716.md), [`labs/train-resume-20261107-1253.md`](labs/train-resume-20261107-1253.md), [`labs/infer-bench-20261030-1720.md`](labs/infer-bench-20261030-1720.md), [`labs/infer-bench-20261107-1257.md`](labs/infer-bench-20261107-1257.md), [`labs/infer-gpu-bench-20261107-1246.md`](labs/infer-gpu-bench-20261107-1246.md), [`labs/job-db-20261107-1258.md`](labs/job-db-20261107-1258.md) |
| 소스 | `apps/train/`, `apps/infer/`, `charts/k3slab-workload/`, `infra/k8s/registry.yaml`, `infra/k8s/mysql.yaml`, `infra/k8s/mysql-schema.sql`, `scripts/` |
| 제안서 | 연구제안서(슬라이드 3~16번), 9주차 진행보고 |
