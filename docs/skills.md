# Skills와 Agents 상세

[README](../README.md) 에서 옮긴 상세 설명. 실행 시 기준 문서는 각 `skills/*/SKILL.md` 와 `agents/*.md`.

## `/front-harness` 진행 흐름

1. **RTK Mode Gate** — 첫 세션에서 출력 압축 모드 선택 (off/standard/aggressive/git-only)
2. **Active Repo Gate** — `hooks/detect-repo.sh` 가 cwd → 레포 매칭. 레지스트리(`knowledge/<org>/repos.md`)가 없으면 범용 규칙으로 진행, 있는데 미등록이면 등록할지 임시로 진행할지 질문
3. **Ambiguity Check** — 애매하면 최대 2개 질문. 지시어("그거", "이거") 처럼 대상이 불명확한 요청을 감지해서 명확화 요청. 조직 overlay 가 감지 항목을 추가할 수 있음
4. **Plan Gate** — `plan.md` 를 `~/.front-harness/state/<repo-id>/` 에 작성하고 전체 경로 안내, 사용자 승인 대기 (Small change 경로는 건너뜀)
5. **Workflow 실행** — intent(figma/ui/feature/refactor/review) 별로 다른 체인
6. **`[DONE]`** — git-commit 까지 자동, 그 이후는 사용자 손에

## Skills 15개

진입점 + 보조 명령어. 모두 `/<skill-name>` 으로 호출 가능. 모든 skill 은 로드 시 `hooks/org-overlay.sh skills <name>` 으로 조직 overlay 를 주입받음 (없으면 범용 규칙만 적용).

### 진입점 (1개)

- **`/front-harness`** — 단일 공개 진입점. RTK Mode Gate → Active Repo Gate → Ambiguity Check → Intent Classification → Figma Check → API Spec Check → Plan Gate → 워크플로우 실행

### 컨텍스트 / 지식 (2개)

- **`/save-knowledge`** — 조직 특화 학습은 `knowledge/<org>/*.md` 로, 진짜 cross-project 만 `~/.front-harness/wisdom/*.md` 로 라우팅
- **`/search-knowledge`** — 플러그인 knowledge (`knowledge/index.md`, `knowledge/<org>/*.md`) 와 global wisdom 에서 source 당 3개 이하 bullet 만 반환. knowledge 가 비어 있으면 호출 자체를 skip

### TDD / 구현 (3개)

- **`/tdd`** — 테스트 프레임워크가 설정된 레포는 RED→GREEN, 미설정 레포는 graceful skip 후 구현 + 수동 검증 경로
- **`/implement-figma`** — Figma URL → ui-builder → pixel-check → a11y-check → reviewer → commit. **branch/PR 자동 체인 제거** (사용자 트리거)
- **`/match-style`** — Figma 없이 기존 스타일 매칭. component-auditor → ui-builder → a11y-check → reviewer → commit

### 리뷰 / 검증 (3개)

- **`/code-review`** — 일반 4 카테고리 (correctness/react-perf/design/scope). PASS/FAIL 출력. 조직 overlay 가 FAIL 게이트를 추가할 수 있음
- **`/pixel-check`** — Figma vs 구현. blocker 수준 차이만 보고 (spacing, typography, 디자인 토큰 대신 raw hex, 누락된 interactive state)
- **`/a11y-check`** — Semantic HTML / ARIA / Keyboard / Contrast / lang

### 컴포넌트 / 리팩터 (2개)

- **`/component-audit`** — 새 UI 작성 전 재사용 컴포넌트 검색 (source 당 후보 3개 이하). 3+ 패턴 반복 감지 시 refactor-architect 제안
- **`/refactor-scan`** — 코드베이스 패턴 스캔 → 리팩터 `plan.md` 제안. 승인 전에는 코드 변경 없음

### Git (3개) — **모두 user-driven**

- **`/git-branch`** — 기존 브렌치 조회 → base 선택 (main/stage/production 등) → 이름 묻기 → `git checkout -b` 명령어 출력. **절대 실행 안 함**
- **`/git-commit`** — `run-state.sh check` 통과 시(현재 작업 트리에 대한 reviewer PASS 기록, 또는 기록된 사용자 override) 자동 실행. Conventional Commit 메시지 생성, .npmrc/.env 보호, --no-verify 금지
- **`/git-pr`** — title + body + `gh pr create` 명령어 + 프리필 GitHub compare URL 생성. **`gh` 절대 실행 안 함**

### 플러그인 운영 (1개)

- **`/rtk-toggle`** (`/front-harness:rtk-toggle`) — 플러그인 내부 Bash 호출의 출력 압축 모드 토글 (off/standard/aggressive/git-only). 다른 프로젝트엔 영향 없음 (플러그인 스코프)

## Git 작업 단계 (사용자 트리거)

작업 완료 후 사용자가 명시적으로:

```
/git-branch              # 또는 "브렌치 만들어줘"
```
→ 플러그인이 현재 브렌치 목록 조회 → AskUserQuestion 으로 base 선택 (main/stage/production 등) → 새 이름 묻기 → 명령어 출력 (사용자가 직접 실행)

```
git push -u origin <branch>
```
→ 사용자가 직접

```
/git-pr                  # 또는 "PR 본문 만들어줘"
```
→ 플러그인이 title + body + `gh pr create ...` 명령어 + 프리필 GitHub compare URL 출력 (사용자가 복사·실행)

## `/git-pr` 출력

### PR body 자동 포함

- **Summary** — 왜 (최대 4 bullets)
- **Changed Areas** — 어디 (폴더/모듈)
- **Test Plan** — 체크박스
- **QA** — 조직 overlay 가 요구할 때만 (예: QA 문서 갱신 내역)
- **Related** — Issue / Plan 링크

### 출력 예시

```
## PR Ready

### Title
feat: add user-login-form with React Hook Form

### Body
<full markdown>

### Command to run (copy-paste)
gh pr create --base main --head feat/user-login-form ...

### Prefilled URL (browser fallback)
https://github.com/<owner>/<repo>/compare/main...feat/user-login-form?expand=1&title=...&body=...

### Reminders
- Push the branch first if you haven't: git push -u origin feat/user-login-form
```

## Agents 6개

역할별 모델 alias 사용 — `fable`/`opus`/`sonnet` (YAML frontmatter `model:` + `effort:` + `color:`, 툴 스코핑 포함). 각 에이전트는 자기에게 필요한 `constraints.md` 섹션만 받음 (전체 파일 미전달). 조직 overlay(`private/agents/<agent>.md`, `private/constraints.md` 의 `#org`)가 있으면 `hooks/extract-constraints.sh` 출력에 함께 붙어 전달됨.

| Agent | Role |
|---|---|
| **developer** | TDD RED→GREEN 구현 + API 통합 (types → hook/service → UI states 인라인 담당) |
| **reviewer** | 4 카테고리 (correctness/react-perf/design/scope) 리뷰. commit 전 단일 품질 gate |
| **ui-builder** | Figma 또는 기존 스타일 매칭 UI 구현 |
| **component-auditor** | 새 UI 작성 전 재사용 컴포넌트 탐색 (읽기 전용) |
| **test-runner** | 테스트 실행 + 결과 요약. 테스트 미설정(`no_tests_configured`) 레포에서 fake PASS 금지 |
| **refactor-architect** | 패턴 중복 감지 + 추출 제안 (`plan.md` 만 작성) |
