#!/bin/sh
# ahcli — aihubshell 래퍼 (POSIX sh 버전)
set -eu

CONF="${AIHUB_CONF:-$HOME/.config/aihub/key}"
PREFIX="${AIHUB_PREFIX:-/opt/aihub}"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- aihubshell 위치 확보 (PATH에 없으면 스크립트 옆에서 임시 로드) ---
_ensure_shell() {
  if command -v aihubshell >/dev/null 2>&1; then return; fi

  if [ -x "$SELF_DIR/aihubshell" ]; then
    export PATH="$SELF_DIR:$PATH"          # 이 프로세스 한정
    return
  fi

  if [ -x "$PREFIX/aihubshell" ]; then
    export PATH="$PREFIX:$PATH"
    return
  fi

  echo "'aihubshell' is not found. Place it in the same directory as the script, or run 'ahcli install'" >&2
  exit 1
}

# --- 호스트 로그인 셸 식별 ($SHELL 우선 → passwd 조회 → 최종 폴백 /bin/sh) ---
# 서브셸로 실행해도 $SHELL 은 사용자의 로그인 셸을 가리키므로 신뢰 가능.
_host_shell() {
  _hs="${SHELL:-}"
  if [ -z "$_hs" ] && command -v getent >/dev/null 2>&1; then
    _hs="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7 || true)"
  fi
  if [ -z "$_hs" ] && command -v dscl >/dev/null 2>&1; then
    _hs="$(dscl . -read "/Users/$(id -un)" UserShell 2>/dev/null | awk '{print $2}' || true)"
  fi
  basename "${_hs:-/bin/sh}"
}

# --- 호스트 셸이 실제 읽는 startup 파일을 로그인+인터랙티브 합집합으로 산출 ---
# 개행 구분·중복 제거. ZDOTDIR(zsh)·$ENV(POSIX)·precedence(bash) 를 존중하므로
# 시놀로지 등 비표준 환경에서도 하드코딩 없이 올바른 파일을 찾는다.
_rc_targets() {
  {
    case "$(_host_shell)" in
      zsh)
        printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
      bash)
        printf '%s\n' "$HOME/.bashrc"            # 인터랙티브 비로그인
        # 로그인 셸 파일: 존재하는 첫 항목. 하나도 없으면 .profile 을 대상으로
        # 한다(.bash_profile 을 새로 만들면 기존 .profile 이 섀도잉되므로 회피).
        _login=""
        for _f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
          if [ -f "$_f" ]; then _login="$_f"; break; fi
        done
        printf '%s\n' "${_login:-$HOME/.profile}" ;;
      *)
        printf '%s\n' "$HOME/.profile"           # POSIX 로그인 셸 (sh/dash/ash/ksh)
        case "${ENV:-}" in
          /*) printf '%s\n' "$ENV" ;;            # 인터랙티브 비로그인 (절대경로만)
        esac ;;
    esac
  } | awk 'NF && !seen[$0]++'
}

# --- uninstall 시 마커를 지울 후보 (감지와 무관하게 알려진 모든 startup 파일) ---
# 설치 후 사용자가 로그인 셸을 바꿔도 잔여 PATH 라인이 남지 않도록 폭넓게 청소.
_rc_cleanup_candidates() {
  {
    _zdir="${ZDOTDIR:-$HOME}"
    printf '%s\n' \
      "$HOME/.profile" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_login" \
      "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zshenv" \
      "$_zdir/.zshrc" "$_zdir/.zprofile" "$_zdir/.zshenv"
    case "${ENV:-}" in /*) printf '%s\n' "$ENV" ;; esac
  } | awk 'NF && !seen[$0]++'
}

# --- rc 파일들에 PATH 라인 멱등 추가 (해석된 타깃 전체) ---
_add_path_rc() {
  dir="$1"
  line="export PATH=\"$dir:\$PATH\"  # aihub"
  _rc_targets | while IFS= read -r rc; do
    [ -n "$rc" ] || continue
    if grep -qF "# aihub" "$rc" 2>/dev/null; then continue; fi
    printf '\n%s\n' "$line" >> "$rc"   # 없으면 생성됨
    echo "added PATH → $rc"
  done
}

# --- rc 파일들에서 PATH 라인(# aihub 마커) 멱등 제거 (알려진 후보 전체) ---
_remove_path_rc() {
  _rc_cleanup_candidates | while IFS= read -r rc; do
    [ -n "$rc" ] || continue
    [ -f "$rc" ] || continue
    grep -qF "# aihub" "$rc" 2>/dev/null || continue
    tmp="$(mktemp)"
    grep -vF "# aihub" "$rc" > "$tmp" && cat "$tmp" > "$rc"
    rm -f "$tmp"
    echo "removed PATH ← $rc"
  done
}

# --- 캐시 키 마스킹 (앞4·뒤4만 노출) ---
_mask() {
  v="$1"; n=${#v}
  if [ "$n" -le 8 ]; then
    echo "****"
  else
    first4="$(printf '%s' "$v" | cut -c1-4)"
    last4="$(printf '%s' "$v" | cut -c$((n-3))-)"
    echo "${first4}****${last4}"
  fi
}

_reload_hint() {
  echo
  echo "Applying environment variables:"
  _rc_targets | while IFS= read -r rc; do
    [ -n "$rc" ] && echo "  source $rc"
  done
  echo "or new shell:  exec \$SHELL -l"

  # --reload 플래그가 있으면 현재 셸 교체
  if [ "${1:-}" = "--reload" ]; then
    echo "Reloading shell..."
    exec "$SHELL" -l
  fi
}

_key() {
  [ -n "${AIHUB_APIKEY:-}" ] && { echo "$AIHUB_APIKEY"; return; }
  [ -f "$CONF" ] && { cat "$CONF"; return; }
  echo "no key. run: ahcli login <KEY>" >&2; exit 1
}

# --- "키, 이름" 목록 라인을 표 행으로 변환 (질의어로 필터) ---
# $1: 분류 라벨(표시폭 10에 맞춰 공백 패딩)  $2: 질의어(빈 값이면 전체)
# aihubshell 의 배너/상태 메시지는 무시하고 '^숫자,' 라인만 처리.
_search_rows() {
  awk -v type="$1" -v q="$2" '
    /^[0-9]+,/ {
      p = index($0, ",")
      key = substr($0, 1, p - 1)
      name = substr($0, p + 1)
      sub(/^[ \t]+/, "", name); sub(/[ \t\r]+$/, "", name)
      if (q != "" && index(tolower(name), tolower(q)) == 0 && index(key, q) == 0) next
      printf "%s  %-6s%s\n", type, key, name
    }'
}

cmd="${1:-}"; [ "$#" -gt 0 ] && shift   # 인자 없을 때 dash 의 shift 경고 회피
case "$cmd" in
  install)  # /opt/aihub 에 복제 + 전역 PATH 등록
    src="$SELF_DIR/aihubshell"

    [ -f "$src" ] || { echo "스크립트 옆에 aihubshell 파일 없음" >&2; exit 1; }
    SUDO=""; [ -w "$(dirname "$PREFIX")" ] || SUDO="sudo"

    $SUDO mkdir -p "$PREFIX"
    $SUDO cp "$src" "$PREFIX/aihubshell"
    $SUDO cp "$SELF_DIR/$(basename "$0")" "$PREFIX/ahcli"
    $SUDO chmod 755 "$PREFIX/aihubshell" "$PREFIX/ahcli"

    echo "installed → $PREFIX"

    # PATH에 이미 있으면 추가 안 함
    case ":$PATH:" in
      *":$PREFIX:"*) echo "Already registered in \$PATH" ;;
      *) _add_path_rc "$PREFIX" ;;
    esac
    _reload_hint "${1:-}" ;;

  uninstall)  # /opt/aihub 제거 + PATH 라인 삭제
    SUDO=""; [ -w "$(dirname "$PREFIX")" ] || SUDO="sudo"
    if [ -e "$PREFIX/ahcli" ] || [ -e "$PREFIX/aihubshell" ]; then
      $SUDO rm -f "$PREFIX/ahcli" "$PREFIX/aihubshell"
      $SUDO rmdir "$PREFIX" 2>/dev/null || true   # 비어있을 때만 제거
      echo "removed → $PREFIX"
    else
      echo "No install: $PREFIX"
    fi
    _remove_path_rc
    echo "\$PATH line removed. Start a new shell to apply (exec \$SHELL -l)" ;;

  login)
    mkdir -p "$(dirname "$CONF")"
    printf '%s' "$1" > "$CONF"; chmod 600 "$CONF"
    echo "saved → $CONF" ;;

  key)  # 캐시된 키 확인 (마스킹 노출)
    if [ -n "${AIHUB_APIKEY:-}" ]; then
      echo "source: env (AIHUB_APIKEY)"
      echo "key:    $(_mask "$AIHUB_APIKEY")  (len=${#AIHUB_APIKEY})"

    elif [ -f "$CONF" ]; then
      k="$(cat "$CONF")"
      echo "source: file ($CONF)"
      echo "key:    $(_mask "$k")  (len=${#k})"

    else
      echo "No cached key. Run 'ahcli login <KEY>' to save it" >&2; exit 1
    fi ;;

  logout)  # 저장된 키 말소
    if [ -f "$CONF" ]; then
      rm -f "$CONF"; echo "removed → $CONF"
    else
      echo "No saved key: $CONF"
    fi
    if [ -n "${AIHUB_APIKEY:-}" ]; then
      echo "Warning: The \$AIHUB_APIKEY environment variable is still set (unset AIHUB_APIKEY)"
    fi ;;

  ls)
    _ensure_shell
    aihubshell -mode l ${1:+-datasetkey "$1"} ;;

  pls)
    _ensure_shell
    aihubshell -mode pl ${1:+-datapckagekey "$1"} ;;

  search)  # 데이터셋 + 데이터 패키지셋 통합 검색 (분류 표기 + 표 출력)
    _ensure_shell
    q="${1:-}"
    printf "%-10s  %-6s%s\n" "TYPE" "KEY" "NAME"
    { aihubshell -mode l  2>/dev/null || true; } | _search_rows "Dataset  " "$q"
    { aihubshell -mode pl 2>/dev/null || true; } | _search_rows "Package  " "$q" ;;

  get)
    _ensure_shell
    ds="$1"; shift || true
    fk="$*"; fk="$(printf '%s' "$fk" | tr ' ' ',')"   # 공백 → 콤마 치환
    key="$(_key)" || exit 1           # 키 부재 시 메인 셸에서 중단
    aihubshell -aihubapikey "$key" -mode d \
      -datasetkey "$ds" ${fk:+-filekey "$fk"} ;;

  pget)
    _ensure_shell
    pk="$1"; shift || true
    fk="$*"; fk="$(printf '%s' "$fk" | tr ' ' ',')"   # 공백 → 콤마 치환
    key="$(_key)" || exit 1           # 키 부재 시 메인 셸에서 중단
    aihubshell -aihubapikey "$key" -mode pd \
      -datapckagekey "$pk" ${fk:+-filekey "$fk"} ;;

  __rc-targets)  _rc_targets ;;          # (내부) 감지된 설치 타깃 — 테스트/디버그용
  __host-shell)  _host_shell ;;          # (내부) 감지된 호스트 셸 — 테스트/디버그용

  *) cat <<'EOF'
ahcli install [--reload]    Clone /opt/aihub + Add to global PATH
ahcli uninstall             Remove /opt/aihub + Delete the PATH line
ahcli login <KEY>           Save API key (~/.config/aihub/key, 600)
ahcli logout                Delete saved API key
ahcli key                   Check Cached API Key (Masking)
ahcli ls [datasetkey]       List of Datasets/Files
ahcli pls [datapckagekey]   List of Packages/Files
ahcli search [query]        Search datasets & packages (table, typed)
ahcli get  <dsk> [fk...]    Download Dataset (Omitted = All)
ahcli pget <pk>  [fk...]    Download the package

Environment variables:
  AIHUB_PREFIX   Installation path     (Default /opt/aihub)
  AIHUB_CONF     Key storage file path (Default ~/.config/aihub/key)
  AIHUB_APIKEY   Specify key directly (takes precedence over file)
    Example) AIHUB_PREFIX=~/.local/aihub ahcli install
EOF
    exit 1 ;;
esac
