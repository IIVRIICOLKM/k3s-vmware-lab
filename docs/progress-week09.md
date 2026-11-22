# 9주차 진행 요약 (2026-11-07)

진행보고에 옮겨 쓸 수 있게 정리한 문서다. 수치는 모두 `docs/labs/`의 실행 기록에서 가져왔다.
9주차 진행보고(11/6)의 "다음 단계: 9–11주차" 세 항목을 제안서 기한(11주차) 안에 구현하고 검증했다.

## 일정 대비 현황 (연구제안서 7. 구현 일정 기준)

| 일정 항목 | 계획 주차 | 상태 | 근거 |
|---|---|---|---|
| 요구사항 정리·전체 구성도 설계 | 1–2 | 완료 | 2주차 진행보고 |
| 가상머신 3대·호스트 노드 등록 | 2–4 | 완료 | `docs/gpu-host-join-prep.md` |
| K3s 클러스터 구축·노드 조인 | 4–6 | 완료 (PASS 11/11) | `docs/labs/k3s-lab-20261030-1646.md` |
| Docker 이미지·레지스트리·Helm | 5–7 | 완료 | `docs/image-builds.md` |
| Python 학습 흐름·체크포인트 저장 | 6–9 | **완료.** 데이터 로더 인터페이스 분리, 업로드한 파일로 학습 | `apps/train/datasets.py`, `docs/labs/job-db-20261107-1258.md` 7절 |
| C++ 추론 워커 (큐·배치·타임아웃) | 8–11 | **완료.** 모듈 분리, GPU(CUDA) 배치 추론, CPU 대체 경로 | `docs/labs/infer-gpu-bench-20261107-1246.md`, `docs/labs/infer-bench-20261107-1257.md` |
| MySQL 작업 상태 연동·중복 방지 | 9–11 | **완료.** 시험 PASS 18/18 | `docs/labs/job-db-20261107-1258.md` |
| Jenkins 빌드·테스트 자동화 | 10–12 | 다음 주 착수 | — |
| Argo CD / Prometheus·Grafana / 검증 실험 | 11–16 | 예정 | — |

## 주요 결과

**MySQL 작업 상태 (제안서 5·11번 슬라이드)**

- MySQL 8.4를 worker-cpu-1(platform 노드)에 올렸다. `scripts/mysql-deploy.sh` 한 번으로 비밀번호 생성, 배포, 테이블 생성까지 한다.
  - 비밀번호는 무작위로 만들어 클러스터 Secret과 `~/.config/k3s-vmware-lab/secrets/mysql.env`에만 둔다. Git에는 없다.
- 테이블 두 개:
  - `jobs`: 제안서 11번의 컬럼(job_id, job_type, model_version, status, checkpoint_path, result_path, updated_at)에 `attempts`(파드 시도 횟수)와 `detail`(에폭·loss 등 JSON)을 더했다.
  - `job_events`: 상태가 바뀔 때마다 한 줄씩 남는 이력이다. 중단과 재개가 나중에도 보인다.
- 사용자 시나리오 여섯 단계를 `scripts/job.sh` 하나로 묶었다.
  - `submit`(템플릿 선택·모델 버전·실행 요청), `upload`(입력 파일 등록), `status`(진행 상태), `result`(결과 확인)
- 중복 방지는 `jobs`의 PRIMARY KEY로 한다. 등록(PENDING)이 성공했을 때만 Helm으로 Job을 만든다.
- 시험 결과 (`scripts/job-db-test.sh`, **PASS 18/18**):

| 시험 | 결과 |
|---|---|
| 등록 | submit 직후 PENDING, 파드가 뜨면 RUNNING(attempts 1) |
| 실행 중 중복 요청 | 새 Job을 만들지 않고 기존 상태 반환 (Helm 리비전 1 유지) |
| 학습 중단 | 2 에폭 뒤 파드 삭제 → INTERRUPTED → 재시도 파드가 RUNNING(resumed_from), attempts 2 |
| **학습 중 DB 중단** | MySQL을 11초 동안 내림(에폭 3 → 5 진행). 학습은 멈추지 않았고, 못 쓴 에폭 4·5 기록은 DB가 돌아온 뒤 한꺼번에 채워졌다. 최종 DONE |
| 완료 후 중복 요청 | 다시 학습하지 않음, 새 파드 없음 |
| 잘못된 요청 (없는 데이터 파일) | DB에 FAILED와 오류 문구. Job은 재시도 없이 바로 실패(podFailurePolicy, 파드 1개) |
| 입력 파일 등록 후 학습 | `.npz` 업로드 → 그 파일로 학습해 DONE (dataset이 DB에 남음) |
| 추론 작업 | 학습 결과를 서빙 → RUNNING, 응답 확인 → stop → DONE |

**학습 흐름 마무리 (제안서 5번 "설계 기준")**

- 데이터 부분을 `apps/train/datasets.py`로 분리했다. 학습 코드는 데이터를 직접 만들지 않고 `batch()`만 부른다.
  - 실험 주제가 정해지면 Dataset 하나를 추가하면 된다. 학습·체크포인트·상태 기록은 그대로 쓴다.
  - 지금 있는 것: `synthetic`(기존 합성 데이터, 결과가 이전과 같음), `npz:/data/<파일>`(업로드한 표 데이터)
- 모델 크기는 `--hidden`(예: `4096,4096`)으로 바꾼다. 내보내는 `model.k3sm` 형식은 그대로라 추론 워커가 그대로 읽는다.
- 이미지 `train-worker:v0.4`. 기존 중단·재개 시험도 다시 통과했다(**PASS 6/6**, `docs/labs/train-resume-20261107-1253.md`).

**추론 워커 GPU 경로 (제안서 10·14번)**

- `main.cpp` 한 파일(404줄)을 역할별 파일로 나눴다: 설정, 모델, 큐, CPU/GPU 계산, 워커 스레드, 메트릭, HTTP.
  - 빌드 폴더가 ConfigMap으로 넘어가서 하위 폴더를 쓸 수 없다. 그래서 파일은 `apps/infer/` 한 폴더에 둔다.
- GPU 계산은 직접 작성한 CUDA 커널이다. 가중치는 시작할 때 한 번만 GPU로 올린다.
  - CUDA 런타임을 정적으로 링크해서 실행 이미지에는 CUDA 라이브러리가 없다(Debian slim).
  - GPU가 없으면 CPU로 계산한다(`DEVICE=auto`).
- 시작할 때 같은 입력을 GPU와 CPU로 계산해 비교한다. 최대 상대 오차는 1.33e-06이었다.
- CPU vs GPU (요청 400개, 동시 100개, MAX_BATCH 8, WORK_MS 0):

| 모델 | 요청당 곱셈 | CPU 걸린 시간 (계산 시간 합) | GPU 걸린 시간 (계산 시간 합) |
|---|---|---|---|
| 작은 모델 64→128→10 | 약 9천 | 1.27s (0.003s) | 1.21s (0.076s) |
| 큰 모델 64→4096→4096→10 | 약 1,700만 | 2.30s (4.488s) | 1.25s (**0.111s**) |

- 큰 모델에서는 GPU 계산 시간이 CPU의 약 1/40이다.
  - 걸린 시간이 1.2초 밑으로 줄지 않는 이유는 부하 클라이언트(curl, 요청마다 새 연결) 쪽 한계다.
- 작은 모델은 계산이 거의 없어서, GPU로 복사하고 호출하는 비용이 오히려 크다.
- 큐·배치·거절 동작은 분리 전과 같다. MAX_BATCH 1 vs 8은 8.08s vs 1.28s, 큐 20에 동시 300개를 보내면 211개가 즉시 429로 거절됐다(`docs/labs/infer-bench-20261107-1257.md`).
  - v0.1 기록은 8.05s vs 1.31s, 207개 거절이다.

## 제안서 대비 바뀐 점과 근거

| 항목 | 제안서 | 구현 | 근거 |
|---|---|---|---|
| 상태 값 | PENDING / RUNNING / DONE / FAILED | INTERRUPTED를 더함 | SIGTERM으로 끊긴 시도와 진짜 실패를 구분한다. 재개 판단 기준은 그대로다(다시 RUNNING) |
| 작업 등록 창구 | (명시 없음, API 파드) | `scripts/job.sh` | 사용자 시나리오 여섯 단계를 명령 하나로 확인할 수 있다. 웹 API는 Jenkins·Argo CD 연동 뒤 필요하면 추가한다 |
| GPU 추론과 학습 | GPU 공유 | GPU 1개를 둘 중 하나만 쓴다 | device plugin이 GPU를 통째로 하나씩 나눠 준다. 학습 중에는 `--device cpu`로 추론을 띄운다 |

## 문제와 대응 (이번 주 발견)

1. **GPU 추론 롤링 업데이트가 멈춤.**
   - 새 파드가 GPU를 기다리는 동안 예전 파드가 하나뿐인 GPU를 놓지 않았다.
   - GPU를 쓰는 Deployment는 예전 파드를 먼저 내리게(`maxSurge: 0`) 차트를 고쳤다.
2. **학습 이미지에 패키지 설치 실패.**
   - PyTorch 이미지의 Python이 "externally managed"(PEP 668)라서 pip가 시스템 경로 설치를 거부했다.
   - PyMySQL을 해시 고정으로 `/app/vendor`에 따로 설치하고 PYTHONPATH로 잡았다.
3. **CUDA 빌드 실패.** `std::max` 헤더(`<algorithm>`)가 빠져 있었다. 고친 뒤 빌드했고, 실패한 시도는 push되지 않아 태그가 남지 않았다.
4. **DB 재시작 시험이 너무 빨리 끝남.**
   - 처음에는 `rollout restart`로 시험했는데, MySQL이 몇 초 만에 돌아와 재연결 한 번으로 끝났다. 기록 보류 경로가 실제로 실행되지 않았다.
   - MySQL을 2 에폭 동안 내려 두는 방식으로 바꿔 보류된 기록이 나중에 채워지는 것까지 확인했다.

## 다음 주 (10주차) 계획

- Jenkins (10–12주):
  - 코드가 올라오면 C++ 빌드(`make CUDA=0`)와 Python 문법·단위 검사를 돌린다.
  - 통과하면 지금과 같은 Kaniko 방식으로 이미지를 만든다.
- worker-cpu-1 메모리 점검: 레지스트리와 MySQL에 Jenkins·Argo CD·모니터링이 더해진다(6 GB).
- 장애 영역 정리(검증 실험 준비, 13–16주): 물리 호스트가 하나라서 막을 수 없는 장애와 막을 수 있는 장애를 나눈다.
  - 막을 수 없는 장애: GPU 고장, 디스크 고장 시 local-path 데이터 손실
  - 막을 수 있는 장애: 파드·노드 중단, DB 재시작
