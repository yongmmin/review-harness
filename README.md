# Frontend Harness

React/Next.js 프론트엔드 작업용 Claude Code 플러그인입니다. `/front-harness "자연어 요청"` 한 줄을 받아 6개 전문 에이전트(developer / ui-builder / component-auditor / test-runner / reviewer / refactor-architect)에게 작업을 위임합니다. 기본 상태로는 범용 harness 로 동작하고, 조직은 gitignore 대상인 private overlay 로 자기 레포·컨벤션 규칙을 얹을 수 있습니다 ([조직 전용 overlay](#조직-전용-overlay) 참고).

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

**업데이트** — marketplace 가 로컬 디렉터리로 등록되므로 자동 업데이트되지 않습니다. 등록한 디렉터리를 갱신한 뒤 플러그인을 업데이트합니다:

```bash
cd ~/claude-plugins/front-harness && git pull
claude plugin marketplace update front-harness
claude plugin update front-harness@front-harness
```

열려 있는 세션에는 `/reload-plugins` 로 적용하고, 새 세션은 자동으로 새 버전을 씁니다. 세션 안에서는 `/plugin` → **Installed** → front-harness → **Update now** 로도 됩니다.

`jq` 가 있어야 review gate 와 사용률 표시가 동작합니다. `rtk` 는 선택입니다. 설치 스크립트 상세와 제거 방법은 [docs/hooks.md](docs/hooks.md) 참고.

## 빠른 시작

프로젝트 디렉터리에서 Claude Code 를 열고:

| 명령 | 하는 일 |
|---|---|
| `/front-harness 결제 화면에 결제 API 연결해줘` | 기능 추가. 계획(`plan.md`) 승인 → 구현 → 테스트 → 리뷰 → commit |
| `/front-harness https://figma.com/design/xxx 이 화면 구현해줘` | Figma 프레임을 UI 로 구현 |
| `/front-harness 이 코드 리팩토링해줘` | 중복 패턴을 찾아 리팩터 계획을 먼저 제안 |
| `/code-review` | 현재 변경을 PASS / FAIL 로 리뷰 |
| `/git-branch` | 브랜치 이름과 `git checkout -b` 명령을 만들어 줌 (실행은 본인이) |
| `/git-pr` | PR 제목·본문·`gh pr create` 명령을 만들어 줌 (실행은 본인이) |

처음 실행하면 출력 압축(rtk) 모드를 한 번 묻습니다. 레포 레지스트리가 없으면 범용 규칙으로 진행하고, 레지스트리는 있는데 현재 디렉터리가 등록돼 있지 않으면 등록할지 이번만 임시로 진행할지 묻습니다.

## Workflow

```
Feature        [search-knowledge? || component-auditor?] → developer
               → test-runner → reviewer → git-commit → DONE

Small change   메인 세션이 직접 수정
               → test-runner → reviewer → git-commit → DONE

Figma          [search-knowledge? || component-auditor] → ui-builder
               → [pixel-check || a11y-check] → reviewer → git-commit → DONE
```

- `||` 는 병렬 실행, `?` 는 조건에 따라 건너뛰는 단계입니다.
- **Small change** 는 기존 파일 2개 이하만 고치고 새 파일·컴포넌트·hook·store·endpoint·socket event 를 만들지 않는 변경입니다. `plan.md` 작성과 승인 대기를 건너뜁니다.
- 그 외 경로는 `plan.md` 를 쓰고 승인을 받은 뒤 실행합니다.
- 테스트 실패와 reviewer FAIL 은 합쳐서 3회까지 재시도하고, 상한에 닿으면 중단하고 남은 문제를 보고합니다.
- `DONE` 이후(브랜치, push, PR)는 사용자가 직접 합니다.
- UI(디자인 없음), Refactor, Review 흐름은 [skills/front-harness/SKILL.md](skills/front-harness/SKILL.md) 의 Workflow Selection 참고.

## Agent와 모델

| Agent | 역할 | model | effort |
|---|---|---|---|
| developer | TDD 구현 + API 통합 (types → hook/service → UI states) | `opus` | high |
| ui-builder | Figma 또는 기존 스타일에 맞춘 UI 구현 | `opus` | high |
| test-runner | 테스트 실행 + 결과 요약 | `opus` | medium |
| reviewer | 변경 리뷰 (correctness / react-perf / design / scope). commit 전 단일 품질 gate | `fable` | high |
| refactor-architect | 중복 패턴 감지 + 추출 제안 (`plan.md` 만 작성) | `fable` | high |
| component-auditor | 새 UI 작성 전 재사용 컴포넌트 탐색 (읽기 전용) | `sonnet` | medium |

모델은 각 `agents/*.md` 의 frontmatter `model:` 값입니다. 에이전트별 역할은 [docs/skills.md](docs/skills.md) 참고.

## 꼭 알아야 할 규칙

1. **git 작업은 사용자가 실행합니다.** 플러그인은 commit 만 자동으로 하고, 브랜치 생성·push·PR 은 명령과 본문만 만들어 줍니다. "푸시해줘" 는 거절하고 명령만 보여 줍니다.
2. **reviewer PASS 없이는 commit 이 막힙니다.** reviewer 판정은 리뷰 시점의 작업 트리 hash 와 함께 파일에 기록됩니다. 리뷰 후 코드를 고치면 다시 리뷰해야 합니다 (`git add` 는 영향 없음). `git commit` 은 hook 이 같은 검사로 차단합니다. 그래도 commit 하려면 명시적으로 지시하세요. override 로 기록됩니다.
3. **조직 overlay 가 추가 규칙을 넣을 수 있습니다.** 예: 기능 변경 시 QA 문서 갱신을 reviewer FAIL 조건으로 추가. overlay 가 없으면 이 문서의 규칙만 적용됩니다.
4. **5시간 사용률이 80% 이상이면 모델을 묻습니다.** reviewer / refactor-architect 를 띄우기 전에 `Fable 유지` / `이번 실행은 Opus` 를 한 번 묻고, 그 실행 동안 유지합니다. 사용률은 status line 이 `~/.claude/usage-state.json` 에 기록한 값을 읽으며, 파일이 없거나 10분 넘게 갱신되지 않았으면 묻지 않습니다.
5. **`package.json`, `next.config.*`, `tsconfig*.json` 수정은 승인이 필요합니다.** `.env*` 는 수정할 수 없습니다.

## 상태 파일 위치

플러그인은 작업 중인 레포 안에 파일을 만들지 않습니다. 모두 `~/.front-harness/state/<repo-id>/` 에 둡니다. `<repo-id>` 는 작업 트리 이름 + 절대 경로 hash 라서 git worktree 마다 따로 생깁니다.

| 파일 | 내용 |
|---|---|
| `run-state.json` | 진행 중인 workflow, 단계별 완료, 재시도 횟수, reviewer 판정 |
| `plan.md` | 승인 대기 중인 계획. 작성할 때마다 전체 경로를 알려 줍니다 |
| `rtk-session.flag` | 출력 압축 모드 |
| `approved/` | 설정 파일 수정 승인 기록 (30분 TTL) |
| `cache/` | tsc / eslint 임시 파일 (1시간 지나면 정리) |
| `repo-path` | 이 폴더가 어느 작업 트리의 것인지 |

실행이 중간에 끊기면 다음 `/front-harness` 시작 때 이어서 할지 새로 시작할지 묻습니다. cross-project 학습은 `~/.front-harness/wisdom/` 에 저장됩니다.

## 조직 전용 overlay

조직·회사에 한정된 내용은 tracked 파일에 두지 않고, gitignore 대상인 두 폴더에 둡니다.

- `private/skills/<skill>.md`, `private/agents/<agent>.md` — skill / 에이전트별 조직 규칙
- `private/constraints.md` — `#org` constraints 섹션, `private/docs/` — 이 문서들의 조직판
- `knowledge/index.md`, `knowledge/<org>/*.md` — 레포 레지스트리(`repos.md`)와 도메인 지식

`hooks/org-overlay.sh` 가 overlay 파일을 출력하고, 각 skill 은 로드 시점에, 에이전트는 `hooks/extract-constraints.sh` 를 통해 전달받습니다. 두 폴더가 없으면(새로 clone 한 상태) overlay 는 아무것도 출력하지 않고 플러그인은 범용 React/Next.js harness 로 동작합니다.

## 상세 문서

- [docs/skills.md](docs/skills.md) — skill 15개 설명, `/front-harness` 진행 흐름, `/git-pr` 출력, 에이전트별 규칙
- [docs/hooks.md](docs/hooks.md) — hook 스크립트 12개, Git 정책, 설정 파일 보호와 제거 방법, constraints 시스템, RTK, 조직 overlay · knowledge 구조
- [CHANGELOG.md](CHANGELOG.md) — 버전별 변경 이력
- [skills/front-harness/SKILL.md](skills/front-harness/SKILL.md) — 실행 시 기준이 되는 workflow 정의
- [constraints.md](constraints.md), [CLAUDE.md](CLAUDE.md) — 에이전트 규칙과 런타임 규칙

라이센스: MIT. 사내 개인용 도구라 외부 PR 은 받지 않습니다.
