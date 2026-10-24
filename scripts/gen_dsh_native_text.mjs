#!/usr/bin/env node
// Generate Zig constants for dsh model-visible text (design §3.5, B15, B25b,
// B26, B27, B30, B31).
//
// Usage:
//   node scripts/gen_dsh_native_text.mjs \
//     --dsh-root /root/jsplug-proto/dsh \
//     --out src/harness/dsh_native/generated
//   node scripts/gen_dsh_native_text.mjs ... --check
//
// --dsh-root defaults to a POSIX path; on Windows pass it explicitly (the
// default would resolve under the current drive's root and fail loudly).
//
// Extraction is anchored to 1-based inclusive line ranges in the dsh checkout.
// Every generated string records its dsh-relative POSIX source path, line
// range, the LF-normalized whole-file SHA-256 at generation time
// (SOURCE_SHA256), and the SHA-256 of the extracted content (CONTENT_SHA256).
// CRLF is normalized before parsing and hashing, so a Windows checkout checks
// identically to a Linux one. Moving or changing any anchored source line
// changes the generated output, so --check fails instead of drifting.
//
// Conditional model-visible text is generated for the base dsh bundle defaults:
// packages/bundle/base/cordis.patch.yml sets sampleOverCapGlobResults=false;
// tool-bash defaults enableRunInBackground/promoteOnTimeout=true; no sandbox
// escalation modes are advertised without a confining backend.
//
// If the source checkout is unavailable, run this against the mirror image
// junclaw:full-dsh-test's /opt/dsh/node_modules instead (same relative paths).

import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'

const SYS = 'packages/core/system-prompt/src/index.ts'
const READ = 'packages/fs/tool-fs/src/read.ts'
const WRITE = 'packages/fs/tool-fs/src/write.ts'
const EDIT = 'packages/fs/tool-fs/src/edit.ts'
const READ_RENDER = 'packages/fs/tool-fs/src/read-render.ts'
const FS_ERROR = 'packages/fs/tool-fs/src/error.ts'
const BASH = 'packages/shell/tool-bash/src/index.ts'
const BASH_RENDER = 'packages/shell/tool-bash/src/render.ts'
const GREP = 'packages/fs/tool-fs-search/src/grep.ts'
const GLOB = 'packages/fs/tool-fs-search/src/glob.ts'
const SPILL_LOCAL = 'packages/spill/spill-local/src/index.ts'
const GOAL_TOOL = 'packages/goal/tool-goal/src/index.ts'
const GOAL_ROUND_PROMPT = 'packages/goal/goal-round-driver/src/prompt.ts'
const GOAL_WRAPUP = 'packages/goal/tool-goal/src/wrapup.ts'
const SUMMARIZER = 'packages/compaction/compaction-basic/src/summarizer.ts'
const PRUNER_CONFIG = 'packages/compaction/compaction-tool-result-pruner/src/config.ts'
const USER_APPROVAL = 'packages/interaction/user-approval/src/index.ts'
const CORE_TOOLS = 'packages/core/tools/src/index.ts'
const TOOL_ASK_USER = 'packages/interaction/tool-ask-user/src/index.ts'

// Files whose semantics or defaults shape the generated text without yielding a
// string constant of their own. Their hashes still gate --check.
const SUPPORTING_SOURCES = [
  ['packages/core/tools/src/schema.ts', 'parameter DSL to JSON Schema compiler semantics'],
  ['packages/core/tools/src/presentation.ts', 'tool presentation vocabulary'],
  ['packages/bundle/base/cordis.patch.yml', 'deployment defaults for conditional text'],
  ['packages/subprocess/subprocess/src/types.ts', 'DSH_ENV_PREFIX used by the bash description'],
]

function parseArgs(argv) {
  const args = { check: false }
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === '--check') {
      args.check = true
    } else if (arg === '--dsh-root' || arg === '--out') {
      const value = argv[++i]
      if (value === undefined) throw new Error(`${arg} needs a value`)
      args[arg.slice(2)] = value
    } else if (arg.startsWith('--dsh-root=') || arg.startsWith('--out=')) {
      const [key, ...rest] = arg.slice(2).split('=')
      args[key] = rest.join('=')
    } else {
      throw new Error(`unknown argument: ${arg}`)
    }
  }
  return args
}

function sha256hex(data) {
  return crypto.createHash('sha256').update(data).digest('hex')
}

// A literal entry: extract every string literal in the inclusive line range and
// concatenate them, or pick one by index. `subs` maps template expressions
// (without `${}`) to their generated value.
function E(id, file, start, end, opts = {}) {
  return { id, file, start, end, ...opts }
}

// Entry whose value is composed from several anchored literals; the recorded
// range covers every contributing line and CONTENT_SHA256 hashes the result.
function C(id, file, start, end, value) {
  const source = readSource(file)
  return { id, file, start, end, value, source_sha256: source.sha, content_sha256: sha256hex(Buffer.from(value, 'utf8')) }
}

function zigLiteral(value) {
  let out = '"'
  for (const ch of value) {
    const cp = ch.codePointAt(0)
    if (ch === '\\') out += '\\\\'
    else if (ch === '"') out += '\\"'
    else if (ch === '\n') out += '\\n'
    else if (ch === '\r') out += '\\r'
    else if (ch === '\t') out += '\\t'
    else if (cp < 0x20 || cp === 0x7f) out += '\\x' + cp.toString(16).padStart(2, '0')
    else out += ch
  }
  return out + '"'
}

const sources = new Map()

function readSource(rel) {
  if (!sources.has(rel)) {
    // path.join keeps the checkout path native; the dsh-relative key stays
    // POSIX because it is also the generated provenance identifier.
    const abs = path.join(dshRoot, rel)
    let buf
    try {
      buf = fs.readFileSync(abs)
    } catch (error) {
      throw new Error(`cannot read dsh source ${abs}: ${error.message}`)
    }
    // Normalize CRLF so a Windows (autocrlf) checkout parses and hashes like
    // the LF checkout the generated files were recorded from.
    const text = buf.toString('utf8').replaceAll('\r\n', '\n')
    sources.set(rel, {
      lines: text.split('\n'),
      sha: sha256hex(text),
    })
  }
  return sources.get(rel)
}

function skipQuoted(text, start, where) {
  const quote = text[start]
  let i = start + 1
  while (i < text.length) {
    if (text[i] === '\\') {
      i += 2
      continue
    }
    if (text[i] === quote) return i + 1
    if (quote === '`' && text[i] === '$' && text[i + 1] === '{') {
      i = findMatchingBrace(text, i + 1, where) + 1
      continue
    }
    i++
  }
  throw new Error(`${where}: unterminated quoted text`)
}

function findMatchingBrace(text, openIndex, where) {
  let depth = 0
  let i = openIndex
  while (i < text.length) {
    const ch = text[i]
    if (ch === "'" || ch === '"' || ch === '`') {
      i = skipQuoted(text, i, where)
      continue
    }
    if (ch === '{') depth++
    else if (ch === '}') {
      depth--
      if (depth === 0) return i
    }
    i++
  }
  throw new Error(`${where}: unterminated interpolation`)
}

function parseLiteral(text, start, subs, where) {
  const quote = text[start]
  let out = ''
  let i = start + 1
  while (i < text.length) {
    const ch = text[i]
    if (ch === '\\') {
      const esc = text[i + 1]
      if (esc === undefined) throw new Error(`${where}: dangling escape`)
      if (esc === '\n') {
        i += 2
        continue
      }
      if (esc === 'n') out += '\n'
      else if (esc === 'r') out += '\r'
      else if (esc === 't') out += '\t'
      else if (esc === 'b') out += '\b'
      else if (esc === 'f') out += '\f'
      else if (esc === 'v') out += '\v'
      else if (esc === '0') out += '\0'
      else if (esc === '\\' || esc === "'" || esc === '"' || esc === '`' || esc === '$') out += esc
      else if (esc === 'x') {
        const hex = text.slice(i + 2, i + 4)
        if (!/^[0-9a-fA-F]{2}$/.test(hex)) throw new Error(`${where}: bad \\x escape`)
        out += String.fromCodePoint(parseInt(hex, 16))
        i += 4
        continue
      } else if (esc === 'u') {
        if (text[i + 2] === '{') {
          const close = text.indexOf('}', i + 3)
          if (close === -1) throw new Error(`${where}: bad \\u{} escape`)
          out += String.fromCodePoint(parseInt(text.slice(i + 3, close), 16))
          i = close + 1
          continue
        }
        const hex = text.slice(i + 2, i + 6)
        if (!/^[0-9a-fA-F]{4}$/.test(hex)) throw new Error(`${where}: bad \\u escape`)
        out += String.fromCodePoint(parseInt(hex, 16))
        i += 6
        continue
      } else {
        throw new Error(`${where}: unsupported escape \\${esc}`)
      }
      i += 2
      continue
    }
    if (quote === '`' && ch === '$' && text[i + 1] === '{') {
      const close = findMatchingBrace(text, i + 1, where)
      const expr = text.slice(i + 2, close).trim()
      if (!Object.hasOwn(subs, expr)) throw new Error(`${where}: no substitution for \${${expr}}`)
      out += subs[expr]
      i = close + 1
      continue
    }
    if (ch === quote) return { value: out, next: i + 1 }
    out += ch
    i++
  }
  throw new Error(`${where}: unterminated ${quote} literal`)
}

function scanLiterals(text, subs, where) {
  const out = []
  let i = 0
  while (i < text.length) {
    const ch = text[i]
    if (ch === '/' && text[i + 1] === '/') {
      const nl = text.indexOf('\n', i)
      i = nl === -1 ? text.length : nl + 1
      continue
    }
    if (ch === '/' && text[i + 1] === '*') {
      const close = text.indexOf('*/', i + 2)
      if (close === -1) throw new Error(`${where}: unterminated comment`)
      i = close + 2
      continue
    }
    if (ch === "'" || ch === '"' || ch === '`') {
      const parsed = parseLiteral(text, i, subs, where)
      out.push(parsed.value)
      i = parsed.next
      continue
    }
    i++
  }
  return out
}

function extract(entry) {
  if (entry.value !== undefined) return entry
  const source = readSource(entry.file)
  if (!Number.isInteger(entry.start) || !Number.isInteger(entry.end)
    || entry.start < 1 || entry.end < entry.start || entry.end > source.lines.length) {
    throw new Error(`${entry.file}:${entry.start}-${entry.end}: line range out of bounds`)
  }
  const where = `${entry.file}:${entry.start}-${entry.end} (${entry.id})`
  const text = source.lines.slice(entry.start - 1, entry.end).join('\n')
  const literals = scanLiterals(text, entry.subs ?? {}, where)
  if (literals.length === 0) throw new Error(`${where}: no string literal found`)
  let picked = literals
  if (Array.isArray(entry.pick)) {
    picked = entry.pick.map((index) => {
      if (literals[index] === undefined) throw new Error(`${where}: pick ${index} out of range (${literals.length})`)
      return literals[index]
    })
  } else if (entry.pick !== undefined) {
    picked = [literals[entry.pick]]
    if (picked[0] === undefined) throw new Error(`${where}: pick ${entry.pick} out of range (${literals.length})`)
  }
  const value = picked.join(entry.join ?? '')
  return {
    id: entry.id,
    file: entry.file,
    start: entry.start,
    end: entry.end,
    value,
    source_sha256: source.sha,
    content_sha256: sha256hex(Buffer.from(value, 'utf8')),
  }
}

// Extract one integer option from an object literal. The manifest hashes the
// decimal digits; generated Zig constants carry them as u32.
function extractNumber(entry) {
  const source = readSource(entry.file)
  if (!Number.isInteger(entry.start) || !Number.isInteger(entry.end)
    || entry.start < 1 || entry.end < entry.start || entry.end > source.lines.length) {
    throw new Error(`${entry.file}:${entry.start}-${entry.end}: line range out of bounds`)
  }
  const where = `${entry.file}:${entry.start}-${entry.end} (${entry.id})`
  const pattern = new RegExp(`^\\s*${entry.key}:\\s*(\\d+),?\\s*$`)
  for (let line = entry.start; line <= entry.end; line++) {
    const match = source.lines[line - 1].match(pattern)
    if (match === null) continue
    const value = match[1]
    return {
      id: entry.id,
      file: entry.file,
      start: line,
      end: line,
      value,
      source_sha256: source.sha,
      content_sha256: sha256hex(Buffer.from(value, 'utf8')),
    }
  }
  throw new Error(`${where}: no numeric literal for ${entry.key}`)
}

function header(concern, refs = 'B15, B25b') {
  return [
    '//! Generated by scripts/gen_dsh_native_text.mjs from the dsh checkout.',
    '//! Do not edit by hand: run the generator; `--check` rejects drift.',
    `//! Concern: ${concern} (design §3.5, ${refs}).`,
    '//! Source paths are dsh-relative POSIX identifiers (provenance only); the',
    '//! model-facing strings keep dsh\'s LF newlines on every platform.',
    '',
  ].join('\n')
}

const records = []

function record(ext, expr) {
  records.push({
    id: ext.id,
    path: ext.file,
    line_start: ext.start,
    line_end: ext.end,
    source_sha256: ext.source_sha256,
    content_sha256: ext.content_sha256,
    expr,
  })
}

function moduleConst(module, name, ext) {
  record(ext, `${module}.${name}`)
  return `pub const ${name} = ${zigLiteral(ext.value)};\n`
}

function structConst(module, structName, name, ext) {
  record(ext, `${module}.${structName}.${name}`)
  return `    pub const ${name} = ${zigLiteral(ext.value)};\n`
}

// Numeric constants have no Zig string constant to point the manifest at, so
// the root Source.content is the decimal literal itself.
function numberConst(name, ext) {
  record(ext, zigLiteral(ext.value))
  return `    pub const ${name}: u32 = ${ext.value};\n`
}

// ---------------------------------------------------------------------------
// Manifest

const sysEntries = [
  E('identity_text', SYS, 453, 453),
  E('persona_prefix_section', SYS, 190, 190),
  E('persona_suffix_section', SYS, 193, 193),
  E('persona_prefix_default', SYS, 460, 460),
  E('persona_suffix_default', SYS, 465, 465),
  E('tool_order_rest', SYS, 202, 202),
  E('read_prompt', READ, 74, 74),
  E('write_prompt', WRITE, 68, 70, { pick: [0, 2, 3, 4] }),
  E('edit_prompt', EDIT, 82, 82),
  E('glob_prompt', GLOB, 302, 302),
  E('grep_prompt', GREP, 280, 281, { pick: [0, 3] }),
  E('bash_prompt', BASH, 254, 254),
]

const tools = [
  {
    module: 'read',
    file: READ,
    name: E('read.name', READ, 78, 78),
    description: E('read.description', READ, 79, 79),
    schemaRange: [81, 83],
    params: [
      { name: 'file_path', type: 'string', required: true, desc: E('read.file_path.description', READ, 81, 81, { pick: [1] }) },
      { name: 'offset', type: 'number', required: false, desc: E('read.offset.description', READ, 82, 82, { pick: [1] }) },
      { name: 'limit', type: 'number', required: false, desc: E('read.limit.description', READ, 83, 83, { pick: [1], subs: { 'caps.limit': '2000' } }) },
    ],
  },
  {
    module: 'write',
    file: WRITE,
    name: E('write.name', WRITE, 74, 74),
    description: E('write.description', WRITE, 75, 75),
    schemaRange: [79, 82],
    params: [
      { name: 'file_path', type: 'string', required: true, desc: E('write.file_path.description', WRITE, 79, 80, { pick: [0, 1] }) },
      { name: 'content', type: 'string', required: true, desc: E('write.content.description', WRITE, 82, 82, { pick: [1] }) },
    ],
  },
  {
    module: 'edit',
    file: EDIT,
    name: E('edit.name', EDIT, 86, 86),
    description: E('edit.description', EDIT, 87, 87),
    schemaRange: [90, 96],
    params: [
      { name: 'file_path', type: 'string', required: true, desc: E('edit.file_path.description', EDIT, 90, 92, { pick: [1, 2] }) },
      { name: 'old_string', type: 'string', required: true, desc: E('edit.old_string.description', EDIT, 94, 94, { pick: [1] }) },
      { name: 'new_string', type: 'string', required: true, desc: E('edit.new_string.description', EDIT, 95, 95, { pick: [1] }) },
      { name: 'replace_all', type: 'boolean', required: false, desc: E('edit.replace_all.description', EDIT, 96, 96, { pick: [1] }) },
    ],
  },
  {
    module: 'bash',
    file: BASH,
    name: E('bash.name', BASH, 369, 369),
    description: E('bash.description', BASH, 91, 98, { subs: { DSH_ENV_PREFIX: 'DSH_' } }),
    schemaRange: [375, 388],
    params: [
      { name: 'description', type: 'string', required: true, desc: E('bash.description_param.description', BASH, 375, 377, { pick: [0, 1, 2] }) },
      { name: 'command', type: 'string', required: true, desc: E('bash.command.description', BASH, 379, 379, { pick: [1] }) },
      { name: 'timeoutMs', type: 'number', required: false, desc: E('bash.timeoutMs.description', BASH, 383, 383) },
      { name: 'workdir', type: 'string', required: false, desc: E('bash.workdir.description', BASH, 386, 386, { pick: [1] }) },
      { name: 'run_in_background', type: 'boolean', required: false, desc: E('bash.run_in_background.description', BASH, 388, 388, { pick: [1] }) },
    ],
  },
  {
    module: 'grep',
    file: GREP,
    name: E('grep.name', GREP, 285, 285),
    description: E('grep.description', GREP, 286, 287, { subs: { 'caps.maxMatches': '250' } }),
    schemaRange: [289, 291],
    params: [
      { name: 'pattern', type: 'string', required: true, desc: E('grep.pattern.description', GREP, 289, 289, { pick: [1] }) },
      { name: 'path', type: 'string', required: false, desc: E('grep.path.description', GREP, 290, 290, { pick: [1] }) },
      { name: 'include', type: 'string', required: false, desc: E('grep.include.description', GREP, 291, 291, { pick: [1] }) },
    ],
  },
  {
    module: 'glob',
    file: GLOB,
    name: E('glob.name', GLOB, 307, 307),
    description: E('glob.description', GLOB, 308, 310, {
      subs: { 'caps.maxResults': '100', overCapDescription: 'keeps the first paths' },
    }),
    schemaRange: [315, 318],
    params: [
      { name: 'pattern', type: 'string', required: true, desc: E('glob.pattern.description', GLOB, 315, 316, { pick: [0, 1] }) },
      { name: 'path', type: 'string', required: false, desc: E('glob.path.description', GLOB, 318, 318, { pick: [1] }) },
    ],
  },
  {
    module: 'get_goal',
    file: GOAL_TOOL,
    name: E('get_goal.name', GOAL_TOOL, 196, 196),
    description: E('get_goal.description', GOAL_TOOL, 56, 56),
    schemaRange: [198, 198],
    params: [],
  },
  {
    module: 'create_goal',
    file: GOAL_TOOL,
    name: E('create_goal.name', GOAL_TOOL, 208, 208),
    description: E('create_goal.description', GOAL_TOOL, 51, 54),
    schemaRange: [210, 220],
    params: [
      { name: 'objective', type: 'string', required: true, desc: E('create_goal.objective.description', GOAL_TOOL, 211, 214, { pick: [1] }) },
      { name: 'max_goal_rounds', type: 'number', required: false, desc: E('create_goal.max_goal_rounds.description', GOAL_TOOL, 216, 219, { pick: [1] }) },
    ],
  },
  {
    module: 'update_goal',
    file: GOAL_TOOL,
    name: E('update_goal.name', GOAL_TOOL, 235, 235),
    description: E('update_goal.description', GOAL_TOOL, 236, 236),
    schemaRange: [237, 253],
    params: [
      { name: 'goal_id', type: 'string', required: true, desc: E('update_goal.goal_id.description', GOAL_TOOL, 238, 238, { pick: [1] }) },
      { name: 'revision', type: 'number', required: true, desc: E('update_goal.revision.description', GOAL_TOOL, 239, 239, { pick: [1] }) },
      {
        name: 'action',
        type: 'string',
        required: true,
        enum: ['edit', 'pause', 'resume', 'complete', 'blocked'],
        desc: E('update_goal.action.description', GOAL_TOOL, 240, 246, { pick: [1, 2] }),
      },
      { name: 'objective', type: 'string', required: false, desc: E('update_goal.objective.description', GOAL_TOOL, 247, 247, { pick: [1] }) },
      { name: 'max_goal_rounds', type: 'number', required: false, desc: E('update_goal.max_goal_rounds.description', GOAL_TOOL, 248, 248, { pick: [1] }) },
      { name: 'blocked_reason', type: 'string', required: false, desc: E('update_goal.blocked_reason.description', GOAL_TOOL, 249, 252, { pick: [1] }) },
    ],
  },
]

// Goal prompt/wrap-up text: <goal_round> is one template literal; wrap-up uses
// JS string concatenation, so its exact final text is composed from anchored
// pieces plus the shared heading and grounding constants.
function goalRenderEntries() {
  const heading = extract(E('goal.wrapup_heading', GOAL_WRAPUP, 18, 18, {
    subs: { 'JSON.stringify(objective)': '{s}' },
  })).value
  const grounding = extract(E('goal.wrapup_grounding', GOAL_WRAPUP, 5, 7)).value
  const complete = extract(E('goal.complete_open', GOAL_WRAPUP, 20, 20)).value
    + heading
    + extract(E('goal.complete_body', GOAL_WRAPUP, 22, 24)).value
    + grounding
    + extract(E('goal.complete_tail', GOAL_WRAPUP, 26, 27)).value
    + extract(E('goal.complete_close', GOAL_WRAPUP, 28, 28)).value
  const blocked = extract(E('goal.blocked_open', GOAL_WRAPUP, 29, 29)).value
    + heading
    + extract(E('goal.blocked_reason', GOAL_WRAPUP, 31, 31, {
      subs: { 'JSON.stringify(blockedReason)': '{s}' },
    })).value
    + extract(E('goal.blocked_body', GOAL_WRAPUP, 32, 35)).value
    + grounding
    + extract(E('goal.blocked_tail', GOAL_WRAPUP, 37, 38)).value
    + extract(E('goal.blocked_close', GOAL_WRAPUP, 39, 39)).value
  return [
    E('goal.round_prompt', GOAL_ROUND_PROMPT, 15, 24, {
      subs: { 'JSON.stringify(goal.objective)': '{s}', 'round': '{d}', 'goal.maxGoalRounds': '{d}' },
    }),
    C('goal.complete_wrapup', GOAL_WRAPUP, 18, 28, complete),
    C('goal.blocked_wrapup', GOAL_WRAPUP, 18, 39, blocked),
  ]
}

const renderGroups = [
  {
    name: 'read',
    consts: [
      E('read.line_truncated', READ_RENDER, 70, 70, {
        subs: { 'line.substring(0, maxLineLength)': '{s}', maxLineLength: '{d}' },
      }),
      E('read.out_of_range', READ_RENDER, 97, 97, {
        pick: [0], subs: { 'request.offset': '{d}', displayPath: '{s}', 'acc.totalLines': '{d}' },
      }),
      E('read.capped_footer', READ_RENDER, 156, 156, {
        subs: { 'outcome.offset': '{d}', endLine: '{d}', 'endLine + 1': '{d}' },
      }),
      E('read.showing_footer', READ_RENDER, 158, 158, {
        subs: {
          'outcome.offset': '{d}', endLine: '{d}', 'outcome.totalLines': '{d}', 'endLine + 1': '{d}',
        },
      }),
      E('read.eof_footer', READ_RENDER, 160, 160, { subs: { 'outcome.totalLines': '{d}' } }),
      E('read.envelope', READ_RENDER, 165, 169, { subs: { displayPath: '{s}', body: '{s}' } }),
      E('read.error_positive_integer', READ, 44, 44, { subs: { name: '{s}' } }),
      E('read.error_limit_max', READ, 59, 59, { subs: { maxLimit: '{d}' } }),
    ],
  },
  {
    name: 'write',
    consts: [
      E('write.created_verb', WRITE, 37, 37, { pick: 1 }),
      E('write.updated_verb', WRITE, 37, 37, { pick: 2 }),
      E('write.output_envelope', WRITE, 38, 42, { subs: { displayPath: '{s}', verb: '{s}' } }),
    ],
  },
  {
    name: 'edit',
    consts: [
      E('edit.success_all', EDIT, 67, 67, { subs: { displayPath: '{s}' } }),
      E('edit.success_single', EDIT, 68, 68, { subs: { displayPath: '{s}' } }),
      E('edit.error_empty_path', EDIT, 48, 48),
      E('edit.error_empty_old', EDIT, 49, 49),
      E('edit.error_equal', EDIT, 50, 50),
      E('edit.error_not_observed', FS_ERROR, 25, 25, { subs: { displayPath: '{s}' } }),
      E('edit.error_stale_suffix', FS_ERROR, 31, 31, { subs: { 'error.message': '{s}' } }),
    ],
  },
  {
    name: 'grep',
    consts: [
      E('grep.header_truncated', GREP, 217, 217, { subs: { 'retained.kept': '{d}', 'retained.seen': '{d}' } }),
      E('grep.header_found', GREP, 218, 218, { subs: { 'retained.seen': '{d}', 'matchNoun(retained.seen)': '{s}' } }),
      E('grep.match_singular', GREP, 181, 181, { pick: 0 }),
      E('grep.match_plural', GREP, 181, 181, { pick: 1 }),
      E('grep.recovery_saved', GREP, 222, 222, {
        subs: { 'spillRef.locator': '{s}', 'spillRef.retrievalHint': '{s}' },
      }),
      E('grep.recovery_unsaved', GREP, 223, 223),
      E('grep.no_matches', GREP, 229, 229),
    ],
  },
  {
    name: 'glob',
    consts: [
      E('glob.no_files', GLOB, 232, 232),
      E('glob.sampled_basis', GLOB, 216, 216, { subs: { 'sample.shown': '{d}', 'sample.total': '{d}' } }),
      E('glob.narrow_hint', GLOB, 217, 217, { pick: 0 }),
      E('glob.recovery_saved', GLOB, 225, 225, {
        subs: { 'spillRef.locator': '{s}', 'spillRef.retrievalHint': '{s}' },
      }),
      E('glob.recovery_unsaved', GLOB, 226, 226),
      E('glob.page', GLOB, 227, 227, {
        subs: { body: '{s}', 'items.length': '{d}', seen: '{d}', basis: '{s}', recovery: '{s}' },
      }),
    ],
  },
  {
    name: 'bash',
    consts: [
      E('bash.output_truncated', BASH_RENDER, 14, 14, {
        subs: { 'output.text': '{s}', "output.spillPath ?? '(unavailable)'": '{s}' },
      }),
      E('bash.stderr_section', BASH_RENDER, 39, 39, { subs: { err: '{s}' } }),
      E('bash.no_output', BASH_RENDER, 41, 41),
      E('bash.timed_out', BASH_RENDER, 53, 53, { subs: { 'result.timeoutMs': '{d}' } }),
      E('bash.stopped', BASH_RENDER, 56, 56, { subs: { 'result.stopped': '{s}' } }),
      E('bash.killed_by_signal', BASH_RENDER, 58, 58, { subs: { 'result.signal': '{s}' } }),
      E('bash.exit_code', BASH_RENDER, 60, 60, { subs: { 'result.exitCode': '{d}' } }),
      E('bash.promoted', BASH_RENDER, 81, 81, {
        subs: { body: '{s}', 'promoted.timeoutMs': '{d}', 'promoted.jobId': '{s}' },
      }),
      E('bash.promoted_hint', BASH_RENDER, 82, 83),
      E('bash.lossy_notice', BASH_RENDER, 108, 108, {
        subs: { "spillPaths.length > 0 ? spillPaths.join(', ') : '(unavailable)'": '{s}' },
      }),
      E('bash.sandbox_runner_failed', BASH_RENDER, 111, 111, { subs: { 'sandbox.mode': '{s}' } }),
    ],
  },
  {
    name: 'spill',
    consts: [
      E('spill.retrieval_hint', SPILL_LOCAL, 159, 159),
    ],
  },
  {
    name: 'goal',
    consts: goalRenderEntries,
  },
]

// Numeric pruner defaults are extracted from the DEFAULTS object literal.
const compactionNumberEntries = [
  { id: 'compaction.prune_threshold_chars', file: PRUNER_CONFIG, start: 10, end: 14, key: 'thresholdChars' },
  { id: 'compaction.prune_head_chars', file: PRUNER_CONFIG, start: 10, end: 14, key: 'headChars' },
  { id: 'compaction.prune_tail_chars', file: PRUNER_CONFIG, start: 10, end: 14, key: 'tailChars' },
]

// ---------------------------------------------------------------------------
// Generation

function sectionOrders() {
  const source = readSource(SYS)
  const out = []
  for (let line = 132; line <= 164; line++) {
    const match = source.lines[line - 1].match(/^\s*([A-Z][A-Z0-9_]*):\s*(-?\d+),/)
    if (match === null) continue
    out.push({ name: match[1], value: match[2], line, source_sha256: source.sha })
  }
  if (out.length === 0) throw new Error(`${SYS}: no section orders found`)
  return out
}

function buildInputSchema(tool) {
  const properties = {}
  const required = []
  for (const param of tool.params) {
    const ext = extract(param.desc)
    properties[param.name] = { type: param.type, description: ext.value }
    if (param.enum !== undefined) properties[param.name].enum = param.enum
    if (param.required) required.push(param.name)
  }
  const schema = { type: 'object', properties }
  if (required.length > 0) schema.required = required
  return JSON.stringify(schema)
}

function generateSystemPrompt() {
  let out = header('system prompt identity, deployment persona slots, section order, tool guidance')
  out += '\n'
  for (const entry of sysEntries) {
    out += moduleConst('system_prompt', entry.id, extract(entry))
  }
  const orders = sectionOrders()
  out += '\npub const section_orders = struct {\n'
  for (const order of orders) out += `    pub const ${order.name}: i32 = ${order.value};\n`
  out += '};\n\n'
  out += '// SOURCE_SHA256 and line ranges for the section-order numbers above.\n'
  out += 'pub const SectionOrderSource = struct {\n'
  out += '    name: []const u8,\n'
  out += '    line_start: u32,\n'
  out += '    line_end: u32,\n'
  out += '    /// SOURCE_SHA256: LF-normalized whole-file hash at generation time.\n'
  out += '    source_sha256: []const u8,\n'
  out += '};\n\n'
  out += 'pub const section_order_sources = [_]SectionOrderSource{\n'
  for (const order of orders) {
    out += `    .{ .name = ${zigLiteral(order.name)}, .line_start = ${order.line}, .line_end = ${order.line}, .source_sha256 = ${zigLiteral(order.source_sha256)} },\n`
  }
  out += '};\n'
  return out
}

function generateToolSchemas() {
  let out = header('tool name, description and inputSchema JSON for read/write/edit/bash/grep/glob')
  for (const tool of tools) {
    out += `\npub const ${tool.module} = struct {\n`
    out += structConst('tool_schemas', tool.module, 'name', extract(tool.name))
    out += structConst('tool_schemas', tool.module, 'description', extract(tool.description))
    const schema = buildInputSchema(tool)
    const source = readSource(tool.file)
    const schemaExt = {
      id: `${tool.module}.input_schema_json`,
      file: tool.file,
      start: tool.schemaRange[0],
      end: tool.schemaRange[1],
      value: schema,
      source_sha256: source.sha,
      content_sha256: sha256hex(Buffer.from(schema, 'utf8')),
    }
    out += structConst('tool_schemas', tool.module, 'input_schema_json', schemaExt)
    out += '};\n'
  }
  return out
}

function generateToolRender() {
  let out = header('tool result rendering templates and edit failure text')
  for (const group of renderGroups) {
    out += `\npub const ${group.name} = struct {\n`
    for (const entry of typeof group.consts === 'function' ? group.consts() : group.consts) {
      out += structConst('tool_render', group.name, entry.id.slice(group.name.length + 1), extract(entry))
    }
    out += '};\n'
  }
  return out
}

function generateCompaction() {
  let out = header('compaction summary instruction/framing and tool-result pruner defaults', 'B30, B31')
  out += '\n'
  const open = extract(E('compaction.summary_open_tag', SUMMARIZER, 22, 22))
  out += moduleConst('compaction', 'summary_open_tag', open)
  out += moduleConst('compaction', 'summary_close_tag', extract(E('compaction.summary_close_tag', SUMMARIZER, 23, 23)))
  out += moduleConst('compaction', 'instruction', extract(E('compaction.instruction', SUMMARIZER, 33, 66, {
    join: '\n',
    subs: { SUMMARY_OPEN_TAG: open.value },
  })))
  const preamble = extract(E('compaction.checkpoint_preamble', SUMMARIZER, 70, 71))
  out += moduleConst('compaction', 'checkpoint_preamble', preamble)
  out += '/// Replacement user message: replacement_prefix, then the summary, then summary_close_tag.\n'
  out += moduleConst('compaction', 'replacement_prefix', extract(E('compaction.replacement_prefix', SUMMARIZER, 190, 190, {
    pick: 1,
    subs: { CHECKPOINT_PREAMBLE: preamble.value, SUMMARY_OPEN_TAG: open.value },
  })))
  out += moduleConst('compaction', 'prune_marker', extract(E('compaction.prune_marker', PRUNER_CONFIG, 7, 7)))
  out += '\npub const prune_defaults = struct {\n'
  for (const entry of compactionNumberEntries) {
    out += numberConst(entry.id.slice('compaction.prune_'.length), extractNumber(entry))
  }
  out += '};\n'
  return out
}

// The legacy (default) ask_user_question parameter schema compiled by
// packages/core/tools/src/schema.ts. Descriptions are extracted from the tool
// declaration; the shape mirrors the author schema DSL.
function askUserDescription(line, pick = 0) {
  return extract(E('questions.schema_description', TOOL_ASK_USER, line, line, { pick })).value
}

function buildAskUserQuestionSchema() {
  return JSON.stringify({
    type: 'object',
    properties: {
      questions: {
        type: 'array',
        description: askUserDescription(45),
        items: {
          type: 'object',
          additionalProperties: true,
          properties: {
            id: { type: 'string', description: askUserDescription(50, 1) },
            question: { type: 'string', description: askUserDescription(51, 1) },
            header: { type: 'string', description: askUserDescription(54) },
            options: {
              type: 'array',
              description: askUserDescription(58),
              items: {
                type: 'object',
                additionalProperties: true,
                properties: {
                  label: { type: 'string', description: askUserDescription(63, 1) },
                  description: { type: 'string', description: askUserDescription(64, 1) },
                },
                required: ['label'],
              },
            },
            multi_select: { type: 'boolean', description: askUserDescription(70) },
          },
          required: ['id', 'question'],
        },
      },
    },
    required: ['questions'],
  })
}

function generateInteraction() {
  let out = header('approval policy text and ask_user_question tool schema', 'B26, B27')
  out += '\npub const approval = struct {\n'
  out += structConst('interaction', 'approval', 'never_sentence',
    extract(E('approval.never_sentence', USER_APPROVAL, 73, 73)))
  out += structConst('interaction', 'approval', 'ask_sentence',
    extract(E('approval.ask_sentence', USER_APPROVAL, 75, 75)))
  out += structConst('interaction', 'approval', 'policy_change_notice',
    extract(E('approval.policy_change_notice', USER_APPROVAL, 191, 191, {
      subs: { previous: '{s}', policy: '{s}' },
    })))
  const denials = [
    ['deny_no_service', 1742],
    ['deny_no_agent', 1748],
    ['deny_rejected', 1763],
    ['deny_cancelled', 1767],
    ['deny_no_channel', 1771],
  ]
  for (const [name, line] of denials) {
    out += structConst('interaction', 'approval', name,
      extract(E(`approval.${name}`, CORE_TOOLS, line, line, {
        pick: 1, subs: { 'exec.name': '{s}' },
      })))
  }
  out += '};\n'
  out += '\npub const ask_user_question = struct {\n'
  out += structConst('interaction', 'ask_user_question', 'name',
    extract(E('questions.name', TOOL_ASK_USER, 39, 39)))
  out += structConst('interaction', 'ask_user_question', 'description',
    extract(E('questions.description', TOOL_ASK_USER, 31, 31)))
  const schema = buildAskUserQuestionSchema()
  out += structConst('interaction', 'ask_user_question', 'input_schema_json', {
    id: 'questions.input_schema_json',
    file: TOOL_ASK_USER,
    start: 41,
    end: 75,
    value: schema,
    source_sha256: readSource(TOOL_ASK_USER).sha,
    content_sha256: sha256hex(Buffer.from(schema, 'utf8')),
  })
  out += '};\n'
  return out
}

function generateRoot() {
  let out = header('generated artifact manifest and content-hash self-check', 'B15, B25b, B26, B27, B30, B31')
  out += 'const std = @import("std");\n\n'
  out += 'pub const system_prompt = @import("system_prompt.zig");\n'
  out += 'pub const tool_schemas = @import("tool_schemas.zig");\n'
  out += 'pub const tool_render = @import("tool_render.zig");\n'
  out += 'pub const compaction = @import("compaction.zig");\n'
  out += 'pub const interaction = @import("interaction.zig");\n\n'
  out += 'pub const Source = struct {\n'
  out += '    id: []const u8,\n'
  out += '    path: []const u8,\n'
  out += '    line_start: u32,\n'
  out += '    line_end: u32,\n'
  out += '    /// SOURCE_SHA256: LF-normalized whole-file hash at generation time.\n'
  out += '    source_sha256: []const u8,\n'
  out += '    /// CONTENT_SHA256: hash of the extracted content.\n'
  out += '    content_sha256: []const u8,\n'
  out += '    content: []const u8,\n'
  out += '};\n\n'
  out += 'pub const sources = [_]Source{\n'
  for (const item of records) {
    out += `    .{ .id = ${zigLiteral(item.id)}, .path = ${zigLiteral(item.path)}, `
    out += `.line_start = ${item.line_start}, .line_end = ${item.line_end}, `
    out += `.source_sha256 = ${zigLiteral(item.source_sha256)}, `
    out += `.content_sha256 = ${zigLiteral(item.content_sha256)}, .content = ${item.expr} },\n`
  }
  out += '};\n\n'
  out += 'pub const SupportingSource = struct {\n'
  out += '    path: []const u8,\n'
  out += '    purpose: []const u8,\n'
  out += '    /// SOURCE_SHA256: LF-normalized whole-file hash at generation time.\n'
  out += '    source_sha256: []const u8,\n'
  out += '};\n\n'
  out += 'pub const supporting_sources = [_]SupportingSource{\n'
  for (const [rel, purpose] of SUPPORTING_SOURCES) {
    const source = readSource(rel)
    out += `    .{ .path = ${zigLiteral(rel)}, .purpose = ${zigLiteral(purpose)}, .source_sha256 = ${zigLiteral(source.sha)} },\n`
  }
  out += '};\n\n'
  out += 'test "generated content hashes match recorded values" {\n'
  out += '    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;\n'
  out += '    for (sources) |source| {\n'
  out += '        std.crypto.hash.sha2.Sha256.hash(source.content, &digest, .{});\n'
  out += '        const hex = std.fmt.bytesToHex(digest, .lower);\n'
  out += '        try std.testing.expectEqualStrings(source.content_sha256, &hex);\n'
  out += '        try std.testing.expectEqual(@as(usize, 64), source.source_sha256.len);\n'
  out += '        try std.testing.expect(source.line_start >= 1);\n'
  out += '        try std.testing.expect(source.line_end >= source.line_start);\n'
  out += '    }\n'
  out += '    for (system_prompt.section_order_sources) |source| {\n'
  out += '        try std.testing.expectEqual(@as(usize, 64), source.source_sha256.len);\n'
  out += '        try std.testing.expect(source.line_start >= 1);\n'
  out += '        try std.testing.expect(source.line_end >= source.line_start);\n'
  out += '    }\n'
  out += '    for (supporting_sources) |source| {\n'
  out += '        try std.testing.expectEqual(@as(usize, 64), source.source_sha256.len);\n'
  out += '        try std.testing.expect(source.path.len > 0);\n'
  out += '    }\n'
  out += '}\n'
  return out
}

function build() {
  const files = {
    'system_prompt.zig': generateSystemPrompt(),
    'tool_schemas.zig': generateToolSchemas(),
    'tool_render.zig': generateToolRender(),
    'compaction.zig': generateCompaction(),
    'interaction.zig': generateInteraction(),
  }
  // root.zig records reference constants from the modules above, so build it last.
  files['root.zig'] = generateRoot()
  return files
}

const args = parseArgs(process.argv.slice(2))
const dshRoot = path.resolve(args['dsh-root'] ?? '/root/jsplug-proto/dsh')
const outDir = path.resolve(args.out ?? 'src/harness/dsh_native/generated')

if (!fs.existsSync(dshRoot)) {
  console.error(`dsh source not found: ${dshRoot}`)
  console.error('Pass --dsh-root, or use the mirror image junclaw:full-dsh-test /opt/dsh/node_modules.')
  process.exit(2)
}

let files
try {
  files = build()
} catch (error) {
  console.error(`generation failed: ${error.message}`)
  process.exit(2)
}

if (args.check) {
  let failed = false
  for (const [name, content] of Object.entries(files)) {
    const target = path.join(outDir, name)
    let actual
    try {
      // A Windows checkout may have converted the committed files to CRLF;
      // compare the semantic LF form, not the working-tree line endings.
      actual = fs.readFileSync(target, 'utf8').replaceAll('\r\n', '\n')
    } catch {
      console.error(`drift: missing ${target}`)
      failed = true
      continue
    }
    if (actual !== content) {
      console.error(`drift: ${target}`)
      failed = true
    } else {
      console.log(`ok: ${target}`)
    }
  }
  process.exit(failed ? 1 : 0)
}

fs.mkdirSync(outDir, { recursive: true })
for (const [name, content] of Object.entries(files)) {
  const target = path.join(outDir, name)
  fs.writeFileSync(target, content, 'utf8')
  console.log(`wrote: ${target}`)
}
