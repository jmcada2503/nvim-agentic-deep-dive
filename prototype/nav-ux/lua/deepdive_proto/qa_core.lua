-- PROTOTYPE (throwaway): scripted stand-in for the Q&A agent, Revision proposals, Fix runs, Pending revisions and
-- the Revision history. No real agent: answers, Fix-run progress and ops are canned so the three panel variants
-- (qa_views.lua) can be judged on layout and interaction only. State lives in memory, shared by all variants.
local G = require('deepdive_proto.graph')
local C = {}

C.threads = {}     -- focus key -> { focus, msgs }
C.log = {}         -- chronological events (chat variant): { k='msg', th=, m= } | { k='fix', f= } | { k='note', text=, hl= }
C.proposals = {}
C.revisions = {}
C.fix = nil        -- current Fix run
C.pending = nil    -- current Pending revision
C.ov = nil         -- graph diff overlay: { from=, to= } or { pending=true }
C.sim_fail = true  -- the first Fix run attempt gets stuck in the validation loop (demo toggle)

local listeners = {}
function C.on(fn) listeners[#listeners + 1] = fn end
local function emit(what) for _, f in ipairs(listeners) do pcall(f, what) end end
C.emit = emit

-- ---------- anchors ----------
local function A(repo, path, s, e) return { repo = repo, path = path, s = s, e = e or s } end
function C.check(a) -- the same cheap check as the Validator: file exists, lines in range
  a.file = G.root .. '/' .. a.repo .. '/' .. a.path
  if vim.fn.filereadable(a.file) == 0 then a.bad = 'file not found'; return a end
  local n = #vim.fn.readfile(a.file)
  if a.e > n then a.bad = 'lines ' .. a.s .. '-' .. a.e .. ' past end of file (' .. n .. ')' end
  return a
end
function C.astr(a) return a.repo .. '/' .. a.path .. ':' .. a.s .. (a.e ~= a.s and ('-' .. a.e) or '') end
local function find(repo, path, prefix)
  for i, l in ipairs(vim.fn.readfile(G.root .. '/' .. repo .. '/' .. path)) do
    if l:find(prefix, 1, true) then return i end
  end
  return 1
end
local function stepcite(id) local a = G.steps[id].anchor; return C.check(A(a.repo, a.path, a.s, a.e)) end
local L429 = find('orders-service', 'src/payments/billingClient.ts', 'res.status === 429')
local LSLEEP = find('orders-service', 'src/payments/chargeWithRetry.ts', 'await sleep')

-- ---------- focus ----------
function C.focus_of(S, e)
  if e then
    return { kind = 'edge', key = 'edge:' .. e.from .. '>' .. e.to, id = S.sel, edge = e,
      label = G.steps[e.from].title .. ' → ' .. G.steps[e.to].title .. ' (' .. e.shape .. ')' }
  end
  return { kind = 'step', key = 'step:' .. S.sel, id = S.sel, label = G.steps[S.sel].title }
end
C.DIVE = { kind = 'dive', key = 'dive', label = 'whole dive “' .. G.title .. '”' }

local function thread(f)
  local t = C.threads[f.key]
  if not t then t = { focus = f, msgs = {} }; C.threads[f.key] = t end
  return t
end
function C.thread_count(id)
  local n = 0
  for _, t in pairs(C.threads) do if t.focus.id == id then n = n + #vim.tbl_filter(function(m) return m.role == 'user' end, t.msgs) end end
  return n
end

-- ---------- history (fake r1, r2 already accepted) ----------
C.revisions = {
  { n = 1, kind = 'extension', reason = 'The graph went straight from pricing to reserving; out-of-stock orders stop with 409 and were missing.',
    q = 'what happens when an item is out of stock?', ops = {
      { op = 'add', what = 'step', id = 'os.reject', note = 'early return at placeOrder.ts:27' },
      { op = 'change', what = 'step', id = 'os.stock', field = 'kind', before = 'action “Check stock”', after = 'decision “All in stock?”', note = 'the check now branches' },
      { op = 'add', what = 'edge', id = 'os.stock → os.reject [no]', note = 'carries PricedLine[]' },
    } },
  { n = 2, kind = 'correction', reason = 'The exit of the retry loop is the return after the loop, not createCharge.',
    q = 'where does the retry end?', ops = {
      { op = 'change', what = 'step', id = 'pay.result', field = 'anchor', before = 'billingClient.ts:14-27', after = 'chargeWithRetry.ts:16', note = 'createCharge is the boundary, not the exit' },
    } },
}
G.steps['os.reject'].rev = { n = 1, kind = 'extension', reason = C.revisions[1].reason, before = '(none)', after = 'added' }
G.steps['os.stock'].rev = { n = 1, kind = 'extension', reason = C.revisions[1].reason, before = 'action “Check stock”', after = 'decision “All in stock?”' }

-- ---------- the scripted agent ----------
local CHARGE = { ['os.charge'] = 1, ['pay.count'] = 1, ['pay.billing'] = 1, ['pay.retry'] = 1, ['pay.result'] = 1, ['os.approved'] = 1 }
local function charge_related(f)
  if f.kind == 'edge' then return f.edge.shape == 'ChargeResult' or f.edge.shape == 'ChargeRequest' end
  return f.kind == 'step' and CHARGE[f.id] ~= nil
end
local function level_label(id)
  local st = G.steps[id]
  local lvl = st.parent and ('“' .. G.steps[st.parent].title .. '” level') or 'root level'
  return lvl .. ' + subtree of “' .. st.title .. '”'
end

local function new_prop(t)
  t.n = #C.proposals + 1
  t.id = 'P' .. t.n
  t.status, t.ver = 'open', 1
  C.proposals[#C.proposals + 1] = t
  return t
end

local function script(f, q)
  local b = {}
  if f.kind == 'dive' then
    b[#b + 1] = { t = 'p', text = 'From the graph: the flow starts at “Submit checkout” in storefront, crosses to orders-service over HTTP, creates a pending order, charges the card through billing-service and answers 201, 402, 409 or 400 back to the storefront.' }
    b[#b + 1] = { t = 'cite', a = stepcite('sf.submit') }
    b[#b + 1] = { t = 'cite', a = stepcite('os.receive') }
    b[#b + 1] = { t = 'p', text = 'Two Boundaries are unresolved: billing-service and the orders.placed consumers. ' .. #C.revisions .. ' Revisions so far.' }
    return b
  end
  if charge_related(f) and not C.p429 then
    b[#b + 1] = { t = 'p', text = 'It retries only while billing answers status "error" and attempts remain; each retry waits backoffMs(attempt), doubling from 200 ms.' }
    b[#b + 1] = { t = 'cite', a = stepcite('pay.retry') }
    b[#b + 1] = { t = 'cite', a = C.check(A('orders-service', 'src/payments/backoff.ts', 3, 9)) } -- hallucinated: struck out
    b[#b + 1] = { t = 'unv', text = 'billingClient also maps HTTP 429 (rate limited) to "error" and attaches retryAfterMs, so rate limits are retried too; nothing reads retryAfterMs, the wait stays the backoff. The graph says only 5xx and network errors.',
      cites = { C.check(A('orders-service', 'src/payments/billingClient.ts', L429)), C.check(A('orders-service', 'src/payments/chargeWithRetry.ts', LSLEEP)) } }
    C.p429 = new_prop {
      kind = 'correction', target = 'pay.billing', scope = level_label('pay.billing'),
      reason = 'The boundary says 5xx and network errors become "error"; billingClient.ts:' .. L429 .. ' also turns 429 into "error" (with retryAfterMs), so rate limits are retried.',
      evidence = { C.check(A('orders-service', 'src/payments/billingClient.ts', L429)) },
      q = q, scripted = true,
    }
    b[#b + 1] = { t = 'prop', p = C.p429, ver = 1 }
    return b
  end
  local st = G.steps[f.id]
  if f.kind == 'edge' then
    local e = f.edge
    b[#b + 1] = { t = 'p', text = 'This edge carries ' .. e.shape .. (e.card == 'many' and '[]' or '') .. ' from “' .. G.steps[e.from].title .. '” to “' .. G.steps[e.to].title .. '”' .. (e.when and (' when ' .. e.when) or '') .. (e.transport and (', over ' .. e.transport) or '') .. '. Fields: ' .. table.concat(G.shapes[e.shape] or {}, ', ') .. '.' }
    b[#b + 1] = { t = 'cite', a = stepcite(e.from) }
    return b
  end
  b[#b + 1] = { t = 'p', text = 'From the graph: ' .. st.summary }
  b[#b + 1] = { t = 'cite', a = stepcite(f.id) }
  if st.parent then b[#b + 1] = { t = 'p', text = 'It runs inside “' .. G.steps[st.parent].title .. '”.' } end
  return b
end

-- stream an agent message block by block
local function stream(t, blocks, after)
  local m = { role = 'agent', blocks = blocks, n = 0, done = false }
  t.msgs[#t.msgs + 1] = m
  C.log[#C.log + 1] = { k = 'msg', th = t, m = m }
  emit('thread')
  local function tick()
    m.n = m.n + 1
    if m.n >= #blocks then
      m.done = true
      emit('graph') -- new badges / proposals
      if after then after() end
    else
      emit('thread')
      vim.defer_fn(tick, 260)
    end
  end
  vim.defer_fn(tick, 650)
  return m
end

local function user_msg(t, text, tag)
  local m = { role = 'user', text = text, tag = tag }
  t.msgs[#t.msgs + 1] = m
  C.log[#C.log + 1] = { k = 'msg', th = t, m = m }
end

function C.ask(f, q)
  local t = thread(f)
  user_msg(t, q)
  stream(t, script(f, q))
  emit('graph')
  return t
end

-- the user describes a problem in plain words; the agent turns it into a proposal
function C.report(f, text)
  local t = thread(f)
  user_msg(t, text, 'problem')
  local id = f.id or 'sf.submit'
  local p = new_prop {
    kind = text:lower():find('miss') and 'extension' or 'correction', target = id, scope = level_label(id),
    reason = 'You said: “' .. text .. '”. Checked ' .. C.astr(stepcite(id)) .. ': the step summary does not cover it.',
    evidence = { stepcite(id) }, q = text,
  }
  stream(t, { { t = 'p', text = 'I turned that into a Revision proposal. Reply to change it, or accept to start a Fix run.' }, { t = 'prop', p = p, ver = 1 } })
  return t
end

function C.thread_of(p)
  for _, t in pairs(C.threads) do
    for _, m in ipairs(t.msgs) do
      for _, blk in ipairs(m.blocks or {}) do if blk.p == p then return t end end
    end
  end
end

-- reply in the thread: the agent regenerates the proposal (the user never edits it)
function C.reply(p, text)
  local t = C.thread_of(p)
  user_msg(t, text, 'reply')
  p.ver = p.ver + 1
  if text:lower():find('scope') or text:lower():find('wider') or text:lower():find('widen') then
    p.scope = 'root level + subtree of “Charge card”'
  else
    p.reason = p.reason .. ' (Per your reply: ' .. text .. ')'
  end
  stream(t, { { t = 'p', text = 'Regenerated ' .. p.id .. ' (v' .. p.ver .. ').' }, { t = 'prop', p = p, ver = p.ver } })
end

function C.dismiss(p) p.status = 'dismissed'; emit('graph') end

function C.open_props()
  return vim.tbl_filter(function(p) return p.status == 'open' end, C.proposals)
end

-- ---------- Fix run ----------
local function fixlog(f, text, icon, hl)
  f.log[#f.log + 1] = { text = text, icon = icon or '·', hl = hl }
  emit('fix')
end

local function chain(f, items, done)
  local i = 0
  local function nxt()
    if C.fix ~= f then return end
    i = i + 1
    if i > #items then return done() end
    local it = items[i]
    fixlog(f, it[1], it[2], it[3])
    vim.defer_fn(nxt, it[4] or 700)
  end
  nxt()
end

local function ops_for(p, note)
  if p.scripted then
    local st = G.steps['pay.billing']
    return {
      { op = 'change', what = 'step', id = 'pay.billing', field = 'summary', before = st.summary,
        after = 'HTTP call to billing-service. 5xx, 429 (rate limited) and network errors become status "error"; 429 also carries retryAfterMs. Its code is not in the known repos.',
        note = '429 branch at billingClient.ts:' .. L429 },
      { op = 'change', what = 'shape', id = 'ChargeResult', field = 'fields', before = table.concat(G.shapes.ChargeResult, ', '),
        after = table.concat(G.shapes.ChargeResult, ', ') .. ', retryAfterMs?: number', note = 'set on 429; nothing reads it yet (Critic R1)' },
    }
  end
  local st = G.steps[p.target]
  return { { op = 'change', what = 'step', id = p.target, field = 'summary', before = st.summary,
    after = st.summary .. ' (fixed: ' .. p.q .. ')', note = note and ('per your feedback: ' .. note) or 'stub op' } }
end

local function make_pending(f)
  local p = f.p
  C.pending = { n = #C.revisions + 1, kind = p.kind, reason = p.reason, p = p, q = p.q, ops = ops_for(p, f.note), feedback = f.note }
  f.state = 'pending'
  C.ov = { pending = true }
  fixlog(f, 'Pending revision r' .. C.pending.n .. ' ready for review', '✓', 'DiagnosticOk')
  emit('graph')
end

local function run(f)
  local p = f.p
  local fail = C.sim_fail and f.attempt == 1 and p.scripted
  local items = {
    { 'reading Anchors in scope: ' .. p.scope, '·' },
    { 'builder: 2 ops (change “billing-service /v1/charges”, change “Retry?”)', '·' },
    { 'Validator: structure ✓  Anchors ✓  ops inside scope ✓', '✓', 'DiagnosticOk' },
    { 'Critic: Risk R1  “Retry?” would say Retry-After is honoured; chargeWithRetry.ts:' .. LSLEEP .. ' always sleeps backoffMs(attempt)', '!', 'DiagnosticWarn', 900 },
  }
  if not p.scripted then
    items = { { 'reading Anchors in scope: ' .. p.scope, '·' }, { 'builder: 1 op', '·' },
      { 'Validator: structure ✓  Anchors ✓  ops inside scope ✓', '✓', 'DiagnosticOk' }, { 'Critic: agree, no open Risks', '✓', 'DiagnosticOk' } }
  elseif fail then
    items[#items + 1] = { 'builder rebuts R1: billingClient now returns retryAfterMs', '·' }
    items[#items + 1] = { 'Critic raises R1 again after the rebuttal → stuck', '✗', 'DiagnosticError' }
  elseif f.attempt == 1 then
    items[#items + 1] = { 'builder fixes R1: drops the “Retry?” change, adds retryAfterMs to ChargeResult', '·' }
    items[#items + 1] = { 'Validator ✓   Critic: agree, no open Risks', '✓', 'DiagnosticOk' }
  else
    items = { { 'reading Anchors in scope: ' .. p.scope, '·' },
      { 'builder: 2 ops (change “billing-service /v1/charges”, add retryAfterMs to ChargeResult)', '·' },
      { 'Validator: structure ✓  Anchors ✓  ops inside scope ✓', '✓', 'DiagnosticOk' },
      { 'Critic: agree, no open Risks', '✓', 'DiagnosticOk' } }
  end
  chain(f, items, function()
    if fail then
      f.state = 'failed'
      f.why = 'Builder and Critic disagree on R1: should “Retry?” say Retry-After is honoured? The builder reads retryAfterMs as used; the Critic finds no reader.'
      emit('graph')
    else
      make_pending(f)
    end
  end)
end

function C.start_fix(p, note, attempt)
  p.status = 'fixing'
  local prev = C.fix
  local f
  if prev and prev.p == p then -- same Fix run, next attempt: keep one log
    f = prev
    f.state, f.attempt, f.note, f.why = 'running', attempt or (f.attempt + 1), note, nil
    fixlog(f, '── attempt ' .. f.attempt .. (note and (': ' .. note) or ''), '↻', 'Title')
  else
    f = { p = p, log = {}, state = 'running', attempt = attempt or 1, note = note }
    C.log[#C.log + 1] = { k = 'fix', f = f }
  end
  C.fix = f
  emit('graph')
  run(f)
end

function C.accept(p)
  if C.fix or C.pending then p.status = 'queued'; emit('graph'); return end
  C.start_fix(p)
end

-- validation-failure dialogue
function C.clarify(q)
  local f = C.fix
  fixlog(f, q, 'you', 'DDYou')
  vim.defer_fn(function()
    if C.fix ~= f then return end
    fixlog(f, 'R1 is about “Retry?”: chargeWithRetry.ts:' .. LSLEEP .. ' sleeps backoffMs(attempt) on every error. I kept rebutting because billingClient sets retryAfterMs, but nothing reads it, so the Critic is right.', 'agent')
  end, 700)
end
function C.hint(h) C.start_fix(C.fix.p, 'hint: ' .. h, C.fix.attempt + 1) end
function C.widen(areas)
  local p = C.fix.p
  p.scope = p.scope .. ' + ' .. (areas ~= '' and areas or 'root level')
  C.start_fix(p, 'scope widened', C.fix.attempt + 1)
end

local function after_resolution(touched)
  for _, q in ipairs(C.proposals) do
    if q.status == 'queued' then
      if touched and touched[q.target] then
        q.ver = q.ver + 1
        q.reason = q.reason .. ' (regenerated after r' .. #C.revisions .. ' touched its step)'
      end
      C.start_fix(q)
      return
    end
  end
end

function C.abandon()
  local p = C.fix.p
  p.status = 'abandoned'
  C.fix = nil
  emit('graph')
  after_resolution()
end

-- ---------- Pending revision ----------
function C.accept_pending()
  local pr = C.pending
  local touched = {}
  for _, op in ipairs(pr.ops) do
    if op.what == 'step' then
      touched[op.id] = true
      if op.field == 'summary' then G.steps[op.id].summary = op.after end
      G.steps[op.id].rev = { n = pr.n, kind = pr.kind, reason = pr.reason, before = op.field .. ': ' .. op.before, after = op.field .. ': ' .. op.after }
    elseif op.what == 'shape' and op.id == 'ChargeResult' then
      table.insert(G.shapes.ChargeResult, 'retryAfterMs?: number')
    end
  end
  C.revisions[#C.revisions + 1] = { n = pr.n, kind = pr.kind, reason = pr.reason, q = pr.q, ops = pr.ops }
  pr.p.status = 'accepted'
  pr.p.rev = pr.n
  C.log[#C.log + 1] = { k = 'note', text = '✓ r' .. pr.n .. ' accepted (' .. pr.kind .. '): ' .. pr.reason, hl = 'DiagnosticOk' }
  C.pending, C.fix, C.ov = nil, nil, nil
  emit('graph')
  after_resolution(touched)
end

function C.reject_pending(feedback)
  local p = C.pending.p
  C.pending, C.ov = nil, nil
  if feedback and feedback ~= '' then
    C.start_fix(p, 'feedback: ' .. feedback, C.fix.attempt + 1)
  else
    p.status = 'rejected' -- leaves no trace in the Revisions
    C.fix = nil
    emit('graph')
    after_resolution()
  end
end

-- ---------- graph diff overlay ----------
function C.ov_revs()
  if not C.ov then return {} end
  if C.ov.pending then return C.pending and { C.pending } or {} end
  local out = {}
  for _, r in ipairs(C.revisions) do
    if r.n >= C.ov.from and r.n <= C.ov.to then out[#out + 1] = r end
  end
  return out
end
function C.targets()
  local t = {}
  for _, r in ipairs(C.ov_revs()) do
    for _, op in ipairs(r.ops) do if op.what == 'step' then t[op.id] = { op = op.op, r = r, o = op } end end
  end
  return t
end
local HL = { add = 'DDRevAdd', change = 'DDRevChg', remove = 'DDRevDel' }
function C.node_hl(id)
  if not C.ov then return end
  local t = C.targets()
  if t[id] then return HL[t[id].op] end
  for tid in pairs(t) do
    for _, a in ipairs(G.ancestors(tid)) do if a == id then return 'DDRevIn' end end
  end
end
function C.ops_at(id)
  local out = {}
  for _, r in ipairs(C.ov_revs()) do
    for _, op in ipairs(r.ops) do if op.id == id then out[#out + 1] = { r = r, o = op } end end
  end
  return out
end
function C.ov_label()
  if not C.ov then return nil end
  if C.ov.pending then return C.pending and ('pending r' .. C.pending.n) or nil end
  return (C.ov.from == C.ov.to and ('r' .. C.ov.from) or ('r' .. C.ov.from .. '–r' .. C.ov.to))
end

-- ---------- shared text rendering (content, not layout) ----------
function C.canvas()
  local c = { lines = {}, hls = {}, cites = {}, props = {} }
  function c.add(s, hl, c0, c1) c.lines[#c.lines + 1] = s; if hl then c.hls[#c.hls + 1] = { row = #c.lines - 1, hl = hl, c0 = c0, c1 = c1, prio = 150 } end; return #c.lines - 1 end
  function c.hl(row, hl, c0, c1) c.hls[#c.hls + 1] = { row = row, hl = hl, c0 = c0, c1 = c1, prio = 160 } end
  return c
end

local function wrap(s, n)
  local out, cur = {}, ''
  for word in s:gmatch('%S+') do
    if #cur > 0 and vim.fn.strdisplaywidth(cur .. ' ' .. word) > n then out[#out + 1] = cur; cur = word
    else cur = (#cur > 0 and (cur .. ' ') or '') .. word end
  end
  if #cur > 0 then out[#out + 1] = cur end
  return out
end
C.wrap = wrap

local function cite(c, a, ind)
  local s = ind .. '↗ ' .. C.astr(a)
  local r = c.add(s .. (a.bad and ('   ✗ ' .. a.bad) or ''), 'Comment')
  local i0 = vim.fn.strchars(ind) + 2
  c.hl(r, a.bad and 'DDBadCite' or 'DDCite', i0, i0 + vim.fn.strchars(C.astr(a)))
  if not a.bad then c.cites[r] = a end
end

local STATUS = {
  open = { '', 'DDKey' }, fixing = { '⟳ Fix run in progress', 'DiagnosticInfo' }, queued = { '⧗ queued behind the current Fix run', 'Comment' },
  accepted = { '✓ accepted', 'DiagnosticOk' }, dismissed = { 'dismissed', 'Comment' }, rejected = { 'rejected, no trace kept', 'Comment' },
  abandoned = { 'Fix run abandoned', 'Comment' },
}
function C.render_prop(c, p, w, ind, ver, keys)
  ind = ind or ''
  if ver and ver < p.ver then
    c.add(ind .. '╶ ' .. p.id .. ' v' .. ver .. ' superseded by v' .. p.ver, 'Comment')
    return
  end
  local live = p.status == 'open' or p.status == 'queued' or p.status == 'fixing'
  local frame = live and 'DDCard' or 'Comment'
  local r = c.add(ind .. '╭ Revision proposal ' .. p.id .. (p.ver > 1 and (' v' .. p.ver) or '') .. ' · ' .. p.kind, frame)
  c.hl(r, live and 'DDCardTitle' or 'Comment', vim.fn.strchars(ind) + 2)
  local function row(label, text, hl)
    local lines = wrap(text, w - 13 - vim.fn.strchars(ind))
    for i, l in ipairs(lines) do
      local rr = c.add(ind .. '│ ' .. (i == 1 and string.format('%-9s', label) or string.rep(' ', 9)) .. l, frame)
      c.hl(rr, hl or (live and 'Normal' or 'Comment'), vim.fn.strchars(ind) + 11)
    end
  end
  local st = G.steps[p.target]
  row('target', (st.kind == 'boundary' and '⇢ ' or '') .. st.title)
  row('scope', p.scope)
  row('reason', p.reason)
  for _, a in ipairs(p.evidence or {}) do
    local rr = c.add(ind .. '│ ' .. string.format('%-9s', 'evidence') .. '↗ ' .. C.astr(a), frame)
    c.hl(rr, 'DDCite', vim.fn.strchars(ind) + 13)
    c.cites[rr] = a
  end
  local s = STATUS[p.status]
  local tail = p.status == 'open' and (keys or 'y accept · x dismiss · R reply') or s[1]
  if p.status == 'accepted' and p.rev then tail = '✓ became r' .. p.rev end
  local rr = c.add(ind .. '╰ ' .. tail, frame)
  c.hl(rr, p.status == 'open' and 'DDKeyHint' or s[2], vim.fn.strchars(ind) + 2)
  c.props[rr] = p
end

-- one message; `who` chooses the role labels
function C.render_msg(c, m, w, ind, opts)
  ind = ind or ''
  opts = opts or {}
  if m.role == 'user' then
    local tag = m.tag == 'problem' and '⚑ ' or (m.tag == 'reply' and '↩ ' or '')
    for i, l in ipairs(wrap(tag .. m.text, w - 6 - vim.fn.strchars(ind))) do
      local r = c.add(ind .. (i == 1 and (opts.you or 'you  ') or string.rep(' ', vim.fn.strchars(opts.you or 'you  '))) .. l, 'DDYouText')
      if i == 1 then c.hl(r, 'DDYou', vim.fn.strchars(ind), vim.fn.strchars(ind) + vim.fn.strchars(opts.you or 'you  ')) end
    end
    return
  end
  local lab = opts.agent or 'agent'
  local pad = ind .. string.rep(' ', vim.fn.strchars(lab) + 2)
  local first = true
  local function lead() if first then first = false; return ind .. lab .. '  ' end return pad end
  if m.n == 0 then
    local r = c.add(lead() .. '…', 'Comment'); c.hl(r, 'DDAgent', vim.fn.strchars(ind), vim.fn.strchars(ind) + vim.fn.strchars(lab))
    return
  end
  for k = 1, math.min(m.n, #m.blocks) do
    local b = m.blocks[k]
    if b.t == 'p' then
      for _, l in ipairs(wrap(b.text, w - vim.fn.strchars(pad))) do
        local isfirst = first
        local r = c.add(lead() .. l)
        if isfirst then c.hl(r, 'DDAgent', vim.fn.strchars(ind), vim.fn.strchars(ind) + vim.fn.strchars(lab)) end
      end
    elseif b.t == 'cite' then
      cite(c, b.a, lead())
    elseif b.t == 'unv' then
      c.add(lead() .. '⚠ not in graph, unverified', 'DDUnvHead')
      for _, l in ipairs(wrap(b.text, w - vim.fn.strchars(pad) - 2)) do c.add(pad .. '┃ ' .. l, 'DDUnv') end
      for _, a in ipairs(b.cites) do cite(c, a, pad .. '┃ ') end
    elseif b.t == 'prop' then
      C.render_prop(c, b.p, w, lead(), b.ver, opts.keys)
    end
  end
  if not m.done then c.add(pad .. '…', 'Comment') end
end

function C.render_fix(c, f, w, ind, keys)
  ind = ind or ''
  for _, l in ipairs(f.log) do
    local lines = wrap(l.text, w - 6 - vim.fn.strchars(ind))
    for i, t in ipairs(lines) do
      local icon = i == 1 and l.icon or ' '
      local r = c.add(ind .. (icon == 'you' and 'you ' or (icon == 'agent' and 'agt ' or (icon .. '   '))) .. t, l.hl)
      if i == 1 and icon == 'you' then c.hl(r, 'DDYou', vim.fn.strchars(ind), vim.fn.strchars(ind) + 3) end
    end
  end
  if f.state == 'running' then c.add(ind .. '⟳   …', 'DiagnosticInfo') end
  if f.state == 'failed' then
    c.add('')
    for _, l in ipairs(wrap('Stuck: ' .. f.why, w - 2 - vim.fn.strchars(ind))) do c.add(ind .. l, 'DiagnosticError') end
    local r = c.add(ind .. (keys or 'Q clarify · H hint + retry · W widen scope · X abandon'), 'DDKeyHint')
    c.hl(r, 'DDKeyHint')
  end
end

-- Pending revision as cards: reason on top, op notes inline (variants A and C)
function C.render_review(c, w, ind, keys, only_id)
  ind = ind or ''
  local pr = C.pending
  if not pr then return end
  local r = c.add(ind .. 'Pending revision r' .. pr.n .. ' · ' .. pr.kind .. ' · from ' .. pr.p.id, 'DDCardTitle')
  for _, l in ipairs(wrap('reason  ' .. pr.reason, w - 2 - vim.fn.strchars(ind))) do c.add(ind .. l) end
  c.add(ind .. 'asked   “' .. pr.q .. '”', 'Comment')
  if pr.feedback then c.add(ind .. 'rerun   ' .. pr.feedback, 'Comment') end
  c.add('')
  for _, op in ipairs(pr.ops) do
    if not only_id or op.id == only_id then
      local name = op.what == 'step' and ('“' .. G.steps[op.id].title .. '”') or op.id
      local sym = op.op == 'add' and '+' or (op.op == 'remove' and '-' or '~')
      local rr = c.add(ind .. sym .. ' ' .. op.op .. ' ' .. op.what .. ' ' .. name .. '  · ' .. op.field, op.op == 'add' and 'DDRevAdd' or 'DDRevChg')
      c.hl(rr, op.op == 'add' and 'DDRevAdd' or 'DDRevChg', 0, vim.fn.strchars(ind) + 1)
      for _, l in ipairs(wrap(op.before, w - 8 - vim.fn.strchars(ind))) do c.add(ind .. '   − ' .. l, 'DiffDelete') end
      for _, l in ipairs(wrap(op.after, w - 8 - vim.fn.strchars(ind))) do c.add(ind .. '   + ' .. l, 'DiffAdd') end
      c.add(ind .. '   ✎ ' .. op.note, 'DDNote')
    end
  end
  if keys then c.add(''); c.add(ind .. keys, 'DDKeyHint') end
  return r
end

function C.hl_setup()
  local hl = function(n, v) vim.api.nvim_set_hl(0, n, v) end
  hl('DDYou', { fg = '#1e1e1e', bg = '#61afef', bold = true })
  hl('DDYouText', { fg = '#9ecbff' })
  hl('DDAgent', { fg = '#1e1e1e', bg = '#c678dd', bold = true })
  hl('DDCite', { fg = '#56b6c2', underline = true })
  hl('DDBadCite', { fg = '#e06c75', strikethrough = true })
  hl('DDUnvHead', { fg = '#1e1e1e', bg = '#e5c07b', bold = true })
  hl('DDUnv', { fg = '#e5c07b', italic = true })
  hl('DDCard', { fg = '#c678dd' })
  hl('DDCardTitle', { fg = '#c678dd', bold = true })
  hl('DDKeyHint', { fg = '#98c379', bold = true })
  hl('DDNote', { fg = '#7f848e', italic = true })
  hl('DDRevAdd', { fg = '#98c379', bg = '#24312a', bold = true })
  hl('DDRevChg', { fg = '#e5c07b', bg = '#35321f', bold = true })
  hl('DDRevDel', { fg = '#e06c75', strikethrough = true })
  hl('DDRevIn', { fg = '#b8a165' })
  hl('DDPill', { fg = '#1e1e1e', bg = '#e5c07b', bold = true })
  hl('DDTab', { fg = '#abb2bf', bg = '#2c313c' })
  hl('DDDim', { fg = '#3e4452' })
  hl('DDWhole', { fg = '#c678dd' })
  hl('DDWholeBar', { fg = '#1e1e1e', bg = '#61afef', bold = true })
  hl('DDTabSel', { fg = '#1e1e1e', bg = '#c678dd', bold = true })
end

return C
