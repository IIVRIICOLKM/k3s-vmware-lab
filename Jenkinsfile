// Jenkinsfile - CI for k3s-vmware-lab (proposal: Jenkins build and test automation, weeks 10-12).
//
// When the code changes, Jenkins checks the C++ inference worker, the Python training code, the shell scripts and the Helm chart.
// Only when all checks pass it builds the images with Kaniko, the way scripts/image-build.sh does, tagged with the commit.
// Every stage runs in a Kubernetes agent pod (namespace ci); the commands live in scripts/jenkins-stage-*.sh so that the
// same checks run by hand: scripts/jenkins-check.sh.
//
// [한국어 설명] 코드가 바뀌면 Jenkins가 아래 순서로 돈다. 단계마다 Kubernetes 에이전트 파드에서 실행된다.
//   검사 (파드 1개: jnlp + gcc + torch 컨테이너. 앞 단계가 실패하면 뒤 단계는 건너뛴다)
//     소스    GitHub develop 체크아웃. 시험용으로는 작업 폴더를 ConfigMap으로 받는다 (SOURCE_ID 파라미터, scripts/jenkins-run.sh)
//     C++     apps/infer를 make CUDA=0으로 빌드하고 실행 검사          → scripts/jenkins-stage-cpp.sh
//     Python  py_compile과 tests/train 단위 시험                         → scripts/jenkins-stage-python.sh
//     쉘      bash -n과 ShellCheck(v0.11.0 고정)                        → scripts/jenkins-stage-shell.sh
//     Helm    helm lint와 helm template (학습 Job, 추론 Deployment)     → scripts/jenkins-stage-helm.sh
//   이미지 (검사가 모두 통과했을 때만. 이미지마다 파드 1개를 차례로: kaniko가 gpu-host에서 빌드. Kaniko는 컨테이너 하나로 이미지 하나만 만든다)
//     infer-worker, train-worker를 registry.k3slab.local:5000/<이름>:<태그>로 빌드해 push하고 digest를 확인한다.
//     태그는 덮어쓰지 않는다: git 소스는 git-<커밋 7자리>, ConfigMap 소스는 src-<소스 해시 12자리>.
//     이미 있는 태그는 다시 빌드하지 않고 그 digest를 쓴다 (scripts/image-build.sh의 "태그는 불변" 규칙과 같다).
//   결과 기록: ci-result.json(빌드 산출물)과 ConfigMap ci-latest(git) / ci-latest-local(ConfigMap 소스)에 태그·커밋·digest를 남긴다.
//     Argo CD 연동은 이 값을 읽는다 (infra/k8s/jenkins/README.md "결과 전달").

// ---------------------------------------------------------------------------------------------------------------
// 도우미 함수 (파이프라인 밖: 파드 정의와 이미지 목록)
// ---------------------------------------------------------------------------------------------------------------

// imageDir 이름 : 이미지 이름 → 빌드 폴더. 허용 목록에 없으면 에러 (파라미터로 임의 경로가 들어오지 못하게)
def imageDir(String name) {
  if (name == 'infer-worker') { return 'apps/infer' }
  if (name == 'train-worker') { return 'apps/train' }
  error("unknown image '${name}' (allowed: infer-worker, train-worker)")
}

// agentCommon : 모든 에이전트 파드가 같은 배치와 계정을 쓴다.
//   gpu-host에서 돌린다: 물리 PC라 메모리가 넉넉하고(VM 노드는 3~6GB), Kaniko가 큰 베이스 이미지(CUDA 8GB)를 풀 디스크도 거기 있다.
//   GPU는 요청하지 않는다(nvidia.com/gpu 없음, runtimeClass 없음). taint만 견딘다.
//   serviceAccountName: 결과 ConfigMap(ci-latest)을 쓸 수 있는 최소 권한 (infra/k8s/jenkins/ci-base.yaml)
//   securityContext: 모든 컨테이너에 seccomp RuntimeDefault (컨테이너 런타임의 기본 시스템 호출 제한).
//     컨테이너마다 privileged 금지와 권한 상승 금지(allowPrivilegeEscalation: false)를 따로 적는다. 추가 capability는 없다.
def agentCommon() {
  return '''
  serviceAccountName: jenkins-agent
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  nodeSelector:
    k3slab.io/role: gpu
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
'''
}

// jnlpContainer : Jenkins 에이전트 본체. 이미지는 고정 태그. 소스를 ConfigMap으로 받을 때만 /ci-source에 마운트한다.
def jnlpContainer(String sourceId) {
  def mount = sourceId ? '''
      volumeMounts:
        - name: ci-source
          mountPath: /ci-source
          readOnly: true''' : ''
  return """
    - name: jnlp
      image: docker.io/jenkins/inbound-agent:3395.v6e5377b_0fb_3c-5-jdk25
      securityContext: {privileged: false, allowPrivilegeEscalation: false}
      resources:
        requests: {cpu: 50m, memory: 128Mi}
        limits: {memory: 384Mi}${mount}
"""
}

// checksPod : 검사 단계 파드. 컨테이너는 단계가 시작될 때 모두 뜨고 cat으로 대기한다(container('이름') { sh ... }로 명령을 넣는다).
//   gcc   : C++ 빌드, 쉘 검사, Helm 검사 (apps/infer/Dockerfile의 빌드 이미지와 같은 gcc:15.3.0-trixie. curl, bash, xz 포함)
//           appArmorProfile Unconfined는 이 컨테이너 하나에만 준다 (파드 전체나 jnlp에는 주지 않는다).
//           이유: gpu-host의 containerd 기본 AppArmor 프로파일(cri-containerd.apparmor.d//&unconfined)이 컨테이너 안에서 자식
//           프로세스에 신호(TERM, KILL, USR1)를 보내는 것을 막는다 (kill -0만 됨, root와 CAP_KILL이 있어도 EPERM).
//           C++ 단계가 워커를 띄우고 SIGTERM으로 끝내 보는 시험(scripts/jenkins-stage-cpp.sh)에 신호가 필요하다.
//           포기하는 것: 이 컨테이너의 AppArmor 한 겹. 나머지(seccomp, 권한 상승 금지, privileged 금지)는 그대로다.
//           자세히: infra/k8s/jenkins/README.md "gpu-host의 AppArmor"
//   torch : 학습 이미지의 베이스와 같은 PyTorch 이미지 → 운영과 같은 Python·torch·numpy로 시험한다
//   requests 합계 CPU 1100m / 메모리 1152Mi, limits 메모리 합계 4.4Gi (cc1plus와 torch가 잠깐 쓰는 양)
def checksPod(String sourceId) {
  def volume = sourceId ? """
  volumes:
    - name: ci-source
      configMap:
        name: ci-source-${sourceId}""" : ''
  return '''
apiVersion: v1
kind: Pod
metadata:
  labels:
    k3slab.io/ci: checks
spec:''' + agentCommon() + volume + '''
  containers:''' + jnlpContainer(sourceId) + '''
    - name: gcc
      image: docker.io/library/gcc:15.3.0-trixie
      command: ["cat"]
      tty: true
      securityContext:
        privileged: false
        allowPrivilegeEscalation: false
        appArmorProfile:
          type: Unconfined
      resources:
        requests: {cpu: 500m, memory: 512Mi}
        limits: {memory: 2Gi}
    - name: torch
      image: docker.io/pytorch/pytorch:2.14.1-cuda13.0-cudnn9-runtime
      command: ["cat"]
      tty: true
      securityContext: {privileged: false, allowPrivilegeEscalation: false}
      resources:
        requests: {cpu: 500m, memory: 512Mi}
        limits: {memory: 2Gi}
'''
}

// buildPod : 이미지 단계 파드. scripts/image-build.sh의 Kaniko Job과 같은 설정이다 (같은 Kaniko v1.28.6, 요청 CPU 1 / 메모리 2Gi).
//   이미지마다 이 파드를 새로 만든다 (Kaniko는 빌드 하나가 끝나면 컨테이너의 파일시스템을 지우므로 컨테이너 하나로 이미지 하나만 만든다).
//   kaniko : -debug 이미지는 같은 v1.28.6에 busybox 셸이 들어 있어 Jenkins가 명령을 넣을 수 있다 (일반 이미지는 셸이 없다)
//   tools  : 레지스트리 조회와 결과 기록(curl, bash)용. 검사 파드와 같은 gcc 이미지라 노드에 이미 있다.
//   hostAliases: 파드 안에서 registry.k3slab.local을 레지스트리 ClusterIP로 연결 (파드는 노드의 registries.yaml을 모른다)
//   limits 메모리 8Gi는 image-build.sh에는 없는 안전장치다: 물리 PC(32GB)를 VM과 나눠 쓰므로 빌드가 폭주해도 호스트를 지킨다.
def buildPod() {
  return '''
apiVersion: v1
kind: Pod
metadata:
  labels:
    k3slab.io/ci: build
spec:''' + agentCommon() + '''
  hostAliases:
    - ip: "10.43.0.50"
      hostnames: ["registry.k3slab.local"]
  containers:''' + jnlpContainer('') + '''
    - name: kaniko
      image: docker.io/martizih/kaniko:v1.28.6-debug
      command: ["/busybox/cat"]
      tty: true
      securityContext: {privileged: false, allowPrivilegeEscalation: false}
      resources:
        requests: {cpu: "1", memory: 2Gi}
        limits: {memory: 8Gi}
    - name: tools
      image: docker.io/library/gcc:15.3.0-trixie
      command: ["cat"]
      tty: true
      securityContext: {privileged: false, allowPrivilegeEscalation: false}
      resources:
        requests: {cpu: 50m, memory: 64Mi}
        limits: {memory: 256Mi}
'''
}

// ---------------------------------------------------------------------------------------------------------------
// 파이프라인
// ---------------------------------------------------------------------------------------------------------------
pipeline {
  // 단계마다 에이전트를 지정한다 (컨트롤러에서는 아무것도 돌리지 않는다)
  agent none

  options {
    timestamps()
    // 한 번에 하나만: gpu-host의 빌드와 같은 태그 중복 빌드를 막는다
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '20'))
    timeout(time: 90, unit: 'MINUTES')
  }

  parameters {
    // 비우면 GitHub(develop)에서 받는다. 값이 있으면 scripts/jenkins-run.sh가 만든 ConfigMap ci-source-<값>의 작업 폴더를 쓴다.
    string(name: 'SOURCE_ID', defaultValue: '', description: 'Empty: check out from git. 12 hex chars: use the working-tree snapshot in ConfigMap ci-source-<id> (scripts/jenkins-run.sh)')
    booleanParam(name: 'BUILD_IMAGES', defaultValue: true, description: 'Build and push the images when every check passes')
    string(name: 'IMAGES', defaultValue: 'infer-worker,train-worker', description: 'Images to build, comma separated (infer-worker, train-worker)')
  }

  stages {
    // ===== 검사: 파드 하나에서 단계를 차례로. 실패하면 이 단계 아래의 나머지와 "이미지" 단계가 건너뛰어진다 =====
    stage('검사') {
      agent {
        kubernetes {
          yaml checksPod(params.SOURCE_ID ?: '')
        }
      }
      stages {
        stage('소스') {
          steps {
            timeout(time: 10, unit: 'MINUTES') {
              script {
                // 새 파드의 작업 폴더는 비어 있지만, 같은 폴더가 다시 쓰이는 경우(로컬 점검 등)에도 이전 파일이 섞이지 않게 비운다
                deleteDir()
                if (params.SOURCE_ID) {
                  // 시험용: ConfigMap에 담긴 작업 폴더 스냅샷. 해시를 다시 계산해 파라미터와 같은지 확인한 뒤 푼다.
                  sh '''
                    set -eu
                    case "$SOURCE_ID" in *[!0-9a-f]*|"") echo "SOURCE_ID must be 12 hex characters"; exit 1;; esac
                    [ "${#SOURCE_ID}" -eq 12 ] || { echo "SOURCE_ID must be 12 hex characters"; exit 1; }
                    got=$(sha256sum /ci-source/source.tgz | cut -c1-12)
                    [ "$got" = "$SOURCE_ID" ] || { echo "source.tgz hash $got differs from SOURCE_ID $SOURCE_ID"; exit 1; }
                    tar -xzf /ci-source/source.tgz -C "$WORKSPACE"
                    echo "source: working-tree snapshot $SOURCE_ID ($(find . -type f | wc -l) files)"
                  '''
                  env.CI_SOURCE = 'configmap'
                  env.CI_COMMIT = 'none'
                  env.IMAGE_TAG = "src-${params.SOURCE_ID}"
                } else {
                  // 운영: GitHub develop (저장소는 공개라 인증이 필요 없다). 작업 정의의 SCM 설정을 그대로 쓴다.
                  checkout scm
                  def commit = sh(returnStdout: true, script: 'git rev-parse HEAD').trim()
                  env.CI_SOURCE = 'git'
                  env.CI_COMMIT = commit
                  env.IMAGE_TAG = "git-${commit.take(7)}"
                }
                currentBuild.description = env.IMAGE_TAG
                echo "source=${env.CI_SOURCE} commit=${env.CI_COMMIT} image tag=${env.IMAGE_TAG}"
              }
            }
          }
        }
        stage('C++') {
          steps {
            timeout(time: 15, unit: 'MINUTES') {
              container('gcc') { sh 'bash scripts/jenkins-stage-cpp.sh' }
            }
          }
        }
        stage('Python') {
          steps {
            timeout(time: 15, unit: 'MINUTES') {
              container('torch') { sh 'bash scripts/jenkins-stage-python.sh' }
            }
          }
        }
        stage('쉘') {
          steps {
            timeout(time: 5, unit: 'MINUTES') {
              container('gcc') { sh 'bash scripts/jenkins-stage-shell.sh' }
            }
          }
        }
        stage('Helm') {
          steps {
            timeout(time: 5, unit: 'MINUTES') {
              container('gcc') { sh 'bash scripts/jenkins-stage-helm.sh "$IMAGE_TAG"' }
            }
          }
        }
      }
      // 검사가 모두 통과했을 때만 이미지 빌드 폴더를 보관해 다음 단계(다른 파드)로 넘긴다
      post {
        success {
          stash name: 'src', includes: 'apps/infer/**,apps/train/**,scripts/jenkins-registry.sh,scripts/jenkins-record.sh'
        }
      }
    }

    // ===== 이미지: 검사 단계가 모두 성공했을 때만 실행된다 (실패하면 Jenkins가 이 단계를 건너뛴다) =====
    //   Kaniko는 빌드가 끝나면 자기 컨테이너의 파일시스템을 지우고 베이스 이미지로 바꾼다. 그래서 같은 컨테이너에서
    //   두 번째 명령(두 번째 이미지)을 실행할 수 없다 (첫 시험에서 "Process exited immediately after creation").
    //   scripts/image-build.sh가 이미지마다 Job을 따로 쓰는 것과 같은 이유로, 여기서도 이미지마다 파드를 새로 만들어 차례로 쓴다.
    //   파드는 항상 하나만 떠 있다 (자원 승인안 그대로). 결과 기록은 마지막 이미지의 파드에서 한다.
    stage('이미지') {
      // 이 단계는 에이전트를 직접 두지 않는다 (아래에서 이미지마다 podTemplate/node로 파드를 만든다)
      when { expression { return params.BUILD_IMAGES } }
      options { timeout(time: 60, unit: 'MINUTES') }
      steps {
        script {
          def registry = 'registry.k3slab.local:5000'
          def tag = env.IMAGE_TAG
          def digests = [:]
          def names = []
          for (n in params.IMAGES.split(',')) {
            if (n.trim()) { names << n.trim() }
          }
          if (names.isEmpty()) { error('IMAGES is empty') }

          for (int i = 0; i < names.size(); i++) {
            def name = names[i]
            def dir = imageDir(name)
            def last = (i == names.size() - 1)
            podTemplate(yaml: buildPod()) {
              node(POD_LABEL) {
                unstash 'src'
                // 태그는 덮어쓰지 않는다: 레지스트리에 이미 있으면 다시 빌드하지 않고 그 digest를 쓴다
                def existing = ''
                container('tools') {
                  existing = sh(returnStdout: true, script: "bash scripts/jenkins-registry.sh digest ${name} ${tag}").trim()
                }
                if (existing) {
                  echo "${name}:${tag} already exists (${existing}); not building it again"
                  digests[name] = existing
                } else {
                  // scripts/image-build.sh와 같은 Kaniko 옵션: 내부 레지스트리는 HTTP라 --insecure, digest는 파일로,
                  // 빌드 폴더는 ConfigMap이 아니라 작업 폴더를 그대로 쓴다 (하위 폴더·크기 제한이 없다)
                  container(name: 'kaniko', shell: '/busybox/sh') {
                    sh """
                      /kaniko/executor \\
                        --context=dir://${env.WORKSPACE}/${dir} \\
                        --dockerfile=Dockerfile \\
                        --destination=${registry}/${name}:${tag} \\
                        --insecure \\
                        --digest-file=${env.WORKSPACE}/.digest-${name} \\
                        --snapshot-mode=redo
                    """
                  }
                  def built = readFile(".digest-${name}").trim()
                  // push됐는지 레지스트리에 다시 물어서 확인한다 (Kaniko가 알려 준 digest와 같아야 한다)
                  def listed = ''
                  container('tools') {
                    listed = sh(returnStdout: true, script: "bash scripts/jenkins-registry.sh digest ${name} ${tag}").trim()
                  }
                  if (listed != built) { error("registry reports '${listed}' for ${name}:${tag}, Kaniko built '${built}'") }
                  digests[name] = built
                  echo "built ${registry}/${name}:${tag} ${built}"
                }

                if (last) {
                  // 결과 기록: Argo CD 연동이 읽는 값 (태그, 커밋, digest)
                  def imageArgs = ''
                  for (e in digests) { imageArgs += " --image ${e.key}=${e.value}" }
                  def configmap = env.CI_SOURCE == 'git' ? 'ci-latest' : 'ci-latest-local'
                  container('tools') {
                    sh "bash scripts/jenkins-record.sh --tag ${tag} --commit ${env.CI_COMMIT} --source ${env.CI_SOURCE} --build ${env.BUILD_NUMBER} --build-url ${env.BUILD_URL} --out ci-result.json --configmap ${configmap}${imageArgs}"
                  }
                  archiveArtifacts artifacts: 'ci-result.json', fingerprint: true
                }
              }
            }
          }
        }
      }
    }
  }

  post {
    success { echo 'CI passed' }
    failure { echo 'CI failed: see the first failing stage above; the image stage is skipped when a check fails' }
  }
}
