#!/bin/bash
# Install the security scanning tools used by the installed skills.
#
# Everything lands under /root so it survives a redeploy:
#   /root/.local/bin        binaries (already on PATH)
#   /root/.venvs/sec        Python tools (semgrep, guarddog)
#
# Idempotent: a tool that already answers `--version` is skipped, so a warm
# volume does no network work.
#
# Usage:
#   ./install-scan-tools.sh           install what is missing
#   ./install-scan-tools.sh --check   report only, exit 1 if anything is missing

set -uo pipefail

BIN=/root/.local/bin
VENV=/root/.venvs/sec
PIP="$VENV/bin/pip"
# Release metadata is parsed with the system interpreter: it needs only the
# standard library, and it must work before the venv exists.
SYS_PY=$(command -v python3 || command -v python)
CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1
MISSING=0

log() { printf '[tools] %s\n' "$*"; }
warn() { printf '[tools] WARN: %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

mkdir -p "$BIN"

# Resolve a GitHub release asset URL for the current architecture.
# Args: repo, regex of the asset name to match.
release_url() {
  local repo=$1 pattern=$2
  curl -fsSL --max-time 30 "https://api.github.com/repos/$repo/releases/latest" \
    | "$SYS_PY" -c '
import json, re, sys
pattern = re.compile(sys.argv[1])
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for asset in data.get("assets", []):
    if pattern.search(asset["name"]):
        print(asset["browser_download_url"]); break
' "$pattern"
}

# Download a GitHub release tarball, extract one binary into $BIN.
# Args: name, repo, asset-regex, binary-name-inside-tarball
install_tarball() {
  local name=$1 repo=$2 pattern=$3 member=$4
  if have "$name"; then log "$name present ($("$name" --version 2>&1 | head -1))"; return 0; fi
  if [ "$CHECK_ONLY" = 1 ]; then warn "$name MISSING"; MISSING=1; return 1; fi
  local url tmp
  url=$(release_url "$repo" "$pattern") || { warn "$name: could not resolve release"; return 1; }
  [ -n "$url" ] || { warn "$name: no asset matched $pattern"; return 1; }
  tmp=$(mktemp -d)
  log "downloading $name from $url"
  if ! curl -fsSL --max-time 300 -o "$tmp/pkg.tgz" "$url"; then
    warn "$name: download failed"; rm -rf "$tmp"; return 1
  fi
  if ! tar -xzf "$tmp/pkg.tgz" -C "$tmp" "$member" 2>/dev/null; then
    tar -xzf "$tmp/pkg.tgz" -C "$tmp" 2>/dev/null || { warn "$name: extract failed"; rm -rf "$tmp"; return 1; }
  fi
  local found
  found=$(find "$tmp" -type f -name "$member" -perm -u+x 2>/dev/null | head -1)
  [ -n "$found" ] || found=$(find "$tmp" -type f -name "$member" 2>/dev/null | head -1)
  [ -n "$found" ] || { warn "$name: binary $member not found in archive"; rm -rf "$tmp"; return 1; }
  install -m 0755 "$found" "$BIN/$name"
  rm -rf "$tmp"
  have "$name" && log "$name installed ($("$name" --version 2>&1 | head -1))"
}

# Download a single static binary (no archive).
# Args: name, repo, asset-regex
install_binary() {
  local name=$1 repo=$2 pattern=$3
  if have "$name"; then log "$name present ($("$name" version 2>&1 | head -1))"; return 0; fi
  if [ "$CHECK_ONLY" = 1 ]; then warn "$name MISSING"; MISSING=1; return 1; fi
  local url
  url=$(release_url "$repo" "$pattern") || { warn "$name: could not resolve release"; return 1; }
  [ -n "$url" ] || { warn "$name: no asset matched $pattern"; return 1; }
  log "downloading $name from $url"
  if curl -fsSL --max-time 300 -o "$BIN/$name.tmp" "$url" \
     && install -m 0755 "$BIN/$name.tmp" "$BIN/$name"; then
    rm -f "$BIN/$name.tmp"
    log "$name installed ($("$name" version 2>&1 | head -1))"
  else
    warn "$name: download failed"; rm -f "$BIN/$name.tmp"; return 1
  fi
}

# Python tools live in their own venv, symlinked onto PATH.
ensure_venv() {
  [ -x "$PIP" ] && return 0
  [ "$CHECK_ONLY" = 1 ] && return 0
  log "creating venv at $VENV"
  if ! python3 -m venv "$VENV" >/dev/null 2>&1; then
    warn "could not create venv at $VENV"; return 1
  fi
  "$PIP" install --quiet --upgrade pip >/dev/null 2>&1
}

install_python_tool() {
  local name=$1 pkg=${2:-$1} entry=${3:-$1}
  if have "$name"; then log "$name present"; return 0; fi
  if [ "$CHECK_ONLY" = 1 ]; then warn "$name MISSING"; MISSING=1; return 1; fi
  ensure_venv || return 1
  log "installing $pkg into venv"
  if "$PIP" install --quiet "$pkg" >/dev/null 2>&1; then
    [ -x "$VENV/bin/$entry" ] && ln -sf "$VENV/bin/$entry" "$BIN/$name"
    have "$name" && log "$name installed ($("$name" --version 2>&1 | head -1))"
  else
    warn "$name: pip install failed"
  fi
}

# --- Go/Rust static binaries -------------------------------------------------
install_tarball gitleaks gitleaks/gitleaks 'linux_x64\.tar\.gz$' gitleaks
install_tarball trivy    aquasecurity/trivy 'Linux-64bit\.tar\.gz$' trivy
install_tarball syft     anchore/syft      'linux_amd64\.tar\.gz$'  syft
install_tarball grype    anchore/grype     'linux_amd64\.tar\.gz$'  grype
install_binary  cosign   sigstore/cosign   'cosign-linux-amd64$'
install_binary  opa      open-policy-agent/opa 'opa_linux_amd64$'

# --- Python tools ------------------------------------------------------------
install_python_tool semgrep semgrep
install_python_tool guarddog guarddog

# --- summary -----------------------------------------------------------------
if [ "$CHECK_ONLY" = 1 ]; then
  echo '---'
  for t in gitleaks trivy syft grype cosign opa semgrep guarddog; do
    printf '  %-10s %s\n' "$t" "$(have "$t" && echo ok || echo MISSING)"
  done
  [ "$MISSING" = 1 ] && { warn 'tools incomplete'; exit 1; }
  log 'all tools present'; exit 0
fi
log 'done'
