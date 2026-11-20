#!/bin/bash
# Entrypoint for the DSH container.
#
# Everything installed here lives under /root so it survives a redeploy:
#   /root/.npm-global       claude-mem (npm prefix)
#   /root/.venvs/graphify   graphify venv
#   /root/.agents/skills    skill files DSH discovers
#   /root/.local/bin        launcher symlinks (already on PATH)
#
# This script only acts when something is missing. A normal boot with a warm
# volume does no network work at all.
#
# Usage:
#   ./entrypoint.sh          boot: repair what is missing, then start DSH
#   ./entrypoint.sh --check  report status only, start nothing; exits 1 if incomplete

set -uo pipefail

export NPM_CONFIG_PREFIX=/root/.npm-global
export PATH="/root/.npm-global/bin:/root/.venvs/graphify/bin:/root/.local/bin:$PATH"

CLAUDE_MEM_VERSION="16.0.2"
CLAUDE_MEM_BIN="/root/.npm-global/bin/claude-mem"
GRAPHIFY_VENV="/root/.venvs/graphify"
GRAPHIFY_BIN="$GRAPHIFY_VENV/bin/graphify"
GRAPHIFY_LINK="/root/.local/bin/graphify"
GRAPHIFY_SKILL_DIR="/root/.agents/skills/graphify"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1
MISSING=0

log() { printf '[entrypoint] %s\n' "$*"; }
warn() { printf '[entrypoint] WARN: %s\n' "$*" >&2; }

# --- claude-mem ------------------------------------------------------------
ensure_claude_mem() {
  if [ -x "$CLAUDE_MEM_BIN" ]; then
    log "claude-mem present ($("$CLAUDE_MEM_BIN" version 2>/dev/null || echo unknown))"
    return 0
  fi
  MISSING=1
  if [ "$CHECK_ONLY" = 1 ]; then
    warn "claude-mem MISSING ($CLAUDE_MEM_BIN)"
    return 1
  fi
  log "claude-mem missing, installing into /root/.npm-global ..."
  if npm install -g "claude-mem@${CLAUDE_MEM_VERSION}" >/dev/null 2>&1; then
    log "claude-mem installed"
    return 0
  fi
  warn "claude-mem install failed (network?). DSH still starts; retries next boot."
  return 1
}

# --- graphify --------------------------------------------------------------
graphify_usable() {
  [ -x "$GRAPHIFY_BIN" ] && "$GRAPHIFY_VENV/bin/python3" -c 'import graphify' >/dev/null 2>&1
}

ensure_python_venv_support() {
  python3 -m venv --help >/dev/null 2>&1 && return 0
  log "python3-venv missing, installing from apt ..."
  apt-get update -qq >/dev/null 2>&1 \
    && apt-get install -y -qq --no-install-recommends python3-venv >/dev/null 2>&1
}

link_graphify() {
  mkdir -p /root/.local/bin
  ln -sf "$GRAPHIFY_BIN" "$GRAPHIFY_LINK"
}

ensure_graphify() {
  if graphify_usable; then
    log "graphify present ($("$GRAPHIFY_BIN" --version 2>/dev/null | head -1))"
    link_graphify
    ensure_graphify_skill
    return 0
  fi
  MISSING=1
  if [ "$CHECK_ONLY" = 1 ]; then
    warn "graphify MISSING ($GRAPHIFY_BIN)"
    return 1
  fi
  log "graphify missing, recreating venv ..."
  ensure_python_venv_support
  if ! python3 -m venv "$GRAPHIFY_VENV" >/dev/null 2>&1; then
    warn "could not create venv at $GRAPHIFY_VENV. DSH still starts."
    return 1
  fi
  if "$GRAPHIFY_VENV/bin/pip" install --quiet graphifyy >/dev/null 2>&1; then
    log "graphify installed"
    link_graphify
    ensure_graphify_skill
    return 0
  fi
  warn "graphify pip install failed (network?). DSH still starts; retries next boot."
  return 1
}

ensure_graphify_skill() {
  [ -f "$GRAPHIFY_SKILL_DIR/SKILL.md" ] && return 0
  MISSING=1
  if [ "$CHECK_ONLY" = 1 ]; then
    warn "graphify skill MISSING ($GRAPHIFY_SKILL_DIR/SKILL.md)"
    return 1
  fi
  log "graphify skill missing, installing into $GRAPHIFY_SKILL_DIR ..."
  "$GRAPHIFY_BIN" install --platform agents >/dev/null 2>&1 \
    || warn "graphify skill install failed"
}

# --- run -------------------------------------------------------------------
ensure_claude_mem
ensure_graphify

if [ "$CHECK_ONLY" = 1 ]; then
  echo "---"
  log "graphify on PATH:    $(command -v graphify || echo MISSING)"
  log "graphify skill:      $([ -f "$GRAPHIFY_SKILL_DIR/SKILL.md" ] && echo present || echo MISSING)"
  log "claude-mem config:   $([ -d /root/.claude-mem ] && echo present || echo 'absent (run: npx claude-mem install)')"
  [ "$MISSING" = 1 ] && { warn "volume incomplete - a real boot would repair the above"; exit 1; }
  log "all components present"
  exit 0
fi

# The app refuses 0.0.0.0, so bind the container's concrete IPv4.
IP=$(hostname -i | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
exec pnpm dsh web --no-open --host "$IP" --port 3080 \
  --public-url "$PUBLIC_URL" --trusted-host "$TRUSTED_HOST"
