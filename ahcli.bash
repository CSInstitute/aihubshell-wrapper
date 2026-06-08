#!/usr/bin/env bash
# ahcli — aihubshell 래퍼
set -euo pipefail

CONF="${AIHUB_CONF:-$HOME/.config/aihub/key}"
PREFIX="${AIHUB_PREFIX:-/opt/aihub}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- aihubshell 위치 확보 (PATH에 없으면 스크립트 옆에서 임시 로드) ---
_ensure_shell() {
  if command -v aihubshell >/dev/null 2>&1; then return; fi

  if [[ -x "$SELF_DIR/aihubshell" ]]; then
    export PATH="$SELF_DIR:$PATH"          # 이 프로세스 한정
    return
  fi

  if [[ -x "$PREFIX/aihubshell" ]]; then
    export PATH="$PREFIX:$PATH"
    return
  fi

  echo "`aihubshell` is not found. Place it in the same directory as the script or run `ahcli install`" >&2
  exit 1
}

# --- rc 파일에 PATH 라인 멱등 추가 ---
_add_path_rc() {
  local dir="$1" line rc
  line="export PATH=\"$dir:\$PATH\"  # aihub"

  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] || continue
    grep -qF "# aihub" "$rc" 2>/dev/null && continue
    printf '\n%s\n' "$line" >> "$rc"
    echo "added PATH → $rc"
  done
}

# --- rc 파일에서 PATH 라인(# aihub 마커) 멱등 제거 ---
_remove_path_rc() {
  local rc tmp

  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] || continue
    grep -qF "# aihub" "$rc" 2>/dev/null || continue
    tmp="$(mktemp)"
    grep -vF "# aihub" "$rc" > "$tmp" && cat "$tmp" > "$rc"
    rm -f "$tmp"

    echo "removed PATH ← $rc"
  done
}

# --- 캐시 키 마스킹 (앞4·뒤4만 노출) ---
_mask() {
  local v="$1" n=${#1}
  if (( n <= 8 )); then echo "****"; else echo "${v:0:4}****${v: -4}"; fi
}

_reload_hint() {
  echo
  echo "Applying environment variables:"
  echo "  source ~/.bashrc   (If zsh, ~/.zshrc)"
  echo "or new shell:  exec \$SHELL -l"

  # --reload 플래그가 있으면 현재 셸 교체
  if [[ "${1:-}" == "--reload" ]]; then
    echo "Reloading shell..."
    exec "$SHELL" -l
  fi
}

_key() {
  [[ -n "${AIHUB_APIKEY:-}" ]] && { echo "$AIHUB_APIKEY"; return; }
  [[ -f "$CONF" ]] && { cat "$CONF"; return; }
  echo "no key. run: ahcli login <KEY>" >&2; exit 1
}

cmd="${1:-}"; shift || true
case "$cmd" in
  install)  # /opt/aihub 에 복제 + 전역 PATH 등록
    src="$SELF_DIR/aihubshell"

    [[ -f "$src" ]] || { echo "스크립트 옆에 aihubshell 파일 없음" >&2; exit 1; }
    SUDO=""; [[ -w "$(dirname "$PREFIX")" ]] || SUDO="sudo"

    $SUDO mkdir -p "$PREFIX"
    $SUDO cp "$src" "$PREFIX/aihubshell"
    $SUDO cp "$SELF_DIR/$(basename "${BASH_SOURCE[0]}")" "$PREFIX/ahcli"
    $SUDO chmod 755 "$PREFIX/aihubshell" "$PREFIX/ahcli"

    echo "installed → $PREFIX"

    # PATH에 이미 있으면 추가 안 함
    case ":$PATH:" in
      *":$PREFIX:"*) echo "Already registered in \$PATH" ;;
      *) _add_path_rc "$PREFIX" ;;
    esac
    _reload_hint "${1:-}" ;;

  uninstall)  # /opt/aihub 제거 + PATH 라인 삭제
    SUDO=""; [[ -w "$(dirname "$PREFIX")" ]] || SUDO="sudo"
    if [[ -e "$PREFIX/ahcli" || -e "$PREFIX/aihubshell" ]]; then
      $SUDO rm -f "$PREFIX/ahcli" "$PREFIX/aihubshell"
      $SUDO rmdir "$PREFIX" 2>/dev/null || true   # 비어있을 때만 제거
      echo "removed → $PREFIX"
    else
      echo "No install: $PREFIX"
    fi
    _remove_path_rc
    echo "\$PATH line removed. Reflected in the new shell (source ~/.bashrc or exec \$SHELL -l)" ;;

  login)
    mkdir -p "$(dirname "$CONF")"
    printf '%s' "$1" > "$CONF"; chmod 600 "$CONF"
    echo "saved → $CONF" ;;

  key)  # 캐시된 키 확인 (마스킹 노출)
    if [[ -n "${AIHUB_APIKEY:-}" ]]; then
      echo "source: env (AIHUB_APIKEY)"
      echo "key:    $(_mask "$AIHUB_APIKEY")  (len=${#AIHUB_APIKEY})"

    elif [[ -f "$CONF" ]]; then
      k="$(cat "$CONF")"
      echo "source: file ($CONF)"
      echo "key:    $(_mask "$k")  (len=${#k})"

    else
      echo "No cached key. Run 'ahcli login <KEY>' to save it" >&2; exit 1
    fi ;;

  logout)  # 저장된 키 말소
    if [[ -f "$CONF" ]]; then
      rm -f "$CONF"; echo "removed → $CONF"
    else
      echo "No saved key: $CONF"
    fi
    if [[ -n "${AIHUB_APIKEY:-}" ]]; then
      echo "Warning: The \$AIHUB_APIKEY environment variable is still set (unset AIHUB_APIKEY)"
    fi ;;

  ls)
    _ensure_shell
    aihubshell -mode l ${1:+-datasetkey "$1"} ;;

  pls)
    _ensure_shell
    aihubshell -mode pl ${1:+-datapckagekey "$1"} ;;

  get)
    _ensure_shell
    ds="$1"; shift || true
    fk="$*"; fk="${fk// /,}"          # bash 3.2 호환: $* 직접 치환 회피
    key="$(_key)" || exit 1           # 키 부재 시 메인 셸에서 중단
    aihubshell -aihubapikey "$key" -mode d \
      -datasetkey "$ds" ${fk:+-filekey "$fk"} ;;

  pget)
    _ensure_shell
    pk="$1"; shift || true
    fk="$*"; fk="${fk// /,}"          # bash 3.2 호환: $* 직접 치환 회피
    key="$(_key)" || exit 1           # 키 부재 시 메인 셸에서 중단
    aihubshell -aihubapikey "$key" -mode pd \
      -datapckagekey "$pk" ${fk:+-filekey "$fk"} ;;

  *) cat <<'EOF'
ahcli install [--reload]    Clone /opt/aihub + Add to global PATH
ahcli uninstall             Remove /opt/aihub + Delete the PATH line
ahcli login <KEY>           Save API key (~/.config/aihub/key, 600)
ahcli logout                Delete saved API key
ahcli key                   Check Cached API Key (Masking)
ahcli ls [datasetkey]       List of Datasets/Files
ahcli pls [datapckagekey]   List of Packages/Files
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