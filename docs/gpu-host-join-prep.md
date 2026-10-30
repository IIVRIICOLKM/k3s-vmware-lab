# 물리 GPU 호스트(gpu-host) K3s 합류

**2026-10-06 합류 완료.** 4노드 Ready, gpu-host INTERNAL-IP 172.16.133.1, `nvidia.com/gpu` 1, device plugin Running.

스모크 테스트에서 `nvidia-smi`(RTX 3090, 드라이버 580.178.04, CUDA 13.0)와 클러스터 DNS 조회(`kubernetes.default` → 10.43.0.1)가 성공했다. VM에서 호스트 kubelet(10250)으로 접속하면 401이 돌아와 ufw 규칙도 확인했다.

아래는 다시 실행하거나 되돌릴 때를 위한 기록이다. 이 명령은 sudo 비밀번호(`-K`)가 필요하고 호스트 네트워크를 바꾸므로, 다시 실행할 때도 **호스트 콘솔에서** 한다.

## 실행 (콘솔)

조건: VM 3대가 켜져 있고 `scripts/entry.sh`가 통과한 상태여야 한다.

```bash
cd ~/Projects/k3s-vmware-lab
source ~/.local/share/k3s-vmware-lab/ansible-venv/bin/activate
cd infra/ansible
ansible-playbook playbooks/gpu-host.yml -e host_changes_allowed=true -K
```

마지막에 `Smoke-test output`에 `nvidia-smi` 표(RTX 3090)와 `kubernetes.default.svc.cluster.local` 주소가 나오고, `Nodes`에 4대가 보이면 성공이다. 다시 실행해도 안전하다(멱등).

## playbook이 하는 일

| 순서 | 작업 | 바뀌는 곳 |
|---|---|---|
| 1 | `host_changes_allowed` 확인. 없으면 sudo를 쓰기 전에 멈춤 | — |
| 2 | vmnet8 주소가 있는지 확인 | — |
| 3 | NVIDIA Container Toolkit 1.20.1-1 설치(패키지 4개 버전 고정, apt hold) | `/etc/apt/keyrings/nvidia-container-toolkit.asc`(SHA-256 고정), `/etc/apt/sources.list.d/nvidia-container-toolkit.sources`, 패키지 |
| 4 | NetworkManager가 파드 인터페이스를 관리하지 않게 함 | `/etc/NetworkManager/conf.d/k3s.conf` → NetworkManager reload |
| 5 | ufw가 켜져 있으면 규칙 추가 | vmnet8에서 오는 10250/tcp(kubelet)·8472/udp(VXLAN), 10.42.0.0/16(파드)·10.43.0.0/16(서비스) 허용 |
| 6 | k3s-agent 설치·시작 | `/usr/local/bin/k3s`(+`kubectl`·`crictl`·`ctr` 링크), `/etc/rancher/k3s/config.yaml`, `/etc/systemd/system/k3s-agent.service` |
| 7 | (서버에서) gpu-host 등록·Ready 대기 | — |
| 8 | NVIDIA device plugin 배포 → `nvidia.com/gpu` 자원이 보일 때까지 대기 | 서버의 `/var/lib/rancher/k3s/server/manifests/k3slab-nvidia-device-plugin.yaml` |
| 9 | 스모크 테스트 Job: gpu-host의 파드에서 `nvidia-smi`와 DNS 조회 | `default/k3slab-gpu-smoke`(1시간 뒤 자동 삭제) |

6번에서 생기는 agent 설정은 다음과 같다. 렌더링해서 확인한 값이다.

```yaml
node-name: gpu-host
server: https://172.16.133.134:6443    # 그때의 k3s-server IP
node-ip: 172.16.133.1                  # vmnet8 주소 (LAN 192.168.1.162가 아님)
flannel-iface: vmnet8
node-label: [k3slab.io/role=gpu]
selinux: false
token: (secrets/k3s-token)
```

## 왜 이렇게 바꿨나 (2026-10-05 호스트 점검 결과)

| 발견 | 그대로 실행했다면 | 반영한 곳 |
|---|---|---|
| Ubuntu 26.04라 `restorecon`이 없음 | k3s 역할이 이 작업에서 **실패** | `roles/k3s_node/tasks/main.yml`: SELinux가 켜진 경우에만 실행 |
| 기본 경로가 LAN(`enp5s0`, 192.168.1.162) | 노드 IP·VXLAN이 LAN으로 잡혀 VM과의 통신이 NAT를 거쳐 꼬임 | `group_vars/gpu_nodes.yml`의 `k3s_extra_config`(node-ip·flannel-iface) + `roles/k3s_agent`에서 병합 |
| ufw 활성, INPUT·FORWARD DROP | 서버 → kubelet(10250), VXLAN(8472)이 막힘 | `roles/gpu_host_prep` ufw 규칙 |
| NetworkManager 활성 | 파드용 인터페이스를 NetworkManager가 건드릴 수 있음 | `roles/gpu_host_prep` |
| `nvidia-ctk` 미설치, Ubuntu 저장소에 없음 | playbook이 첫 검사에서 멈춤 | `roles/gpu_host_prep`: NVIDIA 저장소 + 버전 고정 |
| vmnet8은 `vmware.service`가 만듦 | 부팅 순서가 어긋나면 k3s-agent가 재시작을 반복 | `k3s.service.j2`: `After=... vmware.service`(gpu-host만) |
| K3s v1.36은 RuntimeClass `nvidia`를 기본 제공 | — | 따로 만들지 않음 |
| `/usr/bin/sudo`가 sudo-rs 0.2.13 (2026-10-06 첫 실행에서 발견) | sudo-rs가 프롬프트를 `[sudo: …] 비밀번호:`로 감싸서 Ansible이 비밀번호를 못 보내고 `Timed out waiting for become ... password prompt`로 멈춤 | `inventories/lab/hosts.yml`: gpu-host만 `ansible_become_exe: /usr/bin/sudo.ws`(기존 sudo 1.9.17) |
| HashiCorp apt 저장소 서명 실패 (2026-09-10 키 교체, 새 키 `FC9CA96ACA026560`; 시스템엔 2023년 키만 있음) | 전체 apt 캐시 갱신이 실패해서 toolkit 설치 단계에서 `Failed to update apt cache after 5 retries`로 멈춤 | `roles/gpu_host_prep`: NVIDIA 저장소만 골라서 갱신(`Dir::Etc::SourceList`, `List-Cleanup=0`). HashiCorp 키 갱신은 별도 작업 |

미리 검증한 것(sudo 없이):

- 플래그 없이 실행하면 첫 작업에서 멈춘다.
- agent 설정·유닛·ufw 대상 대역을 렌더링해서 값을 확인했다.
- 임시 apt 디렉터리로 저장소 서명을 검증했고, 패키지 4개 모의 설치에 성공했다(의존성 추가 없음).
- 두 매니페스트가 실제 API의 `--dry-run=server`를 통과했다.
- `site.yml`을 다시 돌려도 VM 3대는 `changed=0`이다.

## 직접 할 UI 설정 (바꿀 것 없음, 확인만)

| 위치 | 할 일 |
|---|---|
| KDE 시스템 설정 → 전원 관리 → 전원 연결 시 | 자동 절전 "안 함" — **이미 꺼져 있다**. 실험 중에는 메뉴에서 절전·최대 절전을 누르지 않는다(노드 NotReady, VM 정지) |
| KDE 시스템 설정 → 방화벽 | playbook이 넣은 규칙 4개가 보인다(설명: `k3s …`). 지우지 않는다 |
| KDE 네트워크 애플릿 | 합류 뒤 `cni0`·`flannel.1`·`veth…`가 보여도 연결하거나 끊지 않는다 |
| VMware → 편집 → 가상 네트워크 편집기 | vmnet8(NAT, 172.16.133.0/24, "호스트 가상 어댑터 연결")을 **그대로 둔다** |
| NVIDIA 설정 앱 | 바꿀 것 없음. 드라이버 580 유지 |

## 실행 뒤 따로 확인할 때

```bash
export KUBECONFIG=~/.config/k3s-vmware-lab/secrets/kubeconfig
kubectl get nodes -o wide                                    # 4대 Ready, gpu-host INTERNAL-IP 172.16.133.1
kubectl describe node gpu-host | grep -A1 'nvidia.com/gpu'   # Capacity/Allocatable 1
kubectl -n kube-system get pods -l name=nvidia-device-plugin-ds -o wide
sudo grep -n nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml
```

`kubectl`은 합류하면서 생긴 `/usr/local/bin/kubectl`(k3s 링크)을 쓴다.

## 남은 위험

- **서버 IP 변경:** agent 설정에는 그때의 k3s-server IP가 적힌다. DHCP로 서버 IP가 바뀌면 `entry.sh` 뒤에 `gpu-host.yml`을 다시 실행해야 한다(인계서 위험 #5). 근본 해결은 `/etc/vmware/vmnet8/dhcpd/dhcpd.conf`에서 서버 IP를 예약하는 것이다(root 필요, vmnet 재시작 동안 VM 네트워크가 끊김).
- **taint 없음:** gpu-host에는 아직 taint가 없다. `nodeSelector`가 없는 일반 파드도 이 호스트에 배치될 수 있다. GPU 전용으로 묶는 taint는 K3s 실습의 "작업 배치" 단계에서 정한다.
- **VRAM 공유:** 게임 같은 데스크톱 GPU 사용과 학습 파드가 24 GB VRAM을 나눠 쓴다.

## 문제가 생기면 되돌리기

```bash
# 노드 빼기
sudo systemctl disable --now k3s-agent
kubectl --kubeconfig ~/.config/k3s-vmware-lab/secrets/kubeconfig delete node gpu-host
# device plugin 제거 (서버에서)
ansible k3s_server -b -m ansible.builtin.file -a 'path=/var/lib/rancher/k3s/server/manifests/k3slab-nvidia-device-plugin.yaml state=absent'
ansible k3s_server -b -m ansible.builtin.command -a '/usr/local/bin/k3s kubectl -n kube-system delete ds nvidia-device-plugin-daemonset --ignore-not-found'
```

- 재부팅하면 K3s가 만든 인터페이스(`cni0`, `flannel.1`)와 iptables 규칙이 사라진다. `/etc/rancher/k3s`, `/var/lib/rancher/k3s`, `/usr/local/bin/k3s`는 남는다. 다시 합류할 때 그대로 쓰면 된다.
- ufw 규칙(`sudo ufw status numbered` → `sudo ufw delete 번호`)과 `/etc/NetworkManager/conf.d/k3s.conf`는 남겨 둬도 해가 없다.
- toolkit까지 지우려면 다음을 실행한다.
  ```bash
  sudo apt-mark unhold nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container-tools libnvidia-container1
  sudo apt remove nvidia-container-toolkit
  ```
