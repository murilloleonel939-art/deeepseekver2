#!/usr/bin/env node
/**
 * Make claude-mem's DSH adapter close sessions.
 *
 * The adapter hooks `agent/created`, `tools/post-execute` and
 * `agent/turn-stopping`, and calls `POST /api/sessions/init` and
 * `/api/sessions/summarize`. It never calls `/api/sessions/session-end`, so
 * every session stays `status: 'active'`, and claude-mem only treats closed
 * sessions as recallable memory. The result: observations are captured but a
 * new session is told "no previous sessions found".
 *
 * DSH exposes `agent/disposed`, which is exactly the missing signal. This
 * script appends a handler for it that summarises (when the flag is on) and
 * closes the session in the worker.
 *
 * Idempotent: a file that already contains the handler is left alone. Safe on
 * an absent or unexpected file — it reports and exits 0 so it never blocks a
 * boot.
 *
 * Usage: node patch-claude-mem-adapter.js [path-to-adapter-index.js]
 */

'use strict'

const fs = require('node:fs')
const path = require('node:path')

const NEEDLE = ',r.summarize&&e.on("agent/turn-stopping",n=>{ys(t,n.agent,r)})}'
const MARKER = 'agent/disposed'

const HANDLER = NEEDLE.slice(0, -1) + `
,e.on("agent/disposed",async n=>{
  try{
    const a=n&&n.agent;
    if(!a||!a.session)return;
    if(r.summarize) await ys(t,a,r);
    const base=process.env.CLAUDE_MEM_WORKER_URL||"http://127.0.0.1:37700";
    await fetch(base+"/api/sessions/session-end",{
      method:"POST",
      headers:{"content-type":"application/json"},
      body:JSON.stringify({contentSessionId:a.session.id,cwd:a.session.header&&a.session.header.cwd,reason:"agent disposed"})
    })
  }catch(e){}
})}`

function main() {
  const target = process.argv[2]
    || '/root/.npm-global/lib/node_modules/claude-mem/dsh/lib/index.js'

  if (!fs.existsSync(target)) {
    console.log(`[adapter-patch] adapter not found at ${target}; nothing to do`)
    return 0
  }
  const src = fs.readFileSync(target, 'utf8')
  if (src.includes(MARKER)) {
    console.log('[adapter-patch] session-end handler already present')
    return 0
  }
  if (!src.includes(NEEDLE)) {
    console.log('[adapter-patch] hook site not found; adapter version changed, leaving file untouched')
    return 0
  }
  fs.writeFileSync(path.resolve(target), src.replace(NEEDLE, HANDLER))
  console.log('[adapter-patch] added agent/disposed session-end handler')
  return 0
}

process.exit(main())
