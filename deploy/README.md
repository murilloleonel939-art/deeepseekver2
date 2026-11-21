# Deploy assets

Everything needed to make a redeploy non-destructive. Three files, one entrypoint.

**For where everything lives, the repository, credentials and how to recover
after a redeploy, read [`ESTADO-DEL-DESPLIEGUE.md`](./ESTADO-DEL-DESPLIEGUE.md).**

## Layout

| File | Role |
|------|------|
| `deploy/skills.tar.gz` | The 66 agent skills. Source of truth for `/root/.agents/skills`. |
| `deploy/SKILLS-MANIFEST.md` | Human-readable list of what the tarball contains. |
| `deploy/install-scan-tools.sh` | Installs the security scanners into `/root/.local/bin` and `/root/.venvs/sec`. |
| `deploy/llm-shim.py` | OpenAI-compatible endpoint on `127.0.0.1:37778` in front of pateway2gpt, pinned to `gpt-6-luna`. |
| `deploy/patch-claude-mem-adapter.js` | Adds the missing session registration and close handlers so memory becomes recallable. |
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
7. **Adapter session-lifecycle patch** — installs session init, the inactivity
   timer and the dispose handler into the adapter, idempotently.
8. **Playwright** — `npm install` in `playwright-skill/` and Chromium plus its
   system libraries, so browser testing works after a fresh volume.
9. **Scan tools** — gitleaks, trivy, syft, grype, cosign, opa, semgrep, guarddog.

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

claude-mem only injects memory from sessions it considers closed: it lists
`sdk_sessions` rows with `status = 'completed'`, and a row only reaches that
state when the worker finalizes the session's generator. The DSH adapter had two
gaps:

1. It defines `sessionInit` but never calls it, so no session row is created for
   a real DSH chat. Observations land in a fallback session instead of the one a
   later chat will open.
2. It never closes a session. DSH has no Claude-Code-style stop hook, so
   `agent/disposed` is the only available signal.

`deploy/patch-claude-mem-adapter.js` adds both:

| DSH event | Worker call |
|-----------|-------------|
| `agent/created` | `POST /api/sessions/init` |
| `agent/disposed` | `POST /api/sessions/summarize` (when enabled), then `POST /api/sessions/session-end` |

Verified end to end: after init, an observation and a summary, a fresh
`/api/context/inject` for the same working directory returns the generated
summary fields — request, investigated, learned, completed, next steps. Without
the patch the same call answers "No previous sessions found".

The patch is idempotent and fails soft — if a future claude-mem moves either
hook site, it reports that and leaves the file untouched, so a version bump
cannot corrupt a running adapter. `entrypoint.sh --check` reports both
`session init:` and `sessions end:`.

## When memory is written

Observations are captured continuously — one per tool call, as the work happens.
That raw record is available to search immediately.

A session becomes *recallable* (injected into a new chat) only once it is closed,
because that is when the summary is generated. Two triggers close it:

| Trigger | When | Notes |
|---------|------|-------|
| Inactivity | 30 minutes with no activity | Default. Restarts on every turn, so an active chat is never closed under you. |
| `agent/disposed` | The agent is released | Closing or restarting the chat. Closes immediately instead of waiting. |

The inactivity window is `CLAUDE_MEM_INACTIVITY_MS` (default `1800000`, i.e. 30
minutes). `entrypoint.sh` exports it, so it can be overridden from Coolify
without touching the image.

Practical consequence: **you do not have to close a chat** for its memory to be
written. Leaving it idle for 30 minutes is enough. Closing it makes that happen
sooner.

**Cost note:** with `summarize: true` one haiku summary runs per turn, measured
at about 4,300 tokens each. Set the flag to `false` to keep capture and search
without per-turn model calls.

## Playwright runs headless, as root

The container has no display, so `playwright-skill` is configured for headless
use. `entrypoint.sh` exports `PW_HEADLESS=true`, and the skill's `launchBrowser()`
helper reads it and adds `--no-sandbox` because the process runs as root.

If you write Playwright code by hand rather than through the helper, both flags
are required or Chromium refuses to start:

```js
const browser = await chromium.launch({ headless: true, args: ['--no-sandbox'] });
```

The skills bundle excludes `node_modules` — it is 19 MB and reinstallable — so
`deploy/skills.tar.gz` stays at 4.5 MB. `ensure_playwright` restores the npm
dependency and Chromium, including the apt libraries `node:24-slim` lacks
(`libnss3`, `libgbm`, `libatk`, and the rest), which is roughly 150 MB on a cold
volume and takes a minute or two.

Chromium is cached in `/root/.cache/ms-playwright`, so it survives a redeploy
with a warm volume.

## The LLM shim and which model it calls

claude-mem's `host` provider expects an OpenAI-compatible server on localhost and
never starts one. `deploy/llm-shim.py` supplies `/v1/chat/completions` and
`/v1/models`, and translates to and from pateway1's Anthropic-messages dialect.

**The model is pinned to `gpt-6-luna` (provider `pateway2gpt`, key `PATEWAY2GPT_API_KEY`).** The shim overwrites whatever model
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
