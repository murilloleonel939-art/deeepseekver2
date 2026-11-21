#!/usr/bin/env node
/**
 * Make claude-mem's DSH adapter register, refresh and close sessions.
 *
 * claude-mem only injects memory from sessions it considers closed: it lists
 * `sdk_sessions` rows with `status = 'completed'`, and a row only reaches that
 * state when the worker finalizes the session. The DSH adapter has three gaps:
 *
 * 1. It defines `sessionInit` but never calls it, so no session row is created
 *    for a real DSH chat and observations land in a fallback session.
 * 2. It never closes a session, so nothing ever becomes recallable.
 * 3. `agent/disposed` only fires when the agent is released, which may never
 *    happen if a chat is simply left open. Waiting for it means memory may
 *    never be written.
 *
 * This script replaces the adapter's hook-registration function with one that
 * covers all three:
 *
 *   agent/created        POST /api/sessions/init
 *   agent/turn-stopping  restart a per-session inactivity timer
 *   <timer expires>      POST /api/sessions/summarize (when enabled)
 *                        POST /api/sessions/session-end
 *   agent/disposed       flush immediately instead of waiting
 *
 * The inactivity window defaults to 30 minutes and is set by
 * CLAUDE_MEM_INACTIVITY_MS. Timers are kept on `globalThis` so they survive the
 * plugin object being re-created, and are `unref`ed so they never hold the
 * process open.
 *
 * Idempotent: a file carrying the marker is left untouched. Fails soft: if a
 * future claude-mem changes the function shape, it reports that and leaves the
 * file alone rather than corrupting a running adapter.
 *
 * Usage:
 *   node patch-claude-mem-adapter.js [path-to-adapter-index.js]
 */

'use strict'

const fs = require('node:fs')
const path = require('node:path')

const DEFAULT_TARGET = '/root/.npm-global/lib/node_modules/claude-mem/dsh/lib/index.js'
const MARKER = 'dsh-session-lifecycle'
const WORKER = 'process.env.CLAUDE_MEM_WORKER_URL||"http://127.0.0.1:37700"'
const INACTIVITY = 'process.env.CLAUDE_MEM_INACTIVITY_MS||1800000'

/** The adapter's own hook-registration function, as shipped in 16.0.2. */
const ORIGINAL = [
  'function vn(e,t,r){e.on("agent/created",async n=>{let{agent:o}=n;',
  'r.injectContext&&await ms(t,o,r)}),r.ingest&&e.on("tools/post-execute",',
  '(n,o,i)=>(gs(t,n,o,r),i())),r.summarize&&e.on("agent/turn-stopping",',
  'n=>{ys(t,n.agent,r)})}',
].join('')

/**
 * The replacement. Written as one expression so it stays a drop-in for the
 * original function, with no new imports required.
 *
 * `mt(t,a,r)` closes a session: summarise when enabled, then session-end.
 * `wd(t,a,r)` restarts that session's inactivity timer.
 */
const PATCHED = [
  'function vn(e,t,r){',
  // --- helpers, defined once per call (cheap) ---
  'const MT=globalThis.__cmTimers=globalThis.__cmTimers||new Map();',
  'async function mt(c,a,cfg){try{',
  `const base=${WORKER};`,
  'if(cfg.summarize)await ys(c,a,cfg);',
  'await fetch(base+"/api/sessions/session-end",{method:"POST",',
  'headers:{"content-type":"application/json"},',
  'body:JSON.stringify({contentSessionId:a.session.id,',
  'cwd:a.session.header&&a.session.header.cwd,reason:"session lifecycle"})})',
  '}catch(_){}}',
  'function wd(c,a,cfg){try{',
  'const sid=a.session.id;',
  'const prev=MT.get(sid);if(prev)clearTimeout(prev);',
  `const h=setTimeout(()=>{MT.delete(sid);mt(c,a,cfg)},Number(${INACTIVITY}));`,
  'if(h&&h.unref)h.unref();',
  'MT.set(sid,h);',
  '}catch(_){}}',
  // --- hooks ---
  // Sessions register on the first pre-step, not on creation, because that is
  // the only point where the user's actual text is available. Registering
  // earlier would have to invent a prompt, and claude-mem stores whatever it
  // is given: a placeholder produced summaries about the placeholder.
  'const TX=globalThis.__cmInited=globalThis.__cmInited||new Set();',
  'function tx(m){try{if(!m)return"";if(typeof m==="string")return m;',
  'if(typeof m.text==="string")return m.text;',
  'if(typeof m.content==="string")return m.content;',
  'const c=m.content||m.blocks||m.parts;if(Array.isArray(c))return c.map(x=>',
  'typeof x==="string"?x:(x&&typeof x.text==="string"?x.text:"")).join(" ");',
  'return""}catch(_){return""}}',
  'e.on("agent/created",async n=>{let{agent:o}=n;',
  'r.injectContext&&await ms(t,o,r)}),',
  'e.on("agent/pre-step",(n,next)=>{try{',
  'const a=n&&n.agent;if(a&&a.session&&!TX.has(a.session.id)){',
  'const msgs=Array.isArray(n.messages)?n.messages:[];',
  'let txt="";for(const m of msgs){const v=tx(m);',
  'if(v&&v.trim())txt=v.trim()}',
  'if(txt){TX.add(a.session.id);',
  `const b=${WORKER};`,
  'fetch(b+"/api/sessions/init",{method:"POST",',
  'headers:{"content-type":"application/json"},',
  'body:JSON.stringify({contentSessionId:a.session.id,',
  'project:typeof r.project==="string"&&r.project.trim()?r.project:undefined,',
  'cwd:a.session.header&&a.session.header.cwd,prompt:txt.slice(0,4000)})})',
  '.catch(()=>{})}',
  'wd(t,a,r)}}catch(_){}return next()}),',
  'r.ingest&&e.on("tools/post-execute",(n,o,i)=>(gs(t,n,o,r),i())),',
  'r.summarize&&e.on("agent/turn-stopping",n=>{ys(t,n.agent,r)}),',
  'e.on("agent/turn-stopping",n=>{try{',
  'const a=n&&n.agent;if(a&&a.session)wd(t,a,r)}catch(_){}}),',
  'e.on("agent/disposed",async n=>{try{',
  'const a=n&&n.agent;if(!a||!a.session)return;',
  'const sid=a.session.id;const p=MT.get(sid);',
  'if(p){clearTimeout(p);MT.delete(sid)}',
  'await mt(t,a,r)',
  '}catch(_){}})',
  `}/*${MARKER}*/`,
].join('')

function patchFile(target) {
  if (!fs.existsSync(target)) {
    console.log(`[adapter-patch] adapter not found at ${target}; nothing to do`)
    return 0
  }
  let src = fs.readFileSync(target, 'utf8')

  if (src.includes(MARKER)) {
    console.log('[adapter-patch] session lifecycle already patched')
    return 0
  }

  // A newer claude-mem may have already replaced the function; fall back to the
  // narrower per-hook edits if the whole-function shape is not recognised.
  if (!src.includes(ORIGINAL)) {
    console.log('[adapter-patch] hook-registration function shape not recognised;')
    console.log('[adapter-patch] leaving the adapter untouched so the boot cannot break')
    return 0
  }

  const tmp = `${target}.tmp`
  fs.writeFileSync(tmp, src.replace(ORIGINAL, PATCHED))
  fs.renameSync(tmp, path.resolve(target))
  console.log('[adapter-patch] session lifecycle installed')
  console.log('[adapter-patch]   init on first pre-step, with the real prompt')
  console.log('[adapter-patch]   inactivity close (default 30 min) on agent/turn-stopping')
  console.log('[adapter-patch]   immediate close on agent/disposed')
  return 0
}

process.exit(patchFile(process.argv[2] || DEFAULT_TARGET))
