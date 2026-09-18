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

`entry.sh`는 아래 단계 스크립트를 순서대로 호출하는 얇은 진입점이다. 어느 단계든 실패하면 즉시 멈추고 `FAILED at step N/9: <명령>`을 출력한다.

| 단계 | 호출 | 처음 실행 | 다시 실행 |
|---|---|---|---|
| 1 | `scripts/vmrest-start.sh` | vmrest를 HTTPS·`127.0.0.1:8697`로 기동 | 이미 떠 있으면 그대로 둔다 |
| 2 | `scripts/fetch-rocky-iso.sh` | Rocky 9.8 DVD ISO(15.2GB) 다운로드 후 공식 서명·SHA-256 검증 | 서명과 해시만 재확인 |
| 3 | `scripts/preflight.sh` | 도구 버전·vmrest·비밀값 권한·ISO·골든 이미지 무결성 점검. FAIL이 하나라도 있으면 중단 | 동일 |
| 4 | `scripts/golden-build.sh <버전>` | Packer로 골든 이미지 빌드(약 11분) | 해당 버전이 있으면 건너뜀(이미지는 불변) |
| 5 | `scripts/tf.sh init` | Provider 설치(lock 파일 해시로 고정) | 변경 없음 |
| 6 | `scripts/cluster-apply.sh -auto-approve` | VM 3대를 꺼진 채 생성 → 켬 | 코드와 달라진 것만 맞춘다(예: 꺼진 VM을 켬). 같으면 `No changes` |
| 7 | `scripts/render-inventory.sh` | Terraform의 VM ID로 vmrest에서 IP를 받아 inventory 생성 | IP를 다시 받아 갱신 |
| 8 | `ansible-playbook playbooks/ping.yml` | SSH 접속 확인 | 동일 |
| 9 | `ansible-playbook playbooks/site.yml` | OS 구성(bootstrap) + K3s server/agent | `changed=0` |

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

- 오래 걸리는 단계는 ISO 다운로드(15.2GB, 회선 속도에 따라 다름)와 골든 이미지 빌드(약 11분)다. 빌드 VM은 헤드리스로 돌아 화면에 창이 뜨지 않는다.
- 마지막 줄에 `provisioning complete: golden image …, nodes k3s-server, worker-cpu-1, worker-cpu-2`가 나오면 끝이다. 직전 출력에 세 노드가 `Ready`로 나열된다.
- kubeconfig는 `~/.config/k3s-vmware-lab/secrets/kubeconfig`(0600)에 생긴다.

### 시나리오 2. 다시 실행하기 / 호스트 재부팅 후 복구

같은 명령을 다시 실행한다.

```bash
scripts/entry.sh
```

- 이미 가동 중이면 아무것도 바꾸지 않는다(검증: 약 2분, Terraform `No changes`, Ansible `changed=0`).
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

## 검증

```bash
scripts/tf.sh plan -detailed-exitcode       # 0이어야 함
scripts/preflight.sh

source ~/.local/share/k3s-vmware-lab/ansible-venv/bin/activate
cd infra/ansible
ansible-playbook playbooks/bootstrap.yml    # 재실행 changed=0
ansible-playbook playbooks/k3s.yml          # 재실행 changed=0
ansible k3s_server -b -m command -a '/usr/local/bin/k3s kubectl get nodes -o wide'
ansible k3s_server -b -m command -a '/usr/local/bin/k3s kubectl get pods -A -o wide'
```

## Rocky 골든 이미지

- ISO는 `scripts/fetch-rocky-iso.sh`만으로 받는다. 바이트는 국내 KRFOSS Rocky 미러에서 받지만, Rocky 9 공식 키 지문과 공식 `CHECKSUM.asc` 서명을 확인한 뒤 크기와 SHA-256을 다시 고정값과 대조한다.
- Anaconda Kickstart는 `OEMDRV` 라벨의 보조 CD로 전달한다. 빌드 과정에서 HTTP 서버나 LAN 수신 포트를 열지 않는다.
- DVD ISO의 `Server` 환경을 설치하고 `skipx` 및 음수 패키지 항목으로 GNOME/Xorg를 제외한다.
- 빌드 VM은 vmnet8 DHCP 풀 밖의 `.10` 고정 주소를 사용한다. `finalize.sh`는 저장된 NetworkManager 프로필을 MAC 기반 DHCP로 바꿔 복제본이 첫 부팅 때 고유 주소를 받게 한다.
- `finalize.sh`는 OS/버전, `multi-user.target`, GUI 패키지 부재, NetworkManager와 open-vm-tools를 확인한다. 그 후 SSH 호스트 키와 machine-id를 비워 복제본별로 재생성한다.
- 골든 VMX/VMDK는 SHA-256 기록 후 0444로 잠그고 vmrest에 등록한다.

## Rocky/K3s 구성

- SELinux는 enforcing으로 유지한다. Ansible이 `container-selinux`, `selinux-policy-base`, 서명된 `k3s-selinux` RPM을 설치하고 K3s 설정에 `selinux: true`를 기록한다.
- 시간 동기화는 `chronyd`가 담당한다.
- K3s 공식 RHEL 계열 권고에 따라 VM의 `firewalld`는 bootstrap에서 중지·비활성화한다. VM은 외부 브리지 대신 호스트 전용 NAT인 vmnet8에만 연결된다.
- 스왑은 Kickstart에서 만들지 않으며 Ansible이 0인지 검사한다.

## Provider 2.0.1 제약

1. Terraform은 반드시 `scripts/tf.sh`로 실행한다. 이 wrapper가 자격증명, 외부 state, 0600 백업, `-parallelism=1`을 강제한다.
2. 골든 NIC는 `custom`/`vmnet8`이어야 한다. `nat`이면 provider의 NIC 재생성이 실패한다.
3. 새 VM은 꺼진 상태로 생성한 뒤 두 번째 apply에서 켠다. `scripts/cluster-apply.sh`가 두 단계를 처리한다.
4. provider의 모든 수정은 VM을 강제로 끈다. CPU·메모리 변경 전 게스트를 정상 종료한다.
5. `sourceid` 변경은 자동 교체하지 않는다. 새 골든으로 노드를 재구축할 때만 명시적으로 `-replace`한다.
6. `debug = "DEBUG"`는 vmrest 암호를 로그에 노출하므로 `NONE`을 유지한다.
7. Terraform 관리 VM을 Workstation GUI에서 복제·이름 변경·삭제하지 않는다.

## 원격 세션 안전

물리 호스트는 원격 운용 중이다. 기본 VM 경로와 사용자 영역 데이터 외의 호스트 네트워크·커널·서비스는 이 워크플로우가 변경하지 않는다. `playbooks/gpu-host.yml`은 물리 호스트 네트워크에 K3s/CNI 규칙을 추가하므로 콘솔 유지보수 창에서 `-e host_changes_allowed=true -K`를 명시한 경우에만 실행한다.
