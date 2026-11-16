# Hooks와 정책 상세

[README](../README.md) 에서 옮긴 상세 설명. 실행 시 기준 문서는 [`CLAUDE.md`](../CLAUDE.md), [`constraints.md`](../constraints.md), [`skills/front-harness/SKILL.md`](../skills/front-harness/SKILL.md).

## 핵심 원칙

1. **Conductor** — 오케스트레이터는 직접 코드를 작성하지 않고 전문 에이전트에게 위임
2. **Evidence First** — 테스트 실행 결과 없이 완료 선언 금지
3. **YAGNI** — 명시적으로 요청된 것만 구현. 추측 기능 추가 금지
4. **Reuse First** — 계획 단계에서 메인 세션이 재사용 가능한 컴포넌트·hook·util 을 먼저 찾아 `plan.md` 의 `Reuse` 항목에 적음. 비어 있으면 reviewer 가 FAIL
5. **Token Budget** — 모든 에이전트에 최소 컨텍스트만 전달 (constraints.md 태그별 부분 로딩, stderr 로 토큰 측정)
6. **User-Driven Git** — branch 생성 / push / PR 모두 사용자 트리거

## 설치 상세

`install.sh` 는 (v0.2.0 부터 심볼릭 링크를 만들지 않음):

1. 구버전 설치 방식의 skill 심볼릭 링크 / command 스텁 정리 (이 플러그인 소유분만)
2. `~/.claude/settings.json` 의 `permissions.deny` 에 `.env*` 보호 룰 추가 (플러그인은 사용자 settings 를 수정할 수 없어 이 단계만 스크립트로 유지. 쓰기 전 `.bak` 백업)
3. `rtk` 바이너리 감지 (선택. 없어도 동작)
4. 플러그인 등록 여부 확인 + 아래 2단계 명령 안내

> ⚠️ 스킬 심볼릭 링크만으로는 **hooks (`tsc`/`eslint` 자동 피드백 루프)와 agents frontmatter (모델 핀 / 툴 스코핑)가 활성화되지 않는다.** `hooks.json` 과 `agents/` 는 플러그인으로 설치되어야 하네스가 읽고, `${CLAUDE_PLUGIN_ROOT}` 도 그때 주입된다. 설치 후 새 세션에서 `/plugin` 으로 확인.

## Git 정책 (USER-DRIVEN)

| 작업 | 플러그인 동작 |
|---|---|
| **Branch 생성** | 사용자가 `/git-branch` 호출 → 플러그인이 (1) `git branch -a` 로 기존 목록 조회 (read-only), (2) `AskUserQuestion` 으로 base 선택 (main / stage / production 등), (3) 새 이름 묻기, (4) `git checkout -b <name>` 명령어 출력. **절대 실행하지 않음** |
| **Commit** | `run-state.sh check` 통과 시 **자동 실행** (현재 작업 트리에 대한 reviewer PASS 기록 또는 기록된 사용자 override. Conventional Commit). `commit-gate.sh` 가 같은 검사로 `git commit` 을 차단 |
| **Push** | **절대 자동 실행 안 함**. 사용자가 직접 `git push -u origin <branch>` |
| **PR 생성** | 사용자가 `/git-pr` 호출 → 플러그인이 title + body + `gh pr create` 명령어 + 프리필 URL 출력. **`gh` 절대 실행하지 않음** |

### 트리거 표현

| 사용자 입력 | 플러그인 반응 |
|---|---|
| `"브렌치 만들어줘"`, `"브랜치 생성해줘"`, `/git-branch` | 기존 브렌치 조회 → base 선택 → 이름 묻기 → 명령어 출력 |
| `"PR 만들어줘"`, `"PR 본문 만들어줘"`, `"PR 날릴 준비해줘"`, `/git-pr` | 본문 + URL 출력 |
| `"푸시해줘"` | 정중히 거절 + 추천 명령어만 표시 |

## Hooks 12개

`hooks/` 디렉토리. session/tool 이벤트에 자동 후킹되거나, 플러그인 내부 스크립트로 호출됨.

| Hook | 트리거 | 역할 |
|---|---|---|
| **`session-start.sh`** | SessionStart | `~/.front-harness/knowledge/index.md` 컴팩트 요약 출력 + `detect-repo.sh` 호출해서 active repo 메타데이터 컨텍스트 주입 + `~/.front-harness/state/<repo-id>/cache/` 1시간 이상 파일 정리 |
| **`pre-tool-use.sh`** | PreToolUse (Write\|Edit\|MultiEdit\|NotebookEdit) | `package.json`/`next.config.*`/`tsconfig.json` 수정을 deny. 사용자 승인 후 `pre-tool-use.sh --approve <path>` 로 30분 TTL 승인 기록 → 재시도 통과 |
| **`post-tool-use.sh`** | PostToolUse (Write\|Edit\|MultiEdit\|NotebookEdit) | TS/TSX 파일 저장 시 incremental tsc + eslint 병렬 실행, 실패 시 컴팩트 에러만 (디바운스 3초, 자동 캐시 정리). 토큰 예산 stderr 로깅 |
| **`detect-repo.sh`** | session-start + skill 로드 시 | `cwd` 가 `~/.front-harness/knowledge/<org>/repos.md` 의 어떤 레포에 매칭되는지 awk 파싱. 매칭되면 컴팩트 메타데이터 (`name`/`role`/`stack`/`layout`/`env`/`path_alias`/`doc_routing` 등) 출력. 레지스트리가 없으면 아무것도 출력하지 않고, 매칭이 없으면 `not registered` |
| **`extract-constraints.sh`** | 에이전트 spawn 직전 | `constraints.md` 에서 해당 에이전트에 필요한 섹션 태그만 추출 (`#code-rules`/`#filesystem`/`#completion`/`#review`/`#failure-patterns`) + `~/.front-harness/org/constraints.md` 의 `#org` 섹션과 에이전트 overlay 를 덧붙임. 토큰 예산 stderr 로깅 |
| **`org-overlay.sh`** | skill 로드 시 + `extract-constraints.sh` | 조직 overlay(`~/.front-harness/org/skills\|agents/<name>.md`) 출력. 없으면 아무것도 출력하지 않음 |
| **`knowledge-has-content.sh`** | `/search-knowledge` 호출 직전 | knowledge/wisdom 파일에 placeholder 외 실제 내용이 있는지 빠르게 검증. 비어있으면 `/search-knowledge` 호출 자체를 skip |
| **`rtk-wrap.sh`** | 플러그인 내부 Bash 호출 | `git`/`gh`/`tsc`/`eslint`/`jest`/`vitest`/`grep`/`find`/`ls` 등의 호출을 `rtk` 로 감싸서 출력 압축 (모드별). `rtk` 미설치 시 raw 명령으로 fallback. 다른 프로젝트엔 영향 없음 |
| **`usage-state.sh`** | `/front-harness`, `/code-review`, `/refactor-scan` 로드 시 | `~/.claude/usage-state.json` (사용자 status line wrapper 가 기록) 에서 5시간 사용률을 읽어 `N% (resets HH:MM)` 출력. 파일 없음 / 10분 초과 / window 리셋 시 `unknown` |
| **`state-dir.sh`** | 다른 hook / skill 이 호출 | 작업 트리별 상태 디렉터리 `~/.front-harness/state/<repo-id>/` 경로 출력 (`<repo-id>` = 작업 트리 이름 + 절대 경로 hash). 플러그인은 소비 레포 안에 파일을 만들지 않음 |
| **`run-state.sh`** | 모든 workflow 첫 단계 + reviewer + git-commit | `run-state.json` 관리: `start` / `step` / `attempt` / `verdict` / `override` / `check` / `done` / `abandon` / `status`. 재시도 횟수·시각·작업 트리 hash 는 전부 script 가 계산 |
| **`commit-gate.sh`** | PreToolUse (Bash) | active 실행에서 reviewer PASS 가 현재 작업 트리와 일치하지 않으면 `git commit` 을 deny. 상태 파일 없음 → 통과, 24시간 넘게 방치된 실행 → 안내만 |

### Hooks 설치

`hooks.json` 이 `plugin.json` 의 `hooks` 키로 등록됨 — 단, **플러그인으로 설치된 경우에만** (`/plugin install`, [README 설치](../README.md#설치--업데이트) 참고). 스킬 심볼릭 링크만으로는 훅이 로드되지 않음.

## 도구 경계 제거 방법

`install.sh` 가 `~/.claude/settings.json` 의 `permissions.deny` 에 다음 룰을 자동 추가:

| 파일 | 처리 |
|---|---|
| `.env*` | 수정 금지 — settings.json Deny 룰로 하드 차단 (Write/Edit/MultiEdit/NotebookEdit 모두) |
| `package.json` | 수정 전 사용자 승인 필요 — PreToolUse 훅이 deny (`pre-tool-use.sh --approve <path>` 또는 `FE_HARNESS_ALLOW_CONFIG_EDITS=1`) |
| `next.config.js/ts/mjs` / `tsconfig.json` | 같은 승인 게이트 |

### 룰 제거

**1. `.env*` 차단 해제** — `~/.claude/settings.json` 에서 아래 항목 삭제:
```json
"Write(.env*)",
"Edit(.env*)",
"MultiEdit(.env*)",
"NotebookEdit(.env*)"
```

**2. PreToolUse 훅 비활성화** — 이 플러그인 저장소의 `hooks/hooks.json` 의 `PreToolUse` 에서 해당 항목 삭제 (`Write|Edit|MultiEdit|NotebookEdit` = 설정 파일 승인 게이트, `Bash` = `commit-gate.sh` review gate)

**3. 플러그인 완전 삭제**:

```
/plugin uninstall front-harness@front-harness
/plugin marketplace remove front-harness
```

구버전(≤0.1.0) 심볼릭 링크 설치의 잔재가 남아 있다면 `./install.sh` 를 한 번 실행하면 자동 정리됨 (또는 수동으로):
```bash
for skill in front-harness tdd code-review refactor-scan save-knowledge search-knowledge \
  git-branch git-commit git-pr rtk-toggle; do
  rm -f ~/.claude/skills/$skill
  rm -f ~/.claude/commands/$skill.md
done
```

## Constraints 시스템

[`constraints.md`](../constraints.md) 가 모든 룰의 단일 출처. 에이전트마다 자기 태그만 부분 로딩.

### 태그 매핑

| 태그 | 대상 에이전트 |
|---|---|
| `#code-rules` | developer / refactor-architect |
| `#filesystem` | developer |
| `#completion` | developer / test-runner |
| `#review` | reviewer |
| `#failure-patterns` | reviewer / test-runner |
| `#org` | developer / reviewer / refactor-architect (`~/.front-harness/org/constraints.md` 에 있음. 없으면 생략) |

### 토큰 예산 측정

- `hooks/extract-constraints.sh` 와 `hooks/post-tool-use.sh` 가 모든 호출마다 바이트/추정 토큰 수를 **stderr** 에 로그
- 경고 임계값: 8192 바이트 (~2K 토큰)
- 환경변수 `FE_HARNESS_BUDGET_WARN_BYTES` 로 오버라이드
- stderr 는 에이전트 컨텍스트에 도달하지 않음 — 관측용
- `[warn]` 라인 보이면 해당 `constraints.md` 섹션 축소 또는 더 작은 태그로 분리

### `#failure-patterns` 원장 (2026-07-10 증류)

이 원장은 **다른 레이어가 못 잡는 패턴만** 보관 — reviewer.md 정적 게이트 / `#review`·`#org` 룰 / ESLint(tsc) 로 이미 강제되는 룰은 넣지 않음. 40개 시드 중 34개가 중복이라 제거됨.

현재 0건 (2026-11-16 GC: 6건 모두 90일 초과로 제거).

GC 룰: 3072 바이트 초과 시 (extract-constraints.sh stderr 로 관측) 유사 룰 병합 + 90일 이상 항목 제거.

### 결정론적 강제 (2026-07-10)

일부 중복 변수/재선언 류 룰은 프롬프트가 아니라 각 레포의 ESLint 가 강제한다. 어떤 룰이 켜져 있는지는 레포마다 다르며, 조직 overlay 가 레포별 현황을 정리해 둘 수 있다. PostToolUse 훅이 편집 파일 단위로 `eslint --max-warnings=0` 을 돌리므로 `warn` 인 룰도 훅에서는 블로킹이고, 기존 CI 는 그대로다.

## RTK 통합 (선택)

[rtk](https://github.com/rtk-ai/rtk) 는 명령 출력의 토큰을 압축하는 CLI 툴. 플러그인은 **선택적/세션 한정/플러그인 스코프** 로만 통합 — 다른 프로젝트엔 영향 없음.

### 모드

| 모드 | 동작 |
|---|---|
| `off` | raw 명령 그대로 (기본값) |
| `standard` | `rtk` 적용 (git/gh/tsc/eslint/test/grep/find/ls) |
| `aggressive` | standard + `-u` (ultra-compact) |
| `git-only` | `rtk` 가 git/gh 만 압축, 나머지는 raw |

### 모드 선택

- **첫 세션**: `/front-harness` 호출 시 picker 자동 표시
- **수동 변경**: `/rtk-toggle` 또는 `/rtk-toggle standard` 같은 인자
- **상태 조회**: `/rtk-toggle status` (현재 모드는 스킬 로드 시 자동 주입됨)
- **환경 변수 오버라이드**: `FE_HARNESS_RTK=standard` (세션 flag보다 우선)

### 보장

- 글로벌 `rtk init -g` 절대 실행 안 함
- `~/.claude/settings.json` 의 hooks 절대 안 건드림
- 세션 flag 는 `~/.front-harness/state/<repo-id>/rtk-session.flag` 에만 저장 (작업 트리별, 레포 밖)
- `rtk` 미설치 시 silent fallback to raw

## 조직 overlay 와 knowledge 구조

조직·회사에 한정된 내용은 이 저장소에 두지 않는다. 플러그인 폴더 밖의 `~/.front-harness/` 에만 둔다 (`FRONT_HARNESS_HOME` 으로 위치 변경 가능).

```
~/.front-harness/
├── org/
│   ├── skills/<skill>.md       # skill 별 조직 overlay
│   ├── agents/<agent>.md       # 에이전트별 조직 overlay
│   └── constraints.md          # `## #org` constraints 섹션
├── knowledge/
│   ├── index.md                # 세션 시작 시 컴팩트 요약 자동 로드
│   └── <org>/
│       ├── repos.md            # 레포 레지스트리 (detect-repo.sh 가 읽음)
│       └── *.md                # 도메인 지식
├── state/<repo-id>/            # 실행 상태 (run-state.json, plan.md 등)
└── wisdom/                     # cross-project 학습
```

- `hooks/org-overlay.sh <skills|agents> <name>` 이 overlay 파일을 출력한다. 파일이 없으면 아무것도 출력하지 않는다
- 모든 `SKILL.md` 는 로드 시점에 자기 overlay 를 주입받는다
- `hooks/extract-constraints.sh <agent>` 는 `#org` 섹션과 에이전트 overlay 를 오케스트레이터가 에이전트에 넘기는 내용 뒤에 붙인다
- `org/` 와 `knowledge/` 가 없으면 overlay 가 비고, `detect-repo.sh` 는 아무것도 출력하지 않으며, `knowledge-has-content.sh` 는 비어 있다고 보고한다. 플러그인은 범용 규칙만으로 동작한다
- 상세 도메인 파일은 on-demand 로 `search-knowledge` 가 로드. 세션 시작 시엔 `index.md` 만 자동

### 글로벌 wisdom (cross-project 학습)

```
~/.front-harness/wisdom/
├── summary.md                  # 20줄 제한
├── learnings.md
├── decisions.md
└── issues.md
```

진짜 cross-project (특정 조직 한정 아닌) 학습만 여기 저장. 조직 특화는 위의 `~/.front-harness/knowledge/<org>/*` 으로.
