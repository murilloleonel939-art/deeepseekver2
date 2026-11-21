#!/usr/bin/env node
/**
 * Give the Web UI a launch token that survives restarts.
 *
 * `dsh web` prints its entry URL as `.../?token=<43 chars>`. The authentication
 * plugin derives that token with `randomBytes` per process, so every restart
 * prints a different one: a bookmarked URL stops working, and after a redeploy
 * every browser has to be handed the new link. The signed cookie the token
 * exchange mints softens this, but only for browsers that already logged in
 * once with the current token.
 *
 * This script replaces `processLaunchToken` with a version that persists the
 * token to a file on the volume (mode 0600) and reuses it on later boots. The
 * token keeps the same strength: 32 random bytes, base64url, produced by the
 * same code path, only stored instead of discarded.
 *
 * Overrides:
 *   DSH_LAUNCH_TOKEN        fixed token; wins over the file when it is a valid
 *                           43-character base64url value
 *   DSH_LAUNCH_TOKEN_FILE   token path (default /root/.dsh/web-launch-token)
 *
 * Written as ESM on purpose: this repository sets "type": "module", so a
 * `require`-based script dies with "require is not defined in ES module scope"
 * and the boot would silently skip the patch. (patch-claude-mem-adapter.js has
 * that defect; it survives only because the adapter is usually already patched
 * and the call is skipped.)
 *
 * Idempotent: a file carrying the marker is left untouched. Fails soft: if a
 * future DSH changes the function shape, it reports that and leaves the plugin
 * alone so a boot cannot break.
 *
 * Usage:
 *   node patch-web-token.js [path-to-authentication-token-index.js]
 */

import fs from 'node:fs'
import path from 'node:path'

const DEFAULT_TARGET = '/app/packages/host/authentication-token/lib/index.js'
const MARKER = 'dsh-stable-launch-token'

const ORIGINAL = `function processLaunchToken(owner) {
\tconst existing = PROCESS_LAUNCH_TOKENS.get(owner);
\tif (existing !== void 0) return existing;
\tconst created = encodeBase64Url(randomBytes(SECRET_BYTES));
\tPROCESS_LAUNCH_TOKENS.set(owner, created);
\treturn created;
}`

const PATCHED = `/* ${MARKER} */
function processLaunchToken(owner) {
\tconst existing = PROCESS_LAUNCH_TOKENS.get(owner);
\tif (existing !== void 0) return existing;
\tconst valid = (value) => typeof value === "string" && /^[A-Za-z0-9_-]{43}$/u.test(value);
\tlet created;
\tconst fixed = process.env.DSH_LAUNCH_TOKEN;
\tif (valid(fixed)) created = fixed;
\tif (created === void 0) {
\t\tconst tokenFile = process.env.DSH_LAUNCH_TOKEN_FILE || "/root/.dsh/web-launch-token";
\t\tconst fs = process.getBuiltinModule("node:fs");
\t\ttry {
\t\t\tconst stored = fs.readFileSync(tokenFile, "utf8").trim();
\t\t\tif (valid(stored)) created = stored;
\t\t} catch {}
\t\tif (created === void 0) {
\t\t\tcreated = encodeBase64Url(randomBytes(SECRET_BYTES));
\t\t\ttry {
\t\t\t\tfs.mkdirSync("/root/.dsh", { recursive: true });
\t\t\t\tfs.writeFileSync(tokenFile, created + "\\n", { mode: 384 });
\t\t\t} catch {}
\t\t}
\t}
\tPROCESS_LAUNCH_TOKENS.set(owner, created);
\treturn created;
}`

function patchFile(target) {
  const resolved = path.resolve(target)
  if (!fs.existsSync(resolved)) {
    console.log(`[web-token-patch] ${resolved} not found; leaving it alone`)
    return 0
  }
  const src = fs.readFileSync(resolved, 'utf8')

  if (src.includes(MARKER)) {
    console.log('[web-token-patch] stable launch token already installed')
    return 0
  }

  if (!src.includes(ORIGINAL)) {
    console.log('[web-token-patch] processLaunchToken shape not recognised;')
    console.log('[web-token-patch] leaving the plugin untouched so the boot cannot break')
    return 0
  }

  const tmp = `${resolved}.tmp`
  fs.writeFileSync(tmp, src.replace(ORIGINAL, PATCHED))
  fs.renameSync(tmp, resolved)
  console.log('[web-token-patch] launch token now persists across restarts')
  console.log('[web-token-patch]   file: /root/.dsh/web-launch-token (0600)')
  console.log('[web-token-patch]   override: DSH_LAUNCH_TOKEN or DSH_LAUNCH_TOKEN_FILE')
  return 0
}

process.exit(patchFile(process.argv[2] || DEFAULT_TARGET))
