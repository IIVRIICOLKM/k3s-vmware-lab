# k3s-vmware-lab

VMware Workstation Pro 위에 Rocky Linux 9.8 Server VM 3대를 만들고 K3s를 구성하는 재현 가능한 로컬 연구 환경이다. 물리 데스크톱은 별도 GPU 노드이며, 게스트 VM과 달리 현재 Ubuntu 호스트 OS를 유지한다.

## 역할 분리

| 계층 | 책임 |
|---|---|
| Packer (`infra/packer`) | Rocky Linux 9.8 DVD ISO에서 `Server` 환경의 골든 VM 생성. GNOME/X11은 설치하지 않는다. |
| Terraform (`infra/terraform`) | 골든 VM을 `k3s-server`, `worker-cpu-1`, `worker-cpu-2`로 복제하고 CPU·메모리·전원·state를 관리한다. |
| Ansible (`infra/ansible`) | Rocky 호스트명·DNF 패키지·SELinux·chronyd·K3s server/agent를 구성한다. 물리 GPU 호스트는 별도 유지보수 창에서만 다룬다. |

골든 이미지는 `@^server-product-environment`를 사용한다. Minimal Install은 아니지만 `skipx`, `multi-user.target`, `gnome-shell`/Xorg 부재 검사를 통해 **GUI 없는 서버 구성**을 강제한다.

## 경로

| 경로 | 내용 |
|---|---|
| `infra/packer/` | Rocky Kickstart, Packer HCL, 일반화 스크립트 |
| `infra/terraform/` | VMware Workstation 리소스와 provider lock |
| `infra/ansible/` | 정적/생성 inventory, 역할, playbook |
| `scripts/entry.sh` | 전체 프로비저닝 진입점. 아래 단계 스크립트를 순서대로 호출한다 |
| `scripts/` | 단계 스크립트: vmrest 기동, ISO 검증·다운로드, 사전 점검, 이미지 빌드, Terraform wrapper, 2단계 apply, inventory 생성, provider 스모크 테스트 |
| `docs/` | 최신 인계서와 워크플로우 다이어그램 |
| `~/.local/share/k3s-vmware-lab/images/` | 읽기 전용 골든 VMX/VMDK와 `SHA256SUMS` |
| `~/.local/share/k3s-vmware-lab/vms/` | Terraform 관리 VM |
| `~/.local/share/k3s-vmware-lab/iso-cache/` | 서명·SHA-256 검증된 Rocky ISO |
| `~/.local/share/k3s-vmware-lab/ansible-venv/` | 고정 버전 ansible-core |
| `~/.local/state/k3s-vmware-lab/terraform/` | 0600 Terraform state와 백업 |
| `~/.local/state/k3s-vmware-lab/logs/` | Packer·provider 실행 로그 |
| `~/.config/k3s-vmware-lab/secrets/` | vmrest 인증서/자격증명, SSH 키, 콘솔 암호 해시, K3s token/kubeconfig |

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
| 3 | 시작 전 건강검진 | 도구·네트워크·권한·남은 용량·이미지 상태 확인 | **0분 50초** | **0분 50초** |
| 4 | 기준 VM 만들기 | Rocky가 설치된 복제 원본 생성 | **11분 00초** | **0분 00초**(있으면 건너뜀) |
| 5 | VM 도구 준비 | 필요한 Terraform 확장 기능 확인 | **0분 01초** | **0분 01초** |
| 6 | VM 3대 맞추기 | VM 생성·사양 확인·전원 켜기 | **0분 12초** | **0분 00초** |
| 7 | IP 주소 적기 | 세 VM의 현재 IP를 Ansible 목록에 반영 | **0분 26초** | **0분 01초** |
| 8 | 접속 시험 | 세 VM에 SSH로 들어갈 수 있는지 확인 | **0분 06초** | **0분 06초** |
| 9 | OS와 K3s 맞추기 | 보안·시간·네트워크 기본값과 K3s 구성 | **2분 47초** | **0분 20초** |
| **합계** |  |  | **16분 00초** | **1분 56초** |

16분 중 기준 VM 빌드가 11분으로 가장 오래 걸리며 전체의 약 69%를 차지한다. ISO 최초 다운로드는 이 표와 별도다. 2·3단계가 재실행 때도 긴 이유는 15.2GB ISO 전체를 다시 읽어 손상 여부를 확인하기 때문이다.

골든 이미지 버전은 `infra/terraform/variables.tf`의 `golden_vm_name` 기본값(`k3slab-golden-rocky98-20260918-1`)에서 읽는다. Terraform이 복제할 이미지와 빌드할 이미지가 항상 같다. 8·9단계는 `~/.local/share/k3s-vmware-lab/ansible-venv`를 활성화한 뒤 `infra/ansible`에서 실행한다.

## 사용자 시나리오

### 시나리오 0. 사전 준비 (호스트당 한 번)

`entry.sh`는 도구 설치와 비밀값 생성은 하지 않는다. 아래를 먼저 갖춘다. 빠진 것이 있으면 `entry.sh`의 1단계 또는 3단계(preflight)가 무엇이 없는지 알려 주고 멈춘다.

1. **도구**: VMware Workstation Pro 26.0.0(vmrest 1.3.1 포함), Terraform 1.16.3, Packer 1.16.0이 `PATH`에 있어야 한다. `jq`, `curl`, `gpg`, `openssl`, `xorriso`도 필요하다.
2. **Ansible venv**:
   ```bash
   python3 -m venv --without-pip ~/.local/share/k3s-vmware-lab/ansible-venv
   python3 -m pip --python ~/.local/share/k3s-vmware-lab/ansible-venv/bin/python install -r infra/ansible/requirements.txt
   ```
3. **디렉터리**:
   ```bash
   mkdir -p ~/.local/share/k3s-vmware-lab/{images,vms,iso-cache} ~/.local/state/k3s-vmware-lab/terraform ~/.config/k3s-vmware-lab/secrets
   chmod 700 ~/.local/state/k3s-vmware-lab/terraform ~/.config/k3s-vmware-lab/secrets
   ```
4. **Workstation 설정**: GUI를 닫은 상태에서 `~/.vmware/preferences`에 `prefvmx.defaultVMPath = "/home/<사용자>/.local/share/k3s-vmware-lab/vms"`를 넣는다. vmrest는 복제본을 이 경로에만 만든다. 프로젝트 기간 동안 버전을 고정하려면 `pref.autoSoftwareUpdatePermission = "deny"`도 설정한다.
5. **비밀값** (`~/.config/k3s-vmware-lab/secrets/`, 모든 파일 0600):
   - vmrest 인증서: `openssl req -x509 -newkey rsa:3072 -sha256 -days 825 -nodes -keyout vmrest.key -out vmrest.crt -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"`
   - vmrest 자격증명: `vmrest -C`로 사용자명과 비밀번호(8–12자, 대·소문자·숫자·특수문자 포함)를 등록하고, 같은 값을 `vmrest.env`에 적는다.
     ```bash
     export VMWS_USERNAME="<사용자명>"
     export VMWS_PASSWORD="<비밀번호>"
     export VMWS_ENDPOINT="https://127.0.0.1:8697/api"
     export VMWS_HTTPS="true"
     ```
   - Ansible·Packer용 SSH 키: `ssh-keygen -t ed25519 -N '' -C 'k3s-vmware-lab ansible' -f ansible_ed25519`
   - 골든 이미지 콘솔 비밀번호 해시(SSH 비밀번호 로그인은 막혀 있고 콘솔 전용): `printf "GOLDEN_CONSOLE_PASSWORD_SHA512='%s'\n" "$(openssl passwd -6)" > golden-console.env`

### 시나리오 1. 처음 구축

```bash
scripts/entry.sh
```

- ISO가 준비된 상태에서는 전체 약 16분이며, 그중 골든 이미지 빌드가 11분으로 가장 오래 걸린다. 15.2GB ISO 최초 다운로드 시간은 별도다. 빌드 VM은 헤드리스로 돌아 화면에 창이 뜨지 않는다.
- 마지막 줄에 `provisioning complete: golden image …, nodes k3s-server, worker-cpu-1, worker-cpu-2`가 나오면 끝이다. 직전 출력에 세 노드가 `Ready`로 나열된다.
- kubeconfig는 `~/.config/k3s-vmware-lab/secrets/kubeconfig`(0600)에 생긴다.

### 시나리오 2. 다시 실행하기 / 호스트 재부팅 후 복구

같은 명령을 다시 실행한다.

```bash
scripts/entry.sh
```

- 이미 가동 중이면 아무것도 바꾸지 않는다(2026-09-18 실측 1분 56초, Terraform `No changes`, Ansible `changed=0`).
- 호스트 재부팅 뒤처럼 vmrest가 멈추고 VM이 꺼져 있으면 vmrest를 띄우고, VM을 켜고, 새 IP로 inventory를 만든 뒤 Ansible로 상태를 확인한다(검증: 약 2분 30초, VM 3대 전원 켬, `changed=0`, 세 노드 `Ready`).

### 시나리오 3. 중간에 실패했을 때

- 출력 끝의 `FAILED at step N/9: <명령>`에서 멈춘 단계를 확인하고, 그 위의 메시지대로 원인을 고친 뒤 `scripts/entry.sh`를 다시 실행한다. 끝난 단계는 건너뛰거나 변경 없이 지나간다.
- 3단계(preflight) 실패는 `[FAIL]` 줄이 원인이다. 예를 들어 커널 업데이트 뒤 `vmmon.ko missing`이 나오면, 콘솔에서 `sudo vmware-modconfig --console --install-all`로 모듈을 다시 빌드한다(원격 작업 중에는 하지 않는다).
- 4단계는 Packer가 실패하면 출력 디렉터리를 스스로 지운다. 그러나 Packer가 끝난 뒤(SHA-256 기록·vmrest 등록)에 실패하면 이미지 디렉터리가 남아 다음 실행에서 건너뛰어진다. 이때는 이미지 파일에 쓰기 권한을 주고(`chmod u+w`) vmrest에서 삭제한 뒤, Workstation 라이브러리(`~/.vmware/inventory.vmls`)에 항목이 남았으면 정리하고 다시 실행한다.
- 7단계가 `no guest IP`로 실패하면 VM이 켜져 있는지, 게스트의 open-vm-tools가 떠 있는지 확인한다.

### 시나리오 4. 일부 단계만 다시 실행

`entry.sh`를 거치지 않고 단계 스크립트를 직접 불러도 된다. Terraform은 항상 `scripts/tf.sh`로 실행한다.

```bash
scripts/tf.sh plan                 # 변경 예정 사항만 보기
scripts/render-inventory.sh        # VM IP가 바뀌었을 때
source ~/.local/share/k3s-vmware-lab/ansible-venv/bin/activate
cd infra/ansible
ansible-playbook playbooks/site.yml
```

### 시나리오 5. 클러스터 정지

Provider의 수정은 VM을 강제로 끄므로, 게스트 안에서 먼저 정상 종료한다. 다시 올릴 때는 `scripts/entry.sh`를 실행한다.

```bash
source ~/.local/share/k3s-vmware-lab/ansible-venv/bin/activate
cd infra/ansible
ansible vms -b -B 60 -P 0 -m ansible.builtin.shell -a 'sleep 2 && systemctl poweroff'
vmrun -T ws list                   # "Total running VMs: 0"이 될 때까지 확인
```

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

## 다 끝났는지 확인하기

복잡한 진단보다 아래 네 가지 결과만 먼저 본다.

| 확인 질문 | 실행할 명령 | 정상 결과 |
|---|---|---|
| 시작 조건이 모두 정상인가? | `scripts/preflight.sh` | 마지막 줄이 `0 FAIL, 0 WARN` |
| 코드와 실제 VM이 같은가? | `scripts/tf.sh plan -detailed-exitcode` | `No changes`, 종료 코드 0 |
| 세 노드가 준비됐는가? | 아래 `get nodes` 명령 | 세 줄 모두 `Ready` |
| 기본 서비스가 살아 있는가? | 아래 `get pods` 명령 | 모두 `Running` 또는 `Completed` |

```bash
source ~/.local/share/k3s-vmware-lab/ansible-venv/bin/activate
cd infra/ansible
ansible k3s_server -b -m command -a '/usr/local/bin/k3s kubectl get nodes -o wide'
ansible k3s_server -b -m command -a '/usr/local/bin/k3s kubectl get pods -A -o wide'
```

`scripts/entry.sh`를 다시 실행했을 때 Terraform은 `No changes`, Ansible은 `changed=0`이면 반복 실행 안전성도 확인된 것이다.

## 자주 나오는 말, 쉬운 뜻

| 문서의 용어 | 이 README에서 생각할 뜻 |
|---|---|
| 골든 이미지 | VM 3대를 찍어 내는 **복제 원본** |
| vmrest | VMware를 명령줄에서 움직이는 **로컬 제어창** |
| Terraform | VM 개수·사양·전원을 맞추는 **VM 상태 관리자** |
| Ansible | VM 안의 설정과 K3s를 맞추는 **자동 설정 도구** |
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
3. Terraform이 관리하는 VM을 Workstation GUI에서 복제·이름 변경·삭제하지 않는다.
4. 복제 원본을 수정하지 않는다. 바꿀 내용이 있으면 새 버전 이름으로 다시 만든다.
5. Provider의 디버그 모드를 켜지 않는다. 로그에 vmrest 비밀번호가 노출될 수 있다.
6. SSH 키, 비밀번호, K3s 접속 파일은 저장소 밖 `~/.config/k3s-vmware-lab/secrets/`에만 둔다.
7. 물리 GPU 호스트 작업은 원격 세션에서 하지 않는다. `gpu-host.yml`은 콘솔 유지보수 시간에만 실행한다.

Provider API, 파일 해시, SELinux 컨텍스트 같은 상세 근거가 필요하면 [기술 인계서](docs/vmware-iac-handoff.md)를 본다.
