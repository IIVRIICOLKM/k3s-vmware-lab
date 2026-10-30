# 5~6주차 작업 목록 (2026-10-05 ~ 10-18)

연구제안서 「7. 구현 일정」과 2026-10-05 기준 저장소·호스트 상태를 비교해서, 이번 주와 다음 주에 해야 할 일을 정리했다.

- **주차 계산:** 2주차 진행보고(2026-09-18)가 들어 있는 주를 2주차로 보고, 9/7 주를 1주차로 셌다.
  - 이번 주(10/5~10/11)는 **5주차**, 다음 주(10/12~10/18)는 **6주차**다. 10/9(금)는 한글날이다.
  - 학기 시작일(9/1) 기준으로 세면 한 주씩 밀려 6~7주차가 되지만, 아래 목록은 그대로 해당한다.
- **3~4주차(9/21~10/4)는 진행이 없었다.** 그래서 2~4주차 항목 일부가 밀려 있다.

## 한눈에 보기

| 일정 항목 | 계획 주차 | 현재 상태 (10/5) | 이번 2주 목표 |
|---|---|---|---|
| 요구사항 정리·전체 구성도 설계 | 1–2 | 완료 | — |
| 가상머신 3대·호스트 노드 등록 | 2–4 | **완료** (10/6 물리 호스트 합류) | — |
| K3s 클러스터 구축·노드 조인 | 4–6 | VM 3노드 Ready. 제안서 8번 실습 항목은 시작 전 | 4노드 Ready, 실습 5개 결과 기록 (**6주차 마감**) |
| Docker 이미지·레지스트리·Helm | 5–7 | 시작 전 (호스트에 Docker 29.6.1만 있음) | 레지스트리 운영, 첫 이미지 pull 확인, Helm 차트 골격 |
| Python 학습 흐름·체크포인트 저장 | 6–9 | 시작 전 | 6주차 착수: 학습 스크립트 골격, 체크포인트 저장·재개 |

Jenkins(10–12주), Argo CD(11–13주), Prometheus·Grafana(12–14주), MySQL(9–11주), C++ 추론 워커(8–11주)는 아직 할 차례가 아니다.

## 0. 재개 전 점검 (5주차 첫날)

2026-10-05에 읽기 전용으로 확인한 상태는 다음과 같다.

- **커널이 바뀌었다.** 7.0.0-31에서 7.0.0-34로 올라갔다.
  - 10/1 부팅 때 `vmware.service`가 `Virtual machine monitor - failed`로 실패한 기록이 남아 있다. 인계서 위험 #1과 같은 증상이다.
  - 지금은 7.0.0-34용 `vmmon.ko`·`vmnet.ko`가 빌드·로드돼 있다. vmnet8의 DHCP·NAT 데몬과 VM 3대도 실행 중이라 복구된 것으로 보인다.
  - systemd의 `failed` 표시는 그때 남은 기록이다.
- **vmrest는 꺼져 있다.** 재부팅 뒤에는 원래 꺼져 있다.
- **GPU 관련 도구:** NVIDIA 드라이버는 580.178.04(RTX 3090 인식)다. `nvidia-ctk`, `kubectl`, `helm`은 설치돼 있지 않다.
- **Docker:** 29.6.1이 설치돼 있지만 현재 사용자가 `docker` 그룹에 속해 있지 않다.

할 일:

- [x] (10/6 완료: 2m53s, VM 3대를 꺼진 상태에서 다시 켜고 Ansible `changed=0`) `scripts/entry.sh`를 실행해 9단계가 모두 통과하는지 본다. Terraform `No changes`, Ansible `changed=0`이 나와야 한다(약 2분).
- [x] (10/6 완료: 3대 Ready) 노드 상태 확인:
  ```bash
  source ~/.local/share/k3s-vmware-lab/ansible-venv/bin/activate
  cd infra/ansible
  ansible k3s_server -b -m ansible.builtin.command -a '/usr/local/bin/k3s kubectl get nodes -o wide'
  ```
- [x] (10/30 브랜치 `week08-catchup`에 커밋, push는 직접) 쉬는 동안 바뀐 작업을 커밋한다. 스크립트 14개의 한국어 주석이 아직 커밋 전이다. 추적되지 않은 `outnodes.json`은 커밋에서 빼거나 지운다.
- [x] (상세 README(로컬·Notion) 시나리오 3과 `preflight.sh` WARN으로 안내. 10/15에 실제로 다시 발생해 콘솔 재빌드로 복구) 다음 커널 업데이트에 대비한다. `preflight.sh`가 "newest installed kernel ... has no vmmon.ko"라는 WARN을 내면, 재부팅 전에 **콘솔에서** `sudo vmware-modconfig --console --install-all`을 실행한다.

## 1. [밀림] 물리 GPU 호스트 K3s 합류 — 5주차

제안서의 "호스트 노드 등록"(2–4주)과 "노드 조인"(4–6주)을 마무리하는 작업이다.

10/6에 저장소 준비를 마쳤다. 남은 것은 **호스트 콘솔에서 명령 하나를 실행하는 것**뿐이다(sudo 비밀번호 필요).

원격 접속 중에는 하지 않는다. 패키지, 방화벽, NetworkManager, k3s-agent가 호스트 네트워크를 바꾸기 때문이다. 자세한 내용은 `docs/gpu-host-join-prep.md`에 있다.

- [x] 저장소 반영 (10/6)
  - `gpu_host_prep` 역할: toolkit 1.20.1-1 고정 설치, NetworkManager 제외 설정, ufw 규칙
  - k3s 역할: Ubuntu 호환(`restorecon` 조건), 노드 IP·flannel을 vmnet8로 고정, `vmware.service` 뒤에 시작
  - `infra/k8s/`의 device plugin v0.20.1과 스모크 테스트 Job. RuntimeClass `nvidia`는 K3s가 기본 제공해서 만들 필요가 없다
  - 검증한 것:
    - 플래그 없이 실행하면 sudo 전에 멈춘다
    - 렌더링 값이 맞다
    - apt 모의 설치가 성공한다
    - 매니페스트가 서버 dry-run을 통과한다
    - VM 쪽은 `changed=0`이다
- [x] (10/6 완료) **콘솔에서 실행한다.**
  ```bash
  cd ~/Projects/k3s-vmware-lab
  source ~/.local/share/k3s-vmware-lab/ansible-venv/bin/activate
  cd infra/ansible
  ansible-playbook playbooks/gpu-host.yml -e host_changes_allowed=true -K
  ```
  - 이 명령이 하는 일: toolkit 설치 → NetworkManager·ufw 설정 → 합류 → Ready 대기 → device plugin 배포 → `nvidia.com/gpu` 확인 → 스모크 테스트(`nvidia-smi`와 DNS)
- [x] (10/6 완료) 결과 확인: `get nodes`에서 4대 Ready, gpu-host INTERNAL-IP가 172.16.133.1, `nvidia.com/gpu: 1`, 스모크 테스트 출력에 RTX 3090
- [x] (상세 README(로컬·Notion) "운영할 때 꼭 지킬 것" 11번) 운영 규칙을 메모한다. 호스트가 노드가 되면 게임 같은 데스크톱 GPU 사용과 학습 파드가 24 GB VRAM을 나눠 쓴다. 실험 중에는 게임을 하지 않는다.

## 2. K3s 실습 5개 — 6주차 마감 (제안서 8번 슬라이드)

| 실습 | 작업 | 확인 기준 |
|---|---|---|
| 노드 조인 | 1번 작업 | `get nodes`에서 4대 Ready |
| 작업 배치 | 학습 파드에 `nodeSelector: k3slab.io/role=gpu`와 `nvidia.com/gpu: 1` 요청 지정 | 학습 파드가 gpu-host에만 뜬다 |
| 복제본 조정 | 테스트용 API 디플로이먼트(`k3slab.io/role=app`)의 replicas를 1에서 3으로 | 요청이 세 파드로 나뉘어 들어간다 |
| 파드 재시작 | 실행 중인 파드를 강제 삭제 | 새 파드가 자동으로 뜨고, 재시작 횟수가 기록된다 |
| 노드 중단 | worker-cpu-2를 강제 종료 | 작업이 남은 노드로 옮겨진다 |

- **노드 중단 실험 명령이 제안서와 다르다.** 제안서는 `virsh`(KVM) 기준으로 적혀 있지만 이 환경은 VMware다.
  ```bash
  vmrun -T ws stop ~/.local/share/k3s-vmware-lab/vms/worker-cpu-2/worker-cpu-2.vmx hard
  ```
  - 기본 설정에서는 노드가 NotReady가 된 뒤 파드가 다른 노드로 옮겨지기까지 약 5분이 걸린다. not-ready/unreachable toleration이 300초이기 때문이다.
  - 실험이 끝나면 `scripts/entry.sh`로 원래 상태를 되돌린다. 재부팅 복구와 같은 경로다.
  - Terraform이 관리하는 VM이므로 GUI에서 삭제하거나 이름을 바꾸지 않는다.
- [x] (10/30, `docs/labs/k3s-lab-20261030-1646.md`, PASS 11/11) 실습마다 실행한 명령, 출력, 걸린 시간을 `docs/`에 기록한다. 제안서 검증 계획의 기록 방식(명령 기록·상태·화면)을 따른다.

## 3. Docker 이미지·레지스트리·Helm — 5주차 착수, 7주차 마감

- [x] (10/25 helm 4.3.1 / kubectl은 k3s 링크. Docker는 쓰지 않고 클러스터 안 Kaniko로 빌드) **호스트 도구를 준비한다.**
  - `kubectl`과 `helm`을 설치한다. 프로젝트 규칙대로 `scripts/lib/pinned-versions.env`에 버전을 고정하고 `preflight.sh`에 버전 검사를 추가한다.
  - kubeconfig는 이미 `~/.config/k3s-vmware-lab/secrets/kubeconfig`에 있다.
  - Docker 권한 방식은 직접 정한다. 시스템 설정 변경이다.
    - `docker` 그룹 추가(`sudo usermod -aG docker $USER`, 다시 로그인 필요)
    - 또는 rootless Docker
- [x] (10/30 배포: worker-cpu-1, 고정 ClusterIP 10.43.0.50 — 표의 A·B 대신 이 방식으로 DHCP 문제와 호스트 변경을 둘 다 피함) **레지스트리 위치를 정하고 배포한다.** 제안서에는 "연구실 내부 레지스트리"라고만 돼 있다.

  | 안 | 장점 | 단점 |
  |---|---|---|
  | A. 호스트의 vmnet8 주소(`172.16.133.1:5000`)에서 Docker `registry:2` 실행 | 주소가 고정이라 DHCP 문제가 없다. 이미지를 빌드하는 곳과 같다 | 클러스터 밖에 있다. 호스트 서비스가 하나 늘어난다(콘솔에서 작업) |
  | B. worker-cpu-1에 Deployment + PVC + NodePort | 클러스터 안에서 관리된다 | 노드 IP가 DHCP라 주소 고정 작업이 필요하다(인계서 위험 #5). VM을 다시 만들 때 데이터를 주의해야 한다 |

  - 추천은 **A**다. 다만 vmnet8 주소에만 바인딩해서 LAN에 노출되지 않게 한다.
  - HTTP로 운영하면 호스트 Docker에 `insecure-registries` 설정이 필요하다. TLS로 운영하면 인증서를 모든 노드에 배포해야 한다.
- [x] (10/30) 노드 4대 모두에 `/etc/rancher/k3s/registries.yaml`을 배포하는 작업을 Ansible 역할에 추가하고, k3s를 재시작한다.
- [x] (10/30 `train-worker:v0.3`, `infer-worker:v0.1`. v0.1·v0.2는 결함으로 삭제, `docs/image-builds.md`) **첫 이미지를 만든다.**
  - 학습용 Dockerfile을 작성한다. 제안서 9번 예시는 `python:3.11 + torch 2.x`다.
  - GPU 학습용이면 CUDA가 포함된 PyTorch 베이스 이미지를 쓴다. CUDA 버전은 `nvidia-smi` 상단의 CUDA Version 이하로 맞춘다.
  - 빌드 → 태그 → push → 클러스터에서 pull까지 확인한다. 태그 규칙은 `train-worker:v0.1`처럼 정한다.
- [x] (`charts/k3slab-workload`, 학습·추론 values 모두 lint 통과) **Helm 차트 골격을 만든다.**
  - 학습용·추론용 values 파일을 둔다. 제안서 5번 슬라이드의 "실행 템플릿"에 해당한다.
  - values 항목: 이미지 태그, 모델 버전, 자원 요청량(GPU 1), replicas, 큐 크기
  - `helm lint`와 `helm template`이 통과해야 한다.
- [x] (태그 불변 + 빌드마다 git 커밋·digest·폴더 해시를 `docs/image-builds.md`에 기록) Dockerfile, 이미지 태그, values 파일을 한 묶음으로 기록하는 규칙을 정한다(제안서 9번).

## 4. Python 학습 흐름·체크포인트 저장 — 6주차 착수, 9주차 마감

- [x] (시드 고정 합성 10클래스 데이터) 작은 예제 모델(MNIST/CIFAR 수준)로 학습 스크립트 골격을 만든다. 인자는 `job_id`, `model_version`, `epochs`, `checkpoint_dir`이다.
- [x] 에폭마다 체크포인트를 저장한다. 시작할 때 마지막 체크포인트가 있으면 거기서부터 이어서 학습한다(제안서 11번의 `checkpoint_path`·재개).
- [x] (10/30 cuda 확인) Helm values로 K8s Job을 만들어 gpu-host에서 실행한다.
- [x] (gpu-host hostPath `/var/lib/k3slab/checkpoints/<job-id>/`) 체크포인트 저장 위치를 정한다. 파드가 죽어도 남아야 한다.
  - gpu-host의 hostPath
  - 또는 PVC
- [x] (10/30 `docs/labs/train-resume-20261030-1716.md`, PASS 6/6) 학습 도중 파드를 삭제하고 다시 실행했을 때 이어서 학습되는지 확인한다. 검증 계획 ②의 "학습 중단" 시나리오 예행연습이다.
- MySQL 연동(9–11주) 전까지는 상태를 로그나 파일로만 남긴다. 출력 형식은 나중에 DB 컬럼(`job_id`, `status`, `checkpoint_path`, `updated_at`)에 바로 넣을 수 있게 맞춰 둔다.

## 5. 보고와 문서

- [x] (`docs/progress-week08.md` "일정 재조정") 5주차 진행보고에 일정 재조정을 적는다. 3~4주차에 진행이 없었던 점, 호스트 합류가 늦어진 점, 그 영향(6주차에 K3s 실습과 레지스트리를 같이 진행)을 쓴다.
- [x] (`docs/progress-week08.md` "제안서 대비 바뀐 점", 문구 확인 필요) 하이퍼바이저 변경 근거를 1~2줄로 정리한다. 제안서는 KVM/libvirt인데 구현은 VMware Workstation이다. 노드 중단 실험 명령이 `virsh`에서 `vmrun`으로 바뀐 것도 함께 적는다.
- [x] (Workstation 화면에서 Remove로 정리, 직접 편집 금지와 일치) 상세 README(로컬·Notion) 시나리오 3을 정리한다. `inventory.vmls`를 직접 정리하라는 안내를 "`scripts/register-vms.sh` 또는 vmrest API로 정리"로 바꾸면, "운영할 때 꼭 지킬 것" 9번("평소에 직접 편집하지 않는다")과 어긋나지 않는다.

## 순서 제안

| 주 | 할 일 |
|---|---|
| 5주차 (10/5~10/11, 10/9 휴일) | 0번 재개 점검·커밋 → 1번 GPU 호스트 합류 + device plugin → 2번 실습 중 노드 조인·작업 배치·복제본·파드 재시작 → 3번 도구 설치·레지스트리 방식 결정 |
| 6주차 (10/12~10/18) | 2번 노드 중단 실험과 결과 기록(**K3s 항목 마감**) → 3번 레지스트리 배포·`registries.yaml`·첫 이미지 push → Helm 골격 → 4번 학습 스크립트와 체크포인트 재개 |

## 2주 뒤 완료 기준

- [x] (10/6) 4노드가 Ready이고, gpu-host에 `nvidia.com/gpu: 1`이 표시된다.
- [x] (10/30) K3s 실습 5개의 결과가 `docs/`에 기록돼 있다.
- [x] (10/30) 내부 레지스트리의 이미지를 클러스터가 pull한다. Helm 차트가 `lint`를 통과한다.
- [x] (10/30) 학습 Job이 중간에 끊겨도 마지막 체크포인트부터 다시 시작한다.

## 7주차 진행 현황 (2026-10-25 기준)

**10/15부터 VM이 꺼져 있다.** 커널 7.0.0-38로 재부팅하면서 VMware 모듈(`vmmon`·`vmnet`)이 없어졌고, `vmware.service`가 실패했다(인계서 위험 #1, 두 번째). 클러스터가 필요한 작업은 모두 준비만 해 두고 실행을 기다린다.

| 일정 항목 | 상태 |
|---|---|
| K3s 실습 5개 (4–6주) | 준비 완료. `scripts/k3s-lab.sh`, `infra/k8s/labs/`, 상세 README(로컬·Notion) 시나리오 10. 클러스터 복구 뒤 실행 |
| 레지스트리 (5–7주) | 준비 완료. `infra/k8s/registry.yaml`: worker-cpu-1, 고정 ClusterIP 10.43.0.50. 노드 `registries.yaml`은 `k3s_node` 역할에 추가 |
| 이미지 빌드 (5–7주) | 준비 완료. `scripts/image-build.sh`: Kaniko를 gpu-host에서 실행, 태그 불변, `docs/image-builds.md`에 기록 |
| Helm (5–7주) | **완료.** v4.3.1을 `~/.local/bin`에 설치(SHA-256 검증, preflight에서 버전 검사). `charts/k3slab-workload` 학습·추론 values 모두 `helm lint` 통과 |
| Python 학습·체크포인트 (6–9주) | 스크립트 **완료·로컬 검증.** `apps/train/train.py`, `Dockerfile`. 클러스터 Job 실행은 복구 뒤 |

`train.py` 로컬 검증 (CPU, PyTorch 2.14.1):

- 4 에폭 학습 후 `DONE`. 같은 작업 번호로 다시 요청하면 학습하지 않고 기존 상태를 돌려준다.
- 3 에폭 1번째 스텝에서 SIGTERM을 보내면 체크포인트를 저장하고 종료한다(exit 143). 다시 실행하면 그 지점부터 이어서 학습해 `DONE`이 된다.
- 끊었다가 이어서 학습한 모델이 한 번에 끝까지 학습한 모델과 **비트 단위로 같다.** 옵티마이저 상태와 난수 상태까지 복원된다는 뜻이다.

정한 운영 규칙:

- gpu-host에 `nvidia.com/gpu=present:NoSchedule` taint를 건다(제안서 8번: 가장 부족한 자원이 배치 기준).
- 이미지 태그는 불변이다.
- 빌드는 클러스터 안에서 한다(호스트 Docker 미사용).

복구 순서 (콘솔, sudo):

```bash
sudo vmware-modconfig --console --install-all
sudo systemctl restart vmware.service
cd ~/Projects/k3s-vmware-lab && scripts/entry.sh               # VM 3대 켜기 + VM에 registries.yaml
cd infra/ansible && source ~/.local/share/k3s-vmware-lab/ansible-venv/bin/activate
ansible-playbook playbooks/gpu-host.yml -e host_changes_allowed=true -K   # gpu-host에 registries.yaml + taint 설정
```

그다음 순서: 레지스트리 배포 → `k3s-lab.sh` → `image-build.sh apps/train train-worker v0.1` → 학습 Job과 중단·재개 시험.

## 8주차 진행 현황 (2026-10-30)

10/30에 VMware를 복구한 뒤, 밀린 4–7주차 항목과 8주차 착수분을 모두 실행·검증했다. 요약과 진행보고용 문구는 `docs/progress-week08.md`에 있다.

| 항목 | 결과 |
|---|---|
| K3s 실습 5개 | PASS 11/11 (`docs/labs/k3s-lab-20261030-1646.md`) |
| 레지스트리 | worker-cpu-1, 10.43.0.50, 노드 4대에서 pull 확인 |
| 이미지 | `train-worker:v0.3`, `infer-worker:v0.1` (v0.1·v0.2 학습 이미지는 결함으로 삭제, `docs/image-builds.md`) |
| 학습 중단·재개 (GPU) | PASS 6/6 (`docs/labs/train-resume-20261030-1716.md`). 첫 시도 실패와 원인은 `train-resume-20261030-1702.md` |
| 추론 워커 (8주차 착수) | 배치 1 vs 8: 8.05s vs 1.31s, 큐 초과 207/300 즉시 429 (`docs/labs/infer-bench-20261030-1720.md`) |
