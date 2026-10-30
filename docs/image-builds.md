# 이미지 빌드 기록

`scripts/image-build.sh`가 빌드마다 한 줄씩 추가한다. 실행 기록(Helm values)과 함께 보면 어떤 코드와 설정으로 돌린 결과인지 추적할 수 있다.

| 시각 | 이미지 | digest | git 커밋 | 빌드 폴더 | 폴더 해시 |
|---|---|---|---|---|---|
| 2026-10-30 16:54:45 | ~~`registry.k3slab.local:5000/train-worker:v0.1`~~ **삭제**: `/app/train.py`가 ConfigMap 심볼릭 링크(`-> ..data/train.py`)로 들어가 실행 불가. 빌드 스크립트 수정 후 v0.2로 다시 빌드 | `sha256:8542cb16c551f9bd963cedcce49300a79f95f3c83b363a6d7cd4d365da2a5e42` | `e5337a8+dirty` | `apps/train` | `c9325953cdd4348d` |
| 2026-10-30 17:00:01 | ~~`registry.k3slab.local:5000/train-worker:v0.2`~~ **삭제**: GPU에서 이어서 학습할 때 `torch.load(map_location=cuda)`가 난수 상태를 GPU로 옮겨 `set_state()` 실패(재시도 6회 모두). CPU로 읽도록 고쳐 v0.3 | `sha256:833e112b0f54950b63243f887ec03acf4cb0c75b1964273600b470a90083aaa2` | `e5337a8+dirty` | `apps/train` | `c9325953cdd4348d` |
| 2026-10-30 17:00:40 | `registry.k3slab.local:5000/infer-worker:v0.1` | `sha256:20dd54eee1862ccee64c905de5ad22be059c312299ef2ea6ff882aa3050c251e` | `e5337a8+dirty` | `apps/infer` | `dfea8f79bf0f6f73` |
| 2026-10-30 17:15:30 | `registry.k3slab.local:5000/train-worker:v0.3` | `sha256:5eeeab4ba8182a91b0c142f700b074c257e3695a21ba94145de09998d59ad635` | `e5337a8+dirty` | `apps/train` | `f009928cbd0cacf6` |
