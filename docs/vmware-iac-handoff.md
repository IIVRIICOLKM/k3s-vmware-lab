# VMware Workstation IaC 프로젝트 인계서

> 최종 갱신 2026-09-18. Rocky Linux 9.8 Server 무GUI 마이그레이션의 실행 명령·관찰·결과는 13장, 남은 위험은 14장에 있다.
> IaC 저장소: `/home/lkm/Projects/k3s-vmware-lab` (이 문서의 사본은 저장소의 `docs/vmware-iac-handoff.md`).

## 1. 목적

로컬 Linux 데스크톱에서 VMware Workstation Pro를 하이퍼바이저로 사용하고, 다음 세 도구의 역할을 분리해 K3s 실험 환경을 재현 가능하게 구축한다.

- Packer: 운영체제가 설치된 기준 VM 이미지 생성
- Terraform: VM 복제·등록·전원·가상 네트워크와 상태 관리
- Ansible: 게스트 운영체제와 K3s 및 애플리케이션 구성

운영 대상은 VM 3대와 물리 GPU 호스트 1대로 구성된 K3s 클러스터다.

## 2. 현재 확인된 호스트 환경

| 항목 | 확인값 | 상태 |
|---|---|---|
| 호스트 OS | Ubuntu 26.04.1 LTS | 확인됨 |
| 아키텍처 | x86_64 | 확인됨 |
| 커널 | 7.0.0-31-generic | 확인됨 |
| VMware Workstation Pro | 26.0.0 build 25388281 | 설치됨 |
| vmrest | 1.3.1 build 25388281 | HTTPS `127.0.0.1:8697` 전용으로 기동 (`scripts/vmrest-start.sh`) |
| vmmon / vmnet | 커널 모듈 설치·로드됨 | 활성 |
| vmnet1 / vmnet8 | 네트워크 인터페이스 존재 | 활성 |
| vmware.service | active (exited), Result=success | 09-11 부팅 시 실패는 해소됨. 원인 확정(13.1) |
| Terraform | 1.16.3 (`~/.local/bin`) | 설치·서명 검증됨 |
| Packer | 1.16.0 + 플러그인 hashicorp/vmware 2.1.6 | 설치·서명 검증됨 |
| Ansible | ansible-core 2.21.4 (venv, `~/.local/bin`에 링크) | 설치됨 |
| kvm_amd / VirtualBox 모듈 | 로드됨, `kvm.enable_virt_at_load=Y` | VMware VM 기동과 공존 확인(13.2) |
| Workstation 기본 VM 경로 | `~/.local/share/k3s-vmware-lab/vms` | 설정함(13.6) |

(갱신) 2026-09-18 확인 결과 `vmware.service`는 정상 상태이며, 부팅 시 실패는 커널 7.0.0-31용 모듈이 부팅 이후에야 빌드됐기 때문이었다(13.1). 아래는 원래 기록이다.

`vmware.service`의 실패 상태와 별개로 현재 `vmmon`, `vmnet`, `vmnet1`, `vmnet8`은 활성이다. 따라서 서비스 실패 기록만 보고 Workstation 전체가 동작하지 않는다고 단정하지 말고, 현재 세션을 유지한 상태에서 모듈·네트워크·실제 VM 기동 여부를 각각 검사해야 한다.

현재 호스트는 원격 작업 중이므로 원격 연결이나 실행 중인 작업에 영향을 줄 수 있는 시스템 상태 변경을 자동으로 수행하지 않는다. 문제 조사는 읽기 전용 진단을 우선하며, 위험한 조작이 필요해 보이면 실행하지 않고 근거와 예상 영향만 사용자에게 보고한다.

## 3. 목표 클러스터 구성

| 노드 | 형태 | 자원 | 역할 |
|---|---|---:|---|
| k3s-server | VM | 2 vCPU, 3 GB RAM | K3s control plane |
| worker-cpu-1 | VM | 2 vCPU, 6 GB RAM | Jenkins, Argo CD, 모니터링, MySQL |
| worker-cpu-2 | VM | 2 vCPU, 3 GB RAM | API, 전처리, 장애 실험 대상 |
| gpu-host | 물리 Linux 호스트 | RTX 3090 24 GB | K3s agent, GPU 워크로드 직접 실행 |

(갱신) 세 VM의 표준 게스트 OS는 **Rocky Linux 9.8 Server(그래픽 환경 없음)**다. DVD ISO의 `Server` 환경으로 골든 이미지를 만들고 Terraform으로 세 노드를 재생성한다(13.7–13.10).

GPU는 물리 호스트에서 직접 사용한다. GPU를 VM 생성·복제 워크플로우에 포함하지 말고, Ansible에서 물리 호스트용 별도 inventory 그룹과 role로 관리한다.

## 4. 확정된 워크플로우

```text
IaC 저장소
  ↓ 사전 점검
Packer vmware-iso
  ↓
버전과 SHA-256이 고정된 골든 VMX/VMDK
  ↓
Terraform + elsudano/vmworkstation 2.0.1
  ↓ HTTPS/REST
vmrest 1.3.1 → VMware Workstation Pro 26.0.0
  ↓
VM 3대 생성·등록·기동
  ↓ Terraform output으로 IP/호스트 그룹 생성
Ansible inventory
  ↓
K3s 및 노드별 서비스 구성
```

### Packer의 책임

- `vmware-iso` 빌더로 기준 운영체제 설치
- Anaconda Kickstart 자동 설치 적용
- VMware Tools 또는 open-vm-tools 설치
- 업데이트와 공통 패키지까지만 이미지에 포함
- 생성된 VMX/VMDK의 버전과 SHA-256 기록
- Jenkins, Argo CD처럼 노드별로 달라지는 애플리케이션은 이미지에 넣지 않음

### Terraform의 책임

- 기준 VM으로부터 VM 3대 생성 또는 복제
- CPU, 메모리, 경로, 전원과 지원되는 가상 네트워크 설정
- `terraform.tfstate` 관리
- Ansible에서 사용할 VM ID와 IP 출력
- Provider가 지원하지 않는 작업만 제한적으로 `vmrun` 또는 REST API 스크립트로 보완

### Ansible의 책임

- SSH 준비 상태 확인
- K3s server와 agent 구성
- worker-cpu-1에 Jenkins, Argo CD, 모니터링, MySQL 배치
- worker-cpu-2에 API와 전처리 구성
- 물리 gpu-host에 K3s agent와 GPU 런타임 구성
- 반복 실행 시 결과가 변하지 않도록 멱등성 검증

## 5. Terraform Provider 결정

사용 버전을 다음과 같이 고정했다.

```hcl
terraform {
  required_version = ">= 1.0.0"

  required_providers {
    vmworkstation = {
      source  = "elsudano/vmworkstation"
      version = "= 2.0.1"
    }
  }
}
```

(갱신) 스모크 테스트 통과로 **2.0.1을 확정**했다(13.5). 단 다음 두 규칙이 전제다: 부모 VM의 NIC는 `custom`/`vmnet8`, VM은 꺼진 상태로 생성한 뒤 켠다. 실제 리소스·데이터소스 타입명은 `vmworkstation_virtual_machine`이다.

확인된 Provider 패키지 정보:

- Provider: `elsudano/vmworkstation`
- 버전: `2.0.1`
- 플랫폼: `linux_amd64`
- Terraform Provider protocol: `6.0`
- SHA-256: `3df78cd7fdc20408c70afea258b126c1f09fad7a7c4ca83dc7bc43782dab7c7e` (`terraform init` lock 파일의 `zh:` 해시와 일치 확인)
- 배포 파일: `terraform-provider-vmworkstation_2.0.1_linux_amd64.zip`

참고 자료:

- [Terraform Registry Provider 문서](https://registry.terraform.io/providers/elsudano/vmworkstation/latest/docs)
- [Provider GitHub 저장소](https://github.com/elsudano/terraform-provider-vmworkstation)
- [Provider 2.0.1 릴리스](https://github.com/elsudano/terraform-provider-vmworkstation/releases/tag/v2.0.1)

## 6. 호환성 판단

Provider 2.0.1은 현재 사용 가능한 최신 릴리스이며 Linux AMD64 바이너리가 제공된다. 최신 릴리스에는 VM 생성·수정·삭제, 전원 제어와 Workstation REST API 관련 수정이 포함되어 있다.

Workstation Pro 26.0.0과 Provider 2.0.1 조합을 명시적으로 보증하는 공식 호환성 표는 확인되지 않았다. 따라서 처음에는 후보로만 두었고, 2026-09-18 아래 7단계를 `scripts/provider-smoke-test.sh`로 자동화해 2회 연속 통과한 뒤 **조건부 실동작 검증 완료 버전으로 확정**했다. 첫 실행에서 NIC 재생성 관련 실패 두 건이 나왔고, API 응답 조사로 원인을 찾아 Terraform 안에서 해결했다(13.5).

확정 전에 수행한 스모크 테스트는 다음과 같다.

1. `vmrest` 자격증명을 구성하고 localhost에서 API를 기동한다.
2. 인증을 사용해 `/api/vms` 목록 조회가 가능한지 확인한다.
3. 폐기 가능한 기준 VM 한 대를 준비한다.
4. `terraform init`으로 Provider 2.0.1 설치와 서명을 확인한다.
5. `plan → apply → 동일 plan 재실행 → destroy` 순서로 수행한다.
6. 두 번째 plan에서 의도하지 않은 diff가 없어야 한다.
7. 생성·기동·조회·종료·삭제 후 Workstation GUI와 Terraform state가 일치해야 한다.

스모크 테스트가 실패하면 먼저 Provider issue와 API 응답을 조사한다. 즉시 모든 기능을 `local-exec`로 대체하지 않는다.

## 7. 반드시 지킬 제약조건

1. Provider 버전을 `= 2.0.1`로 고정하고 `.terraform.lock.hcl`을 저장소에 포함한다.
2. Workstation Pro도 검증 완료 후 프로젝트 기간 동안 버전을 고정한다.
3. Provider 문서 기준으로 Terraform 작업은 `-parallelism=1`을 사용한다.
4. `vmrest`는 외부 네트워크에 노출하지 않고 localhost로 제한한다.
5. 사용자명과 비밀번호를 `.tf` 또는 Git에 평문으로 저장하지 않는다.
6. Terraform 관리 VM을 Workstation GUI에서 임의로 복제·삭제·이름 변경하지 않는다.
7. Provider 문서에 명시된 VM 이름과 설명 변경 API 제약을 전제로 설계한다.
8. `terraform.tfstate`를 정기 백업하고 민감 정보가 포함될 수 있다고 취급한다.
9. 골든 이미지 파일은 Terraform 실행 중 변경하지 않는다.
10. `vmrun` 또는 `local-exec` 우회는 Provider 미지원 기능에만 제한한다.
11. 우회 스크립트에는 사전조건 검사, 종료 코드, 재실행 안전성과 사후 상태 검증을 넣는다.
12. GPU 물리 노드 구성과 VM 생명주기를 같은 Terraform resource로 억지로 묶지 않는다.
13. 원격 세션 보호를 위해 연결이나 실행 중인 작업에 영향을 줄 수 있는 시스템 상태 변경을 자동화하지 않는다.
14. 위험한 시스템 조작이 필요한 장애는 읽기 전용 진단으로 원인을 좁힌 후 별도 유지보수 작업으로 분리한다.

스모크 테스트에서 추가된 제약(2026-09-18):

15. 골든(부모) VM의 NIC는 `nat`이 아니라 `custom` + `vmnet8`이어야 한다(Packer `network = "vmnet8"`).
16. 새 VM은 꺼진 상태로 생성하고 두 번째 apply에서 켠다(`scripts/cluster-apply.sh`가 자동 처리).
17. Provider의 모든 수정은 VM 강제 전원 차단을 동반하므로, CPU·메모리·전원 변경 전 게스트를 정상 종료한다.
18. Provider `debug`는 `NONE`으로 둔다(`DEBUG`는 vmrest 비밀번호를 로그에 평문 출력).
19. Terraform은 `scripts/tf.sh`로만 실행한다(자격증명 주입, state 경로, `-parallelism=1`, 0600 백업).
20. Workstation `prefvmx.defaultVMPath`는 `~/.local/share/k3s-vmware-lab/vms`와 같아야 한다(vmrest 복제 위치).

## 8. 현재 선행 작업

1. ✅ 서비스 상태를 변경하지 않고 `journalctl`, 모듈 상태와 프로세스를 조회해 `vmware.service` 실패 원인을 좁힌다. → 13.1
2. ✅ Workstation에서 폐기 가능한 VM 한 대가 정상 부팅되는지 검사한다. → 13.2, 13.7
3. ✅ `vmrest` 자격증명을 구성하고 localhost API를 실행한다. → 13.3
4. ✅ Terraform, Packer, Ansible을 설치하고 버전을 기록한다. → 13.4
5. ✅ Provider 2.0.1 스모크 테스트를 수행한다. → 13.5
6. ✅ 성공하면 Workstation, vmrest, Provider, Terraform 버전을 잠근다. → 13.6
7. ✅ 그다음 Packer 골든 이미지와 VM 3대 구성을 작성한다. → 13.7, 13.8
8. ✅ 마지막으로 Terraform output과 Ansible inventory를 연결한다. → 13.9

## 9. 권장 파일 배치

Packer 템플릿은 실행 결과물이 아니라 IaC 소스이므로 프로젝트 Git 저장소 안에 두는 것이 맞다. 현재 연구 문서 디렉터리와 실행 코드를 분리하려면 다음 위치를 권장한다.

```text
/home/lkm/Projects/k3s-vmware-lab/
```

이 경로 아래에는 사람이 작성하고 검토해야 하는 소스만 둔다.

```text
/home/lkm/Projects/k3s-vmware-lab/
├── infra/
│   ├── packer/
│   │   ├── templates/
│   │   ├── http/
│   │   └── scripts/
│   ├── terraform/
│   │   ├── versions.tf
│   │   ├── provider.tf
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── ansible/
│       ├── inventories/
│       ├── roles/
│       └── playbooks/
├── scripts/
│   ├── preflight.sh
│   └── provider-smoke-test.sh
├── docs/
│   ├── vmware-iac-handoff.md
│   ├── vmware-workstation-iac-workflow.dot
│   └── vmware-workstation-iac-workflow-2560x1440.png
├── .gitignore
└── README.md
```

용량이 크거나 로컬 시스템 상태에 해당하는 파일은 저장소 밖의 XDG 경로로 분리한다.

```text
/home/lkm/.local/share/k3s-vmware-lab/
├── images/      # Packer가 생성한 골든 VMX/VMDK
├── vms/         # Terraform이 관리하는 실제 VM 디렉터리
└── iso-cache/   # 설치 ISO 캐시

/home/lkm/.local/state/k3s-vmware-lab/
└── terraform/   # 로컬 backend를 쓸 경우의 tfstate

/home/lkm/.config/k3s-vmware-lab/
└── secrets/     # vmrest·Ansible 비밀값, 권한 0700/0600
```

(갱신) 실제 구성은 위 트리를 따르되 다음을 추가했다: `scripts/lib/`(공통 함수, 버전 핀), `scripts/vmrest-start.sh`, `scripts/fetch-rocky-iso.sh`, `scripts/tf.sh`, `scripts/cluster-apply.sh`, `scripts/golden-build.sh`, `scripts/render-inventory.sh`, `infra/packer/plugins.sha256`, `infra/ansible/ansible.cfg`·`requirements.txt`. XDG 쪽에는 `ansible-venv/`, `~/.local/state/k3s-vmware-lab/{logs,backups,terraform/backups}`가 있다. Provider 검증에만 쓴 `smoke/` 기준 VM과 데이터는 Rocky 전환 때 삭제했다(13.11). 비밀값 디렉터리는 0700, 파일과 tfstate는 0600이다.

이렇게 분리하면 Git 저장소를 삭제하거나 다른 장비로 clone해도 대용량 VM과 로컬 상태가 섞이지 않는다. Terraform과 Packer에는 위 경로를 변수로 전달하고 코드에 사용자별 절대 경로를 반복해서 하드코딩하지 않는다.

## 10. Git 관리 정책

이 프로젝트는 구성 변경의 재현성과 연구 과정 추적이 중요하므로 Git으로 관리하는 것이 적합하다. 현재 `/home/lkm/Desktop/26-2/개별연구`는 Git 저장소로 확인되지 않았으므로, 실제 IaC 구현을 시작할 때 `/home/lkm/Projects/k3s-vmware-lab`을 별도 저장소로 생성하는 방식을 권장한다.

다음 파일은 Git에 포함한다.

- 모든 `.pkr.hcl`, `.tf`, Ansible playbook·role과 검증 스크립트
- `.terraform.lock.hcl`과 `infra/packer/plugins.sha256`
- `README.md`, 이 인계서와 다이어그램 원본 `.dot`
- 문서에서 바로 열람할 2560×1440 PNG
- 비밀값이 제거된 예제 변수 파일: `*.example`, `*.example.tfvars`

다음 파일은 Git에서 제외한다.

- `*.vmdk`, `*.vmx`, `*.vmem`, `*.nvram`, `*.vmsd`, `*.vmsn`, `*.vmss`
- 설치 ISO와 Packer cache
- `.terraform/`, `*.tfstate`, `*.tfstate.*`, plan 파일
- 실제 `*.tfvars`, Vault 비밀번호 파일, SSH 키와 vmrest 자격증명
- 동적으로 생성된 inventory, 로그와 임시 파일

권장 `.gitignore`의 최소 항목은 다음과 같다.

```gitignore
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
*.tfvars
!*.example.tfvars
.packer.d/
packer_cache/
*.iso
*.vmdk
*.vmx
*.vmem
*.nvram
*.vmsd
*.vmsn
*.vmss
*.log
.generated/
secrets/
```

(갱신) Packer에는 잠금 파일 기능이 없어 `packer.lock.hcl`은 생성되지 않는다. 대신 플러그인 버전을 `= 2.1.6`으로 고정하고 설치된 바이너리의 SHA-256을 `infra/packer/plugins.sha256`에 기록해 `preflight.sh`로 검증한다. 저장소는 `git init` 후 포함 대상을 스테이징까지 했다(git 사용자 정보 미설정으로 커밋은 하지 않음, 14장 9번).

이 인계서는 설계 결정, 제약과 검증 기준을 담고 있으므로 Git 관리 대상이다. 새 저장소를 만들면 현재 파일을 `docs/vmware-iac-handoff.md`로 옮기고, 다이어그램 원본과 대표 PNG도 같은 `docs/` 아래에 둔다.

## 11. 기존 산출물

최초 산출물은 다음 연구 문서 디렉터리에 있었고, 현재는 `/home/lkm/Projects/k3s-vmware-lab` Git 작업 트리의 `docs/`가 실행·편집 기준이다.

```text
/home/lkm/Desktop/26-2/개별연구/
```

- 인계서: `vmware-iac-handoff.md`
- 워크플로우 PNG: `vmware-workstation-iac-workflow-2560x1440.png`
- 고해상도 PNG: `vmware-workstation-iac-workflow.png`
- 편집용 Graphviz: `vmware-workstation-iac-workflow.dot`

새 저장소를 구성할 때 인계서, Graphviz 원본과 대표 PNG는 `docs/`로 이동하고, 고해상도 중복 PNG는 필요성이 없다면 저장소에 포함하지 않는다.

(갱신) 인계서·`.dot`·2560×1440 PNG를 `cp`로 `/home/lkm/Projects/k3s-vmware-lab/docs/`에 복사해 구현을 진행했다. Rocky 마이그레이션 완료 후 최신 인계서·`.dot`·대표 PNG와 새 고해상도 PNG를 연구 문서 디렉터리로 다시 동기화했다.

## 12. 다음 담당자에게 요청할 작업

위 사실과 제약을 유지하면서 다음 순서로 진행한다.

1. ✅ 현재 호스트·네트워크·VMware 상태를 변경하지 말고 읽기 전용으로 측정한다. → 13.1
2. ✅ 위험한 시스템 조작이 필요해 보이면 실행하지 말고 근거와 원격 연결 영향을 먼저 보고한다. → 14장 1·5·7번 (sudo·호스트 네트워크 변경 없음)
3. ✅ `/home/lkm/Projects/k3s-vmware-lab`을 IaC Git 저장소 후보로 사용한다.
4. ✅ 대용량 이미지·VM·state·비밀값은 지정한 외부 XDG 경로에 둔다.
5. ✅ Provider 2.0.1과 Workstation 26.0.0의 실제 API 호환성을 스모크 테스트한다. → 13.5
6. ✅ 테스트 결과가 성공한 경우에만 Packer·Terraform·Ansible 기본 디렉터리와 설정 파일을 작성한다. → 13.7–13.10
7. ✅ 실행 명령, 관찰 결과와 남은 위험을 이 문서에 갱신한다. → 13장, 14장

추측으로 호환성을 확정하지 말고, REST API 응답과 Terraform state의 일치 여부를 근거로 판단한다. 원격 접속이 끊길 수 있는 조작은 자동 복구 절차로 간주하지 않는다.

## 13. 작업 기록 (2026-09-18)

12장 요청을 순서대로 수행했다. 모든 명령은 사용자 권한으로만 실행했고(sudo 미사용), 호스트 네트워크·서비스·커널 모듈은 변경하지 않았다. 변경한 사용자 설정(Workstation 환경설정, GUI 라이브러리 항목)은 13.6·13.7과 14장에 모두 적었다.

### 13.1 읽기 전용 진단 (8장 1번)

```bash
systemctl show vmware.service -p ActiveState,SubState,Result
journalctl -u vmware.service -b --no-pager
modinfo -n vmmon; stat -c %y /lib/modules/$(uname -r)/misc/vmmon.ko
ls /lib/modules/*/misc; zgrep linux-image-7.0.0-31 /var/log/apt/history.log*
pgrep -a -f 'vmnet-|vmware-'; cat /etc/vmware/networking; ss -ltn
```

- `vmware.service`는 현재 **`active (exited)`, `Result=success`**다. 2장 표의 `failed`는 부팅 시점 기록이며 09-18 14:26:09 재시작으로 해소됐다.
- **부팅 시 실패 원인 확정**: 커널 7.0.0-31은 09-05에 설치되어 09-11 12:17에 이 커널로 부팅됐지만, 이 커널용 `vmmon.ko`/`vmnet.ko`는 **09-13 11:26에야 빌드**됐다. 부팅 시점에 모듈 파일이 없어 `Virtual machine monitor - failed`, `Virtual ethernet - failed`가 났다. 7.0.0-30에도 VMware 모듈이 없었다. 즉 **Workstation 모듈은 커널 업데이트 때 자동 재빌드되지 않는다**(14장 위험 1).
- vmnet 데몬 전부 실행 중: `vmnet-dhcpd`(vmnet1, vmnet8), `vmnet-natd`, `vmnet-bridge`, `vmware-authdlauncher`. vmnet8 = 172.16.133.1/24, DHCP 풀 .128–.254, 임대 30분/최대 2시간, 게이트웨이·DNS .2.
- `kvm_amd`가 로드돼 있고 `kvm.enable_virt_at_load=Y`다. 최신 커널에서 VMware와 충돌할 수 있는 조합이지만, 13.2에서 **VMware 26.0.0이 정상적으로 VM을 기동함을 실측**했다. VirtualBox 모듈(`vboxdrv` 등)도 로드돼 있으나 실행 중 게스트는 없다.
- 원격 접속 경로: TeamViewer(5939) + krfb(5900), 물리 NIC `enp5s0`(192.168.1.162). 이후 모든 VM은 사용자 공간 NAT인 vmnet8에만 연결했고 브리지(vmnet0)는 쓰지 않았다.
- Workstation 인벤토리의 `Server(B)` 항목은 디렉터리가 이미 없는 잔존 항목이다. 건드리지 않았다.

### 13.2 폐기용 VM 부팅 검사 (8장 2번)

`~/.local/share/k3s-vmware-lab/smoke/base/`에 OS 없는 기준 VM `k3slab-smoke-base`(BIOS, 1GB 씬 디스크, NAT NIC)를 만들어 `vmrun -T ws start … nogui`로 기동했다.

- 처음 두 번은 `vmware-vmx`가 SIGSEGV로 죽었다. 원인은 호스트가 아니라 **작성한 VMX**였다. `e1000e`는 PCIe 장치인데 PCIe 루트 포트(`pciBridge4~7`)를 빠뜨렸고(`msg.pci.noslotavail`), 첫 실패 때 VMware가 VMX에 기록한 `ethernet0.pciSlotNumber = "21"`(레거시 PCI 슬롯)이 남아 두 번째도 실패했다. 루트 포트 추가 + 자동 기록된 슬롯 번호 삭제로 해결했다. VMware는 이 경우 오류 대신 세그폴트로 종료한다(로그: `~/.local/state/k3s-vmware-lab/logs/boot-test-*.vmware.log`).
- 세 번째 기동 성공: `Monitor Mode: CPL0`, `[vcpu-0] BIOS-UUID`, 빈 디스크이므로 `msg.Backdoor.OsNotFound`, `IP=172.16.133.1 (vmnet8)`. 전원 끄기도 정상.
- 실제 OS 설치·부팅·DHCP·SSH는 13.7의 골든 이미지 빌드로 확인했다.

### 13.3 vmrest (8장 3번)

- 사용자 `k3slab`, 무작위 12자 비밀번호. `vmrest -C`를 pty로 구동해 설정했고, vmrest는 `~/.vmrestCfg`(0600)에 **솔트+해시로만** 저장한다(평문 없음 확인). 평문은 `~/.config/k3s-vmware-lab/secrets/vmrest.env`(0600)에만 있다.
- 자체 서명 인증서(CN=localhost, SAN 127.0.0.1)로 HTTPS 기동: `scripts/vmrest-start.sh`.
- vmrest 1.3.1에는 바인딩 주소 옵션이 없다. 실측 결과 **`127.0.0.1:8697`에만 바인딩**된다. 스크립트는 루프백 외 바인딩이 감지되면 즉시 종료시킨다.
- 검증: 무인증 401, 잘못된 비밀번호 401, 올바른 자격증명 + 인증서 검증(`--cacert`) 200, 외부 IP(192.168.1.162:8697) 접속 불가.
- Provider는 `https = true`일 때 **`InsecureSkipVerify: true`로 인증서를 검증하지 않는다**(API 클라이언트 소스 확인). 실제 보호막은 루프백 바인딩이다(14장).

### 13.4 도구 설치 (8장 4번)

| 도구 | 버전 | 설치 위치 | 검증 |
|---|---|---|---|
| Terraform | 1.16.3 | `~/.local/bin` | HashiCorp 키 지문 C874 011F 0AB4 0511 0D02 1055 3436 5D94 72D7 468F 대조, SHA256SUMS 서명 Good, zip SHA-256 OK |
| Packer | 1.16.0 | `~/.local/bin` | 동일 |
| Packer 플러그인 hashicorp/vmware | 2.1.6 | `~/.config/packer/plugins` | `packer init` 체크섬 검증, `infra/packer/plugins.sha256`에 기록 |
| ansible-core | 2.21.4 (Python 3.14.4) | `~/.local/share/k3s-vmware-lab/ansible-venv` → `~/.local/bin` 심볼릭 링크 | 의존성 고정: `infra/ansible/requirements.txt` |

`python3.14-venv`(ensurepip)가 없어 `python3 -m venv --without-pip` 후 시스템 pip의 `--python` 옵션으로 설치했다. sudo는 쓰지 않았다.

### 13.5 Provider 2.0.1 스모크 테스트 (8장 5번, 6장)

```bash
scripts/preflight.sh
scripts/provider-smoke-test.sh     # 로그: ~/.local/state/k3s-vmware-lab/logs/provider-smoke-test-*.log
```

**`terraform init`**: `Installed elsudano/vmworkstation v2.0.1 (self-signed, key ID 25B4C7DDA0B6F683)`. lock 파일의 `zh:` 해시가 5장의 SHA-256 `3df78cd7…7c7e`와 **일치**.

**스키마 실측** (`terraform providers schema -json`):
- 실제 타입명은 리소스·데이터소스 모두 `vmworkstation_virtual_machine`. 공식 문서 예제의 `vmworkstation_resource_vm`/`vmworkstation_datasource_vm`은 구 버전 이름이다.
- Provider의 `endpoint`/`username`/`password`가 스키마상 required라서, 문서가 안내하는 `VMWS_*` 환경변수만으로는 `plan`이 `Missing required argument`로 실패한다. `sensitive` 변수 + `TF_VAR_*`로 전달한다.

**첫 실행 실패 두 건과 원인** (6장 지침대로 `local-exec`로 넘어가지 않고 API 응답부터 조사):

| 생성 시 `state` | 실패 API 호출 | 응답 |
|---|---|---|
| `on` | `DELETE /vms/{id}/nic/1` | 409 / 107 "The virtual machine is not powered off" |
| `off` | `POST /vms/{id}/nic` `{"type":"nat","vmnet":"vmnet8"}` | 400 / 121 "Redundant parameter: vmnet8" |

- Provider 디버그 로그로 호출 순서를 확인했다: 복제(201) → CPU/메모리(200) → 전원(200) → 조회 → **NIC 목록 조회 → NIC 삭제 → 부모와 같은 type/vmnet으로 NIC 재생성**. 복제본이 부모 MAC을 물려받는 문제를 피하려는 동작이다.
- 이 NIC 재생성 코드는 GitHub의 Provider(v2.0.1 태그·main)와 API 클라이언트(v1.10.46 태그·master) 어디에도 없다. `go.mod`의 `replace … => ../vmware-workstation-api-client` 때문에 **릴리스 바이너리는 공개되지 않은 로컬 코드로 빌드**됐다(바이너리 심볼 `wsapinet.CreateNic/DeleteNic/GetNics`로 확인).
- 두 경우 모두 생성 실패 VM이 **Terraform state에 기록되지 않은 고아**로 남았다. vmrest API로 수동 정리했다.
- API 직접 검증: `{type:nat, vmnet:vmnet8}` → 400, `{type:nat}` → 201, **`{type:custom, vmnet:vmnet8}` → 201**(VMX의 `generatedAddress`가 비워져 새 MAC 생성).

**Terraform 안에서의 해결** (`local-exec`·REST 우회 없음):
1. 부모 VM의 NIC를 `nat`이 아니라 **`custom` + `vmnet8`**(같은 NAT 네트워크)로 둔다 → Provider의 NIC 재생성 요청이 통과한다.
2. VM은 **꺼진 상태로 생성한 뒤 두 번째 apply에서 켠다** → 켜진 VM의 NIC 삭제(409)를 피한다.

**결과: 통과 (2회 연속, 빈 state에서 재현)**. 각 단계 후 재계획이 모두 `No changes`였고, vmrest API·`vmrun list`·Terraform state가 일치했다.

| 단계 | 확인 내용 |
|---|---|
| 생성(off) | API 경로·CPU·메모리·전원·표시 이름 = state |
| 켜기 | 부모와 다른 고유 MAC(`00:0c:29:ae:cf:41` vs `…:e0:65:db`) |
| 켠 상태에서 메모리 512→768 | 같은 ID로 in-place 수정 |
| 끄기 | `vmrun` 목록에서 사라짐 |
| vmrest 재시작 | 꺼진 복제본도 계속 추적됨 |
| 삭제 | API·`vmrun`·디스크·state에서 제거, GUI 라이브러리에 잔존 항목 없음, 부모 VM 파일 해시 불변 |

**함께 확인된 Provider/vmrest 동작** (설계에 반영):
- vmrest 복제 API에는 대상 경로 인자가 없다. 복제본은 항상 Workstation 기본 VM 경로(`prefvmx.defaultVMPath`)에 생긴다 → 이 값을 `~/.local/share/k3s-vmware-lab/vms`로 설정했다(13.6).
- 복제는 **전체 복제**(`parentCID=ffffffff`, `monolithicSparse`)다. 복제 후 골든 이미지에 의존하지 않는다.
- 복제본은 부모의 annotation을 상속하고, Provider는 이름·설명을 바꿀 수 없다(Known Issue) → 설정의 `description`은 부모 값을 미러링한다.
- `UpdateVM`은 **어떤 변경이든 VM을 강제 전원 차단(`off`)한 뒤** 적용하고, `DeleteVM`도 강제 차단 후 삭제한다.
- `ip` 속성은 Create/Read/Update 모두 **`"0.0.0.0/0"` 고정값**이다. IP는 vmrest `/vms/{id}/ip`(VMware Tools 필요)로 얻는다.
- vmrest의 NIC 생성은 모델을 항상 **`e1000`**으로 만든다.
- vmrest로 복제한 VM은 **Workstation GUI 라이브러리(`inventory.vmls`)에 나타나지 않는다**. `POST /vms/registration`으로 등록한 VM만 나타난다.
- Provider `debug = "DEBUG"`는 **vmrest 비밀번호를 평문으로 로그에 출력**한다. 저장된 디버그 로그는 가렸다(`***REDACTED***`).
- 읽기 전용(0444) VMX/VMDK에서도 복제가 된다 → 골든 이미지를 파일 권한으로 잠글 수 있다.

### 13.6 버전 잠금 (8장 6번)

- `scripts/lib/pinned-versions.env`: 상태 `verified`, 검증일 2026-09-18. `scripts/preflight.sh`가 Workstation·vmrest·Terraform·Packer·ansible-core 버전, Provider lock 해시, Packer 플러그인 해시를 검사하고 불일치 시 실패한다.
- `infra/terraform/versions.tf`: `required_version = "= 1.16.3"`, Provider `= 2.0.1`, `.terraform.lock.hcl` 저장소 포함.
- Workstation은 apt가 아닌 `.bundle`(vmware-installer) 설치라 `apt-mark hold`를 쓸 수 없다. 사용자 설정 `pref.autoSoftwareUpdatePermission`을 `allow` → **`deny`**로 바꿨다.
- 같은 사용자 설정 파일에 `prefvmx.defaultVMPath = "~/.local/share/k3s-vmware-lab/vms"`를 추가했다(GUI에서 새 VM을 만들 때의 기본 위치도 바뀐다). 변경 전 원본: `~/.local/state/k3s-vmware-lab/backups/vmware-preferences.*.bak`.
- Packer에는 잠금 파일이 없다(`packer.lock.hcl`은 존재하지 않는 기능). 플러그인 정확 버전 고정 + `infra/packer/plugins.sha256` 기록 + preflight 검증으로 대체했다.

### 13.7 Packer 골든 이미지 (8장 7번)

```bash
scripts/fetch-rocky-iso.sh
scripts/golden-build.sh 20260918-1   # 로그: ~/.local/state/k3s-vmware-lab/logs/golden-build-*.log (0600)
```

- 설치 매체는 `Rocky-9.8-x86_64-dvd.iso`(15,194,259,456바이트)다. 바이트는 국내 KRFOSS Rocky 미러에서 받되, `fetch-rocky-iso.sh`가 Rocky 공식 9 릴리스 키 지문 `21CB 256A E16F C54C 6E65 2949 702D 426D 350D 275D`, 공식 `CHECKSUM.asc` 서명, SHA-256 `d2bcbb64…36d01f`을 순서대로 검증한다.
- Minimal ISO가 아니라 DVD ISO의 **`@^server-product-environment`**를 설치한다. Kickstart의 `skipx`, `multi-user.target`, `-gnome-shell`, `-xorg-x11-server-Xorg`와 `finalize.sh`의 RPM 부재 검사로 GUI가 없는 일반 Server 구성을 보장한다.
- Kickstart는 HTTP 대신 **`OEMDRV` 라벨 보조 CD**의 `/ks.cfg`로 전달한다. 부팅 입력용 VNC는 127.0.0.1:5980–5989이고 LAN 수신 포트는 열지 않는다.
- 빌드 VM은 vmnet8 DHCP 풀(.128–.254) 밖의 고정 IP(.10)를 사용한다. `finalize.sh`는 활성 NetworkManager 프로필을 MAC 기반 DHCP로 저장하되 현재 연결은 건드리지 않아 Packer SSH가 끊기지 않는다.
- 게스트 유형은 Workstation 26이 실제 지원하는 `rockyLinux-64`, 하드웨어 버전 21, EFI, PVSCSI, NIC `custom/vmnet8`/`e1000`이다.
- `finalize.sh`는 Rocky 9.8, NetworkManager, `vmtoolsd`, `multi-user.target`, GUI 패키지 부재를 검증하고 DNF 캐시·로그를 정리한다. `/etc/machine-id`와 SSH 호스트 키는 비워 첫 부팅 시 복제본마다 재생성한다.
- Packer가 만든 소문자 `displayname`은 vmrest 데이터소스 호환을 위해 해시 기록 전에 `displayName`으로 정규화한다. VMX/VMDK는 SHA-256 기록 후 0444로 잠근다.
- 첫 검증 빌드는 OS 설치와 SSH 접속까지 통과한 뒤 Rocky Server에 기본 생성되지 않은 `/var/lib/dbus`에 machine-id 링크를 만들려다 실패했다. `finalize.sh`가 디렉터리를 명시적으로 만들게 수정하고 같은 버전을 다시 빌드해 10분 45초 만에 성공했다.
- 결과 골든은 `k3slab-golden-rocky98-20260918-1`, vmrest ID `KIG21GN5DHTP9KGOVDMB4OUG5A46D1DH`다. 메타데이터는 Server profile·GUI 없음으로 기록됐고, NIC `custom/vmnet8`, `guestOS=rockyLinux-64`, ISO 분리, SHA-256 일치, 파일 모드 0444, 전원 off를 확인했다.

### 13.8 VM 3대 (8장 7번)

```bash
scripts/tf.sh init
scripts/cluster-apply.sh -auto-approve
scripts/tf.sh plan -detailed-exitcode   # exit 0
```

- `infra/terraform`: `for_each`로 `k3s-server`(2 vCPU/3GB), `worker-cpu-1`(2/6GB), `worker-cpu-2`(2/3GB). 골든 이미지는 데이터소스로 찾고, `precondition`으로 골든 이미지가 꺼져 있음을 강제한다. `sourceid`·`description`은 `ignore_changes`(골든 이미지가 새 버전으로 바뀌어도 기존 노드에 강제 전원 차단이 걸리지 않게 하고, 재구축은 `-replace`로 명시).
- `cluster-apply.sh` 1단계에서 세 대를 꺼진 채 생성, 2단계에서 켰다. ID는 `k3s-server=8IHO6F95UCAN4UDRKGJVT2S6COE4POK2`, `worker-cpu-1=HU3K1UUA10SN1EMVKHBCB4HKTJSNMP8J`, `worker-cpu-2=GNH26I1RGKV315GNJFG2G3A51NIDOKJV`다. 재계획은 exit 0, `No changes`였다. 세 복제본의 MAC은 모두 고유했다(`00:0c:29:08:f1:e4`, `…:3d:6b:4c`, `…:25:78:82`). 게스트가 메모리를 지연 할당해 최종 사전 점검 시 호스트 가용 메모리는 19GB였다.
- 사전 리허설: 같은 설정을 OS 없는 기준 VM과 노드당 512MB로 먼저 적용·삭제해 2단계 로직을 검증했다. 이때 **`terraform.tfstate`가 0664로 생성되는 문제**를 발견해 `tf.sh`에 `umask 077`을 넣고 state 디렉터리 0700, state·백업 0600으로 고쳤다(`preflight.sh`가 검사).

### 13.9 Terraform output ↔ Ansible inventory (8장 8번)

```bash
scripts/render-inventory.sh
cd infra/ansible && ansible-playbook playbooks/ping.yml
```

- Terraform output `nodes`가 이름·vmrest ID·그룹을 내보내고, `render-inventory.sh`가 ID로 vmrest `/vms/{id}/ip`(open-vm-tools 보고)를 조회해 `infra/ansible/inventories/lab/.generated/terraform.yml`(Git 제외)을 만든다. Provider의 `ip`가 고정값이라 쓰는 REST 보완이며, 7장 10번(미지원 기능만 보완)에 해당한다.
- 결과: `k3s-server` 172.16.133.134, `worker-cpu-1` .136, `worker-cpu-2` .135. 정적 인벤토리(`hosts.yml`의 물리 `gpu-host`)와 병합되어 `k3s_server`, `k3s_agents`, `platform_nodes`, `app_nodes`, `vms`, `gpu_nodes` 그룹이 구성된다.
- `ping.yml`: 세 VM 모두 SSH 성공. 전용 `known_hosts`의 호스트 키 지문은 `wNQP…`, `Y9cf…`, `B9Fc…`, machine-id는 `669f…`, `c5ad…`, `7bd7…`로 모두 달랐다(골든 이미지 일반화 확인). 재구축된 노드가 같은 IP에 새 키로 나타나도 막히지 않도록 `render-inventory.sh`가 해당 IP의 옛 호스트 키를 지운다.

### 13.10 Ansible 기본 구성 (12장 6번, 4장 Ansible 책임 중 VM 부분)

```bash
ansible-playbook playbooks/bootstrap.yml   # 2회 실행
ansible-playbook playbooks/k3s.yml         # 2회 실행
```

- `bootstrap.yml`(역할 `common`)은 Rocky 9.8과 SELinux enforcing을 먼저 단언한다. DNF로 공통 패키지·`container-selinux`·`selinux-policy-base`를 설치하고, SHA-256이 고정된 Rancher 공개 키와 `k3s-selinux-1.6-1.el9` RPM을 검증·설치한다. 이어서 호스트명, `/etc/hosts`, `overlay`·`br_netfilter`, 포워딩·bridge-nf sysctl, 스왑 없음, `chronyd`를 구성한다. K3s의 RHEL 계열 권고에 따라 VM의 `firewalld`는 중지·비활성화한다.
- `k3s.yml`: K3s `v1.36.4+k3s1`을 GitHub 릴리스 바이너리 SHA-256(`835873f3…`)으로 검증해 설치한다. systemd 유닛과 `/etc/rancher/k3s/config.yaml`(0600)은 Ansible이 관리하며 Rocky 노드에는 `selinux: true`를 기록한다. 조인 토큰은 `secrets/k3s-token`(0600), kubeconfig는 `secrets/kubeconfig`(0600)에 새로 생성한다. 노드 라벨은 `platform`(worker-cpu-1)·`app`(worker-cpu-2)이다.
- 첫 `bootstrap.yml`은 노드당 `changed=12`, 두 번째는 전 노드 `changed=0`이었다. 첫 K3s 적용에서 서버는 정상 기동했지만 Ansible의 root PATH에 `/usr/local/bin`이 없어 준비 확인 명령만 실패했다. 플레이북의 모든 검증 명령을 `/usr/local/bin/k3s` 절대경로로 수정한 뒤 서버·에이전트 설치와 합류가 성공했고, 두 번째 `k3s.yml`은 서버·워커 모두 `changed=0`이었다.
- 최종 상태는 세 노드 모두 `Ready`, OS `Rocky Linux 9.8 (Blue Onyx)`, K3s `v1.36.4+k3s1`이다. 시스템 파드 9개는 모두 `Running` 또는 `Completed`다. 세 노드는 SELinux enforcing, `multi-user.target`, 스왑 0, GUI 패키지 없음, NetworkManager·vmtoolsd·chronyd enabled/active, firewalld disabled/inactive이며, K3s 프로세스는 `container_runtime_t`, 바이너리는 `container_runtime_exec_t` 컨텍스트다.
- `gpu-host.yml`은 `site.yml`에 넣지 않았다. `-e host_changes_allowed=true` 없이 실행하면 **권한 상승 전에** 중단함을 확인했다(처음 버전은 플레이 수준 `become` 때문에 사실 수집 단계에서 sudo를 먼저 시도했다 → 가드가 가장 먼저 실행되도록 수정, sudo 시도 0회 확인).
- 4장의 나머지 Ansible 책임(worker-cpu-1의 Jenkins·Argo CD·모니터링·MySQL, worker-cpu-2의 API·전처리 워크로드, 물리 gpu-host의 GPU 런타임과 K3s 합류)은 이번 인계 범위(12장) 밖이다. 노드 라벨로 배치 기반만 마련했고, gpu-host는 14장 7번의 유지보수 절차로 진행한다.

### 13.11 Rocky Linux 9.8 마이그레이션 및 기존 런타임 폐기

- 폐기 전 세 노드와 K3s 시스템 파드 상태를 기록했다. 노드는 모두 Ready였고 CoreDNS, metrics-server, local-path-provisioner, Traefik 계열 파드가 동작 중이었다.
- Ansible 비동기 명령으로 세 게스트를 정상 종료하고 vmrest가 모두 `poweredOff`임을 확인한 뒤 `scripts/tf.sh destroy -auto-approve`로 VM 세 대와 Terraform 관리 상태를 제거했다.
- vmrest에서 이전 골든 이미지와 OS 없는 스모크 기준 VM을 삭제하고 Workstation `inventory.vmls`의 두 항목도 제거했다. images/vms 디렉터리가 빈 상태이고 vmrest 등록 VM이 0대임을 확인했다.
- 이전 설치 ISO·체크섬, 동적 Ansible inventory, 전용 known_hosts, K3s token·kubeconfig, 이전 Terraform state 백업과 골든 빌드 로그를 제거했다. vmrest 인증서·SSH 키·콘솔 암호 해시·Ansible venv는 새 환경에서 재사용하므로 보존했다.
- 소스에서는 이전 자동설치 템플릿과 Packer HCL을 삭제하고 Rocky Kickstart·Packer HCL·ISO 검증 스크립트로 대체했다. Terraform 기본 골든 이름, provider 스모크 테스트 기준 이름, README, 인계서와 다이어그램도 같은 기준으로 바꿨다.
- 최종 `scripts/preflight.sh`는 `0 FAIL, 0 WARN`, Terraform 재계획은 exit 0 `No changes`, 골든 이미지 SHA-256은 복제 뒤에도 불변이었다.
- 셸 `bash -n`, Packer `fmt -check`·필수 변수 포함 `validate`, 렌더링한 Kickstart의 `ksvalidator -v RHEL9`, Terraform `fmt -check`·`validate`, 모든 Ansible playbook `--syntax-check`도 통과했다.

## 14. 남은 위험과 후속 조치

| # | 위험 | 영향 | 대응 |
|---|---|---|---|
| 1 | Workstation 커널 모듈은 커널 업데이트 때 자동 재빌드되지 않는다(09-11 부팅 실패의 원인). | 새 커널로 재부팅하면 `vmware.service` 실패, VM 기동 불가 | `preflight.sh`가 "최신 설치 커널에 vmmon.ko 없음"을 경고한다. 재부팅 전 **콘솔에서** `sudo vmware-modconfig --console --install-all` 실행(별도 유지보수 작업, 원격으로 자동화하지 않음). |
| 2 | Provider 2.0.1은 생성 실패 시 VM을 state에 남기지 않는다. | Terraform이 모르는 고아 VM | 부모 NIC `custom/vmnet8` + 꺼진 생성 규칙을 지키면 재현되지 않았다. 발생하면 vmrest API로 확인 후 삭제한다. |
| 3 | Provider의 모든 수정은 VM 강제 전원 차단을 동반한다. | CPU·메모리·전원 변경 시 게스트 데이터 손상 위험(특히 K3s 서버) | 변경 전 Ansible로 게스트를 정상 종료한다. README에 명시. |
| 4 | Provider는 `https = true`에서도 인증서를 검증하지 않는다. | TLS가 서버 인증을 하지 않음 | vmrest는 루프백 전용이고 자격증명이 필요하다. `vmrest-start.sh`와 `preflight.sh`가 바인딩을 강제·검사한다. |
| 5 | 노드 IP는 vmnet8 DHCP 임대(30분/최대 2시간)다. MAC 기반 클라이언트 ID라 같은 VM은 대체로 같은 주소를 받지만 보장되지 않는다. | K3s 에이전트는 서버 IP로 접속하므로 서버 주소가 바뀌면 재접속 필요 | 주소가 바뀌면 `render-inventory.sh` → `site.yml` 재실행. 영구 해결은 `/etc/vmware/vmnet8/dhcpd/dhcpd.conf` 예약(root 필요, 유지보수 작업)이나 게스트 고정 IP. |
| 6 | Terraform 관리 VM은 Workstation GUI 라이브러리에 나타나지 않는다. | GUI에서 열어 조작하면 state와 어긋날 수 있음 | 7장 6번 제약 유지. 관찰은 `vmrun -T ws list`, vmrest API, `scripts/tf.sh show`로 한다. |
| 7 | 물리 `gpu-host`의 K3s 합류는 수행하지 않았다. | 클러스터에 GPU 노드 없음 | `playbooks/gpu-host.yml`은 `-e host_changes_allowed=true` 없이는 권한 상승 전에 중단한다. NVIDIA Container Toolkit 설치 후 콘솔 유지보수 창에서 `-K`와 함께 실행한다. |
| 8 | Workstation 사용자 설정 두 가지를 바꿨다(`prefvmx.defaultVMPath`, `pref.autoSoftwareUpdatePermission=deny`). | GUI의 새 VM 기본 위치가 XDG 경로로 바뀌고 자동 업데이트 확인이 꺼짐 | 원본은 `~/.local/state/k3s-vmware-lab/backups/`. 되돌리려면 해당 줄 삭제 또는 백업 복원(스모크 테스트 재검증 필요). |
| 9 | Git 저장소는 초기화·스테이징까지만 했다. | 커밋 이력 없음 | git `user.name`/`user.email`이 설정돼 있지 않고, git 설정은 임의로 바꾸지 않았다. 설정 후 `git commit`만 하면 된다. |
| 10 | Terraform state는 로컬 단일 파일이다. | 디스크 손상 시 유실 | `tf.sh`가 변경 명령 전 0600 백업을 30개까지 순환 보관한다. |
| 11 | vmrest는 사용자 프로세스라 재부팅·로그아웃 시 멈춘다. | Terraform 실행 불가 | 작업 전 `scripts/vmrest-start.sh`. 상시 서비스화는 하지 않았다(영구 설정 변경이므로 사용자 판단). |
| 12 | Workstation 인벤토리에 디렉터리가 없는 `Server(B)` 잔존 항목이 있다. | 기능 영향 없음 | 사용자 소유 항목이라 그대로 두었다. |
| 13 | 골든 이미지 빌드는 vmnet8의 고정 주소(.10)를 쓴다. | 그 주소를 다른 장치가 쓰면 빌드 불가 | `golden-build.sh`가 빌드 전 응답 여부를 확인하고 거부한다. `BUILD_IP=`로 바꿀 수 있다. |
| 14 | 클러스터 VM 3대는 가동 상태로 남겨 두었다(설정 합계 12GB, 게스트 지연 할당으로 실사용은 더 적음). | 원격 세션 중 호스트 메모리 사용 | 정지는 게스트 정상 종료 후 상태를 맞춘다: `ansible vms -b -m command -a 'systemctl poweroff'` → `scripts/tf.sh apply -var power_state=off`. 재기동은 `scripts/cluster-apply.sh` 후 `render-inventory.sh`. |
| 15 | Rocky DVD ISO는 약 15.2GB로 크다. | 캐시와 백업 공간 사용 증가 | ISO는 한 벌만 `iso-cache`에 두고 `fetch-rocky-iso.sh`의 서명·크기·SHA-256 검증을 통과한 파일만 사용한다. 스모크 테스트는 Rocky 골든을 기준으로 사용하므로 별도 기준 VM을 두지 않는다. |
