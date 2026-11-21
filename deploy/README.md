# Deploy assets

Everything needed to make a redeploy non-destructive. Three files, one entrypoint.

## Layout

| File | Role |
|------|------|
| `deploy/skills.tar.gz` | The 66 agent skills. Source of truth for `/root/.agents/skills`. |
| `deploy/SKILLS-MANIFEST.md` | Human-readable list of what the tarball contains. |
| `deploy/install-scan-tools.sh` | Installs the security scanners into `/root/.local/bin` and `/root/.venvs/sec`. |
| `deploy/llm-shim.py` | OpenAI-compatible endpoint on `127.0.0.1:37778` in front of pateway1, pinned to `claude-haiku-5-5`. |
| `deploy/patch-claude-mem-adapter.js` | Adds the missing `agent/disposed` handler so sessions close and become recallable. |
| `entrypoint.sh` (repo root) | Restores anything missing, then starts DSH. |

The `Dockerfile` copies `deploy/` and `entrypoint.sh` into the image and uses the
entrypoint as `ENTRYPOINT`.

## Why state is split in two layers

| Layer | Holds | Survives a redeploy because |
|-------|-------|-----------------------------|
| Image (`/app`) | Code, `deploy/`, `entrypoint.sh` | Rebuilt from the repo every deploy |
| Volume (`/root`) | Skills, venvs, binaries, configs, sessions, projects | Coolify keeps the volume |

Nothing important lives outside those two. `/app` must stay a volume-free image
layer: mounting a volume there would hide the application.

## What the entrypoint restores

Run with no arguments on boot. Each step is skipped when the thing already
exists, so a warm volume does no network work.

1. **Skills** — if `/root/.agents/skills/.bundle-sha256` does not match the
   tarball, extract `deploy/skills.tar.gz` over the directory and rewrite the
   marker. Local extract, no network, so a wiped volume gets all 66 skills back
   in about a second.
2. **Bun** — rebuild `/root/.bun` if missing (claude-mem's worker runs on it).
3. **claude-mem** — `npm install -g claude-mem@16.0.2` into `/root/.npm-global`.
4. **graphify** — rebuild `/root/.venvs/graphify` and its skill symlink.
5. **LLM shim** — starts `deploy/llm-shim.py` on port 37778 and writes
   `/root/.claude-mem/settings.json` so claude-mem's provider points at it.
6. **claude-mem adapter** — installs `@claude-mem/dsh` into the `web` profile and
   ensures its flags are `injectContext: true`, `ingest: true`, `summarize: false`.
7. **Adapter session-end patch** — appends the `agent/disposed` handler to the
   installed adapter, idempotently.
8. **Scan tools** — gitleaks, trivy, syft, grype, cosign, opa, semgrep, guarddog.

Failures are logged and the app still starts. A missing tool never blocks boot.

## Checking state without changing it

```bash
/app/entrypoint.sh --check
```

Prints one line per component and exits `1` if anything is missing. It never
installs, extracts, or writes anything.

## Updating the skill set

```bash
# on the machine that has the current skills
tar czf deploy/skills.tar.gz -C /root/.agents/skills .
sha256sum deploy/skills.tar.gz          # note the hash if you want to verify
# commit, push, redeploy — the entrypoint sees a new hash and re-extracts
```

The marker makes this automatic: change the tarball and the next boot replaces
the skill directory with the new content.

## First boot cost

On an empty volume the entrypoint downloads roughly 150 MB of scanners plus npm
and pip packages: expect **2-3 minutes**. Raise Coolify's health-check start
period above that, or the first deploy will report failure while the container
is healthy.

Later boots are local-only and take about a second.

## Manual recovery

If the volume is lost and you want the skills without a redeploy:

```bash
tar xzf /app/deploy/skills.tar.gz -C /root/.agents/skills
```

## Why memory did not work without the patch

claude-mem only treats a session as recallable once it is closed: it lists
`status = 'completed'` sessions when injecting context. The DSH adapter hooks
`agent/created`, `tools/post-execute` and `agent/turn-stopping`, and calls
`/api/sessions/init` and `/api/sessions/summarize`, but never
`/api/sessions/session-end`. Every session therefore stayed `active`, and a new
session was told "No previous sessions found" even though observations were
piling up.

DSH exposes `agent/disposed`, which is exactly the missing signal.
`deploy/patch-claude-mem-adapter.js` appends a handler for it that summarises
when the flag is on, then closes the session in the worker. Verified: with the
session closed, `/api/context/inject` returns the real summary; without it, it
returns "This project has no memory yet".

The patch is idempotent and fails soft — if a future claude-mem changes the hook
site, it reports that and leaves the file untouched, so a version bump cannot
break the boot. `entrypoint.sh --check` reports `sessions end: patched`.

**Cost note:** with `summarize: true` one haiku summary runs per turn, measured
at about 4,300 tokens each. Set the flag to `false` to keep capture and search
without per-turn model calls.

## The LLM shim and which model it calls

claude-mem's `host` provider expects an OpenAI-compatible server on localhost and
never starts one. `deploy/llm-shim.py` supplies `/v1/chat/completions` and
`/v1/models`, and translates to and from pateway1's Anthropic-messages dialect.

**The model is pinned to `claude-haiku-5-5`.** The shim overwrites whatever model
the caller requests, so no other model — opus, sonnet, fable — can be reached
through it. The choice lives in one place, `SHIM_MODEL` in `entrypoint.sh`.

The pateway1 key is read per request from `/root/.dsh/.credentials.yaml`
(`PATEWAY1_API_KEY`). It is never copied into a file the shim owns and never
logged.

With `summarize: false`, this model is not called at all: observations are stored
raw and embedded locally. The shim exists so the provider is configured and
healthy, ready if summarisation is ever turned on. Every request the shim serves
is logged, so `grep forwarding /root/.llm-shim/shim.log` is the audit trail for
any model usage.

## claude-mem provider

The binary and plugin install automatically, but claude-mem needs an LLM
provider that this deployment does not supply. Its `host` mode expects a local
OpenAI-compatible server on `127.0.0.1:37777`, which DSH does not run; the
other providers need an API key or a cmem.ai sign-in. Until one is configured,
`claude-mem status` reports the worker as not running and memory capture stays
off. This does not affect skills, graphify, or the scanners.
