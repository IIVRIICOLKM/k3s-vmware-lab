# k3s-vmware-lab

VMware Workstation Pro 위에 Rocky Linux 9.8 Server VM 3대를 만들고 K3s를 구성하는 재현 가능한 로컬 연구 환경이다. 물리 데스크톱은 별도 GPU 노드이며, 게스트 VM과 달리 현재 Ubuntu 호스트 OS를 유지한다.

## 역할 분리

| 계층 | 책임 |
|---|---|
| Packer (`infra/packer`) | Rocky Linux 9.8 DVD ISO에서 `Server` 환경의 골든 VM 생성. GNOME/X11은 설치하지 않는다. |
| Terraform (`infra/terraform`) | 골든 VM을 `k3s-server`, `worker-cpu-1`, `worker-cpu-2`로 복제하고 CPU·메모리·전원·state를 관리한다. |
| Ansible (`infra/ansible`) | Rocky 호스트명·DNF 패키지·SELinux·chronyd·K3s server/agent를 구성한다. 물리 GPU 호스트는 별도 유지보수 창에서만 다룬다. |

골든 이미지는 `@^server-product-environment`를 사용한다. Minimal Install은 아니지만 `skipx`, `multi-user.target`, `gnome-shell`/Xorg 부재 검사를 통해 **GUI 없는 서버 구성**을 강제한다.

## 지금 자동화되는 범위

현재 `entry.sh`가 완성하는 범위는 **Rocky Linux VM 3대 + 기본 K3s 클러스터**다. Jenkins, Argo CD, 모니터링, MySQL, API, 전처리 애플리케이션 배포는 아직 이 저장소에 구현되어 있지 않다. 물리 GPU 호스트도 기본 실행에 자동 합류하지 않으며 시나리오 7에서 별도로 작업한다.

| 이름 | 자원 | 현재 역할 | 기본 실행에 포함 |
|---|---:|---|---|
| `k3s-server` | 2 vCPU, 3 GB | K3s 제어 노드 | 예 |
| `worker-cpu-1` | 2 vCPU, 6 GB | `platform` 라벨의 작업 노드 | 예 |
| `worker-cpu-2` | 2 vCPU, 3 GB | `app` 라벨의 작업 노드 | 예 |
| `gpu-host` | 물리 호스트 | GPU 작업용 K3s agent 후보 | 아니요. 명시적 유지보수 작업만 제공 |

## 필요한 호스트 자원과 네트워크

| 항목 | 기준 |
|---|---|
| 호스트 | Linux x86_64, VMware Workstation Pro 26.0.0 |
| 메모리 | VM 예약량 12 GB. 실행 전 가용 메모리 **14 GB 이상** 권장 |
| 저장 공간 | ISO·골든 이미지·VM 3대를 위해 데이터 경로에 **40 GB 이상** 여유 권장 |
| VMware NAT | `vmnet8`, `172.16.133.0/24` |
| 호스트 / 게이트웨이·DNS | `172.16.133.1` / `172.16.133.2` |
| DHCP 범위 | `172.16.133.128–254`; 노드 IP는 재부팅·재생성 후 바뀔 수 있음 |
| Packer 설치용 주소 | `172.16.133.10`; DHCP 범위 밖이며 빌드할 때 비어 있어야 함 |

노드 IP를 고정값으로 문서나 설정에 복사하지 않는다. 7단계가 매번 vmrest에서 현재 IP를 읽어 생성 inventory를 갱신한다.

## 경로

| 경로 | 내용 |
|---|---|
| `infra/packer/` | Rocky Kickstart, Packer HCL, 일반화 스크립트 |
| `infra/terraform/` | VMware Workstation 리소스와 provider lock |
| `infra/ansible/` | 정적/생성 inventory, 역할, playbook |
| `scripts/entry.sh` | 전체 프로비저닝 진입점. 아래 단계 스크립트를 순서대로 호출한다 |
| `scripts/` | 단계 스크립트: vmrest 기동, ISO 검증·다운로드, 사전 점검, 이미지 빌드, Terraform wrapper, 2단계 apply, Workstation UI 등록, inventory 생성, provider 스모크 테스트 |
| `docs/` | 최신 인계서와 워크플로우 다이어그램 |
| `~/.local/share/k3s-vmware-lab/images/` | 읽기 전용 골든 VMX/VMDK와 `SHA256SUMS` |
| `~/.local/share/k3s-vmware-lab/vms/` | Terraform 관리 VM |
| `~/.local/share/k3s-vmware-lab/iso-cache/` | 서명·SHA-256 검증된 Rocky ISO |
| `~/.local/share/k3s-vmware-lab/ansible-venv/` | 고정 버전 ansible-core |
| `~/.local/state/k3s-vmware-lab/terraform/` | 0600 Terraform state와 백업 |
| `~/.local/state/k3s-vmware-lab/logs/` | Packer·provider 실행 로그 |
| `~/.local/state/k3s-vmware-lab/ansible/known_hosts` | 이 클러스터 전용 SSH 호스트 키 기록 |
| `~/.config/k3s-vmware-lab/secrets/` | vmrest 인증서/자격증명, SSH 키, 콘솔 암호 해시, K3s token/kubeconfig |
| `infra/ansible/inventories/lab/.generated/terraform.yml` | 현재 VM IP로 자동 생성되는 접속 목록. Git에는 넣지 않음 |

## 고정 버전

`scripts/lib/pinned-versions.env`가 단일 기준이다.

- VMware Workstation Pro 26.0.0 build 25388281, vmrest 1.3.1
- Terraform 1.16.3, `elsudano/vmworkstation` 2.0.1
- Packer 1.16.0, `hashicorp/vmware` 2.1.6
- ansible-core 2.21.4, K3s v1.36.4+k3s1
- Rocky Linux 9.8 x86_64 DVD ISO, SHA-256 `d2bcbb64…36d01f`
- K3s SELinux policy RPM 1.6-1.el9, SHA-256 고정

`scripts/preflight.sh`는 도구 버전, provider/plugin 해시, ISO, 골든 이미지 무결성, 비밀값 권한과 Ubuntu 게스트 잔존물을 검사한다.

## 빠른 시작

사전 준비(시나리오 0)가 끝난 호스트에서 저장소 루트로 이동해 한 번만 실행한다.

```bash
scripts/entry.sh
```

처음이면 골든 이미지와 VM 3대, K3s 클러스터까지 만들고, 이미 만들어져 있으면 바뀐 것만 맞춘다. 같은 명령을 몇 번 실행해도 결과는 같다.

## `scripts/entry.sh`가 하는 일

`entry.sh`는 아래 9단계를 순서대로 실행한다. 어느 단계든 실패하면 즉시 멈추고 `FAILED at step N/9: <명령>`을 출력한다. 성공하면 마지막에 이번 실행의 단계별 소요 시간과 합계를 자동으로 보여 준다.

시간은 2026-09-18 현재 호스트의 실행 기록을 기준으로 잡았다. **Rocky ISO가 이미 캐시에 있는 상태에서 신규 클러스터 완성까지 16분**을 기준으로 단계별 시간을 배분했다. 15.2GB ISO를 처음 내려받는 시간만 네트워크 차이가 너무 커서 이 16분에서 제외한다. 재실행 시간은 정상 가동 중인 클러스터에서 직접 잰 값이다.

| 단계 | 쉬운 키워드 | 실제로 하는 일 | 신규 구축 16분 기준 | 정상 상태 재실행 |
|---:|---|---|---:|---:|
| 1 | 제어창 열기 | VMware를 제어하는 로컬 서비스 시작 | **0분 00초** | **0분 00초** |
| 2 | 설치 파일 확인 | 캐시된 Rocky ISO의 공식 서명과 파일 손상 확인 | **0분 38초** | **0분 38초** |
| 3 | 시작 전 건강검진 | 프로젝트 파일·도구·네트워크·권한·남은 용량·이미지·UI 상태 확인 | **0분 50초** | **0분 52초** |
| 4 | 기준 VM 만들기 | Rocky가 설치된 복제 원본 생성 | **11분 00초** | **0분 00초**(있으면 건너뜀) |
| 5 | VM 도구 준비 | 필요한 Terraform 확장 기능 확인 | **0분 01초** | **0분 00초** |
| 6 | VM 3대 맞추기 | VM 생성·사양 확인·전원 켜기·Workstation UI 목록 등록 | **0분 12초** | **0분 01초** |
| 7 | IP 주소 적기 | 세 VM의 현재 IP를 Ansible 목록에 반영 | **0분 26초** | **0분 00초** |
| 8 | 접속 시험 | 세 VM에 SSH로 들어갈 수 있는지 확인 | **0분 06초** | **0분 06초** |
| 9 | OS와 K3s 맞추기 | 보안·시간·네트워크 기본값과 K3s 구성 | **2분 47초** | **0분 22초** |
| **합계** |  |  | **16분 00초** | **1분 59초** |

16분 중 기준 VM 빌드가 11분으로 가장 오래 걸리며 전체의 약 69%를 차지한다. ISO 최초 다운로드는 이 표와 별도다. 2·3단계가 재실행 때도 긴 이유는 15.2GB ISO 전체를 다시 읽어 손상 여부를 확인하기 때문이다.

골든 이미지 버전은 `infra/terraform/variables.tf`의 `golden_vm_name` 기본값(`k3slab-golden-rocky98-20260918-1`)에서 읽는다. Terraform이 복제할 이미지와 빌드할 이미지가 항상 같다. 8·9단계는 `~/.local/share/k3s-vmware-lab/ansible-venv`를 활성화한 뒤 `infra/ansible`에서 실행한다.

## 사용자 시나리오

### 시나리오 0. 사전 준비 (호스트당 한 번)

`entry.sh`는 도구 설치와 비밀값 생성은 하지 않는다. 아래를 먼저 갖춘다. 빠진 것이 있으면 `entry.sh`의 1단계 또는 3단계(preflight)가 무엇이 없는지 알려 주고 멈춘다.

1. **도구**: VMware Workstation Pro 26.0.0(vmrest 1.3.1 포함), Terraform 1.16.3, Packer 1.16.0이 `PATH`에 있어야 한다. Python 3, `pip`, `jq`, `curl`, `gpg`, `openssl`, `xorriso`, `ip`, `ss`, `ssh-keygen`도 필요하다.
2. **Ansible venv**:
   ```bash
   python3 -m venv --without-pip ~/.local/share/k3s-vmware-lab/ansible-venv
   python3 -m pip --python ~/.local/share/k3s-vmware-lab/ansible-venv/bin/python install -r infra/ansible/requirements.txt
   ```
3. **디렉터리와 여유 공간**:
   ```bash
   mkdir -p ~/.local/share/k3s-vmware-lab/{images,vms,iso-cache}
   install -d -m 0700 ~/.local/state/k3s-vmware-lab/terraform ~/.config/k3s-vmware-lab/secrets
   df -h ~/.local/share/k3s-vmware-lab
   ```
   최소 40 GB 여유가 권장된다. 메모리는 `free -h`의 available 값이 14 GB 이상인지 확인한다.
4. **Workstation 설정**: GUI를 닫은 상태에서 `~/.vmware/preferences`에 `prefvmx.defaultVMPath = "/home/<사용자>/.local/share/k3s-vmware-lab/vms"`를 넣는다. `<사용자>`는 실제 Linux 사용자명으로 바꾼다. vmrest는 복제본을 이 경로에만 만든다. 프로젝트 기간 동안 버전을 고정하려면 `pref.autoSoftwareUpdatePermission = "deny"`도 설정한다.
5. **비밀값**: 먼저 비밀값 디렉터리로 이동한다. 아래 명령을 다른 디렉터리에서 실행하면 `entry.sh`가 파일을 찾지 못한다.
   ```bash
   cd ~/.config/k3s-vmware-lab/secrets
   umask 077
   ```
   - vmrest 인증서: `openssl req -x509 -newkey rsa:3072 -sha256 -days 825 -nodes -keyout vmrest.key -out vmrest.crt -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"`
   - vmrest 자격증명: `vmrest -C`로 사용자명과 비밀번호(8–12자, 대·소문자·숫자·특수문자 포함)를 등록하고, `nano vmrest.env`로 아래 파일을 만들어 같은 값을 적는다.
     ```bash
     export VMWS_USERNAME="<사용자명>"
     export VMWS_PASSWORD="<비밀번호>"
     export VMWS_ENDPOINT="https://127.0.0.1:8697/api"
     export VMWS_HTTPS="true"
     ```
   - Ansible·Packer용 SSH 키: `ssh-keygen -t ed25519 -N '' -C 'k3s-vmware-lab ansible' -f ansible_ed25519`
   - 골든 이미지 콘솔 비밀번호 해시(SSH 비밀번호 로그인은 막혀 있고 콘솔 전용): `printf "GOLDEN_CONSOLE_PASSWORD_SHA512='%s'\n" "$(openssl passwd -6)" > golden-console.env`
   - 마지막으로 `chmod 600 vmrest.env vmrest.crt vmrest.key ansible_ed25519 ansible_ed25519.pub golden-console.env`를 실행한다.
6. **프로젝트 파일 확인**: `scripts/verify-project.sh`가 필수 파일 50개, 실행 권한, 모든 Bash 문법을 검사한다. `scripts/preflight.sh`도 이 검사를 자동 호출한다.

### 시나리오 1. 처음 구축

```bash
scripts/entry.sh
```

- ISO가 준비된 상태에서는 전체 약 16분이며, 그중 골든 이미지 빌드가 11분으로 가장 오래 걸린다. 15.2GB ISO 최초 다운로드 시간은 별도다. 빌드 VM은 헤드리스로 돌아 화면에 창이 뜨지 않는다.
- 마지막 줄에 `provisioning complete: golden image …, nodes k3s-server, worker-cpu-1, worker-cpu-2`가 나오면 끝이다. 직전 출력에 세 노드가 `Ready`로 나열된다.
- kubeconfig는 `~/.config/k3s-vmware-lab/secrets/kubeconfig`(0600)에 생긴다.
- `cluster-apply.sh`가 세 노드를 공식 vmrest 등록 API로 Workstation 라이브러리에 넣는다. 따라서 **My Computer** 목록에는 골든 이미지와 `k3s-server`, `worker-cpu-1`, `worker-cpu-2`가 모두 보여야 한다. 이미 등록된 항목은 다시 만들지 않는다.

### 시나리오 2. 다시 실행하기 / 호스트 재부팅 후 복구

같은 명령을 다시 실행한다.

```bash
scripts/entry.sh
```

- 이미 가동 중이면 아무것도 바꾸지 않는다(2026-09-18 파일·UI 검사 추가 후 실측 1분 59초, Terraform `No changes`, UI 등록 `0 added`, Ansible `changed=0`).
- 호스트 재부팅 뒤처럼 vmrest가 멈추고 VM이 꺼져 있으면 vmrest를 띄우고, VM을 켜고, 새 IP로 inventory를 만든 뒤 Ansible로 상태를 확인한다(검증: 약 2분 30초, VM 3대 전원 켬, `changed=0`, 세 노드 `Ready`).

### 시나리오 3. 중간에 실패했을 때

- 출력 끝의 `FAILED at step N/9: <명령>`에서 멈춘 단계를 확인하고, 그 위의 메시지대로 원인을 고친 뒤 `scripts/entry.sh`를 다시 실행한다. 끝난 단계는 건너뛰거나 변경 없이 지나간다.
- 3단계(preflight) 실패는 `[FAIL]` 줄이 원인이다. 예를 들어 커널 업데이트 뒤 `vmmon.ko missing`이 나오면, 콘솔에서 `sudo vmware-modconfig --console --install-all`로 모듈을 다시 빌드한다(원격 작업 중에는 하지 않는다).
- 4단계는 Packer가 실패하면 출력 디렉터리를 스스로 지운다. 그러나 Packer가 끝난 뒤(SHA-256 기록·vmrest 등록)에 실패하면 이미지 디렉터리가 남아 다음 실행에서 건너뛰어진다. 이때는 이미지 파일에 쓰기 권한을 주고(`chmod u+w`) vmrest에서 삭제한 뒤, Workstation 라이브러리(`~/.vmware/inventory.vmls`)에 항목이 남았으면 정리하고 다시 실행한다.
- 3단계의 `Project files`에서 실패하면 `scripts/verify-project.sh`를 단독 실행한다. 누락 파일 이름, 실행 권한 문제 또는 Bash 문법 오류가 그대로 표시된다.
- VM이 켜지고 SSH도 되는데 Workstation **My Computer**에 노드가 안 보이면 `scripts/register-vms.sh`를 실행한다. VM 파일·전원·Terraform state는 건드리지 않고 빠진 UI 항목만 공식 vmrest API로 등록한다.
- 7단계가 `no guest IP`로 실패하면 VM이 켜져 있는지, 게스트의 open-vm-tools가 떠 있는지 확인한다.

### 시나리오 4. 일부 단계만 다시 실행

`entry.sh`를 거치지 않고 단계 스크립트를 직접 불러도 된다. Terraform은 항상 `scripts/tf.sh`로 실행한다.

```bash
scripts/tf.sh plan                 # 변경 예정 사항만 보기
scripts/register-vms.sh            # Workstation UI 목록만 다시 맞추기
scripts/render-inventory.sh        # VM IP가 바뀌었을 때
source ~/.local/share/k3s-vmware-lab/ansible-venv/bin/activate
cd infra/ansible
ansible-playbook playbooks/site.yml
```

### 시나리오 5. 클러스터 정지

Provider의 수정은 VM을 강제로 끄므로, 게스트 안에서 먼저 정상 종료한다. 아래 방식은 **잠시 끄기**다. Terraform의 목표 상태는 계속 `on`이므로 다음 `scripts/entry.sh` 실행이 세 VM을 다시 켠다.

```bash
source ~/.local/share/k3s-vmware-lab/ansible-venv/bin/activate
cd infra/ansible
ansible vms -b -B 60 -P 0 -m ansible.builtin.shell -a 'sleep 2 && systemctl poweroff'
vmrun -T ws list                   # "Total running VMs: 0"이 될 때까지 확인
```

오랫동안 꺼진 상태를 Terraform에도 기록하려면 정상 종료를 확인한 뒤 저장소 루트에서 `scripts/tf.sh apply -var power_state=off -auto-approve`를 실행한다. 다시 올릴 때는 기본값이 `on`인 `scripts/entry.sh`를 사용한다.

### 시나리오 6. 구성 변경

- **노드 CPU·메모리**: `infra/terraform/variables.tf`의 `nodes`를 고친다 → 시나리오 5로 정지 → `scripts/entry.sh`.
- **새 골든 이미지**: `variables.tf`의 `golden_vm_name` 기본값을 새 버전으로 바꾸고 `scripts/entry.sh`를 실행하면 새 이미지가 빌드된다. 기존 노드는 자동으로 바뀌지 않는다(`ignore_changes`). 노드를 새 이미지로 다시 만들려면 K3s에서 해당 노드를 `kubectl drain` 후 `kubectl delete node`로 지우고, `scripts/cluster-apply.sh -auto-approve -replace='vmworkstation_virtual_machine.node["<노드>"]'` 뒤 `scripts/entry.sh`를 실행한다. `k3s-server` 교체는 클러스터 재구성이다.
- **도구·Provider 버전 업그레이드**: `scripts/lib/pinned-versions.env`를 고치고 도구를 설치한 뒤 `scripts/provider-smoke-test.sh`를 통과시킨다. 통과하면 `PIN_VERIFIED_ON`을 갱신한다.

### 시나리오 7. 물리 GPU 호스트 합류 (콘솔 유지보수 창)

`entry.sh`는 물리 호스트를 건드리지 않는다. NVIDIA Container Toolkit을 설치한 뒤 **호스트 콘솔에서** 실행한다.

```bash
source ~/.local/share/k3s-vmware-lab/ansible-venv/bin/activate
cd infra/ansible
ansible-playbook playbooks/gpu-host.yml -e host_changes_allowed=true -K
```

### 시나리오 8. VM 3대만 완전히 지우고 다시 만들기

이 작업은 Terraform 관리 VM 3대와 그 디스크를 삭제한다. 골든 이미지, ISO, 비밀값, state 백업은 남긴다. 필요한 데이터가 VM 안에 있으면 먼저 별도 백업해야 한다.

```bash
# 먼저 시나리오 5의 정상 종료와 vmrun 목록 0대를 확인한다.
scripts/tf.sh plan -destroy
scripts/tf.sh destroy -auto-approve
scripts/entry.sh
```

`destroy` 전 state는 `~/.local/state/k3s-vmware-lab/terraform/backups/`에 자동 백업된다. 골든 이미지까지 포함한 프로젝트 완전 폐기는 실수 방지를 위해 자동화하지 않는다.

### 시나리오 9. 도구나 Provider를 업그레이드하기 전

실제 노드로 시험하지 않는다. 골든 이미지가 준비된 상태에서 유지보수 시간에 `scripts/provider-smoke-test.sh`를 실행한다. 이 스크립트는 별도의 폐기용 복제본으로 생성 → 전원 → 수정 → 삭제를 검증하며, 실행 중 vmrest를 재시작할 수 있으므로 다른 Terraform 작업과 동시에 실행하지 않는다.

## 다 끝났는지 확인하기

복잡한 진단보다 아래 여섯 가지 결과만 먼저 본다.

| 확인 질문 | 실행할 명령 | 정상 결과 |
|---|---|---|
| 소스 파일이 모두 있는가? | `scripts/verify-project.sh` | `50 required files present` |
| 시작 조건이 모두 정상인가? | `scripts/preflight.sh` | 마지막 줄이 `0 FAIL, 0 WARN` |
| 코드와 실제 VM이 같은가? | `scripts/tf.sh plan -detailed-exitcode` | `No changes`, 종료 코드 0 |
| 세 노드가 Workstation UI에 있는가? | `scripts/register-vms.sh` | `0 added, 3 already present` |
| 세 노드가 준비됐는가? | 아래 `get nodes` 명령 | 세 줄 모두 `Ready` |
| 기본 서비스가 살아 있는가? | 아래 `get pods` 명령 | 모두 `Running` 또는 `Completed` |

```bash
source ~/.local/share/k3s-vmware-lab/ansible-venv/bin/activate
cd infra/ansible
ansible k3s_server -b -m command -a '/usr/local/bin/k3s kubectl get nodes -o wide'
ansible k3s_server -b -m command -a '/usr/local/bin/k3s kubectl get pods -A -o wide'
```

`scripts/entry.sh`를 다시 실행했을 때 Terraform은 `No changes`, Ansible은 `changed=0`이면 반복 실행 안전성도 확인된 것이다.

## 문제가 생기면 어디를 볼까

| 증상 | 먼저 볼 것 | 다음 조치 |
|---|---|---|
| 프로젝트 파일 또는 VMX가 없다고 함 | `scripts/verify-project.sh`와 `scripts/tf.sh plan` | 소스 누락인지 VM 생성 실패인지 먼저 구분 |
| VM은 실행 중인데 UI 목록에 없음 | `scripts/register-vms.sh` | 빠진 항목만 등록한 뒤 Workstation 라이브러리 확인 |
| vmrest 시작/인증 실패 | `~/.local/state/k3s-vmware-lab/logs/vmrest.log` | 인증서 경로, `vmrest.env`, 8697 포트 점검 |
| 골든 이미지 빌드 실패 | `~/.local/state/k3s-vmware-lab/logs/golden-build-<이름>.log` | 로그 마지막 실패와 Packer 출력 확인. 로그는 암호 해시를 포함할 수 있어 공유 전 가림 |
| Provider 업그레이드 시험 실패 | `~/.local/state/k3s-vmware-lab/logs/provider-smoke-test-*.log` | 실제 노드에 적용하지 말고 기존 고정 버전 유지 |
| IP를 못 찾음 | `vmrun -T ws list`, VM의 `open-vm-tools` | VM 부팅 완료 후 `scripts/render-inventory.sh` 재실행 |
| SSH host key 경고 | `~/.local/state/k3s-vmware-lab/ansible/known_hosts` | 생성 스크립트가 관리하므로 시스템 `known_hosts`를 지우지 말고 inventory를 재생성 |
| VMware 콘솔이 로딩·커널 경고 화면에 머묾 | 전원을 켠 뒤 약 25초 기다려 로그인 화면이 다시 그려지는지 확인 | `bootstrap.yml`을 재실행해 `k3slab-console-login.service`와 콘솔 출력 설정을 복구. VM을 강제 종료하지 않음 |
| K3s가 안 뜸 | `systemctl status k3s` 또는 `k3s-agent`, `journalctl -u k3s*` | 해당 VM의 서비스 로그에서 첫 오류 확인 후 `site.yml` 재실행 |

`entry.sh` 자체는 별도 통합 로그 파일을 만들지 않고 현재 터미널에 단계와 실패 명령을 출력한다. 긴 작업을 보존하려면 사용자가 실행 전에 터미널 기록 기능을 켜거나 `script` 명령으로 세션을 기록한다. 비밀번호가 출력될 수 있는 Provider 디버그 모드는 켜지 않는다.

## 무엇을 백업해야 하나

| 중요도 | 대상 | 설명 |
|---|---|---|
| 필수 | Git 저장소 | 모든 재현용 소스. `.generated`, VM, ISO, 비밀값은 의도적으로 제외 |
| 필수 | `~/.config/k3s-vmware-lab/secrets/` | SSH 개인키, K3s token, kubeconfig, vmrest 인증 정보. 암호화된 저장소에만 백업 |
| 권장 | `~/.local/state/k3s-vmware-lab/terraform/` | 현재 state와 최근 30개 자동 백업. 직접 편집하지 않음 |
| 필요 시 | VM 내부 애플리케이션 데이터 | VM 삭제·재생성으로 사라질 수 있으므로 애플리케이션별 별도 백업 필요 |
| 재생성 가능 | ISO, 골든 이미지, 노드 VM | 소스와 비밀값이 있으면 다시 만들 수 있지만 시간과 다운로드 비용이 듦 |

`scripts/tf.sh`는 `apply`, `destroy`, `import`, `state`, `taint`, `untaint` 전에 state를 자동 복사하고 최신 30개만 보관한다. state 복구는 실제 VM과 기록을 어긋나게 만들 수 있으므로 VM을 조작하기 전에 백업 파일과 현재 리소스를 대조한다.

## 경로를 바꾸는 고급 설정

대부분은 기본값을 그대로 쓴다. 다음 값은 명령 앞에 환경 변수로 지정할 수 있다.

| 변수 | 기본값 | 용도 |
|---|---|---|
| `LAB_DATA_DIR` | `~/.local/share/k3s-vmware-lab` | ISO·골든 이미지·VM·Ansible venv 위치 |
| `LAB_STATE_DIR` | `~/.local/state/k3s-vmware-lab` | Terraform state·백업·로그·known_hosts 위치 |
| `LAB_CONFIG_DIR` | `~/.config/k3s-vmware-lab` | 비밀값 상위 위치 |
| `ROCKY_DOWNLOAD_BASE_URL` | 공식 Rocky 미러 | ISO 다운로드 미러 변경 |
| `BUILD_IP` | `172.16.133.10` | Packer 설치 VM의 임시 고정 IP |
| `IP_TIMEOUT_SECONDS` | `300` | 각 VM의 IP를 기다리는 최대 시간 |

경로를 바꾸면 Workstation의 `prefvmx.defaultVMPath`도 최종 `LAB_DATA_DIR/vms`와 같아야 한다. 환경 변수는 구축 도중 임의로 바꾸지 말고 처음부터 일관되게 사용한다.

## 자주 나오는 말, 쉬운 뜻

| 문서의 용어 | 이 README에서 생각할 뜻 |
|---|---|
| 골든 이미지 | VM 3대를 찍어 내는 **복제 원본** |
| vmrest | VMware를 명령줄에서 움직이는 **로컬 제어창** |
| Packer | Rocky를 자동 설치해 복제 원본을 만드는 **이미지 제작 도구** |
| Provider | Terraform이 VMware와 대화하게 해 주는 **확장 기능** |
| Terraform | VM 개수·사양·전원을 맞추는 **VM 상태 관리자** |
| Ansible | VM 안의 설정과 K3s를 맞추는 **자동 설정 도구** |
| K3s | 여러 서버를 한 묶음으로 운영하는 가벼운 **Kubernetes 배포판** |
| kubeconfig | `kubectl`이 어느 클러스터에 어떤 권한으로 접속할지 담은 **접속 파일** |
| inventory | Ansible이 접속할 VM 이름과 IP를 적은 **접속 목록** |
| state | Terraform이 마지막으로 관리한 내용을 기억하는 **상태 기록** |
| SELinux | K3s 프로세스가 허용된 범위에서만 동작하게 하는 **OS 보안 장치** |

## 복제 원본은 이렇게 만든다

- **설치 파일**: Rocky 9.8 DVD ISO를 받고 공식 서명과 파일 지문을 확인한다.
- **자동 설치**: 사람이 화면을 클릭하는 대신 답안 파일(Kickstart)로 Server 환경을 설치한다.
- **화면 환경 제외**: 서버에 필요 없는 GNOME/X11은 넣지 않는다. 부팅 후에도 텍스트 서버 모드인지 확인한다.
- **복제 준비**: 첫 부팅 때 각 VM이 자기 IP, 시스템 ID, SSH 키를 새로 만들도록 원본의 고정값을 비운다.
- **원본 보호**: 완성 파일의 지문을 기록하고 읽기 전용으로 잠근다. 기존 원본은 수정하지 않고 새 버전을 만든다.

## VM 안에서 자동으로 맞추는 값

| 쉬운 키워드 | 자동으로 맞추는 내용 |
|---|---|
| 보안 | SELinux를 켠 상태로 유지하고 K3s용 보안 규칙을 설치 |
| 시간 | 세 VM의 시계를 `chronyd`로 동기화 |
| 네트워크 | 내부 NAT망을 사용하고 K3s 통신에 필요한 커널 설정 적용 |
| 방화벽 | K3s의 RHEL 계열 권고에 따라 VM 내부 `firewalld` 중지 |
| 메모리 | 스왑을 만들지 않고 실제로 0인지 확인 |
| 클러스터 | 서버 1대와 작업 노드 2대를 구성하고 모두 `Ready`가 될 때까지 대기 |

## 운영할 때 꼭 지킬 것

1. 평소에는 `scripts/entry.sh`만 실행한다. Terraform을 따로 쓸 때도 반드시 `scripts/tf.sh`를 거친다.
2. CPU나 메모리를 바꾸기 전에는 시나리오 5처럼 VM 안에서 먼저 정상 종료한다. 이 Provider는 변경할 때 VM을 강제로 끌 수 있다.
3. Terraform이 관리하는 VM을 Workstation GUI에서 복제·이름 변경·삭제하지 않는다. UI에서 목록만 빠졌다면 VM을 새로 만들지 말고 `scripts/register-vms.sh`로 등록을 복구한다.
4. 복제 원본을 수정하지 않는다. 바꿀 내용이 있으면 새 버전 이름으로 다시 만든다.
5. Provider의 디버그 모드를 켜지 않는다. 로그에 vmrest 비밀번호가 노출될 수 있다.
6. SSH 키, 비밀번호, K3s 접속 파일은 저장소 밖 `~/.config/k3s-vmware-lab/secrets/`에만 둔다.
7. 물리 GPU 호스트 작업은 원격 세션에서 하지 않는다. `gpu-host.yml`은 콘솔 유지보수 시간에만 실행한다.
8. DHCP로 받은 현재 노드 IP를 설정 파일에 고정하지 않는다. IP가 바뀌면 `scripts/render-inventory.sh`를 실행한다.
9. Terraform state나 `~/.vmware/inventory.vmls`를 평소에 직접 편집하지 않는다. UI 등록은 공식 vmrest API를 호출하는 스크립트에 맡긴다.
10. 커밋·이관 전 `scripts/verify-project.sh`와 `git status --short`로 필수 파일 누락과 미추적 소스를 확인한다.

Provider API, 파일 해시, SELinux 컨텍스트 같은 상세 근거가 필요하면 [기술 인계서](docs/vmware-iac-handoff.md)를 본다. 전체 흐름은 [워크플로우 다이어그램](docs/vmware-workstation-iac-workflow-2560x1440.png)에서 한눈에 확인할 수 있다.
