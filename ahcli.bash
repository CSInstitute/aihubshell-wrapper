#!/usr/bin/env bash
# aih — aihubshell 래퍼
set -euo pipefail

CONF="${AIHUB_CONF:-$HOME/.config/aihub/key}"
PREFIX="/opt/aihub"
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
  echo "aihubshell 없음. 스크립트와 같은 위치에 두거나 'aih install' 실행" >&2
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

_reload_hint() {
  echo
  echo "환경변수 적용:"
  echo "  source ~/.bashrc   (zsh면 ~/.zshrc)"
  echo "또는 새 셸:  exec \$SHELL -l"
  # --reload 플래그가 있으면 현재 셸 교체
  if [[ "${1:-}" == "--reload" ]]; then
    echo "셸 재시작..."
    exec "$SHELL" -l
  fi
}

_key() {
  [[ -n "${AIHUB_APIKEY:-}" ]] && { echo "$AIHUB_APIKEY"; return; }
  [[ -f "$CONF" ]] && { cat "$CONF"; return; }
  echo "no key. run: aih login <KEY>" >&2; exit 1
}

cmd="${1:-}"; shift || true
case "$cmd" in
  install)  # /opt/aihub 에 복제 + 전역 PATH 등록
    src="$SELF_DIR/aihubshell"
    [[ -x "$src" ]] || { echo "스크립트 옆에 aihubshell 실행파일 없음" >&2; exit 1; }
    SUDO=""; [[ -w /opt ]] || SUDO="sudo"
    $SUDO mkdir -p "$PREFIX"
    $SUDO cp "$src" "$PREFIX/aihubshell"
    $SUDO cp "$SELF_DIR/$(basename "${BASH_SOURCE[0]}")" "$PREFIX/aih"
    $SUDO chmod 755 "$PREFIX/aihubshell" "$PREFIX/aih"
    echo "installed → $PREFIX"
    # PATH에 이미 있으면 추가 안 함
    case ":$PATH:" in
      *":$PREFIX:"*) echo "PATH에 이미 등록됨" ;;
      *) _add_path_rc "$PREFIX" ;;
    esac
    _reload_hint "${1:-}" ;;

  login)
    mkdir -p "$(dirname "$CONF")"
    printf '%s' "$1" > "$CONF"; chmod 600 "$CONF"
    echo "saved → $CONF" ;;

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
ahcli install [--reload]    /opt/aihub 복제 + PATH 전역 등록
ahcli login <KEY>           키 저장 (~/.config/aihub/key, 600)
ahcli ls [datasetkey]       데이터셋/파일 목록
ahcli pls [datapckagekey]   패키지/파일 목록
ahcli get  <dsk> [fk...]    데이터셋 다운로드 (생략=전체)
a pget <pk>  [fk...]    패키지 다운로드
EOF
    exit 1 ;;
esac