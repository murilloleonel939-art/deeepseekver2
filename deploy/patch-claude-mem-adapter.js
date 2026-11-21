#!/usr/bin/env node
/**
 * Make claude-mem's DSH adapter register and close sessions.
 *
 * claude-mem only injects memory into a new chat from sessions it considers
 * closed: it lists sdk_sessions rows with status 'completed'. A row only
 * reaches 'completed' when the in-memory generator for that session exits and
 * the worker finalizes it. The DSH adapter has two gaps that prevent this from
 * ever happening:
 *
 * 1. It defines `sessionInit` but never calls it, so no session row is created
 *    for a real DSH chat. Observations land in a fallback "manual" session.
 * 2. It never closes a session. DSH has no Claude-Code-style hook for "agent
 *    stopped", so `agent/disposed` is the only available signal.
 *
 * This script adds a handler pair:
 *
 *   agent/created   -> POST /api/sessions/init
 *   agent/disposed  -> POST /api/sessions/summarize (when the flag is on)
 *                       POST /api/sessions/session-end
 *
 * Both use the agent's own session id, so the memory is bound to the real
 * session that a later chat in the same working directory will open.
 *
 * Idempotent: each edit is skipped when its marker is already present. Fails
 * soft: if a future claude-mem moves the hook site, it reports that and leaves
 * the file untouched, so a version bump cannot corrupt a running adapter.
 *
 * Usage:
 *   node patch-claude-mem-adapter.js [path-to-adapter-index.js]
 */

'use strict'

const fs = require('node:fs')
const path = require('node:path')

const DEFAULT_TARGET = '/root/.npm-global/lib/node_modules/claude-mem/dsh/lib/index.js'
const WORKER_BASE = 'process.env.CLAUDE_MEM_WORKER_URL||"http://127.0.0.1:37700"'

const CREATED_NEEDLE = 'r.injectContext&&await ms(t,o,r)}'
const CREATED_MARKER = 'dsh-session-init'

const CREATED_REPLACEMENT = [
  'r.injectContext&&await ms(t,o,r)',
  ';try{',
  `if(o.session){const base=${WORKER_BASE};`,
  'await fetch(base+"/api/sessions/init",{method:"POST",',
  'headers:{"content-type":"application/json"},',
  'body:JSON.stringify({contentSessionId:o.session.id,',
  'project:typeof r.project==="string"&&r.project.trim()?r.project:undefined,',
  'cwd:o.session.header&&o.session.header.cwd,prompt:"dsh session"})})}',
  `}catch(_){}/*${CREATED_MARKER}*/}`,
].join('')

const DISPOSED_NEEDLE = ',r.summarize&&e.on("agent/turn-stopping",n=>{ys(t,n.agent,r)})}'
const DISPOSED_MARKER = 'agent/disposed'

const DISPOSED_REPLACEMENT = [
  DISPOSED_NEEDLE.slice(0, -1),
  ',e.on("agent/disposed",async n=>{try{',
  'const a=n&&n.agent;if(!a||!a.session)return;',
  'if(r.summarize)await ys(t,a,r);',
  `const base=${WORKER_BASE};`,
  'await fetch(base+"/api/sessions/session-end",{method:"POST",',
  'headers:{"content-type":"application/json"},',
  'body:JSON.stringify({contentSessionId:a.session.id,',
  'cwd:a.session.header&&a.session.header.cwd,reason:"agent disposed"})})',
  '}catch(_){}})}',
].join('')

function patchFile(target) {
  if (!fs.existsSync(target)) {
    console.log(`[adapter-patch] adapter not found at ${target}; nothing to do`)
    return 0
  }
  let src = fs.readFileSync(target, 'utf8')
  let changed = false

  if (src.includes(CREATED_MARKER)) {
    console.log('[adapter-patch] session init already present')
  } else if (src.includes(CREATED_NEEDLE)) {
    src = src.replace(CREATED_NEEDLE, CREATED_REPLACEMENT)
    changed = true
    console.log('[adapter-patch] added session init on agent/created')
  } else {
    console.log('[adapter-patch] agent/created hook site not found; leaving it alone')
  }

  if (src.includes(DISPOSED_MARKER)) {
    console.log('[adapter-patch] session end already present')
  } else if (src.includes(DISPOSED_NEEDLE)) {
    src = src.replace(DISPOSED_NEEDLE, DISPOSED_REPLACEMENT)
    changed = true
    console.log('[adapter-patch] added session end on agent/disposed')
  } else {
    console.log('[adapter-patch] agent/disposed hook site not found; leaving it alone')
  }

  if (!changed) return 0
  const tmp = `${target}.tmp`
  fs.writeFileSync(tmp, src)
  fs.renameSync(tmp, path.resolve(target))
  console.log('[adapter-patch] written')
  return 0
}

process.exit(patchFile(process.argv[2] || DEFAULT_TARGET))
