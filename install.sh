#!/usr/bin/env bash
# miniagent installer: https://github.com/mikesoylu/miniagent
set -euo pipefail

SCRIPT_URL="${MINIAGENT_SCRIPT_URL:-https://miniagent.sh}"
INSTALL_DIR="${MINIAGENT_INSTALL_DIR:-$HOME/.local/bin}"
TARGET="$INSTALL_DIR/miniagent"
MODE="install"

say() { printf 'miniagent: %s\n' "$*" >&2; }
die() { say "$*"; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

case "${1:-}" in
  "") ;;
  --dependencies-only)
    MODE="dependencies-only"
    shift
    ;;
  -h|--help)
    printf '%s\n' "Usage: install.sh [--dependencies-only]"
    exit 0
    ;;
  *) die "unknown option: $1" ;;
esac
[[ $# -eq 0 ]] || die "unexpected arguments: $*"

ensure_dependencies() {
  local command_name
  local -a required_commands missing_commands
  required_commands=(
    bash curl awk base64 cat chmod cp date dd find head mkdir mktemp mv rm sort
    stty tail tr uname wc sed nl
  )
  missing_commands=()
  for command_name in "${required_commands[@]}"; do
    has "$command_name" || missing_commands+=("$command_name")
  done
  if [[ ${#missing_commands[@]} -gt 0 ]]; then
    die "required standard Unix commands not found: ${missing_commands[*]}"
  fi
}

if [[ ${BASH_VERSINFO[0]} -lt 3 ]]; then
  die "Bash 3.2 or newer is required"
fi

if [[ "${MINIAGENT_SKIP_DEPENDENCY_INSTALL:-0}" != "1" ]]; then
  ensure_dependencies
fi

if [[ "$MODE" == "dependencies-only" ]]; then
  say "dependencies are ready"
  exit 0
fi

mkdir -p "$INSTALL_DIR"
temporary_file=$(mktemp "$INSTALL_DIR/.miniagent.XXXXXX")
trap 'rm -f "$temporary_file"' EXIT

curl -fsSL "$SCRIPT_URL" -o "$temporary_file"
bash -n "$temporary_file" || die "downloaded script failed validation"
chmod 0755 "$temporary_file"
mv -f "$temporary_file" "$TARGET"
trap - EXIT

say "installed $TARGET"
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) say "add $INSTALL_DIR to PATH to run: miniagent" ;;
esac
