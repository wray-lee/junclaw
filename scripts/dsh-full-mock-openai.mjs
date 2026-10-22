// Scripted OpenAI-compatible streaming server. No real model, no keys.
import http from 'node:http'
import fs from 'node:fs'

const PORT = Number(process.env.MOCK_PORT || 18081)
const LOG = process.env.MOCK_LOG || '/tmp/mock.log'
const log = (obj) => fs.appendFileSync(LOG, JSON.stringify({ t: Date.now(), ...obj }) + '\n')

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function chunk(delta, finish = null) {
  return {
    id: 'chatcmpl-mock',
    object: 'chat.completion.chunk',
    created: Math.floor(Date.now() / 1000),
    model: 'mock-model',
    choices: [{ index: 0, delta, finish_reason: finish }],
  }
}

function send(res, obj) {
  res.write('data: ' + JSON.stringify(obj) + '\n\n')
}

async function streamTurn(req, res, body) {
  res.writeHead(200, {
    'content-type': 'text/event-stream',
    'cache-control': 'no-cache',
    connection: 'keep-alive',
  })
  let closed = false
  res.on('close', () => { closed = true })

  const msgs = Array.isArray(body.messages) ? body.messages : []
  const last = msgs[msgs.length - 1]
  const lastRole = last && last.role
  const lastUser = [...msgs].reverse().find((m) => m.role === 'user')
  const lastUserText = lastUser ? JSON.stringify(lastUser.content) : ''
  const hasToolResult = msgs.some((m) => m.role === 'tool')
  const slow = lastUserText.includes('SLOW')

  send(res, chunk({ role: 'assistant' }))

  if (slow) {
    for (let i = 0; i < 200 && !closed; i++) {
      send(res, chunk({ content: `slow-${i} ` }))
      await sleep(50)
    }
    if (!closed) {
      send(res, chunk({}, 'stop'))
      res.write('data: [DONE]\n\n')
      res.end()
    }
    log({ kind: 'slow', closed })
    return
  }

  if (lastRole === 'tool' && JSON.stringify(last.content ?? '').includes('sandbox: escalation available') && !JSON.stringify(msgs).includes('call_mock_2')) {
    const args = JSON.stringify({ command: process.env.MOCK_TOOL_CMD || 'touch /root/outside-workspace.txt', description: 'mock escalation', sandbox_permissions: 'danger-full-access', justification: 'probe approval for an out-of-workspace write' })
    const half = Math.floor(args.length / 2)
    send(res, chunk({ tool_calls: [{ index: 0, id: 'call_mock_2', type: 'function', function: { name: 'bash', arguments: args.slice(0, half) } }] }))
    await sleep(30)
    send(res, chunk({ tool_calls: [{ index: 0, function: { arguments: args.slice(half) } }] }))
    await sleep(30)
    send(res, chunk({}, 'tool_calls'))
    res.write('data: [DONE]\n\n')
    res.end()
    log({ kind: 'escalation_call', msgCount: msgs.length })
    return
  }

  if (lastRole === 'user' && (!hasToolResult || msgs.some((m) => m.role === 'user' && JSON.stringify(m.content).includes('TOOL')))) {
    // First request: stream a bash tool call.
    const args = JSON.stringify({ command: process.env.MOCK_TOOL_CMD || 'echo hello-from-tool', description: 'mock tool' })
    const half = Math.floor(args.length / 2)
    const parts = [args.slice(0, half), args.slice(half)]
    send(res, chunk({ tool_calls: [{ index: 0, id: 'call_mock_1', type: 'function', function: { name: 'bash', arguments: parts[0] } }] }))
    await sleep(30)
    send(res, chunk({ tool_calls: [{ index: 0, function: { arguments: parts[1] } }] }))
    await sleep(30)
    send(res, chunk({}, 'tool_calls'))
    res.write('data: [DONE]\n\n')
    res.end()
    log({ kind: 'tool_call', lastRole, hasToolResult, msgCount: msgs.length, lastUserText: lastUserText.slice(0, 120) })
    return
  }

  // Later turns: plain text.
  for (const piece of ['Final answer: ', 'tool completed, ', 'all good.']) {
    send(res, chunk({ content: piece }))
    await sleep(20)
  }
  send(res, chunk({}, 'stop'))
  send(res, { choices: [], usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } })
  res.write('data: [DONE]\n\n')
  res.end()
  log({ kind: 'text', lastRole, hasToolResult, msgCount: msgs.length, lastUserText: lastUserText.slice(0, 120) })
}

const server = http.createServer((req, res) => {
  const chunks = []
  req.on('data', (c) => chunks.push(c))
  req.on('end', async () => {
    const raw = Buffer.concat(chunks).toString('utf8')
    const url = req.url || ''
    let body = {}
    try { body = raw ? JSON.parse(raw) : {} } catch { /* log parse failure below */ }
    const msgs = Array.isArray(body.messages) ? body.messages : []
    const lastUser = [...msgs].reverse().find((m) => m.role === 'user')
    log({ kind: 'http', method: req.method, url, bodyBytes: raw.length, parsed: raw.length > 0 && Object.keys(body).length > 0, model: body.model, msgCount: msgs.length, msgRoles: msgs.map((m) => m.role), lastUserText: lastUser ? JSON.stringify(lastUser.content).slice(0, 160) : undefined })
    if (req.method === 'GET' && /\/models(\?|$)/.test(url)) {
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ object: 'list', data: [{ id: 'mock-model', object: 'model', owned_by: 'mock' }] }))
      return
    }
    if (req.method === 'POST' && /(\/v1)?\/chat\/completions$/.test(url)) {
      try {
        await streamTurn(req, res, body)
      } catch (err) {
        log({ kind: 'error', message: String(err) })
        if (!res.headersSent) res.writeHead(500, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ error: { message: String(err) } }))
      }
      return
    }
    log({ kind: 'unhandled', method: req.method, url })
    res.writeHead(404, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ error: { message: 'not found' } }))
  })
})

server.listen(PORT, '127.0.0.1', () => {
  log({ kind: 'listen', port: PORT, pid: process.pid })
  console.log('mock listening on ' + PORT)
})
