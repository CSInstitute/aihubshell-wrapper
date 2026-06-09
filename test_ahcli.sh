#!/bin/sh
#
# test_ahcli.sh — ahcli.sh 안전 테스트 하니스 (POSIX sh 버전)
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
#   RUN_NETWORK=1  ./test_ahcli.sh   # ls/pls 의 읽기 전용 실제 API 호출까지 포함
#
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRAPPER="$SCRIPT_DIR/ahcli.sh"

PASS=0
FAIL=0
FAILED_NAMES=""

# ---- 출력 헬퍼 ----
c_green() { printf '\033[32m%s\033[0m' "$1"; }
c_red()   { printf '\033[31m%s\033[0m' "$1"; }
c_dim()   { printf '\033[2m%s\033[0m' "$1"; }

ok()   { PASS=$((PASS+1)); echo "  $(c_green '✓') $1"; }
bad()  {
  FAIL=$((FAIL+1))
  FAILED_NAMES="$FAILED_NAMES$1
"
  echo "  $(c_red '✗') $1"
  [ -n "${2:-}" ] && echo "      $(c_dim "$2")"
  return 0
}

# 부분 문자열 포함 검증
assert_contains() {
  name="$1"; haystack="$2"; needle="$3"
  case "$haystack" in
    *"$needle"*) ok "$name" ;;
    *) bad "$name" "기대(포함): '$needle' / 실제: '$(printf '%s' "$haystack" | cut -c1-200)'" ;;
  esac
}
assert_not_contains() {
  name="$1"; haystack="$2"; needle="$3"
  case "$haystack" in
    *"$needle"*) bad "$name" "포함되면 안 됨: '$needle'" ;;
    *) ok "$name" ;;
  esac
}
assert_eq() {
  name="$1"; actual="$2"; expected="$3"
  if [ "$actual" = "$expected" ]; then ok "$name"
  else bad "$name" "기대: '$expected' / 실제: '$actual'"; fi
}

# ---- 샌드박스 구성 ----
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ahcli_test.XXXXXX")"
SRCDIR="$SANDBOX/src"          # install 소스 (wrapper + mock aihubshell)
PREFIX="$SANDBOX/prefix"       # install 대상 (= 실제 사용될 aihubshell 위치)
MOCK_LOG="$SANDBOX/mock_calls.log"
FAKE_HOME="$SANDBOX/home"
FAKE_CONF="$SANDBOX/conf/key"
mkdir -p "$SRCDIR" "$FAKE_HOME" "$(dirname "$FAKE_CONF")"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# mock aihubshell: 받은 인자를 로그에 1줄로 기록하고 그대로 echo. 네트워크 없음.
# 소스 디렉터리에 둔 뒤 wrapper 의 install 로 PREFIX 에 배치 → 실제 설치 흐름과 동일.
# (일부러 chmod 안 함: install 이 755 를 부여하는지까지 검증)
cat > "$SRCDIR/aihubshell" <<'MOCK'
#!/bin/sh
printf 'ARGS:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'
printf '%s\n' "$*" >> "$MOCK_LOG_FILE"
# search 파싱 검증용: 목록 모드일 때 가짜 "키, 이름" 라인 방출 (배너 노이즈 포함)
case " $* " in
  *" -mode l "*)  printf '%s\n' '==== DataSet ====' '101, 한국어 음성' '102, 영어 음성' ;;
  *" -mode pl "*) printf '%s\n' '==== DataPackage ====' '201, 영어 번역 말뭉치' ;;
esac
exit 0
MOCK
cp "$WRAPPER" "$SRCDIR/ahcli.sh"

# wrapper 의 install 로 mock 을 PREFIX 에 설치 (HOME=샌드박스 → rc 미오염, sudo 불필요)
HOME="$FAKE_HOME" AIHUB_PREFIX="$PREFIX" \
  sh "$SRCDIR/ahcli.sh" install >/dev/null 2>&1

# 래퍼 실행 래퍼: 설치된 $PREFIX/ahcli 를 PREFIX 의 aihubshell 로 구동 (환경 통일).
# 결과는 전역 OUT(=stdout+stderr 결합), RC(=종료코드) 에 저장.
# (명령 치환 서브셸을 쓰면 RC 가 부모로 전파되지 않으므로 전역 + 임시파일 사용)
OUT=""; RC=0
run() {
  PATH="$PREFIX:$PATH" \
  HOME="$FAKE_HOME" \
  AIHUB_CONF="$FAKE_CONF" \
  AIHUB_PREFIX="$PREFIX" \
  MOCK_LOG_FILE="$MOCK_LOG" \
  sh "$PREFIX/ahcli" "$@" >"$SANDBOX/_out" 2>&1
  RC=$?
  OUT="$(cat "$SANDBOX/_out")"
}

echo "════════════════════════════════════════════"
echo " ahcli.sh 안전 테스트"
echo " sandbox: $SANDBOX"
echo "════════════════════════════════════════════"

# ───────────────────────────────────────────────
echo
echo "[1] 정적 검사 (실행 부작용 없음)"
# ───────────────────────────────────────────────
if sh -n "$WRAPPER" 2>/tmp/synerr; then ok "sh -n 구문 검사 통과"
else bad "sh -n 구문 검사" "$(cat /tmp/synerr)"; fi

if command -v shellcheck >/dev/null 2>&1; then
  sc="$(shellcheck -S error "$WRAPPER" 2>&1)"
  if [ -z "$sc" ]; then ok "shellcheck (error 레벨) 통과"
  else bad "shellcheck (error 레벨)" "$sc"; fi
else
  echo "  $(c_dim '· shellcheck 미설치 — 건너뜀')"
fi

# 셋업 sanity: 전역 install 로 PREFIX 에 실행 가능한 aihubshell 이 배치됐는가
if [ -x "$PREFIX/aihubshell" ] && [ -x "$PREFIX/ahcli" ]; then ok "셋업: PREFIX 에 mock aihubshell 설치됨"
else bad "셋업: PREFIX 에 mock aihubshell 설치됨" "install 실패 — 이후 테스트 신뢰불가"; fi

# ───────────────────────────────────────────────
echo
echo "[2] 도움말 / 알 수 없는 명령"
# ───────────────────────────────────────────────
run
assert_contains "인자 없음 → 사용법 출력" "$OUT" "install"
assert_eq "인자 없음 → 종료코드 1" "$RC" "1"

run boguscmd
assert_contains "알 수 없는 명령 → 사용법 출력" "$OUT" "login"
assert_eq "알 수 없는 명령 → 종료코드 1" "$RC" "1"

# ───────────────────────────────────────────────
echo
echo "[3] login (키 저장 — 샌드박스 CONF)"
# ───────────────────────────────────────────────
run login TEST_KEY_12345
assert_eq "login 종료코드 0" "$RC" "0"
assert_contains "login 저장 메시지" "$OUT" "saved"
if [ -f "$FAKE_CONF" ]; then ok "키 파일 생성됨"
else bad "키 파일 생성됨" "$FAKE_CONF 없음"; fi
assert_eq "키 파일 내용 정확" "$(cat "$FAKE_CONF" 2>/dev/null)" "TEST_KEY_12345"
perm="$(stat -c '%a' "$FAKE_CONF" 2>/dev/null || stat -f '%Lp' "$FAKE_CONF" 2>/dev/null)"
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
echo "[4.5] search (데이터셋+패키지 통합 검색, 분류 표기 + 표 출력)"
# ───────────────────────────────────────────────
run search
assert_eq "search: 종료코드 0"            "$RC" "0"
assert_contains "search: 헤더 TYPE/KEY/NAME" "$OUT" "TYPE"
assert_contains "search: 헤더 KEY"           "$OUT" "KEY"
assert_contains "search: 헤더 NAME"          "$OUT" "NAME"
assert_contains "search: 데이터셋 분류 표기" "$OUT" "Dataset"
assert_contains "search: 패키지 분류 표기"   "$OUT" "Package"
assert_contains "search: 데이터셋 행 이름"   "$OUT" "한국어 음성"
assert_contains "search: 데이터셋 행 KEY"    "$OUT" "101"
assert_contains "search: 패키지 행 이름"     "$OUT" "영어 번역 말뭉치"
assert_contains "search: 패키지 행 KEY"      "$OUT" "201"
# 배너/상태 노이즈 라인은 표에 새지 않아야 함
assert_not_contains "search: 배너 노이즈 필터" "$OUT" "DataSet ===="

run search 한국어
assert_contains "search 질의: 매칭 데이터셋 포함"   "$OUT" "한국어 음성"
assert_not_contains "search 질의: 비매칭 데이터셋 제외" "$OUT" "영어 음성"
assert_not_contains "search 질의: 비매칭 패키지 제외"   "$OUT" "영어 번역 말뭉치"

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
  PATH="$PREFIX:$PATH" HOME="$FAKE_HOME" AIHUB_CONF="$FAKE_CONF" \
  AIHUB_PREFIX="$PREFIX" MOCK_LOG_FILE="$MOCK_LOG" AIHUB_APIKEY="ENV_KEY_999" \
  sh "$PREFIX/ahcli" get 71265 2>&1
)"
assert_contains "AIHUB_APIKEY 가 파일보다 우선" "$out" "[-aihubapikey] [ENV_KEY_999]"

# 키 전혀 없음 → 에러
EMPTY_CONF="$SANDBOX/empty/key"
out="$(
  PATH="$PREFIX:$PATH" HOME="$FAKE_HOME" AIHUB_CONF="$EMPTY_CONF" \
  AIHUB_PREFIX="$PREFIX" MOCK_LOG_FILE="$MOCK_LOG" \
  sh "$PREFIX/ahcli" get 71265 2>&1
)"; rc_nokey=$?
assert_contains "키 부재 → 안내 메시지" "$out" "no key"
assert_eq "키 부재 → 비정상 종료" "$rc_nokey" "1"

# ───────────────────────────────────────────────
echo
echo "[7] aihubshell 부재 처리 (mock 제거)"
# ───────────────────────────────────────────────
# PATH 에서 mock 제거 + SELF_DIR 의 실제 aihubshell 도 안 보이게 격리 실행
ISO="$SANDBOX/iso"; mkdir -p "$ISO"
cp "$WRAPPER" "$ISO/ahcli.sh"   # 옆에 aihubshell 없는 위치로 복사
out="$(
  PATH="/usr/bin:/bin" HOME="$FAKE_HOME" AIHUB_CONF="$FAKE_CONF" \
  AIHUB_PREFIX="$SANDBOX/none" MOCK_LOG_FILE="$MOCK_LOG" \
  sh "$ISO/ahcli.sh" ls 2>&1
)"; rc_noshell=$?
assert_contains "aihubshell 없음 → 안내 메시지" "$out" "is not found"
assert_eq "aihubshell 없음 → 종료코드 1" "$rc_noshell" "1"

# ───────────────────────────────────────────────
echo
echo "[7.5] install (샌드박스 PREFIX — /opt·rc 미오염)"
# ───────────────────────────────────────────────
# 음성: 옆에 aihubshell 없는 위치에서 install → 존재 검사 실패 메시지 + exit 1
NOSRC="$SANDBOX/nosrc"; mkdir -p "$NOSRC"
cp "$WRAPPER" "$NOSRC/ahcli.sh"
out="$(
  HOME="$FAKE_HOME" AIHUB_PREFIX="$SANDBOX/prefix_neg" \
  sh "$NOSRC/ahcli.sh" install 2>&1
)"; rc_inst_neg=$?
assert_contains "install: 소스 없음 → 안내" "$out" "aihubshell"
assert_eq "install: 소스 없음 → 종료코드 1" "$rc_inst_neg" "1"

# 양성: 실행권한 없는 aihubshell 이 옆에 있어도 설치 성공해야 함 (버그 회귀 방지)
SRCDIR="$SANDBOX/srcdir"; mkdir -p "$SRCDIR"
cp "$WRAPPER" "$SRCDIR/ahcli.sh"
printf '#!/bin/sh\necho hi\n' > "$SRCDIR/aihubshell"   # 일부러 chmod 안 함 (-rw-r--r--)
INST_PREFIX="$SANDBOX/prefix"
out="$(
  HOME="$FAKE_HOME" AIHUB_PREFIX="$INST_PREFIX" \
  sh "$SRCDIR/ahcli.sh" install 2>&1
)"; rc_inst=$?
assert_eq "install: 비실행 소스로도 설치 성공 (exit 0)" "$rc_inst" "0"
assert_contains "install: 설치 완료 메시지" "$out" "installed"
if [ -x "$INST_PREFIX/aihubshell" ]; then ok "install: 사본에 실행권한 755 부여"
else bad "install: 사본에 실행권한 755 부여" "$INST_PREFIX/aihubshell 실행불가"; fi
if [ -x "$INST_PREFIX/ahcli" ]; then ok "install: ahcli 래퍼 복제됨"
else bad "install: ahcli 래퍼 복제됨" "$INST_PREFIX/ahcli 없음"; fi
# 실제 /opt 와 사용자 rc 파일은 건드리지 않았는지
if [ ! -e /opt/aihub ] || [ -n "${ALLOW_OPT:-}" ]; then ok "install: 실제 /opt/aihub 미오염"
else bad "install: 실제 /opt/aihub 미오염" "/opt/aihub 가 생성됨"; fi

# ───────────────────────────────────────────────
echo
echo "[8] (옵션) 읽기 전용 실제 API — RUN_NETWORK=1 일 때만"
# ───────────────────────────────────────────────
if [ "${RUN_NETWORK:-0}" = "1" ]; then
  # 실제 aihubshell 사용. ls/pls 는 GET 조회만 → 안전. 다운로드 명령은 절대 안 함.
  # repo 의 실제 aihubshell 을 실행 가능한 사본으로 PATH 에 올림 (mock 아님).
  REALBIN="$SANDBOX/realbin"; mkdir -p "$REALBIN"
  cp "$SCRIPT_DIR/aihubshell" "$REALBIN/aihubshell"; chmod 755 "$REALBIN/aihubshell"
  out="$(
    PATH="$REALBIN:$PATH" HOME="$FAKE_HOME" AIHUB_CONF="$FAKE_CONF" \
    AIHUB_PREFIX="$SANDBOX/none" \
    sh "$WRAPPER" pls 2>&1
  )"; rc_net=$?
  assert_eq "실제 pls 종료코드 0" "$rc_net" "0"
  assert_contains "실제 pls 응답 수신" "$out" "datapckage"
else
  echo "  $(c_dim '· 건너뜀 (RUN_NETWORK=1 로 활성화)')"
fi

# ───────────────────────────────────────────────
echo
echo "[9] key (캐시 키 확인 — 마스킹) / logout (말소)"
# ───────────────────────────────────────────────
# FAKE_CONF 에는 [3] 에서 저장한 TEST_KEY_12345 가 있음
run key
assert_eq "key: 종료코드 0" "$RC" "0"
assert_contains "key: 파일 소스 표시"      "$OUT" "source: file"
assert_contains "key: 앞4·뒤4 마스킹"      "$OUT" "TEST****2345"
assert_not_contains "key: 전체 키 미노출"  "$OUT" "TEST_KEY_12345"

# 환경변수 키가 있으면 env 소스로 우선 표시
out="$(
  PATH="$PREFIX:$PATH" HOME="$FAKE_HOME" AIHUB_CONF="$FAKE_CONF" \
  AIHUB_PREFIX="$PREFIX" MOCK_LOG_FILE="$MOCK_LOG" AIHUB_APIKEY="ENV_KEY_999" \
  sh "$PREFIX/ahcli" key 2>&1
)"
assert_contains "key: env 소스 우선"  "$out" "source: env"
assert_contains "key: env 마스킹"     "$out" "ENV_****_999"

# logout → 파일 삭제
run logout
assert_eq "logout: 종료코드 0" "$RC" "0"
assert_contains "logout: 삭제 메시지" "$OUT" "removed"
if [ ! -f "$FAKE_CONF" ]; then ok "logout: 키 파일 삭제됨"
else bad "logout: 키 파일 삭제됨" "$FAKE_CONF 잔존"; fi

# logout 후 key → 키 없음
run key
assert_eq "logout 후 key → 종료코드 1" "$RC" "1"
assert_contains "logout 후 key → 안내" "$OUT" "No cached key"

# logout 멱등
run logout
assert_contains "logout 재실행 → 키 없음 안내" "$OUT" "No saved key"

# ───────────────────────────────────────────────
echo
echo "[10] uninstall (격리 PREFIX/HOME — 실제 /opt·rc 미오염)"
# ───────────────────────────────────────────────
UPREFIX="$SANDBOX/uprefix"; UHOME="$SANDBOX/uhome"; mkdir -p "$UHOME"
# 사용자 줄 + aihub PATH 줄이 섞인 가짜 rc ($PATH 는 rc 안 리터럴이라 단일따옴표 의도)
# shellcheck disable=SC2016
printf 'echo userline\nexport PATH="%s:$PATH"  # aihub\n' "$UPREFIX" > "$UHOME/.bashrc"
HOME="$UHOME" AIHUB_PREFIX="$UPREFIX" sh "$SRCDIR/ahcli.sh" install >/dev/null 2>&1
if [ -x "$UPREFIX/ahcli" ] && [ -x "$UPREFIX/aihubshell" ]; then ok "uninstall 전: 설치 상태 확인"
else bad "uninstall 전: 설치 상태 확인" "install 실패"; fi

out="$(
  HOME="$UHOME" AIHUB_PREFIX="$UPREFIX" \
  sh "$SRCDIR/ahcli.sh" uninstall 2>&1
)"; rc_uninst=$?
assert_eq "uninstall: 종료코드 0" "$rc_uninst" "0"
assert_contains "uninstall: 제거 메시지" "$out" "removed"
if [ ! -e "$UPREFIX/ahcli" ] && [ ! -e "$UPREFIX/aihubshell" ]; then ok "uninstall: 바이너리 제거됨"
else bad "uninstall: 바이너리 제거됨" "잔존 파일 있음"; fi
if [ ! -d "$UPREFIX" ]; then ok "uninstall: 빈 PREFIX 디렉터리 제거"
else bad "uninstall: 빈 PREFIX 디렉터리 제거" "$UPREFIX 잔존"; fi
if ! grep -qF "# aihub" "$UHOME/.bashrc"; then ok "uninstall: rc 의 PATH 라인 제거"
else bad "uninstall: rc 의 PATH 라인 제거" "# aihub 라인 잔존"; fi
if grep -qx "echo userline" "$UHOME/.bashrc"; then ok "uninstall: rc 의 사용자 줄 보존"
else bad "uninstall: rc 의 사용자 줄 보존" "사용자 줄이 손상됨"; fi

# uninstall 멱등
out="$(
  HOME="$UHOME" AIHUB_PREFIX="$UPREFIX" \
  sh "$SRCDIR/ahcli.sh" uninstall 2>&1
)"
assert_contains "uninstall 재실행 → 설치본 없음 안내" "$out" "No install"

# ───────────────────────────────────────────────
echo
echo "[안전성 사후 점검] 샌드박스 밖 오염 없음"
# ───────────────────────────────────────────────
if [ ! -e "$SCRIPT_DIR/download.tar" ]; then ok "download.tar 생성 안 됨"
else bad "download.tar 생성 안 됨" "다운로드가 실제로 일어났을 수 있음!"; fi
if [ ! -d /opt/aihub ] || [ -n "${ALLOW_OPT:-}" ]; then ok "/opt/aihub 미생성 (install 미실행)"
else bad "/opt/aihub 미생성" "install 이 실행된 흔적"; fi

# ───────────────────────────────────────────────
echo
echo "════════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then fail_str="$(c_green "FAIL=0")"; else fail_str="$(c_red "FAIL=$FAIL")"; fi
echo " 결과: $(c_green "PASS=$PASS")  $fail_str"
echo "════════════════════════════════════════════"
if [ "$FAIL" -ne 0 ]; then
  printf ' 실패 항목:\n'
  printf '%s' "$FAILED_NAMES" | while IFS= read -r n; do
    [ -n "$n" ] && echo "   - $n"
  done
  exit 1
fi
echo " All Green ✓"
