# 모니터링 (Prometheus · Grafana)

제안서 12–14주 항목이다. 추론 워커, GPU, 노드, 작업 상태를 Prometheus로 모으고 Grafana 대시보드로 본다. 13–16주 검증 실험은 이 값을 측정 근거로 쓴다.

- 네임스페이스: `monitoring`. 일반 매니페스트(kustomize)이고 Helm·Operator·CRD는 쓰지 않는다.
- 올리기·내리기: `scripts/monitoring-deploy.sh [apply|status|remove]`
- 확인: `scripts/monitoring-test.sh` → 결과는 `docs/labs/monitoring-<날짜-시각>.md`
- 상태: **클러스터에 배포해 시험을 마쳤다(2026-11-22).** 최종 시험 `monitoring-test.sh --with-gpu`는 PASS 70 / FAIL 0이다. 보고서 `docs/labs/monitoring-20261122-1654.md`, 화면 캡처 `docs/labs/monitoring-20261122-dashboard-*.png`. 시험하면서 찾아 고친 것은 그 보고서 9.3절 "발견 사항"에 있다.
- 다른 곳에서 Prometheus를 부를 때(검증 실험의 `--prom` 등): 네임스페이스 `monitoring`, 서비스 `prometheus`, 포트 `9090`. 클러스터 안 주소는 `http://prometheus.monitoring:9090`, 밖에서는 API 서버 프록시 `kubectl get --raw /api/v1/namespaces/monitoring/services/prometheus:9090/proxy/api/v1/query?query=...`.

## 구성

| 구성요소 | 이미지 (고정 버전) | 위치 | requests (CPU / 메모리) | limits (메모리) | 하는 일 |
|---|---|---|---|---|---|
| Prometheus | `quay.io/prometheus/prometheus:v3.16.0` | worker-cpu-1 (role=platform) | 100m / 384Mi | 768Mi | 지표 저장. 보존 7일, 상한 2GB |
| Grafana | `docker.io/grafana/grafana:13.3.1` | worker-cpu-1 | 50m / 192Mi | 512Mi | 대시보드. 데이터소스·대시보드 자동 등록 |
| kube-state-metrics | `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0` | worker-cpu-1 | 20m / 64Mi | 128Mi | 파드·Job·노드 상태를 지표로 |
| node-exporter | `quay.io/prometheus/node-exporter:v1.13.1` | 노드마다 1개(4개) | 10m / 32Mi | 64Mi | 노드 CPU·메모리·디스크 |
| dcgm-exporter | `nvcr.io/nvidia/k8s/dcgm-exporter:4.6.1-4.8.4` | gpu-host | 25m / 128Mi | 768Mi | GPU 사용률·메모리·전력·온도 |

- 저장소(PVC): `prometheus-data` **3Gi, local-path**, worker-cpu-1. Grafana는 PVC가 없다(emptyDir). 화면은 Git의 JSON에서 다시 만들어진다.
- CPU limit은 두지 않는다. 제한에 걸리면 수집이 밀린다.
- 메모리 합계(requests): worker-cpu-1에 672Mi(Prometheus 384 + Grafana 192 + kube-state-metrics 64 + node-exporter 32), 나머지 노드는 node-exporter 32Mi씩, gpu-host는 dcgm-exporter 128Mi가 더해진다. **이 숫자는 설정값이다. 실제 사용량은 배포 뒤 `kubectl top`과 cAdvisor로 재서 보고서에 적는다.**
- Prometheus·Grafana·kube-state-metrics를 worker-cpu-1(6 GB, role=platform)에 두는 이유: worker-cpu-2(3 GB)는 Argo CD와 Gitea 몫이고, 모니터링까지 올리면 메모리 limits 합계가 3,008 MiB로 안전 한도(약 1,860 MiB)를 크게 넘는다(플랫폼_클러스터의 실측·예산표 `docs/plan-week11-capacity.md`, 4.5절. 총괄은 이를 "한도의 155%"로도 전했다. 산정 기준에 따라 숫자가 조금 다르다). 처음에는 worker-cpu-2를 골랐다가 이 예산표를 보고 worker-cpu-1로 옮겼다. 다른 곳으로 옮기려면 `prometheus.yaml`, `grafana.yaml`, `kube-state-metrics.yaml`의 `nodeSelector` 한 줄만 바꾼다.

## 설치 방식 비교: kube-prometheus-stack vs 직접 매니페스트

비교한 것은 kube-prometheus-stack 차트 **93.6.0**(Operator v0.95.2, 2026-11-20 발행)이다. alertmanager, etcd·scheduler·controller-manager·proxy·coreDNS·apiserver 수집, 기본 규칙, 기본 대시보드를 모두 끄고 `helm template`으로 그려서 센 값이다(근거: 이 세션의 렌더링 결과).

| 항목 | kube-prometheus-stack 93.6.0 (최소 설정) | 직접 매니페스트 (선택) |
|---|---|---|
| 워크로드 | Operator, Grafana, kube-state-metrics Deployment 3개 + node-exporter DaemonSet + 웹훅 인증서 Job 2개 + Operator가 만드는 Prometheus StatefulSet | Prometheus, Grafana, kube-state-metrics Deployment 3개 + node-exporter·dcgm-exporter DaemonSet 2개 |
| 컨테이너 수 (노드 1대 기준 상시) | Operator 1 + Grafana 3(사이드카 2개 포함) + kube-state-metrics 1 + node-exporter 1 + Prometheus 2(config-reloader 포함. Operator가 만드는 파드라 `helm template`에는 안 나오는, 일반적인 구성이다) = 8개 + 노드마다 node-exporter | Prometheus 1 + Grafana 1 + kube-state-metrics 1 + node-exporter 1 = 4개 + dcgm-exporter 1 |
| CRD | 10개(YAML 약 4.6 MB). 6개가 256 KB를 넘는다(가장 큰 `prometheuses`는 838 KB). `kubectl apply`의 주석 한도를 넘으므로 `--server-side`가 필요하다 | 없음 |
| 승인 웹훅 | Mutating·Validating 각 1개와 인증서 Job 2개를 관리해야 한다 | 없음 |
| 메모리 (추정) | 직접 매니페스트보다 Operator·config-reloader·Grafana 사이드카 2개만큼 더 든다. 대략 **200–300 MiB 더**(일반적으로 알려진 크기에서 잡은 **추정**이다. 이 연구실에서 재지는 않았다) | 위 표의 requests 합계. 배포 뒤 실측해서 보고서에 적는다 |
| 수집 대상 지정 | ServiceMonitor·PodMonitor (동적으로 늘어남) | `prometheus.yml`의 pod 서비스 디스커버리 + 라벨 (파일 하나) |
| K3s 특이사항 | etcd·scheduler·controller-manager는 K3s에서 포트가 달라 꺼야 한다 | 해당 없음 (이 대상들을 수집하지 않는다) |
| Argo CD 연동 | Helm 차트 + CRD 순서 문제를 관리해야 한다 | 폴더 하나(`kustomization.yaml`)를 그대로 가리키면 된다 |
| 불편한 점 | 설정이 `values.yaml`에 흩어져 있다 | node-exporter·kube-state-metrics 매니페스트를 직접 유지해야 한다 |

**결정: 직접 매니페스트.** 이유는 세 가지다. (1) 메모리가 빠듯하다(worker-cpu-1은 6 GB에 레지스트리·MySQL·Jenkins가 함께 올라온다). (2) 수집 대상이 여섯 가지로 고정돼 있어 Operator의 동적 디스커버리가 필요 없다. (3) Argo CD가 폴더 하나로 관리할 수 있다. 대신 kube-prometheus-stack이 주는 기본 쿠버네티스 대시보드·알림 규칙은 없다. 이 연구는 알림이 필요 없고 대시보드는 직접 만든 세 개로 충분하다.

## 수집 대상 (`prometheus/prometheus.yml`)

차트(`charts/k3slab-workload`)는 고치지 않았다. 모두 **파드에 이미 있는 라벨**로 찾는다.

| job | 대상 | 찾는 방법 | 간격 |
|---|---|---|---|
| `k3slab-infer` | 추론 워커 `/metrics` | 파드 라벨 `k3slab.io/kind=infer`, Running 파드, 선언된 컨테이너 포트. `release`(Helm 릴리스 이름)·`pod`·`node` 라벨을 붙인다 | 5초 |
| `dcgm-exporter` | gpu-host GPU | `monitoring` 네임스페이스의 `app.kubernetes.io/name=dcgm-exporter`, 포트 `metrics` | 5초 |
| `node-exporter` | 노드 4개 | 같은 방식, 포트 `metrics` | 15초 |
| `kube-state-metrics` | 객체 상태 | 같은 방식, 포트 `http-metrics` (`honor_labels`) | 15초 |
| `cadvisor` | 컨테이너별 CPU·메모리 | 노드마다 kubelet을 API 서버 프록시(`/api/v1/nodes/<노드>/proxy/metrics/cadvisor`)로 읽는다. 필요한 6종만 남긴다 | 15초 |
| `prometheus` | 자기 자신 | 정적 | 15초 |

- 추론 워커는 Pending 파드(GPU를 기다리는 중)를 대상에 넣지 않는다(`phase=Running`만). 넣으면 영원히 down인 대상이 생긴다.
- 추론·GPU를 5초로 짧게 잡은 이유: 시험 부하가 20~60초라 15초 간격이면 값이 3~4개뿐이다.
- 작업 상태(MySQL `jobs`)는 Prometheus가 아니라 Grafana가 직접 읽는다(아래).

### node-exporter의 SELinux 설정 (`seLinuxOptions.type: spc_t`)

- **왜 필요했나:** Rocky VM 3대는 SELinux가 켜져 있다. 기본 라벨(`container_t`)로는 호스트의 `/proc/1/mountinfo`를 읽지 못해 디스크 수집기가 `permission denied`로 실패했고, 디스크 지표가 gpu-host 것만 들어왔다(2026-11-22 클러스터에서 확인). 라벨을 `spc_t`로 바꾸자 4노드 모두 `/` 디스크 지표가 들어온다.
- **무엇을 포기했나:** 이 파드(node-exporter 컨테이너 하나)의 SELinux 격리를 사실상 끈 것이다. 루트 권한·`privileged`는 쓰지 않고, 호스트 마운트는 읽기 전용, capability는 전부 뺀 상태 그대로다. 그래도 컨테이너가 뚫리면 SELinux가 막아 주던 호스트 접근이 열린다.
- **대안:** `spc_t` 대신 필요한 경로(`/proc/1/mountinfo` 읽기)만 허용하는 SELinux 정책 모듈을 VM에 설치하는 방법이 있다. 그러려면 VM 설정을 바꿔야 해서(플랫폼_클러스터 몫) 이번에는 하지 않았다. 디스크 지표가 필요 없으면 `--collector.filesystem`을 빼고 `seLinuxOptions`를 지워도 된다.
- gpu-host(Ubuntu)에는 SELinux가 없어서 이 설정이 무시된다.

### 추론 워커 지표 (`apps/infer/metrics.cpp`에서 확인한 이름)

| 지표 | 종류 | 의미 |
|---|---|---|
| `k3slab_infer_info{device,gpu,model_version}` | gauge(=1) | 계산 장치(`cuda`/`cpu`), GPU 이름, 모델 버전 |
| `k3slab_infer_queue_length`, `_queue_capacity`, `_worker_threads` | gauge | 큐에 기다리는 요청 수, `MAX_QUEUE`, 스레드 수 |
| `k3slab_infer_requests_total{result}` | counter | `ok` / `rejected`(429) / `timeout`(504) / `bad_request`(400) / `failed`(500) |
| `k3slab_infer_batch_size` (`_bucket{le=1,2,4,8,16,+Inf}`, `_sum`, `_count`) | histogram | 배치당 요청 수 |
| `k3slab_infer_batch_compute_seconds` (`_sum`, `_count`) | summary | 배치 계산 시간 (CPU/GPU) |
| `k3slab_infer_request_seconds` (`_bucket{le=0.0005 … 2,+Inf}`, `_sum`, `_count`) | histogram | 성공 요청의 큐 대기 + 계산 시간 (버킷 경계와 이유는 `apps/infer/metrics.h`) |

**지연 p50/p95**: 처음 배포했을 때(2026-11-22, 이 README의 시험 결과)는 워커가 지연의 합계와 개수만 내보내서 p50/p95 패널이 "No data"였다. 같은 날 CICD_연결이 워커에 히스토그램 버킷을 더해 Jenkins → Argo CD로 배포했고, 그 뒤 패널에 값이 나온다(`docs/labs/cicd-e2e-20261122-2141.md` 2-2절: p50 0.25 ms, p95 0.475 ms, 1회). 이 두 값은 첫 버킷(0.5 ms) 안을 보간한 값이라 작은 모델에서는 거칠다.

## GPU: dcgm-exporter

- 버전 `4.6.1-4.8.4`(DCGM 4.6.1 + exporter 4.8.4, 2026-09-18). `4.9.0`(2026-11-06)은 기본 지표 이름과 단위를 바꾼다(사용률 % → 0~1 비율, MiB → 바이트). 실험 도중에 단위가 바뀌지 않도록 4.8.4로 고정했고, 대시보드도 4.8.4 이름(`DCGM_FI_DEV_GPU_UTIL` %, `DCGM_FI_DEV_FB_USED` MiB)으로 썼다.
- `runtimeClassName: nvidia`, `nvidia.com/gpu=present:NoSchedule` toleration, `nodeSelector k3slab.io/role=gpu`(device plugin과 같은 방식).
- **`nvidia.com/gpu`를 요청하지 않는다.** requests·limits에 없으므로 device plugin이 GPU를 세지 않고, GPU 1장은 추론 파드·학습 Job이 그대로 쓴다. GPU가 파드 안에서 보이는 것은 runtimeClass `nvidia`와 이미지 기본 환경변수 `NVIDIA_VISIBLE_DEVICES=all` 덕분이다. 이미지 설정을 직접 읽어 확인했다(`NVIDIA_VISIBLE_DEVICES=all`, `NVIDIA_DRIVER_CAPABILITIES=compute,utility,compat32`). gpu-host의 `/etc/nvidia-container-runtime/config.toml`에서 `accept-nvidia-visible-devices-envvar-when-unprivileged`는 주석 처리된 기본값(true)이다(읽기만 했다).
- NVML로 읽기만 한다. `-k`(파드별 GPU 지표)와 프로파일링(DCP) 지표는 쓰지 않아서 `SYS_ADMIN` 권한도 필요 없다.
- 수집 간격은 `-c 1000`(1초). 기본값 30초면 짧은 부하 시험에서 값이 거의 안 변해 보인다.
- **클러스터에서 확인한 결과**: RTX 3090(GeForce)에서도 사용률·메모리(사용/여유)·전력·온도 5종이 모두 나온다. 파드는 `NVIDIA_VISIBLE_DEVICES=all`만으로 GPU를 보았고 UUID 직접 지정은 필요 없었다. gpu-host는 사용자의 데스크톱이기도 해서 GPU가 쉬는 동안에도 사용률이 흔들린다(시험 중 쉬는 구간 최대 16%, 전력 최대 133 W). 메모리는 처음 limit 512Mi가 실사용(439Mi)에 가까워 768Mi로 올렸다(최종 실측 446Mi).

## 작업 상태: Grafana MySQL 데이터소스 (읽기 전용 계정)

mysqld-exporter와 비교해서 **Grafana MySQL 데이터소스**를 골랐다.

| | mysqld-exporter v0.21.0 | Grafana MySQL 데이터소스 (선택) |
|---|---|---|
| 상태별 작업 수 | 못 구한다. 정해진 수집기(`collect.*`) 목록으로 서버 지표(연결 수, 쿼리 수 등)만 내보내고, 테이블 안의 값을 세는 사용자 정의 쿼리 기능이 없다(v0.21.0 README 기준) | `SELECT status, COUNT(*) FROM jobs GROUP BY status` |
| 진행 에폭 | 못 구한다 | `jobs.detail`의 JSON에서 `epoch`·`epochs`·`loss`를 꺼낸다 |
| 이력(중단·재개) | 못 구한다 | `job_events` 테이블을 시간 위에 그린다 |
| `mysql.yaml` 설정 | `--performance-schema=OFF`라서 수집기 상당수가 비어 있다 | 영향 없음 |
| 추가 파드 | 1개 | 없음 |

- 계정 `k3slab_ro`: `jobs`·`job_events` 두 테이블에 **SELECT만**, 동시 접속 5개. `scripts/monitoring-deploy.sh`가 MySQL 파드 안의 root로 SQL만 실행해서 만든다. `infra/k8s/mysql.yaml`은 고치지 않았다.
- 비밀번호(Grafana 관리자·`k3slab_ro`)는 영문·숫자 32자 무작위로, 처음 한 번만 만든다. 클러스터 Secret `monitoring/grafana-secrets`와 `~/.config/k3s-vmware-lab/secrets/monitoring.env`(권한 600)에 둔다. Git에도 화면에도 없다(`scripts/mysql-deploy.sh`와 같은 방식).
- Grafana 데이터소스는 세션 시간대를 UTC(`+00:00`)로 둔다. 서버 시간대가 UTC가 아니면 `updated_at`이 시간대 차이만큼 어긋나 보인다(로컬에서 +9시간 어긋남을 확인하고 고쳤다).

## 대시보드 (`dashboards/*.json`, 패널 49개)

Grafana가 시작할 때 폴더 `k3s-vmware-lab`에 자동으로 넣는다. 화면에서 고쳐도 저장되지 않고(Git의 JSON이 기준), JSON을 고친 뒤 `monitoring-deploy.sh`를 다시 실행하면 약 1분 안에 반영된다.

| 대시보드 (uid) | 패널 |
|---|---|
| 추론 워커 (`k3slab-infer`, 20개) | 장치·실행 워커·처리량·큐 길이·429 비율·GPU 사용률·GPU 메모리(요약), 초당 요청(결과별), 평균 지연, **지연 p50/p95**(위 주의 참고), 큐 길이와 용량, 429·504 비율, 배치 크기 평균·초당 배치 수, 배치 크기 분포, 배치 계산 시간, 워커 스레드 점유율, 워커 파드 CPU·메모리, GPU 사용률·메모리·전력·온도 |
| 학습 작업 (`k3slab-training`, 13개) | **작업 상태별 개수**, 종류×상태, 진행률, 작업 목록, **진행 에폭**, 상태 변화(분당), 상태 변화 이력(MySQL) / 학습 파드 상태·Job 실행·성공·실패·재시작·CPU·메모리, GPU 사용률(Prometheus) |
| 노드 (`k3slab-nodes`, 16개) | 수집 대상 up·DOWN, Ready 노드, 실행 파드, 모니터링 메모리, TSDB 시계열·디스크, **노드별 CPU 사용률**, **메모리 사용률·사용량**, 파드 메모리 합계, 디스크, load1, 노드별 파드 수, monitoring 파드별 메모리, 수집 대상 표 |

## 배포와 접속

```bash
scripts/mysql-deploy.sh            # 먼저: MySQL과 jobs·job_events 테이블 (이미 했으면 건너뜀)
scripts/monitoring-deploy.sh       # 비밀번호·읽기 전용 계정·매니페스트 적용, 준비될 때까지 대기
scripts/monitoring-test.sh --no-load            # 배포 확인만 (GPU 안 씀)
scripts/monitoring-test.sh                      # 추론 부하까지 (CPU 계산, GPU 요청 없음)
scripts/monitoring-test.sh --with-gpu           # GPU 지표 변화까지 (GPU 1장 사용: 승인 필요)
kubectl -n monitoring port-forward svc/grafana 3000:3000   # http://localhost:3000, 사용자 admin, 비밀번호는 monitoring.env
scripts/monitoring-deploy.sh remove             # 네임스페이스(PVC 포함)·ClusterRole·MySQL 계정 삭제
```

- 설정을 고치면 ConfigMap 이름의 해시가 바뀌어 Deployment가 자동으로 다시 뜬다. 예전 해시의 ConfigMap은 `remove`까지 남는다(몇 KB).
- 시험 부하는 `curl --parallel`(연결 재사용)로 보낸다. 로컬에서 요청마다 curl을 새로 띄우는 방식(week 9 시험)보다 훨씬 빠르다.

## 확인 상태

**클러스터 없이 확인한 것** (이 작업 공간, 2026-11-21)

| 확인 | 결과 |
|---|---|
| `kubectl kustomize infra/k8s/monitoring` | 18개 객체, ConfigMap 이름 해시가 Deployment에 반영됨 |
| `kubeconform -strict` (Kubernetes 1.36.0 스키마, v0.8.0) | 18개 모두 Valid |
| `promtool check config` (Prometheus v3.16.0) | 통과 |
| node-exporter v1.13.1을 DaemonSet과 같은 수집기 옵션으로 실행 | 정상 기동, `node_` 시계열 377개 |
| cAdvisor 필터 규칙(`metric_relabel_configs`)을 실제 모양의 시계열에 적용 | 7개 중 3개만 남음 (컨테이너별 CPU·메모리 + 파드 단위 네트워크). `container=""`, `POD`, 그 밖의 지표는 제거 |
| 로컬 Grafana 13.3.1에 `datasources.yaml`·`dashboards.yaml`을 그대로 적용 | 데이터소스 둘 `OK`(MySQL 읽기 전용 계정 포함, 환경변수 비밀번호), 대시보드 셋 자동 등록 |
| 로컬에서 대시보드 쿼리 전부 실행 (`/api/ds/query`) | 61개 중 오류 0. 비어 있는 것은 p50/p95 2개뿐(위 주의). 로컬 MySQL 8.4.13(클러스터와 같은 버전)에 실제 스키마로 시험 |
| 읽기 전용 계정 (로컬 MySQL 8.4.13) | `SELECT`만 되고 `INSERT`·`DELETE`는 `ERROR 1142`로 거부, `mysql.user` 조회도 거부 |
| `monitoring-deploy.sh`의 비밀번호·계정 함수 (가짜 `kubectl` + 로컬 MySQL) | 처음 생성 / 재실행 시 유지 / 클러스터 재생성 시 로컬 사본에서 복구 / 계정 재실행 멱등 모두 통과. 이 시험에서 `rand_pw`가 `set -e`와 SIGPIPE 때문에 멈추는 버그를 찾아 고쳤다 |
| `monitoring-test.sh` 전체 흐름 (가짜 `kubectl`, 로컬 Prometheus·Grafana·추론 워커) | 64 PASS / 0 FAIL(GPU 없는 모드). 부하 클라이언트가 센 200·429 응답 수와 Prometheus 카운터 증가량이 정확히 같았다(6264=6264, 140637=140637) |

위 시험은 **가짜 kube-state-metrics·cAdvisor·DCGM 지표**(실제 이름·라벨 모양, DCGM은 이 PC의 `nvidia-smi` 값)를 썼다. 실제 클러스터 값이 아니므로 보고서의 측정값으로 쓰지 않는다.

**클러스터에서 확인한 것** (2026-11-22, 최종 보고서 `docs/labs/monitoring-20261122-1654.md`)

| 확인 | 결과 |
|---|---|
| 이미지가 노드에서 받아진다 (quay.io, docker.io, registry.k8s.io, nvcr.io) | 파드 8개 모두 Running, 재시작 0, OOMKilled 없음 |
| 수집 대상 up | prometheus 1/1, kube-state-metrics 1/1, node-exporter 4/4, cadvisor 4/4, dcgm-exporter 1/1, 부하 중 추론 워커 1/1 |
| gpu-host의 node-exporter를 호스트 네트워크 없이 파드 IP로 읽는다 (ufw 변경 없음) | up. 호스트 네트워크 카드 지표는 빠진다(감수) |
| dcgm-exporter가 `nvidia.com/gpu` 요청 없이 GPU 값을 낸다 (GeForce 포함) | GPU 지표 5종(사용률·메모리 사용/여유·전력·온도) 모두 1개씩 들어옴. gpu-host의 GPU 할당은 시험 내내 0이었다 |
| cAdvisor를 API 서버 프록시로 읽는 것이 gpu-host에서도 된다 | up (4노드 모두) |
| kube-state-metrics 지표 이름·라벨이 대시보드 쿼리와 맞는다 | 대시보드 3개의 쿼리 61개 모두 오류 0 (Grafana를 거쳐 실행) |
| Grafana → MySQL 접속 (읽기 전용 계정, `caching_sha2_password`) | 데이터소스 상태 `Database Connection OK`. SELECT만 되고 DELETE·UPDATE·INSERT·DROP·`mysql.user` 조회는 거부 |
| 부하 중 추론 지표 변화 | 보통 부하(GPU): 성공 요청 +346000(초당 5766.7), Prometheus 카운터 = 클라이언트가 센 200 응답. 과부하(CPU 워커): 429 +29562 = 클라이언트 429 응답, 큐 길이 최대 20/20 |
| 부하 중 GPU 지표 변화 | GPU 사용률 평균 46.93%(최대 81%) > 쉬는 구간 최댓값 2.00%, 전력 252.52 W > 133.53 W, GPU 메모리 885 → 1219 MiB |
| 메모리 실사용 | monitoring 네임스페이스 합계 944 MiB (Grafana 343, dcgm-exporter 446, Prometheus 87, kube-state-metrics 19, node-exporter 4개 합 46 MiB. 값마다 반올림해서 합이 조금 다르다) |
| 화면 캡처 | `docs/labs/monitoring-20261122-dashboard-infer.png`, `-nodes.png`, `-training.png` |

못 본 것: 학습 Job이 돌 때의 학습 대시보드 패널(진행률·진행 에폭), 보존 7일이 블록을 지우는 것, GPU 학습 중 DCGM 값. 자세히는 보고서 9.4절.

## 알려진 한계

- 지연 p50/p95는 히스토그램 버킷으로 계산한 근삿값이다. 첫 버킷이 0.5 ms라 그보다 빠른 요청의 분포는 구분하지 못한다(위).
- 큐 길이는 5초 간격으로 읽는 순간값이라 몇 초짜리 포화를 놓친다(보고서 9.3절 6). 429 비율과 함께 본다.
- 파드 DNS: Grafana 데이터소스는 짧은 서비스 이름을 쓴다(`datasources.yaml` 머리 주석). 플랫폼_클러스터가 `localdomain` 문제를 고쳤다고 하지만 이 작업에서 다시 재지는 않았다.
- gpu-host는 사용자의 데스크톱이기도 해서 GPU가 쉬는 동안에도 사용률이 흔들린다(이 PC에서 9~41%를 봤다). 그래서 `monitoring-test.sh --with-gpu`는 "부하 중 평균 > 부하 전·후 쉬는 구간의 최댓값"으로 판정한다. 부하 후 값이 이 범위 안이면 FAIL로 남는다.
- Prometheus 데이터는 local-path PVC라서 worker-cpu-1 VM을 다시 만들면 사라진다. 보존은 7일이다(플랫폼_클러스터 권장값. 검증 실험이 며칠에 걸쳐도 앞선 값이 남도록). 크기 상한 2GB가 PVC 3Gi 안에서 용량을 막는다. 실험 기록은 `docs/labs/`에 따로 남긴다.
- 알림(Alertmanager)은 없다.
