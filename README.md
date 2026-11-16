# Frontend Harness

React/Next.js 코드 개발 품질을 위한 범용 Claude Code 하네스 플러그인입니다. `/front-harness "자연어 요청"` 한 줄을 받아 계획 → 구현 → 테스트 → 리뷰를 전문 에이전트(developer / test-runner / reviewer / refactor-architect)에게 맡기고, reviewer 가 PASS 한 변경만 commit 되게 막습니다. 조직별 knowledge(레포 구조, 사내 컨벤션)는 플러그인에 포함되지 않으며, 각자 자기 컴퓨터에 따로 준비합니다.

## 설치 / 업데이트

**1. 클론 + 부트스트랩**

```bash
git clone https://github.com/yongmmin/front-harness.git ~/claude-plugins/front-harness
cd ~/claude-plugins/front-harness
chmod +x install.sh && ./install.sh
```

`install.sh` 는 `~/.claude/settings.json` 에 `.env*` 보호 룰을 추가하고(쓰기 전 `.bak` 백업) 다음 단계 명령을 안내합니다.

**2. 플러그인 등록 (필수)** — Claude Code 세션 안에서:

```
/plugin marketplace add ~/claude-plugins/front-harness
/plugin install front-harness@front-harness
```

이 단계를 거쳐야 hooks 와 agents 가 활성화됩니다. 설치 후 새 세션에서 `/plugin` 으로 확인하세요.

**업데이트** — marketplace 가 로컬 디렉터리로 등록되므로 자동 업데이트되지 않습니다:

```bash
cd ~/claude-plugins/front-harness && git pull
claude plugin marketplace update front-harness
claude plugin update front-harness@front-harness
```

열려 있는 세션에는 `/reload-plugins` 로 적용합니다. `jq` 가 있어야 review gate 와 사용률 표시가 동작하고, `rtk` 는 선택입니다. 상세는 [docs/hooks.md](docs/hooks.md).

## knowledge 준비

플러그인만 설치하면 범용 규칙으로 동작합니다. 내 조직의 레포와 컨벤션을 반영하려면 아래 두 폴더를 직접 만듭니다. 둘 다 플러그인 폴더 밖에 있어 git 에 올라가지 않습니다.

| 위치 | 내용 |
|---|---|
| `~/.front-harness/knowledge/index.md` | 세션 시작 때 요약되는 개요 |
| `~/.front-harness/knowledge/<org>/repos.md` | 레포 레지스트리. 현재 디렉터리가 어느 레포인지 매칭하는 데 씀 |
| `~/.front-harness/knowledge/<org>/*.md` | 도메인 지식 (아키텍처, 컨벤션 등) |
| `~/.front-harness/org/skills/<skill>.md` | skill 에 덧붙는 조직 규칙 |
| `~/.front-harness/org/agents/<agent>.md` | 에이전트에 덧붙는 조직 규칙 |
| `~/.front-harness/org/constraints.md` | `## #org` 절. 에이전트 constraints 에 덧붙음 |

지금 가능한 준비 방법은 파일을 직접 쓰는 것입니다. `repos.md` 는 레포마다 아래 형식의 블록을 둡니다:

```markdown
### my-app
- **local_path**: `/absolute/path/to/my-app`
- **role**: 한 줄 설명
- **layout**: `src/`
```

작성 후 플러그인 폴더에서 확인합니다:

```bash
bash hooks/detect-repo.sh /absolute/path/to/my-app     # Active Repo 블록이 나오면 등록 성공
bash hooks/org-overlay.sh skills front-harness         # 작성한 overlay 가 출력됨
bash hooks/extract-constraints.sh reviewer             # #org 절과 에이전트 overlay 가 끝에 붙음
```

작업 중 얻은 지식은 `/save-knowledge` 로 같은 폴더에 추가할 수 있습니다. 폴더가 비어 있으면 overlay 는 아무것도 출력하지 않고, 레포 매칭과 조직 규칙 없이 범용 규칙만 적용됩니다. knowledge 자동 생성 skill 은 예정 (0.6.0) 입니다.

## 빠른 시작

프로젝트 디렉터리에서 Claude Code 를 열고:

| 명령 | 하는 일 |
|---|---|
| `/front-harness 결제 화면에 결제 API 연결해줘` | 기능 추가(UI 포함). 계획(`plan.md`) 승인 → 구현 → 테스트 → 리뷰 → commit |
| `/front-harness 이 코드 리팩토링해줘` | 중복 패턴을 찾아 리팩터 계획을 먼저 제안 |
| `/code-review` | 현재 변경을 PASS / FAIL 로 리뷰 |
| `/git-branch` | 브랜치 이름과 `git checkout -b` 명령을 만들어 줌 (실행은 본인이) |
| `/git-pr` | PR 제목·본문·`gh pr create` 명령을 만들어 줌 (실행은 본인이) |
| `/rtk-toggle` | 플러그인 내부 명령의 출력 압축 모드 변경 |

처음 실행하면 출력 압축(rtk) 모드를 한 번 묻습니다.

## Workflow

```
Feature        search-knowledge? → developer → test-runner → reviewer → git-commit → DONE

Small change   메인 세션이 직접 수정 → test-runner → reviewer → git-commit → DONE

Refactor       search-knowledge? → refactor-architect → 사용자 재승인
               → developer → test-runner → reviewer → git-commit → DONE

Review         reviewer
```

- `?` 는 조건에 따라 건너뛰는 단계입니다. UI 작업도 Feature 로 처리합니다.
- **Small change** 는 기존 파일 2개 이하만 고치고 새 파일·컴포넌트·hook·store·endpoint·socket event 를 만들지 않는 변경입니다. `plan.md` 작성과 승인 대기를 건너뜁니다.
- 그 외에는 `plan.md` 를 쓰고 승인을 받은 뒤 실행합니다. 계획의 `Reuse` 항목(무엇을 재사용하는지, 새로 만든다면 구체적 이유 하나)은 비워 둘 수 없고, 비어 있으면 reviewer 가 FAIL 합니다.
- 테스트 실패와 reviewer FAIL 은 합쳐서 3회까지 재시도하고, 상한에 닿으면 중단하고 남은 문제를 보고합니다.
- `DONE` 이후(브랜치, push, PR)는 사용자가 직접 합니다.

## Agent와 모델

| Agent | 역할 | model | effort |
|---|---|---|---|
| developer | TDD 구현 + API 통합 (types → hook/service → UI states) | `opus` | high |
| test-runner | 테스트 실행 + 결과 요약 | `opus` | medium |
| reviewer | 변경 리뷰 (correctness / react-perf / design / scope). commit 전 단일 품질 gate | `fable` | high |
| refactor-architect | 중복 패턴 감지 + 추출 제안 (`plan.md` 만 작성) | `fable` | high |

모델은 각 `agents/*.md` 의 frontmatter `model:` 값입니다.

## 꼭 알아야 할 규칙

1. **git 작업은 사용자가 실행합니다.** 플러그인은 commit 만 자동으로 하고, 브랜치 생성·push·PR 은 명령과 본문만 만들어 줍니다.
2. **reviewer PASS 없이는 commit 이 막힙니다.** 판정은 리뷰 시점의 작업 트리 hash 와 함께 파일에 기록됩니다. 리뷰 후 코드를 고치면 다시 리뷰해야 합니다 (`git add` 는 영향 없음). 그래도 commit 하려면 명시적으로 지시하세요. override 로 기록됩니다.
3. **조직 overlay 가 규칙을 더할 수 있습니다.** 예: 기능 변경 시 QA 문서 갱신을 요구하는 gate.
4. **5시간 사용률이 80% 이상이면 모델을 묻습니다.** reviewer / refactor-architect 를 띄우기 전에 `Fable 유지` / `이번 실행은 Opus` 를 한 번 묻습니다. 사용률은 status line 이 `~/.claude/usage-state.json` 에 기록한 값을 읽으며, 파일이 없거나 10분 넘게 갱신되지 않았으면 묻지 않습니다.
5. **`package.json`, `next.config.*`, `tsconfig*.json` 수정은 승인이 필요합니다.** `.env*` 는 수정할 수 없습니다.

## 상태 파일 위치

플러그인은 작업 중인 레포 안에 파일을 만들지 않습니다. 실행 상태는 `~/.front-harness/state/<repo-id>/` 에 둡니다. `<repo-id>` 는 작업 트리 이름 + 절대 경로 hash 라서 git worktree 마다 따로 생깁니다.

| 파일 | 내용 |
|---|---|
| `run-state.json` | 진행 중인 workflow, 단계별 완료, 재시도 횟수, reviewer 판정 |
| `plan.md` | 승인 대기 중인 계획. 작성할 때마다 전체 경로를 알려 줍니다 |
| `rtk-session.flag` | 출력 압축 모드 |
| `approved/` | 설정 파일 수정 승인 기록 (30분 TTL) |
| `cache/` | tsc / eslint 임시 파일 (1시간 지나면 정리) |

실행이 중간에 끊기면 다음 `/front-harness` 시작 때 이어서 할지 새로 시작할지 묻습니다.

## 상세 문서

- [docs/skills.md](docs/skills.md) — skill 10개 설명, `/front-harness` 진행 흐름, `/git-pr` 출력, 에이전트
- [docs/hooks.md](docs/hooks.md) — hook 스크립트 12개, Git 정책, 설정 파일 보호와 제거 방법, constraints, RTK, overlay·knowledge 구조
- [CHANGELOG.md](CHANGELOG.md) — 버전별 변경 이력
- [skills/front-harness/SKILL.md](skills/front-harness/SKILL.md) — 실행 시 기준이 되는 workflow 정의
- [constraints.md](constraints.md), [CLAUDE.md](CLAUDE.md) — 에이전트 규칙과 런타임 규칙

라이센스: [MIT](LICENSE). 외부 PR 은 받지 않습니다.
