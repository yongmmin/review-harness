# Changelog

이 플러그인은 기존 `front-agent` (일반 React/Next 플러그인) 의 Harness Engineering 원칙을 가져와 재구축한 버전입니다.

### v0.4.1 (2026-11-16)

**코드 개발 품질에 집중 — UI/디자인 전용 기능 제거**
- UI·디자인 구현 전용 skill 5개와 agent 2개 제거. 남는 workflow 는 Feature / Small change / Review / Refactor, skill 10개, agent 4개
- UI 요청은 `feature` 로 분류. 디자인 URL 은 `plan.md → Inputs.Design` 에 적는 참고 입력일 뿐 workflow 를 고르지 않음
- `plan.md` 의 `Reuse` 항목은 계획 단계에서 메인 세션이 채움. 비어 있으면 reviewer 가 FAIL
- reviewer 정적 gate 추가: 다른 앱 레포 코드 import, 아이콘만 있는 버튼의 접근 가능한 이름 누락, 키보드로 조작할 수 없는 클릭 요소, `.npmrc` staged, token 이 연결돼 있는데 raw hex, server state 를 Zustand 에 보관
- developer 규칙 추가: 다른 앱 레포 import 금지, Tailwind 주 버전 확인, browser 전용 import 는 `dynamic({ssr:false})`

**조직 overlay 와 knowledge 를 플러그인 폴더 밖으로**
- overlay 는 `~/.front-harness/org/`, knowledge 는 `~/.front-harness/knowledge/` 에서 읽음 (`FRONT_HARNESS_HOME` 으로 변경 가능). 플러그인 폴더에는 조직 전용 파일이 없음
- README 를 범용 하네스 기준으로 다시 쓰고 "knowledge 준비" 절 추가. knowledge 자동 생성 skill 은 0.5.0 예정

### v0.4.0 (2026-11-16)

**Review gate 를 대화가 아닌 파일로 강제**
- `hooks/run-state.sh` + `run-state.json`: workflow 종류, 단계별 완료, 재시도 횟수, reviewer 판정과 리뷰 시점의 작업 트리 hash 기록. 모든 workflow(Small change 포함)가 첫 단계에서 `start`
- `git-commit` 은 `run-state.sh check` 통과 시에만 진행: PASS + hash 일치, 또는 기록된 사용자 override. 리뷰 후 코드가 바뀌면 재리뷰 요구. `git add` / commit 은 hash 를 바꾸지 않음
- `hooks/commit-gate.sh` (PreToolUse Bash): 같은 검사로 `git commit` 을 deny 하는 안전망. 상태 파일 없음 → 통과, 24시간 넘은 active 실행 → 안내만
- 판정은 reviewer 만 기록. 기록이 빠지면 reviewer 를 한 번 다시 띄우고, 그래도 없으면 판정 없음으로 보고 (commit 차단 유지)
- reviewer FAIL 도 테스트 실패와 같은 `MAX_ATTEMPTS = 3` 에 포함. 상한 도달 시 남은 fix list 보고
- 미완료 실행이 있으면 skill 시작 시 "이어서 / 새로 시작" 질문 (`abandon`)

**플러그인이 소비 레포 안에 파일을 만들지 않음**
- `.front-harness-cache/` (rtk flag, 승인 기록, debounce 캐시) 와 `plan.md` 를 `~/.front-harness/state/<repo-id>/` 로 이동 (`hooks/state-dir.sh`, 작업 트리 절대 경로 기준이라 worktree 별로 분리)
- rtk 모드는 플러그인 디렉터리 전역이 아니라 작업 트리별로 저장됨
- 기존 레포에 남은 `.front-harness-cache/` / `plan.md` 는 자동 삭제하지 않음

**조직 전용 내용 분리**
- 조직 전용 내용을 저장소에서 분리, 저장소의 파일은 범용 규칙만 유지 (`hooks/org-overlay.sh`)

### v0.3.1 (2026-11-16)

- 에이전트 모델 티어링: reviewer / refactor-architect → `fable`, developer / test-runner 는 `opus` 유지
- `front-harness` Small change 경로 추가: 기존 파일 2개 이하·신규 요소 없는 변경은 메인 세션이 직접 구현 → test-runner → reviewer → git-commit
- `constraints.md #failure-patterns` GC: 90일 초과 6건 제거. useEffect cleanup 누락 / index-as-key 2건은 `agents/reviewer.md` 정적 게이트로 승격
- Small change 경로는 `plan.md` 작성과 승인 대기를 건너뜀
- 사용률 기반 모델 선택: 5시간 사용률 ≥ 80% 이면 reviewer / refactor-architect 를 띄우기 전에 한 번 묻고(`Fable 유지` / `이번 실행은 Opus`), 선택은 그 실행 동안 유지. `front-harness` / `code-review` / `refactor-scan` 공통 (`hooks/usage-state.sh`, 사용률은 status line wrapper 가 `~/.claude/usage-state.json` 에 기록). 80% 미만이거나 `unknown` 이면 묻지 않고 frontmatter 값 유지
- `plugin.json` / `marketplace.json` 0.3.1

### v0.3.0 (2026-09-23)

**훅 계약 수정 — 조용히 죽어 있던 피드백 루프 2개 복구**
- `post-tool-use.sh`: tsc/eslint 에러를 stdout 평문 + exit 2 로 내보내고 있었음. PostToolUse 의 평문 stdout 은 Claude 에게 전달되지 않음(디버그 로그만). → `hookSpecificOutput.additionalContext` JSON 으로 전달 (jq/python3 로 인코딩). ESLint flat config(`eslint.config.{js,mjs,cjs,ts,mts}`) 및 `.eslintrc.{cjs,yml,yaml}` 탐지 추가
- `pre-tool-use.sh`: "REVIEW REQUIRED" 경고가 같은 이유로 무효였음. → `permissionDecision: deny` 로 실제 차단. 사용자 승인 후 `bash "${CLAUDE_PLUGIN_ROOT}/hooks/pre-tool-use.sh" --approve <path>` 로 30분 TTL 승인 기록 → 재시도 통과. `FE_HARNESS_ALLOW_CONFIG_EDITS=1` 로 전체 우회 가능

**스킬 경로 버그 수정**
- 모든 스킬이 `bash hooks/...` cwd 상대경로를 사용 → 소비 레포(cwd)에서 실행 시 전부 실패. `${CLAUDE_PLUGIN_ROOT}/hooks/...` 절대경로로 교체

**최신 스킬 스펙 적용 (code.claude.com/docs/en/skills 기준)**
- `!`cmd`` / ```` ```! ```` 동적 컨텍스트 주입: detect-repo, rtk 모드, knowledge 유무, `git branch -a`, `git diff --stat`, 테스트 프레임워크 probe 등을 스킬 로드 시점에 자동 삽입 → 스킬당 tool call 2~4회 절감, "detect-repo 를 다시 돌리지 말 것" 규칙 명시
- `disable-model-invocation: true`: git-branch / git-pr / rtk-toggle (user-driven 전용, description 이 컨텍스트에서 빠져 토큰 절감)
- `allowed-tools`: 읽기 전용 git 명령과 플러그인 hook 스크립트 사전 승인 (권한 프롬프트 제거)
- `argument-hint`, `$ARGUMENTS` 전달 표준화
- description 을 트리거 정확도 기준으로 재작성 (언제 발동 / 언제 아닌지 / 한국어 트리거 표현 포함)
- 본문의 `**Model**: claude-opus-4-8` 죽은 줄 제거 (스킬 model 은 frontmatter 필드만 유효)

**에이전트**
- `model: opus` alias (문서 권고) + `effort:` + `color:`. 모델 bump 시 7파일 수정 절차 폐지. 커밋 트레일러는 모델 비의존 `Co-Authored-By: Claude <noreply@anthropic.com>`
- 스폰 규칙 명시: 플러그인 설치 시 `subagent_type` 은 `front-harness:<agent>` 네임스페이스

**기타**
- `plugin.json`: 비표준 `knowledge` 키 → `metadata` 로 이동(`claude plugin validate` 경고 제거), `displayName`/`keywords` 추가, 0.3.0
- `git-commit`: `plan.md`, `.front-harness-cache/` 스테이징 금지 가드
- `refactor-scan`: 슬라이스(≤5파일) 단위 실행 + 슬라이스마다 검증

### v0.2.0 (2026-07-10)

**훅 배선 수리 (기존엔 훅이 실제로 실행되지 않았음)**

- `hooks.json`: `$(dirname "$0")` → `${CLAUDE_PLUGIN_ROOT}/hooks/...` (훅 스크립트 경로가 해석되지 않던 버그)
- `pre/post-tool-use.sh`: 훅 payload 를 stdin JSON `.tool_input.file_path` 로 파싱 (기존 `$CLAUDE_TOOL_INPUT` env 는 fallback)
- `post-tool-use.sh`: 상대경로 무한루프 가드, PID 기반 임시파일, `eslint --max-warnings=0`
- `rtk-wrap.sh`: rtk 모드에서 `npx` 유실 버그 수정 (로컬 바이너리 해석 유지)
- `session-start.sh`: 캐시 정리가 `rtk-session.flag` 를 60분마다 지우던 버그 수정
- `detect-repo.sh`: prefix 오탐 수정 (`my-app-api` 가 `my-app` 으로 매칭되던 문제)
- `knowledge-has-content.sh`: BSD grep 호환 + 실제 knowledge 트리 반영
- `install.sh`: settings.json 파싱 실패 시 덮어쓰기(설정 전체 유실) 제거 + `.bak` 백업

**설치 방식 전환 — 심볼릭 링크 → 정식 플러그인 등록**

- 심볼릭 링크 방식은 스킬만 활성화되고 hooks/agents 는 로드되지 않았음 → `/plugin marketplace add` + `/plugin install` 2단계 설치로 전환
- `install.sh` 재작성: 심볼릭 링크 생성 제거, 구버전 링크 자동 정리 (플러그인 등록 확인 후에만 — 등록 전 실행 시 스킬이 전부 죽는 것 방지), settings deny 룰 + rtk 감지 + 등록 안내만 수행
- `marketplace.json` 에 `name`/`owner` 필드 추가, `plugin.json` v0.2.0

**에이전트 구조**

- 7개 → 6개: `api-integrator` 를 `developer` 로 통합 (쓰기 핸드오프 컨텍스트 유실 = 중복 코드 원인 제거, API 코드가 test-runner 이전에 작성되도록 순서 결함도 해소)
- 전 에이전트에 YAML frontmatter 추가 (`name`/`description`/`model: claude-opus-4-8`/`tools` 스코핑) — 기존 본문 `**Model**:` 표기는 하네스가 읽지 않아 핀이 무효였음

**컨텍스트 다이어트**

- `#failure-patterns` 40건 → 6건 증류 (reviewer 게이트/ESLint 와 중복 제거). reviewer 추출분 9.4KB → 예산(8KB) 내로
- GC 룰을 줄 수 기준 → 바이트 기준(3072B)으로 교체
- 태그 테이블을 extract-constraints.sh 실제 동작과 일치시킴

### v0.1.0 (2026-05-27)

**초기 셋업**

- 플러그인 스켈레톤 (`.claude-plugin/`, `agents/`, `skills/`, `hooks/`, `CLAUDE.md`, `constraints.md`)
- 7개 agents + 17개 skills + 7개 hooks 포팅 (영어, 토큰 최소화)
- 모든 에이전트 모델을 `claude-opus-4-7` 로 핀

**레포 컨텍스트**

- `constraints.md` 에 21개 failure-pattern 시드
- `hooks/detect-repo.sh` 신규: cwd → 레포 매칭
- 레포 레지스트리 등록/조회/추가 skill 신규

**User-Driven Git 정책**

- `git-branch` / `git-pr` 가 자동 실행하지 않도록 변경
- workflow 체인에서 `git-branch → git-commit → git-pr` 자동 체인 제거 → `git-commit → [DONE — await user git ops]`
- `/git-branch` 가 기존 브렌치를 먼저 조회하고 base 선택 (main/stage/production 등) → 이름 묻기 → 명령어 출력
- `/git-pr` 가 본문 + URL 만 생성, `gh` 실행 안 함
- `git-issue` skill 제거 — 3연속 실패 시 사용자에게 컨텍스트 보고만 (이슈 생성은 사용자 판단)

**codex-review 제거**

- `codex-review` skill 제거 — `[reviewer || codex-review]` 병렬 게이트 → 단일 `reviewer` 게이트로 단순화. 4 reference site 모두 정리
