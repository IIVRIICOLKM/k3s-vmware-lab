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
| `scripts/` | ISO 검증·다운로드, 사전 점검, 이미지 빌드, Terraform wrapper, inventory 생성 |
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

## 전체 실행 순서

```bash
cd /home/lkm/Projects/k3s-vmware-lab

scripts/vmrest-start.sh
scripts/fetch-rocky-iso.sh
scripts/preflight.sh

scripts/golden-build.sh 20260918-1

scripts/tf.sh init
scripts/cluster-apply.sh -auto-approve
scripts/render-inventory.sh

source ~/.local/share/k3s-vmware-lab/ansible-venv/bin/activate
cd infra/ansible
ansible-playbook playbooks/ping.yml
ansible-playbook playbooks/site.yml
```

검증:

```bash
cd /home/lkm/Projects/k3s-vmware-lab
scripts/tf.sh plan -detailed-exitcode       # 0이어야 함
scripts/preflight.sh

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
