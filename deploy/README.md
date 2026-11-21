# Deploy assets

Everything needed to make a redeploy non-destructive. Three files, one entrypoint.

## Layout

| File | Role |
|------|------|
| `deploy/skills.tar.gz` | The 66 agent skills. Source of truth for `/root/.agents/skills`. |
| `deploy/SKILLS-MANIFEST.md` | Human-readable list of what the tarball contains. |
| `deploy/install-scan-tools.sh` | Installs the security scanners into `/root/.local/bin` and `/root/.venvs/sec`. |
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
5. **Scan tools** — gitleaks, trivy, syft, grype, cosign, opa, semgrep, guarddog.

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

## claude-mem provider

The binary and plugin install automatically, but claude-mem needs an LLM
provider that this deployment does not supply. Its `host` mode expects a local
OpenAI-compatible server on `127.0.0.1:37777`, which DSH does not run; the
other providers need an API key or a cmem.ai sign-in. Until one is configured,
`claude-mem status` reports the worker as not running and memory capture stays
off. This does not affect skills, graphify, or the scanners.
