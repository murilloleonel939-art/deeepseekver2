#!/bin/bash
# Entrypoint for the DSH container.
#
# Three layers of state, by design:
#   Image layer (/app)     code, entrypoint, vendor/skills.tar.gz — rebuilt on every deploy
#   Volume (/root)         configs, venvs, installed tools, session data — survives deploys
#   Network                only used when something in /root is missing
#
# Everything this script installs lives under /root, so a normal redeploy with a
# warm volume does no network work at all, and a deploy with a fresh volume
# restores itself from the image plus the network.
#
# Usage:
#   ./entrypoint.sh           boot: restore what is missing, then start DSH
#   ./entrypoint.sh --check   report status only, change nothing; exit 1 if incomplete

set -uo pipefail

APP_DIR=${APP_DIR:-/app}
SKILLS_DIR=/root/.agents/skills
SKILLS_BUNDLE="$APP_DIR/deploy/skills.tar.gz"
SKILLS_MARKER="$SKILLS_DIR/.bundle-sha256"
CLAUDE_MEM_VERSION=16.0.2
CLAUDE_MEM_BIN=/root/.npm-global/bin/claude-mem
BUN_BIN=/root/.bun/bin/bun
SHIM_PORT=37778
SHIM_SCRIPT="$APP_DIR/deploy/llm-shim.py"
SHIM_UPSTREAM_API=openai
SHIM_UPSTREAM_BASE_URL=https://api.pateway.ai/v1
SHIM_MODEL=gpt-6-luna
SHIM_UPSTREAM_KEY_ENV=PATEWAY2GPT_API_KEY
CLAUDE_MEM_SETTINGS=/root/.claude-mem/settings.json
PROFILE_DIR=/root/.dsh/profiles/web
GRAPHIFY_VENV=/root/.venvs/graphify
GRAPHIFY_BIN="$GRAPHIFY_VENV/bin/graphify"
TOOLS_SCRIPT="$APP_DIR/deploy/install-scan-tools.sh"
ADAPTER_PATCH="$APP_DIR/deploy/patch-claude-mem-adapter.js"
PW_SKILL_DIR="$SKILLS_DIR/playwright-skill"
PW_BROWSERS=/root/.cache/ms-playwright
ADAPTER_INDEX=/root/.npm-global/lib/node_modules/claude-mem/dsh/lib/index.js

export NPM_CONFIG_PREFIX=/root/.npm-global
export PATH="/root/.bun/bin:/root/.npm-global/bin:$GRAPHIFY_VENV/bin:/root/.venvs/sec/bin:/root/.local/bin:$PATH"
# How long a chat may sit idle before claude-mem closes its session and writes
# the summary. 30 minutes. The adapter reads this; override it in Coolify.
export CLAUDE_MEM_INACTIVITY_MS="${CLAUDE_MEM_INACTIVITY_MS:-1800000}"
# Playwright runs in a container: no display, and root needs --no-sandbox.
# lib/helpers.js reads PW_HEADLESS and adds --no-sandbox automatically.
export PW_HEADLESS=true

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1
MISSING=0

log() { printf '[entrypoint] %s\n' "$*"; }
warn() { printf '[entrypoint] WARN: %s\n' "$*" >&2; }
missing() { MISSING=1; warn "$*"; }

# --- skills bundle -----------------------------------------------------------
# The image carries the whole skill set as a tarball. Restoring from it is a
# local extract, so a wiped volume gets every skill back with no network.
ensure_skills() {
  if [ ! -f "$SKILLS_BUNDLE" ]; then
    missing "skills bundle absent at $SKILLS_BUNDLE (image built without deploy/)"
    return 1
  fi
  local want have_now
  want=$(sha256sum "$SKILLS_BUNDLE" | cut -d' ' -f1)
  have_now=$(cat "$SKILLS_MARKER" 2>/dev/null || true)
  if [ "$want" = "$have_now" ]; then
    log "skills present ($(find "$SKILLS_DIR" -maxdepth 2 -name SKILL.md 2>/dev/null | wc -l) skills, bundle ${want:0:12})"
    return 0
  fi
  if [ "$CHECK_ONLY" = 1 ]; then
    missing "skills not restored from bundle $want"
    return 1
  fi
  log "restoring skills from image bundle ..."
  mkdir -p "$SKILLS_DIR"
  if tar xzf "$SKILLS_BUNDLE" -C "$SKILLS_DIR"; then
    printf '%s' "$want" > "$SKILLS_MARKER"
    log "skills restored ($(find "$SKILLS_DIR" -maxdepth 2 -name SKILL.md | wc -l) skills)"
  else
    warn "skills restore failed"
    return 1
  fi
}

# --- llm shim -------------------------------------------------------------------
# claude-mem's host provider needs an OpenAI-compatible server on localhost and
# never starts one. This shim provides it and forwards to OpenRouter.
shim_up() {
  curl -fsS --max-time 2 "http://127.0.0.1:${SHIM_PORT}/health" >/dev/null 2>&1
}

ensure_shim() {
  if shim_up; then log "llm shim present (port $SHIM_PORT)"; return 0; fi
  if [ "$CHECK_ONLY" = 1 ]; then missing "llm shim not listening on $SHIM_PORT"; return 1; fi
  if [ ! -f "$SHIM_SCRIPT" ]; then warn "shim script absent at $SHIM_SCRIPT"; return 1; fi
  log "starting llm shim on $SHIM_PORT ..."
  mkdir -p /root/.llm-shim
  SHIM_PORT="$SHIM_PORT" SHIM_UPSTREAM_API="$SHIM_UPSTREAM_API" \
    SHIM_UPSTREAM_BASE_URL="$SHIM_UPSTREAM_BASE_URL" SHIM_MODEL="$SHIM_MODEL" \
    SHIM_UPSTREAM_KEY_ENV="$SHIM_UPSTREAM_KEY_ENV" \
    setsid nohup python3 "$SHIM_SCRIPT" >>/root/.llm-shim/shim.out 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    shim_up && { log "llm shim ready"; return 0; }
    sleep 1
  done
  warn "llm shim did not become ready"
  return 1
}

# Point claude-mem at the shim so its provider is not left on the Claude CLI.
ensure_claude_mem_settings() {
  mkdir -p /root/.claude-mem
  if [ -f "$CLAUDE_MEM_SETTINGS" ] && grep -q 'CLAUDE_MEM_OPENROUTER_BASE_URL' "$CLAUDE_MEM_SETTINGS" 2>/dev/null; then
    log "claude-mem settings present"
    return 0
  fi
  if [ "$CHECK_ONLY" = 1 ]; then missing "claude-mem settings not configured for the shim"; return 1; fi
  cat > "$CLAUDE_MEM_SETTINGS" <<SETTINGS
{
  "CLAUDE_MEM_RUNTIME": "worker",
  "CLAUDE_MEM_PROVIDER": "openrouter",
  "CLAUDE_MEM_OPENROUTER_BASE_URL": "http://127.0.0.1:${SHIM_PORT}/v1",
  "CLAUDE_MEM_OPENROUTER_MODEL": "${SHIM_MODEL}",
  "CLAUDE_MEM_OPENROUTER_API_KEY": "shim-managed",
  "CLAUDE_MEM_MODEL": "${SHIM_MODEL}"
}
SETTINGS
  log "claude-mem settings written"
}

# The DSH profile must carry the adapter and its flags; a fresh volume has neither.
ensure_profile_adapter() {
  local pkg
  pkg=$(npm root -g 2>/dev/null)/claude-mem/dsh
  if [ -d "$PROFILE_DIR/node_modules/@claude-mem/dsh" ]; then
    log "claude-mem DSH adapter present"
  elif [ "$CHECK_ONLY" = 1 ]; then
    missing "claude-mem DSH adapter not installed in the profile"
    return 1
  elif [ -d "$pkg" ]; then
    log "installing claude-mem DSH adapter into the profile ..."
    ( cd "$APP_DIR" && pnpm dsh plugin --profile web add "$pkg" >/dev/null 2>&1 ) \
      || warn "adapter install failed"
  fi
  local patch="$PROFILE_DIR/cordis.patch.yml"
  [ -f "$patch" ] || return 0
  if grep -q '@claude-mem/dsh' "$patch" 2>/dev/null; then return 0; fi
  if [ "$CHECK_ONLY" = 1 ]; then missing "claude-mem adapter flags absent from the profile patch"; return 1; fi
  cat >> "$patch" <<'PATCH'
- id: claude-mem
  name: "@claude-mem/dsh"
  config:
    injectContext: true
    ingest: true
    summarize: false
    startLocalWorker: true
PATCH
  log "claude-mem adapter flags added to the profile patch"
}

# The adapter never closes a session, so nothing becomes recallable memory.
# This appends the missing agent/disposed handler; idempotent.
ensure_adapter_patch() {
  if [ ! -f "$ADAPTER_INDEX" ]; then
    log "claude-mem adapter not installed yet; skipping session-end patch"
    return 0
  fi
  if grep -q 'dsh-session-lifecycle' "$ADAPTER_INDEX" 2>/dev/null; then
    log "claude-mem adapter manages sessions (inactivity close: 30m)"
    return 0
  fi
  if [ "$CHECK_ONLY" = 1 ]; then missing "claude-mem adapter lacks the session-lifecycle handler"; return 1; fi
  if [ -f "$ADAPTER_PATCH" ] && command -v node >/dev/null 2>&1; then
    node "$ADAPTER_PATCH" "$ADAPTER_INDEX" || warn "adapter patch failed"
  else
    warn "adapter patch script or node missing"
  fi
}

# The browser-trust fence answers 403 to every authority it was not told about,
# so a custom domain stays dead until its hostname reaches trustedHosts. And the
# launch token is regenerated per process by design, so a long-lived cookie is
# what keeps a browser logged in across restarts. Both live in the profile
# patch; idempotent.
ensure_web_auth_config() {
  local patch="$PROFILE_DIR/cordis.patch.yml"
  [ -f "$patch" ] || return 0
  if grep -q 'trustedHosts' "$patch" 2>/dev/null && grep -q 'cookieMaxAgeDays' "$patch" 2>/dev/null; then
    log "web auth config present (custom domain trusted, long-lived cookie)"
    return 0
  fi
  if [ "$CHECK_ONLY" = 1 ]; then missing "web auth config absent from the profile patch"; return 1; fi
  {
    cat <<'PATCH'
- id: connection
  name: "@deepseek-ai/dsh-client-connection"
  config:
    trustedHosts:
      - constructor.zottagroup.com
PATCH
    [ -n "${TRUSTED_HOST:-}" ] && printf '      - %s\n' "$TRUSTED_HOST"
    cat <<'PATCH'
- id: authentication-token
  name: "@deepseek-ai/dsh-host-authentication-token"
  config:
    cookieMaxAgeDays: 3650
PATCH
  } >> "$patch"
  log "web auth config added to the profile patch"
}

# --- bun ------------------------------------------------------------------------
# claude-mem's worker runs on Bun. It lives under /root/.bun so it survives a
# redeploy; this rebuilds it only when the volume is fresh.
ensure_bun() {
  if [ -x "$BUN_BIN" ]; then
    log "bun present ($("$BUN_BIN" --version 2>/dev/null))"
    return 0
  fi
  if [ "$CHECK_ONLY" = 1 ]; then missing "bun MISSING ($BUN_BIN)"; return 1; fi
  log "bun missing, installing into /root/.bun ..."
  command -v unzip >/dev/null 2>&1 || {
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq --no-install-recommends unzip >/dev/null 2>&1
  }
  if BUN_INSTALL=/root/.bun curl -fsSL https://bun.sh/install 2>/dev/null | BUN_INSTALL=/root/.bun bash >/dev/null 2>&1 \
     && [ -x "$BUN_BIN" ]; then
    log "bun installed ($("$BUN_BIN" --version))"; return 0
  fi
  warn "bun install failed (network?)"; return 1
}

# --- claude-mem ---------------------------------------------------------------
ensure_claude_mem() {
  if [ -x "$CLAUDE_MEM_BIN" ]; then
    log "claude-mem present ($("$CLAUDE_MEM_BIN" version 2>/dev/null || echo unknown))"
    return 0
  fi
  if [ "$CHECK_ONLY" = 1 ]; then missing "claude-mem MISSING ($CLAUDE_MEM_BIN)"; return 1; fi
  log "claude-mem missing, installing ..."
  if npm install -g "claude-mem@${CLAUDE_MEM_VERSION}" >/dev/null 2>&1; then
    log "claude-mem installed"; return 0
  fi
  warn "claude-mem install failed (network?)"; return 1
}

# --- graphify -----------------------------------------------------------------
graphify_usable() {
  [ -x "$GRAPHIFY_BIN" ] && "$GRAPHIFY_VENV/bin/python3" -c 'import graphify' >/dev/null 2>&1
}

ensure_graphify() {
  if graphify_usable; then
    log "graphify present ($("$GRAPHIFY_BIN" --version 2>/dev/null | head -1))"
    mkdir -p /root/.local/bin
    ln -sf "$GRAPHIFY_BIN" /root/.local/bin/graphify
    return 0
  fi
  if [ "$CHECK_ONLY" = 1 ]; then missing "graphify MISSING ($GRAPHIFY_BIN)"; return 1; fi
  log "graphify missing, rebuilding venv ..."
  python3 -m venv --help >/dev/null 2>&1 || {
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq --no-install-recommends python3-venv >/dev/null 2>&1
  }
  python3 -m venv "$GRAPHIFY_VENV" >/dev/null 2>&1 || { warn "venv creation failed"; return 1; }
  "$GRAPHIFY_VENV/bin/pip" install --quiet graphifyy >/dev/null 2>&1 || { warn "pip install failed"; return 1; }
  mkdir -p /root/.local/bin
  ln -sf "$GRAPHIFY_BIN" /root/.local/bin/graphify
  log "graphify installed"
}

# --- playwright -----------------------------------------------------------------
# The skill ships as source; its npm dependency and the Chromium build are
# restored here. Chromium also needs system libraries that node:24-slim lacks,
# so install-deps runs with apt. Roughly 150 MB on a cold volume.
ensure_playwright() {
  if [ ! -f "$PW_SKILL_DIR/SKILL.md" ]; then
    log "playwright skill not present; skipping its setup"
    return 0
  fi

  if [ -d "$PW_SKILL_DIR/node_modules/playwright" ]; then
    log "playwright dependency present"
  else
    if [ "$CHECK_ONLY" = 1 ]; then missing "playwright npm dependency MISSING"; return 1; fi
    log "installing playwright npm dependency ..."
    ( cd "$PW_SKILL_DIR" && npm install --silent >/dev/null 2>&1 ) \
      || warn "playwright npm install failed (network?)"
  fi

  if ls -d "$PW_BROWSERS"/chromium* >/dev/null 2>&1; then
    log "chromium present"
  else
    if [ "$CHECK_ONLY" = 1 ]; then missing "chromium MISSING in $PW_BROWSERS"; return 1; fi
    log "installing chromium and its system libraries ..."
    ( cd "$PW_SKILL_DIR" && npx playwright install-deps chromium >/dev/null 2>&1 ) \
      || warn "chromium system libraries may be incomplete"
    ( cd "$PW_SKILL_DIR" && npx playwright install chromium >/dev/null 2>&1 ) \
      || warn "chromium install failed (network?)"
  fi
}

# --- security scanning tools --------------------------------------------------
ensure_tools() {
  if [ ! -x "$TOOLS_SCRIPT" ]; then
    missing "scan tools installer absent at $TOOLS_SCRIPT"
    return 1
  fi
  if [ "$CHECK_ONLY" = 1 ]; then
    "$TOOLS_SCRIPT" --check >/dev/null 2>&1 || { missing "security scan tools incomplete"; return 1; }
    log "scan tools present"
    return 0
  fi
  "$TOOLS_SCRIPT" >/dev/null 2>&1 || warn "some scan tools failed to install; DSH still starts"
  log "scan tools ready"
}

# --- run ----------------------------------------------------------------------
ensure_skills
ensure_bun
ensure_shim
ensure_claude_mem
ensure_claude_mem_settings
ensure_profile_adapter
ensure_adapter_patch
ensure_web_auth_config
ensure_graphify
ensure_playwright
ensure_tools

if [ "$CHECK_ONLY" = 1 ]; then
  echo '---'
  log "skills:      $(find "$SKILLS_DIR" -maxdepth 2 -name SKILL.md 2>/dev/null | wc -l) installed"
  log "graphify:    $(command -v graphify || echo MISSING)"
  log "playwright:  $([ -d "$PW_SKILL_DIR/node_modules/playwright" ] && echo dependency-ok || echo MISSING)"
  log "chromium:    $(ls -d "$PW_BROWSERS"/chromium* >/dev/null 2>&1 && echo present || echo MISSING)"
  log "llm shim:    $(shim_up && echo "listening on $SHIM_PORT" || echo MISSING)"
  log "cm settings: $([ -f "$CLAUDE_MEM_SETTINGS" ] && echo present || echo MISSING)"
  log "dsh adapter: $([ -d "$PROFILE_DIR/node_modules/@claude-mem/dsh" ] && echo present || echo MISSING)"
  log "session lifecycle: $(grep -q 'dsh-session-lifecycle' "$ADAPTER_INDEX" 2>/dev/null && echo patched || echo UNPATCHED)"
  log "bun:         $([ -x "$BUN_BIN" ] && echo present || echo MISSING)"
  log "claude-mem:  $([ -x "$CLAUDE_MEM_BIN" ] && echo present || echo MISSING)"
  log "cm config:   $([ -d /root/.claude-mem ] && echo present || echo 'absent (run: npx claude-mem install)')"
  for t in gitleaks trivy syft grype cosign opa semgrep guarddog; do
    log "$(printf '%-11s' "$t") $(command -v "$t" || echo MISSING)"
  done
  [ "$MISSING" = 1 ] && { warn "state incomplete — a real boot would restore it"; exit 1; }
  log "all components present"
  exit 0
fi

# The app refuses 0.0.0.0, so bind the container's concrete IPv4.
IP=$(hostname -i | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)

# Trusted authorities for the browser-trust fence. TRUSTED_HOST is the
# platform-provided authority; EXTRA_TRUSTED_HOSTS carries custom domains,
# space-separated, so a custom domain stops answering 403 without editing code.
TRUSTED_ARGS=(--trusted-host "$TRUSTED_HOST")
for host in ${EXTRA_TRUSTED_HOSTS:-constructor.zottagroup.com}; do
  [ -n "$host" ] && TRUSTED_ARGS+=(--trusted-host "$host")
done

exec pnpm dsh web --no-open --host "$IP" --port 3080 \
  --public-url "$PUBLIC_URL" "${TRUSTED_ARGS[@]}"
