#!/usr/bin/env bash
#
# test_ahcli.bash — ahcli.bash 안전 테스트 하니스
#
# 설계 원칙 (SAFETY):
#   1. 실제 네트워크 호출/다운로드 없음. PATH 앞에 mock `aihubshell`을 끼워
#      래퍼가 "조립하는 인자"만 검증한다 (실제 aihubshell은 호출되지 않음).
#   2. 실제 설정 무오염. 모든 것을 mktemp 샌드박스에서 실행하고
#      AIHUB_CONF / HOME 을 샌드박스로 격리한다. ~/.config, ~/.bashrc 안 건드림.
#   3. 위험 명령(install: /opt 복사 + rc 수정) 은 실행하지 않고 정적 검사만.
#   4. get/pget 의 실제 다운로드는 절대 수행하지 않음 (mock 이 가로챔).
#
# 옵션:
#   RUN_NETWORK=1  ./test_ahcli.bash   # ls/pls 의 읽기 전용 실제 API 호출까지 포함
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/ahcli.bash"

PASS=0
FAIL=0
FAILED_NAMES=()

# ---- 출력 헬퍼 ----
c_green() { printf '\033[32m%s\033[0m' "$1"; }
c_red()   { printf '\033[31m%s\033[0m' "$1"; }
c_dim()   { printf '\033[2m%s\033[0m' "$1"; }

ok()   { PASS=$((PASS+1)); echo "  $(c_green '✓') $1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); echo "  $(c_red '✗') $1"; [[ -n "${2:-}" ]] && echo "      $(c_dim "$2")"; }

# 부분 문자열 포함 검증
assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then ok "$name"
  else bad "$name" "기대(포함): '$needle' / 실제: '${haystack:0:200}'"; fi
}
assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then ok "$name"
  else bad "$name" "포함되면 안 됨: '$needle'"; fi
}
assert_eq() {
  local name="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then ok "$name"
  else bad "$name" "기대: '$expected' / 실제: '$actual'"; fi
}

# ---- 샌드박스 구성 ----
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ahcli_test.XXXXXX")"
MOCK_BIN="$SANDBOX/bin"
MOCK_LOG="$SANDBOX/mock_calls.log"
FAKE_HOME="$SANDBOX/home"
FAKE_CONF="$SANDBOX/conf/key"
mkdir -p "$MOCK_BIN" "$FAKE_HOME" "$(dirname "$FAKE_CONF")"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# mock aihubshell: 받은 인자를 로그에 1줄로 기록하고 그대로 echo. 네트워크 없음.
cat > "$MOCK_BIN/aihubshell" <<'MOCK'
#!/usr/bin/env bash
printf 'ARGS:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'
printf '%s\n' "$*" >> "$MOCK_LOG_FILE"
exit 0
MOCK
chmod 755 "$MOCK_BIN/aihubshell"

# 래퍼 실행 래퍼: 샌드박스 환경으로 격리. mock 을 PATH 최우선.
# 결과는 전역 OUT(=stdout+stderr 결합), RC(=종료코드) 에 저장.
# (명령 치환 서브셸을 쓰면 RC 가 부모로 전파되지 않으므로 전역 + 임시파일 사용)
OUT=""; RC=0
run() {
  PATH="$MOCK_BIN:$PATH" \
  HOME="$FAKE_HOME" \
  AIHUB_CONF="$FAKE_CONF" \
  MOCK_LOG_FILE="$MOCK_LOG" \
  bash "$WRAPPER" "$@" >"$SANDBOX/_out" 2>&1
  RC=$?
  OUT="$(cat "$SANDBOX/_out")"
}

echo "════════════════════════════════════════════"
echo " ahcli.bash 안전 테스트"
echo " sandbox: $SANDBOX"
echo "════════════════════════════════════════════"

# ───────────────────────────────────────────────
echo
echo "[1] 정적 검사 (실행 부작용 없음)"
# ───────────────────────────────────────────────
if bash -n "$WRAPPER" 2>/tmp/synerr; then ok "bash -n 구문 검사 통과"
else bad "bash -n 구문 검사" "$(cat /tmp/synerr)"; fi

if command -v shellcheck >/dev/null 2>&1; then
  sc="$(shellcheck -S error "$WRAPPER" 2>&1)"
  if [[ -z "$sc" ]]; then ok "shellcheck (error 레벨) 통과"
  else bad "shellcheck (error 레벨)" "$sc"; fi
else
  echo "  $(c_dim '· shellcheck 미설치 — 건너뜀')"
fi

# ───────────────────────────────────────────────
echo
echo "[2] 도움말 / 알 수 없는 명령"
# ───────────────────────────────────────────────
run
assert_contains "인자 없음 → 사용법 출력" "$OUT" "aih install"
assert_eq "인자 없음 → 종료코드 1" "$RC" "1"

run boguscmd
assert_contains "알 수 없는 명령 → 사용법 출력" "$OUT" "aih login"
assert_eq "알 수 없는 명령 → 종료코드 1" "$RC" "1"

# ───────────────────────────────────────────────
echo
echo "[3] login (키 저장 — 샌드박스 CONF)"
# ───────────────────────────────────────────────
run login TEST_KEY_12345
assert_eq "login 종료코드 0" "$RC" "0"
assert_contains "login 저장 메시지" "$OUT" "saved"
if [[ -f "$FAKE_CONF" ]]; then ok "키 파일 생성됨"
else bad "키 파일 생성됨" "$FAKE_CONF 없음"; fi
assert_eq "키 파일 내용 정확" "$(cat "$FAKE_CONF" 2>/dev/null)" "TEST_KEY_12345"
perm="$(stat -f '%Lp' "$FAKE_CONF" 2>/dev/null || stat -c '%a' "$FAKE_CONF" 2>/dev/null)"
assert_eq "키 파일 권한 600" "$perm" "600"

# ───────────────────────────────────────────────
echo
echo "[4] ls / pls 인자 조립 (mock 가로채기, 네트워크 없음)"
# ───────────────────────────────────────────────
run ls
assert_contains "ls → mode l"            "$OUT" "ARGS: [-mode] [l]"
assert_not_contains "ls (인자없음) → datasetkey 없음" "$OUT" "datasetkey"

run ls 71265
assert_contains "ls KEY → -datasetkey 71265" "$OUT" "[-mode] [l] [-datasetkey] [71265]"

run pls
assert_contains "pls → mode pl" "$OUT" "ARGS: [-mode] [pl]"

run pls 999
assert_contains "pls KEY → -datapckagekey 999" "$OUT" "[-mode] [pl] [-datapckagekey] [999]"

# ───────────────────────────────────────────────
echo
echo "[5] get / pget 인자 조립 (실제 다운로드 없음 — mock)"
# ───────────────────────────────────────────────
# login 으로 저장한 TEST_KEY_12345 가 _key() 로 주입되는지 확인
run get 71265
assert_contains "get DS → mode d"                "$OUT" "[-mode] [d]"
assert_contains "get DS → apikey 주입"           "$OUT" "[-aihubapikey] [TEST_KEY_12345]"
assert_contains "get DS → datasetkey"            "$OUT" "[-datasetkey] [71265]"
assert_not_contains "get DS (파일키 없음) → filekey 생략" "$OUT" "filekey"

run get 71265 1 2 3
assert_contains "get DS 파일키 다수 → 콤마결합" "$OUT" "[-filekey] [1,2,3]"

run pget 555
assert_contains "pget PK → mode pd"        "$OUT" "[-mode] [pd]"
assert_contains "pget PK → datapckagekey"  "$OUT" "[-datapckagekey] [555]"

run pget 555 10 20
assert_contains "pget PK 파일키 → 콤마결합" "$OUT" "[-filekey] [10,20]"

# ───────────────────────────────────────────────
echo
echo "[6] 키 해석 우선순위 / 부재 처리"
# ───────────────────────────────────────────────
# AIHUB_APIKEY 환경변수가 파일보다 우선
out="$(
  PATH="$MOCK_BIN:$PATH" HOME="$FAKE_HOME" AIHUB_CONF="$FAKE_CONF" \
  MOCK_LOG_FILE="$MOCK_LOG" AIHUB_APIKEY="ENV_KEY_999" \
  bash "$WRAPPER" get 71265 2>&1
)"
assert_contains "AIHUB_APIKEY 가 파일보다 우선" "$out" "[-aihubapikey] [ENV_KEY_999]"

# 키 전혀 없음 → 에러
EMPTY_CONF="$SANDBOX/empty/key"
out="$(
  PATH="$MOCK_BIN:$PATH" HOME="$FAKE_HOME" AIHUB_CONF="$EMPTY_CONF" \
  MOCK_LOG_FILE="$MOCK_LOG" \
  bash "$WRAPPER" get 71265 2>&1
)"; rc_nokey=$?
assert_contains "키 부재 → 안내 메시지" "$out" "no key"
assert_eq "키 부재 → 비정상 종료" "$rc_nokey" "1"

# ───────────────────────────────────────────────
echo
echo "[7] aihubshell 부재 처리 (mock 제거)"
# ───────────────────────────────────────────────
# PATH 에서 mock 제거 + SELF_DIR 의 실제 aihubshell 도 안 보이게 격리 실행
ISO="$SANDBOX/iso"; mkdir -p "$ISO"
cp "$WRAPPER" "$ISO/ahcli.bash"   # 옆에 aihubshell 없는 위치로 복사
out="$(
  PATH="/usr/bin:/bin" HOME="$FAKE_HOME" AIHUB_CONF="$FAKE_CONF" \
  MOCK_LOG_FILE="$MOCK_LOG" \
  bash "$ISO/ahcli.bash" ls 2>&1
)"; rc_noshell=$?
assert_contains "aihubshell 없음 → 안내 메시지" "$out" "aihubshell 없음"
assert_eq "aihubshell 없음 → 종료코드 1" "$rc_noshell" "1"

# ───────────────────────────────────────────────
echo
echo "[8] (옵션) 읽기 전용 실제 API — RUN_NETWORK=1 일 때만"
# ───────────────────────────────────────────────
if [[ "${RUN_NETWORK:-0}" == "1" ]]; then
  # 실제 aihubshell 사용. ls/pls 는 GET 조회만 → 안전. 다운로드 명령은 절대 안 함.
  out="$(
    HOME="$FAKE_HOME" AIHUB_CONF="$FAKE_CONF" \
    bash "$WRAPPER" pls 2>&1
  )"; rc_net=$?
  assert_eq "실제 pls 종료코드 0" "$rc_net" "0"
  assert_contains "실제 pls 응답 수신" "$out" "datapckage"
else
  echo "  $(c_dim '· 건너뜀 (RUN_NETWORK=1 로 활성화)')"
fi

# ───────────────────────────────────────────────
echo
echo "[안전성 사후 점검] 샌드박스 밖 오염 없음"
# ───────────────────────────────────────────────
if [[ ! -e "$SCRIPT_DIR/download.tar" ]]; then ok "download.tar 생성 안 됨"
else bad "download.tar 생성 안 됨" "다운로드가 실제로 일어났을 수 있음!"; fi
if [[ ! -d /opt/aihub ]] || [[ -n "${ALLOW_OPT:-}" ]]; then ok "/opt/aihub 미생성 (install 미실행)"
else bad "/opt/aihub 미생성" "install 이 실행된 흔적"; fi

# ───────────────────────────────────────────────
echo
echo "════════════════════════════════════════════"
if [[ $FAIL -eq 0 ]]; then fail_str="$(c_green "FAIL=0")"; else fail_str="$(c_red "FAIL=$FAIL")"; fi
echo " 결과: $(c_green "PASS=$PASS")  $fail_str"
echo "════════════════════════════════════════════"
if [[ $FAIL -ne 0 ]]; then
  printf ' 실패 항목:\n'
  for n in "${FAILED_NAMES[@]}"; do echo "   - $n"; done
  exit 1
fi
echo " 모든 테스트 통과 ✓"
