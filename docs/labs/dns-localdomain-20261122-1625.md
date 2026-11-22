# 클러스터 DNS: 파드의 `localdomain` 때문에 생기던 6초 지연 수정 (2026-11-22 16:25)

관측_모니터링이 찾은 문제를 직접 재현하고, CoreDNS 설정 하나로 고쳤다. VM과 gpu-host 설정, `sudo`는 쓰지 않았다.

## 결과

| 질의 (VM 노드의 시험 파드) | 적용 전 | 적용 후 |
|---|---|---|
| 점이 4개인 긴 이름 `registry.k3slab-system.svc.cluster.local` | **6.01 s** | **0.01 s** |
| `mysql.k3slab-system.svc.cluster.local` | **6.01 s** | **0.01 s** |
| 짧은 이름 `registry.k3slab-system` | 0.00 s | 0.01 s |
| 끝에 점이 붙은 절대 이름 | 0.00 s | 0.01 s |
| `prometheus.monitoring.svc.cluster.local:9090/-/ready` | (측정 안 함) | 0.01 s |
| `gitea.k3slab-system.svc.cluster.local:3000` | (측정 안 함) | 0.01 s |
| 클러스터 밖 `quay.io`, `registry-1.docker.io` (`nslookup`) | 0.02 s, 0.01 s | 0.01 s, 0.01 s |

- gpu-host 노드의 시험 파드는 원래 문제가 없었다(긴 이름 0.01 s). 적용 후에도 같다(0.01 s).
- CoreDNS 로그의 `….localdomain … i/o timeout` 줄: 적용 전 최근 10분에 280줄. 적용 후(`Reloading complete` 이후) **0줄**.
- CoreDNS 파드는 재시작하지 않았다(RESTARTS 9 그대로). ConfigMap이 생기고 약 1분 30초 뒤에 스스로 다시 읽었다.
- 클러스터 밖 이름은 그대로 풀린다(6절).

## 1. 증상

- 파드에서 `x.ns.svc.cluster.local`처럼 점이 4개인 이름을 풀면 약 6초(Go 클라이언트는 약 10초, 관측_모니터링 보고) 걸리고, 짧은 이름(`prometheus`, `mysql.k3slab-system`)은 바로 풀린다.
- CoreDNS 로그에 `prometheus.monitoring.svc.cluster.local.localdomain`, `gitea.k3slab-system.svc.cluster.local.localdomain` 질의의 `i/o timeout`이 반복된다.

## 2. 원인 (직접 재현해서 확인)

| 확인한 것 | 결과 |
|---|---|
| VM 3대의 `/etc/resolv.conf` | 셋 다 `search localdomain`, `nameserver 172.16.133.2` (NetworkManager가 vmnet8 DHCP에서 받음) |
| gpu-host의 `/etc/resolv.conf` | `nameserver 127.0.0.53`(systemd-resolved), `search .` — `localdomain`이 없다 |
| VM 노드 시험 파드의 `/etc/resolv.conf` | `search dns-debug.svc.cluster.local svc.cluster.local cluster.local localdomain`, `ndots:5` |
| gpu-host 노드 시험 파드의 `/etc/resolv.conf` | `search dns-debug.svc.cluster.local svc.cluster.local cluster.local` (`localdomain` 없음) |
| CoreDNS 설정 (`kube-system`의 `coredns`) | `forward . /etc/resolv.conf`. CoreDNS 파드는 k3s-server(VM)에서 돌아서 상위 DNS가 172.16.133.2다. 맨 끝에 `import /etc/coredns/custom/*.server`와 `reload`가 있고, `coredns-custom` ConfigMap은 없었다 |

**흐름:**

1. 점이 5개 미만인 이름은 `ndots:5` 때문에 search 목록을 먼저 거친다. 긴 이름은 `…cluster.local.<네임스페이스>.svc.cluster.local`, `….svc.cluster.local`, `….cluster.local`을 차례로 시도한다. 이것은 CoreDNS가 바로 NXDOMAIN으로 답한다.
2. 마지막 search 항목이 VM에서 물려받은 `localdomain`이라서 `x.ns.svc.cluster.local.localdomain`을 질의한다.
3. 이 이름은 클러스터 존(`cluster.local`)이 아니라서 CoreDNS의 `forward`가 상위 DNS 172.16.133.2로 넘긴다. 상위 DNS는 응답하지 않아서 시간 초과가 난다. 그 뒤에야 절대 이름이 시도되어 성공한다.

**상위 DNS(172.16.133.2)에 VM 안에서 직접 질의한 결과** (호스트에서 보낸 질의는 `quay.io`까지 응답이 없어서 쓰지 않았다):

| 질의 | 결과 |
|---|---|
| `quay.io` | 8개 주소 |
| `quay.io.localdomain` | quay.io의 실제 주소 1개 (23.22.200.48) |
| `github.com.localdomain` | GitHub의 실제 주소 (20.200.245.247) |
| `foo.localdomain` | 응답 없음 (3초 시간 초과) |
| `registry.k3slab-system.svc.cluster.local.localdomain` | 응답 없음 |
| `x.cluster.local.localdomain`, `example.local` | 응답 없음 |

- 상위 DNS는 `.localdomain`을 떼고 풀어 주는 것으로 보인다(그렇게 보는 이유: `quay.io.localdomain`이 `quay.io`의 실제 주소로 풀린다). 그래서 클러스터 밖 이름은 지연이 없다.
- 접미사를 떼면 `.local`이 되는 이름(`cluster.local`)과 한 단어짜리 이름은 응답이 없다. 클러스터 안 긴 이름만 느린 이유다.

## 3. 고치는 방법 비교

| 방법 | 장점 | 단점 | 결론 |
|---|---|---|---|
| **A. `coredns-custom`에 `localdomain` 존을 NXDOMAIN으로** (채택) | 클러스터 안 설정 하나. VM·gpu-host·상위 DNS를 안 건드린다. 모든 파드에 한꺼번에 적용된다. CoreDNS 재시작 없이 반영된다. 지우면 원래대로 돌아간다 | `localdomain` 아래 이름은 풀 수 없게 된다(이 연구실은 쓰지 않는다, 7절) | **채택** |
| B. VM의 DHCP 도메인 제거(NetworkManager `ipv4.dns-search`) | 뿌리를 없앤다 | 3대의 네트워크 설정을 바꾸고 다시 적용해야 한다. 새로 만드는 VM마다 Ansible 역할을 따로 유지한다. 요청한 "VM 설정은 건드리지 않는다"와 어긋난다 | 보류 |
| C. kubelet `--resolv-conf`를 깨끗한 파일로 | 파드 search에서 `localdomain`이 사라진다 | k3s 설정을 바꾸고 모든 노드의 k3s를 재시작해야 해서 지금 배포 중인 다른 세션에 방해가 된다 | 보류 |
| D. 파드마다 `dnsConfig`로 `ndots` 낮추기 | 파드 단위로 끝난다 | 모든 세션의 매니페스트를 고쳐야 하고 새 파드가 빠뜨리면 같은 문제가 난다 | 채택 안 함 |
| E. vmnet8 NAT의 DNS 설정 바꾸기 | 상위에서 해결 | 호스트의 VMware 설정 변경이라 금지 | 채택 안 함 |

## 4. 적용한 것

| 파일 | 내용 |
|---|---|
| `infra/k8s/coredns-custom.yaml` (새 파일) | `kube-system`의 ConfigMap `coredns-custom`. 키 `localdomain.server`: `localdomain:53 { errors; template ANY ANY { rcode NXDOMAIN } }` |
| `infra/ansible/roles/k3s_server/tasks/main.yml` (태스크 1개 추가) | 위 파일을 k3s 서버의 `/var/lib/rancher/k3s/server/manifests/k3slab-coredns-custom.yaml`로 복사한다 |

**클러스터를 다시 만들 때 들어가는 경로:** `scripts/entry.sh` 9단계 → `playbooks/site.yml` → `playbooks/k3s.yml`의 `K3s server` 플레이 → 역할 `k3s_server`의 마지막 태스크 `Deploy the CoreDNS customisation`. k3s는 이 디렉터리의 매니페스트를 적용하고 파일이 바뀌면 다시 적용한다. `nvidia-device-plugin`(`playbooks/gpu-host.yml`)과 같은 방식이다.

- k3s의 AddOn `k3slab-coredns-custom`으로 등록된 것을 확인했다(`kubectl -n kube-system get addon`).
- 이 ConfigMap은 k3s가 관리하므로 `kubectl apply`로 직접 고치지 않는다(`last-applied-configuration` 주석이 없어서 경고가 난다). 고칠 때는 `infra/k8s/coredns-custom.yaml`을 고치고 위 Ansible 단계를 다시 실행한다.

**적용 순서 (2026-11-22):**

| 시각 | 일 |
|---|---|
| 16:1x | 시험 파드로 증상 재현 (VM 파드 긴 이름 6.01 s) |
| 적용 전 | **시험용 CoreDNS**(같은 이미지 `coredns:1.14.6`, 같은 ConfigMap 내용)를 `dns-debug`에 따로 띄워 문법과 동작을 확인했다. `localdomain`은 0.00 s NXDOMAIN, 그 밖의 이름은 일반 블록으로 갔다. 운영 CoreDNS는 건드리지 않았다 |
| 16:21:41 | 기준선 기록: 노드 4개 Ready, `coredns-custom` 없음 |
| 16:21:5x | `ansible-playbook playbooks/k3s.yml -l k3s-server` → `changed=1`(새 태스크만) |
| 16:21:58 | ConfigMap이 클러스터에 생겼다 |
| 16:23:29 | CoreDNS 로그 `Reloading complete` (재시작 없음) |
| 16:23:36 | 적용 후 측정 |
| 이후 | Ansible 재실행 `changed=0`(멱등), `dns-debug` 네임스페이스 삭제 |

- `scripts/entry.sh` 전체는 다시 돌리지 않았다. 다른 세션이 장애 시험을 하는 중이면 Terraform 단계가 VM 전원을 되돌릴 수 있어서, 같은 Ansible 플레이북을 서버 한 대에만 실행했다. 전원과 Terraform은 건드리지 않았다.

## 5. 측정 방법과 전체 값

`dns-debug` 네임스페이스에 `busybox:1.37.0` 파드 2개를 띄웠다(VM 노드 worker-cpu-2, gpu-host). 요청 5m/8Mi, 시험이 끝나서 네임스페이스째 삭제했다. 이미지는 모든 노드에 이미 있었다. busybox에는 `getent`가 없어서 `wget`(libc 해석기가 search 목록을 그대로 쓴다)으로 시간을 쟀고, 시간은 `/proc/uptime`의 0.01초 단위다.

| 질의 | VM 파드 전 | VM 파드 후 | gpu-host 파드 전 | gpu-host 파드 후 |
|---|---|---|---|---|
| 긴 이름 `registry.k3slab-system.svc.cluster.local` | 6.01 s | 0.01 s | 0.01 s | 0.01 s |
| 짧은 이름 `registry.k3slab-system` | 0.00 s | 0.01 s | 0.01 s | 0.00 s |
| 절대 이름 (끝에 점) | 0.00 s | 0.01 s | 0.00 s | 0.00 s |
| 긴 이름 `mysql.k3slab-system.svc.cluster.local:3306` | 6.01 s | 0.01 s | 0.00 s | 0.01 s |
| `quay.io` (`nslookup`) | 0.02 s | 0.01 s | 0.00 s | 0.00 s |
| `registry-1.docker.io` (`nslookup`) | 0.01 s | 0.01 s | 0.00 s | 0.01 s |
| `wget http://quay.io/` (search 목록 거침) | 1.85 s | 1.93 s | 1.98 s | 1.84 s |
| `wget http://github.com/` | 0.12 s | 0.15 s | 0.14 s | 0.11 s |

- `mysql`의 `rc=1`은 3306 포트가 HTTP를 말하지 않아서 난 것이고 시간은 DNS 때문이다.
- `quay.io`의 1.8~2초는 연결과 리다이렉트 시간이다. 절대 이름(`quay.io.`)과 gpu-host 파드도 같아서 DNS 지연이 아니다.
- 적용 후 `registry…:5000/v2/` 3회 반복: 모두 0.01 s(VM), 0.00~0.01 s(gpu-host).
- 실제 서비스 이름 확인(적용 후): `prometheus.monitoring…:9090/-/ready`와 `gitea.k3slab-system…:3000`이 모두 0.01 s, 응답 성공.
- `grafana.monitoring…`은 DNS는 0.00 s였지만 `No route to host (10.43.51.39)`로 연결이 안 됐다. 그 서비스에 준비된 파드가 아직 없는 것으로 보이며(모니터링 세션이 배포 중인 것으로 추정), 이 수정과 무관하다.

## 6. 클러스터 밖 이름은 그대로 풀린다

적용 후 두 시험 파드에서 `ping`으로 풀린 주소를 확인했다. 모두 실제 주소다.

| 이름 | VM 파드 | gpu-host 파드 |
|---|---|---|
| quay.io | 23.22.200.48 | 13.217.177.24 |
| github.com | 20.200.245.247 | 20.200.245.247 |
| registry-1.docker.io | 100.26.133.58 | 34.238.129.170 |

(quay.io, registry-1.docker.io는 주소가 여러 개라서 호출마다 다른 주소가 나올 수 있다.)

- 적용 전에는 `quay.io.localdomain`을 상위 DNS가 실제 주소로 풀어 줘서 search 목록 끝에서 해석됐다. 지금은 그 단계가 즉시 NXDOMAIN이 되고, 그다음 절대 이름 `quay.io`로 풀린다. 주소는 같다.

## 7. 주의할 점과 한계

- `localdomain` 존 전체가 NXDOMAIN이 되므로 `*.localdomain` 이름은 클러스터 파드에서 풀리지 않는다. 저장소에서 `localdomain`을 쓰는 곳은 VM의 `/etc/hosts`의 `localhost.localdomain`뿐이다(DNS가 아니라 영향 없음). 클러스터 안 파드 환경 변수에서도 쓰는 곳이 없었다.
- `ndots:5` 자체의 비용은 남는다. 긴 이름은 search 앞 3개가 NXDOMAIN이 된 뒤에 풀리지만, 모두 CoreDNS가 바로 답해서 합계 약 0.01 s다. 지연이 더 신경 쓰이면 서비스 주소를 끝에 점이 붙은 절대 이름(`….svc.cluster.local.`)으로 쓸 수 있다.
- 상위 DNS 동작(`.localdomain`을 떼고 푼다)은 질의 결과로 추정한 것이다. VMware NAT 쪽 구현을 확인한 것은 아니다.
- 새로 만든 VM도 같은 DHCP를 받아 같은 `search localdomain`을 갖는다. 이 설정이 Ansible 경로에 들어 있어서 클러스터를 다시 만들어도 들어간다(아직 처음부터 다시 만들어 시험하지는 않았다. 서버에서 파일 배치, k3s AddOn 등록, 멱등 재실행까지 확인했다).
- 이미 떠 있는 파드의 `resolv.conf`는 바뀌지 않는다(파드 시작 때 만들어진다). 이 수정은 CoreDNS 쪽이라 기존 파드에도 바로 적용된다.

## 8. 되돌리기

1. `infra/ansible/roles/k3s_server/tasks/main.yml`의 `Deploy the CoreDNS customisation` 태스크를 지우고, k3s 서버의 `/var/lib/rancher/k3s/server/manifests/k3slab-coredns-custom.yaml`을 삭제한다(k3s가 AddOn을 정리한다).
2. 남아 있으면 `kubectl -n kube-system delete configmap coredns-custom`.
3. CoreDNS가 1~2분 안에 다시 읽는다.

## 9. 근거

- CoreDNS 로그: `kubectl -n kube-system logs deploy/coredns`
- Corefile: `kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'` (`# File managed by k3s`, `import /etc/coredns/custom/*.server`)
- 시험 파드: `busybox:1.37.0`, 시험용 CoreDNS: `docker.io/rancher/mirrored-coredns-coredns:1.14.6` (운영 CoreDNS와 같은 버전)
- k3s의 CoreDNS 사용자 설정 방식: Corefile 머리말의 링크 `https://docs.k3s.io/advanced#coredns-custom-configuration-imports`
