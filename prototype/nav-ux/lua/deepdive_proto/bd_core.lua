-- PROTOTYPE (throwaway): scripted Boundary state for the "Boundary and specify-repo view" ticket.
-- No real agent: the staged dive, its needs_input pause, and the extension into another repo are canned, so the
-- three layouts in bd_views.lua can be judged on layout and interaction only. State lives in memory.
--
-- Scenario: the dive is at stage 4/4 ("Charge card") and paused at the billing-service Boundary.
--   answer with a repo  -> dive reads billing-service, "Charge card › Create charge" gets 5 Steps, then pauses again
--                          at the acquirer (a third party: the natural answer is "external")
--   answer later        -> dive finishes; the Boundary stays unresolved; "specify repo" later goes through a
--                          Fix-run-like extension run and a Pending revision (Review tab)
--   orders.placed consumers was left "later" at stage 1; specify repo `notifications` (in the Workspace) for it.
local G = require('deepdive_proto.graph')
local C = require('deepdive_proto.qa_core')
local B = {}
local A = G.A
local ROOT = G.root

local function find(repo, path, prefix)
  for i, l in ipairs(vim.fn.readfile(ROOT .. '/' .. repo .. '/' .. path)) do
    if l:find(prefix, 1, true) then return i end
  end
  return 1
end
local function cite(repo, path, prefix)
  local l = find(repo, path, prefix)
  return C.check({ repo = repo, path = path, s = l, e = l })
end
function B.short(p) return (p:gsub('^' .. vim.pesc(ROOT), '…/demo')) end

-- ---------- Workspace (user-level registry: repo id, local path, remote) ----------
B.workspace = {
  { id = 'storefront', path = ROOT .. '/storefront', remote = 'github.com/acme/storefront', dive = true },
  { id = 'orders-service', path = ROOT .. '/orders-service', remote = 'github.com/acme/orders-service', dive = true },
  { id = 'notifications', path = ROOT .. '/notifications', remote = 'github.com/acme/notifications', dive = false },
}
local function ws(id) for _, r in ipairs(B.workspace) do if r.id == id then return r end end end
local function register(repo)
  local r = ws(repo.id)
  if not r then
    r = { id = repo.id, path = repo.path, remote = '(none)', dive = true, new = true }
    B.workspace[#B.workspace + 1] = r
  end
  r.dive = true
  return r
end

-- ---------- per-Boundary info the agent recorded when it stopped ----------
B.info = {
  ['pay.billing'] = {
    why = 'billingClient.createCharge POSTs to config.billingUrl + /v1/charges; no repo in the Workspace serves POST /v1/charges.',
    evidence = { cite('orders-service', 'src/payments/billingClient.ts', 'fetch(`${config.billingUrl}/v1/charges`'),
      cite('orders-service', 'src/config.ts', 'billingUrl') },
    guess = { kind = 'repo', id = 'billing-service', path = ROOT .. '/billing-service',
      why = 'host “billing-service” in config.ts; a folder with that name sits next to orders-service' },
    expect = 'billing-service',
    hist = {},
  },
  ['ev.placed'] = {
    why = 'publishOrderPlaced publishes orders.placed on the “orders” exchange; no known repo subscribes to it.',
    evidence = { cite('orders-service', 'src/events/publisher.ts', 'ch.publish("orders"'),
      cite('orders-service', 'README.md', 'consumed by fulfilment and email') },
    guess = { kind = 'repo', id = 'notifications', path = ROOT .. '/notifications',
      why = 'Workspace repo; the orders-service README says “email” consumes orders.placed' },
    expect = 'notifications',
    hist = { 'asked during the dive (stage 1, root level) · you answered “later”' },
  },
}

-- ---------- the staged dive ----------
B.dive = {
  state = 'paused', -- running | paused | done
  stages = {
    { title = 'root level', st = 'done', note = '1 Boundary left unresolved' },
    { title = 'Submit checkout', st = 'done' },
    { title = 'Create pending order', st = 'done' },
    { title = 'Charge card', st = 'paused' },
  },
  log = {
    { text = 'stage 4/4 · expanding “Charge card”', icon = '▸', hl = 'Title' },
    { text = 'builder: 4 Steps (Count attempt, billing-service call, Retry?, Return charge result)', icon = '·' },
    { text = 'Boundary: POST billing-service /v1/charges · no Workspace repo serves it', icon = '⇢', hl = 'DiagnosticWarn' },
    { text = 'needs_input → asking you; the session resumes with your answer', icon = '⏸', hl = 'DDRevChg' },
  },
}
B.q = { step = 'pay.billing', stage = 4,
  text = '“Charge card” calls POST billing-service /v1/charges, but no repo in the Workspace serves it. Where does billing-service live?' }
G.waiting = 'pay.billing'

local function emit(what) C.emit(what or 'graph') end -- views listen with C.on
B.emit = emit

local function dlog(text, icon, hl) B.dive.log[#B.dive.log + 1] = { text = text, icon = icon or '·', hl = hl } end

-- ---------- status of a Step, as the UI shows it ----------
function B.status(id)
  local st = G.steps[id]
  if not st then return nil end
  if st.resolved then return 'resolved' end
  if st.kind ~= 'boundary' then return nil end
  if G.waiting == id then return 'waiting' end
  if B.dive.reading == id then return 'reading' end
  if C.fix and C.fix.p.target == id and C.fix.p.bd then return C.pending and 'pending' or 'extending' end
  return st.boundary.status -- unresolved | external | declined
end
function B.is_bd(id) return B.status(id) ~= nil end
B.LABEL = {
  waiting = { '⏸ the dive is waiting for your answer', 'DDRevChg' },
  reading = { '⟳ the dive is reading the repo you named', 'DiagnosticInfo' },
  extending = { '⟳ extension run in progress', 'DiagnosticInfo' },
  pending = { '● Pending revision: review it', 'DDRevChg' },
  unresolved = { '⚠ unresolved', 'DiagnosticWarn' },
  external = { '↗ external: third party, not followed', 'Comment' },
  declined = { '⊘ declined: not followed', 'Comment' },
  resolved = { '✓ resolved', 'DiagnosticOk' },
}
B.BADGE = { waiting = ' ⏸', reading = ' ⟳', extending = ' ⟳', pending = ' ●', external = ' ↗', declined = ' ⊘', resolved = ' ⇢✓' }
function B.badge(id)
  local s = B.status(id)
  local b = s and B.BADGE[s] or ''
  if G.waiting and s ~= 'waiting' then
    for _, a in ipairs(G.ancestors(G.waiting)) do if a == id then b = b .. ' ⏸' end end
  end
  return b
end

-- repos the user can pick for a Boundary: the agent's guess first, then Workspace repos not in the dive yet
function B.candidates(id)
  local info, out = B.info[id] or {}, {}
  local g = info.guess
  if g and g.kind == 'repo' then
    local r = ws(g.id)
    out[#out + 1] = { id = g.id, path = g.path, star = true, where = r and 'Workspace' or 'not in Workspace yet', why = g.why }
  end
  for _, r in ipairs(B.workspace) do
    if not (g and g.id == r.id) then
      out[#out + 1] = { id = r.id, path = r.path, where = 'Workspace' .. (r.dive and ' · in this dive' or '') }
    end
  end
  return out
end
function B.from_path(path)
  path = vim.fn.fnamemodify(vim.fn.expand(vim.trim(path)), ':p'):gsub('/$', '')
  if vim.fn.isdirectory(path) == 0 then return nil, 'not a directory: ' .. path end
  return { id = vim.fn.fnamemodify(path, ':t'), path = path }
end

-- ---------- graph changes (shared by "during the dive" and "later") ----------
local EXT = {}
EXT['pay.billing'] = { repo = 'billing-service', group = 'billing-service', title = 'Create charge',
  summary = 'billing-service authorizes the card with the acquirer, stores approved charges and answers approved or declined.',
  steps = {
    { id = 'bs.receive', entry = true, kind = 'action', title = 'Receive POST /v1/charges',
      summary = 'Express route checks orderId, token and amount; bad bodies get 400 with status "error".',
      anchor = A('billing-service', 'src/routes/charges.ts', 'chargesRouter.post("/v1/charges"', '});') },
    { id = 'bs.acquirer', kind = 'boundary', group = 'unknown', title = 'Acquirer authorize',
      summary = 'HTTPS call to the card acquirer. Its code is not in any known repo.',
      boundary = { transport = 'https', target = 'POST api.acquirer.example /v2/authorizations', status = 'unresolved' },
      callsite = A('billing-service', 'src/charges/createCharge.ts', '  const auth = await authorize', 1),
      anchor = A('billing-service', 'src/acquirer/acquirerClient.ts', 'export async function authorize', '}') },
    { id = 'bs.approved', kind = 'decision', title = 'Authorized?', summary = 'Approved authorizations are stored; anything else is a decline.',
      condition = 'auth.approved', anchor = A('billing-service', 'src/charges/createCharge.ts', '  if (auth.approved) {', '  }') },
    { id = 'bs.store', kind = 'action', title = 'Store charge', summary = 'Saves the charge with its auth code under a new id and answers approved.',
      writes = { 'ChargeResult.chargeId' },
      callsite = A('billing-service', 'src/charges/createCharge.ts', '    const chargeId = await saveCharge', 1),
      anchor = A('billing-service', 'src/charges/store.ts', 'export async function saveCharge', '}') },
    { id = 'bs.decline', kind = 'action', title = 'Return decline', summary = 'Answers declined with the acquirer’s reason.',
      writes = { 'ChargeResult.declineReason' },
      anchor = A('billing-service', 'src/charges/createCharge.ts', '  return { status: "declined"', 1) },
  },
  edges = {
    { from = 'bs.receive', to = 'bs.acquirer', shape = 'ChargeRequest', card = 'one', transport = 'https' },
    { from = 'bs.acquirer', to = 'bs.approved', shape = 'AuthResult', card = 'one' },
    { from = 'bs.approved', to = 'bs.store', shape = 'AuthResult', card = 'one', when = 'yes' },
    { from = 'bs.approved', to = 'bs.decline', shape = 'AuthResult', card = 'one', when = 'no' },
  },
  shape = { 'AuthResult', { 'approved: boolean', 'authCode?: string', 'reason?: string' },
    A('billing-service', 'src/acquirer/acquirerClient.ts', 'export interface AuthResult', '}') },
  log = { 'reading billing-service: handler for POST /v1/charges at src/routes/charges.ts', 'builder: 5 Steps inside “Create charge”, 1 new Boundary (acquirer)' },
}
EXT['ev.placed'] = { repo = 'notifications', group = 'notifications', title = 'Email order confirmation',
  summary = 'notifications consumes orders.placed and emails the customer. Other consumers (fulfilment) were not found.',
  steps = {
    { id = 'nt.consume', entry = true, kind = 'action', title = 'Consume orders.placed',
      summary = 'Queue consumer bound to orders.placed; acks after the handler finishes.',
      anchor = A('notifications', 'src/consumers/orderPlaced.ts', '  subscribe("orders", "orders.placed"', '  });') },
    { id = 'nt.email', kind = 'action', title = 'Send confirmation email', summary = 'POSTs the order-confirmed template to the mailer.',
      reads = { 'OrderPlacedEvent.email', 'OrderPlacedEvent.orderId', 'OrderPlacedEvent.total' },
      callsite = A('notifications', 'src/consumers/orderPlaced.ts', '    await sendEmail', 1),
      anchor = A('notifications', 'src/email/sendEmail.ts', 'export async function sendEmail', '}') },
  },
  edges = { { from = 'nt.consume', to = 'nt.email', shape = 'OrderPlacedEvent', card = 'one' } },
  log = { 'reading notifications: consumer bound to orders.placed at src/consumers/orderPlaced.ts', 'builder: 2 Steps inside “Email order confirmation”' },
}

local function apply(id, via)
  local x = EXT[id]
  local st = G.steps[id]
  st.was = { kind = st.kind, title = st.title, summary = st.summary, group = st.group, boundary = st.boundary }
  st.resolved = { repo = x.repo, via = via, target = st.boundary.target, transport = st.boundary.transport }
  st.kind, st.title, st.summary, st.group, st.boundary = 'action', x.title, x.summary, x.group, nil
  if x.shape then G.add_shape(x.shape[1], x.shape[2], x.shape[3]) end
  for _, s in ipairs(x.steps) do
    local t = vim.deepcopy(s)
    t.parent, t.group = id, t.group or x.group
    G.add(t)
  end
  for _, e in ipairs(x.edges) do G.edges[#G.edges + 1] = e end
  if G.waiting == id then G.waiting = nil end
end

local function ext_ops(id, repo)
  local x = EXT[id]
  local st = G.steps[id]
  local ops = { { op = 'change', what = 'step', id = id, field = 'kind', before = '⇢ boundary “' .. st.title .. '” (' .. st.boundary.status .. ')',
    after = '▣ composite “' .. x.title .. '” in ' .. repo.id, note = 'target ' .. st.boundary.target .. ' is served by ' .. repo.id } }
  for _, s in ipairs(x.steps) do
    ops[#ops + 1] = { op = 'add', what = 'step', id = s.id, title = s.title, before = '(none)',
      after = s.anchor.repo .. '/' .. s.anchor.path, note = s.kind == 'boundary' and 'new Boundary: ' .. s.boundary.target or (s.kind == 'decision' and 'decision' or 'leaf') }
  end
  if not ws(repo.id) then
    ops[#ops + 1] = { op = 'add', what = 'workspace', id = repo.id, before = '(not registered)', after = B.short(repo.path),
      note = 'registers the repo so later Boundaries to it resolve without asking' }
  end
  return ops
end

-- ---------- answering the dive's needs_input question ----------
local function finish_stage(note)
  local stg = B.dive.stages[#B.dive.stages]
  stg.st, stg.note = 'done', note
  B.dive.state, B.dive.reading = 'done', nil
  local u = G.unresolved(nil)
  dlog('dive complete · ' .. u .. ' Boundar' .. (u == 1 and 'y' or 'ies') .. ' unresolved (specify repo any time)', '✓', 'DiagnosticOk')
  emit('graph')
end

local function pause(id, stage_title, text, guess_note)
  G.waiting = id
  B.dive.state = 'paused'
  B.q = { step = id, text = text }
  B.dive.stages[#B.dive.stages + 1] = { title = stage_title, st = 'paused' }
  dlog('needs_input → asking you' .. (guess_note and (' · ' .. guess_note) or ''), '⏸', 'DDRevChg')
  emit('graph')
  -- no notification: the views open the panel on Run, focused on the question (after insert mode ends)
end

local function run_items(items, done)
  local i = 0
  local function nxt()
    i = i + 1
    if i > #items then return done() end
    local it = items[i]
    dlog(it[1], it[2], it[3])
    emit('thread')
    vim.defer_fn(nxt, it[4] or 650)
  end
  nxt()
end

function B.answer(kind, repo)
  local q = B.q
  if not q then return end
  local id = q.step
  local st = G.steps[id]
  local info = B.info[id] or { hist = {} }
  B.q = nil
  G.waiting = nil
  local stg = B.dive.stages[#B.dive.stages]
  if kind == 'external' or kind == 'declined' then
    st.boundary.status = kind
    info.hist[#info.hist + 1] = 'asked during the dive · you answered “' .. kind .. '”'
    dlog((kind == 'external' and 'external (third party)' or 'don’t follow'), 'you', 'DDYou')
    stg.st = 'done'
    return finish_stage()
  elseif kind == 'later' then
    info.hist[#info.hist + 1] = 'asked during the dive · you answered “later”'
    dlog('later · the Boundary stays unresolved, the dive goes on', 'you', 'DDYou')
    return finish_stage('1 Boundary left unresolved')
  end
  -- a repo
  dlog(repo.id .. ' at ' .. B.short(repo.path), 'you', 'DDYou')
  B.dive.state, B.dive.reading = 'running', id
  stg.st = 'running'
  emit('graph')
  local ok = info.expect == repo.id
  local items = { { (ws(repo.id) and 'Workspace: ' .. repo.id .. ' already registered' or 'Workspace + ' .. repo.id .. ' (' .. B.short(repo.path) .. ')'), '·' },
    { 'resume session with --add-dir ' .. B.short(repo.path), '·' } }
  if not ok then
    items[#items + 1] = { 'reading ' .. repo.id .. ': nothing serves ' .. st.boundary.target, '✗', 'DiagnosticError', 900 }
    return run_items(items, function()
      B.dive.reading = nil
      info.hist[#info.hist + 1] = repo.id .. ' did not serve it (during the dive)'
      table.remove(B.dive.stages)
      pause(id, stg.title, repo.id .. ' does not serve ' .. st.boundary.target .. '. Where does it live?')
    end)
  end
  register(repo)
  for _, l in ipairs(EXT[id].log) do items[#items + 1] = { l, '·' } end
  items[#items + 1] = { 'Validator ✓   Critic: agree, no open Risks', '✓', 'DiagnosticOk', 800 }
  run_items(items, function()
    info.hist[#info.hist + 1] = 'resolved during the dive → ' .. repo.id
    apply(id, 'dive')
    B.dive.reading = nil
    stg.st = 'done'
    if id == 'pay.billing' then
      dlog('stage 5 · expanding “Create charge” (billing-service)', '▸', 'Title')
      dlog('Boundary: POST api.acquirer.example /v2/authorizations · host is not in the Workspace', '⇢', 'DiagnosticWarn')
      B.info['bs.acquirer'] = {
        why = 'acquirerClient.authorize POSTs to ACQUIRER_URL (default https://api.acquirer.example); no repo serves it.',
        evidence = { cite('billing-service', 'src/acquirer/acquirerClient.ts', 'const ACQUIRER_URL') },
        guess = { kind = 'external', why = 'public third-party host, no repo with a matching name' },
        hist = {},
      }
      pause('bs.acquirer', 'Create charge', '“Create charge” calls the acquirer at api.acquirer.example. It looks like a third party. Mark it external?', 'agent suggests: external')
    else
      finish_stage()
    end
  end)
end

-- the user typed an answer in Run's prompt: the (scripted) agent reads it. Returns the agent's reply.
function B.answer_text(text)
  local q = B.q
  if not q then return nil end
  local id = q.step
  local t = text:lower()
  local cands = B.candidates(id)
  local n = tonumber(t:match('^%s*(%d)%s*$'))
  if n and cands[n] then B.answer('repo', { id = cands[n].id, path = cands[n].path }); return 'Taking ' .. cands[n].id .. '.' end
  for word in text:gmatch('%S+') do
    if word:find('/', 1, true) then
      local r = B.from_path(word)
      if r then B.answer('repo', r); return 'Taking ' .. r.id .. ' at ' .. B.short(r.path) .. '.' end
    end
  end
  for _, cd in ipairs(cands) do
    if t:find(cd.id, 1, true) then B.answer('repo', { id = cd.id, path = cd.path }); return 'Taking ' .. cd.id .. '.' end
  end
  if t:find('extern') or t:find('third') or t:find('vendor') or t:find('stripe') or t:find('not ours') then
    B.answer('external'); return 'Marked external; the dive goes on.'
  end
  if t:find('skip') or t:find('follow') or t:find('ignore') then B.answer('declined'); return 'Not following it; the dive goes on.' end
  if t:find('later') then B.answer('later'); return 'Left unresolved; the dive goes on.' end
  return 'I could not tell. Name a repo (number, name or path), or say external, skip or later.'
end

-- ---------- after the dive: status changes and "specify repo" ----------
function B.mark(id, status)
  if G.waiting == id then return B.answer(status) end
  local st = G.steps[id]
  if not st or st.kind ~= 'boundary' then return end
  local info = B.info[id] or { hist = {} }
  B.info[id] = info
  info.hist[#info.hist + 1] = 'marked ' .. status .. ' (was ' .. st.boundary.status .. ')'
  st.boundary.status = status
  emit('graph')
end

function B.reopen(id)
  local st = G.steps[id]
  if not st then return end
  if st.resolved then
    vim.notify('Deep dive: “' .. st.title .. '” was resolved into ' .. st.resolved.repo .. '. Reopening it = a Revision proposal that removes those Steps (not prototyped).', vim.log.levels.INFO)
    return
  end
  if st.kind ~= 'boundary' or st.boundary.status == 'unresolved' then return end
  local info = B.info[id] or { hist = {} }
  B.info[id] = info
  info.hist[#info.hist + 1] = 'reopened (was ' .. st.boundary.status .. ')'
  st.boundary.status = 'unresolved'
  emit('graph')
end

local nprop = 0
function B.specify(id, repo)
  if G.waiting == id then return B.answer('repo', repo) end
  local st = G.steps[id]
  if not st or st.kind ~= 'boundary' then return end
  if C.fix or C.pending then vim.notify('Deep dive: a Fix run is in progress; try again after it', vim.log.levels.WARN) return end
  local info = B.info[id] or { hist = {} }
  B.info[id] = info
  nprop = nprop + 1
  local ok = info.expect == repo.id and EXT[id] ~= nil
  local p = { id = 'S' .. nprop, n = nprop, kind = 'extension', target = id, bd = true, ver = 1, status = 'fixing',
    scope = '“' .. st.title .. '” + ' .. repo.id, reason = 'You said ' .. repo.id .. ' (' .. B.short(repo.path) .. ') serves ' .. st.boundary.target .. '.',
    evidence = info.evidence or {}, q = 'specify repo: ' .. repo.id }
  C.proposals[#C.proposals + 1] = p
  p.run = function(f)
    local items = { { (ws(repo.id) and 'Workspace: ' .. repo.id .. ' registered' or 'Workspace + ' .. repo.id .. ' (on accept)'), '·' },
      { 'agent session with --add-dir ' .. B.short(repo.path) .. ', scope: ' .. p.scope, '·' } }
    if not ok then
      items[#items + 1] = { 'reading ' .. repo.id .. ': nothing serves ' .. st.boundary.target, '✗', 'DiagnosticError', 900 }
      return C.chain(f, items, function()
        info.hist[#info.hist + 1] = repo.id .. ' did not serve it (extension run abandoned)'
        p.status = 'abandoned'
        C.fix = nil
        C.emit('graph')
        vim.notify('Deep dive: ' .. repo.id .. ' does not serve ' .. st.boundary.target .. '; Boundary stays ' .. st.boundary.status, vim.log.levels.WARN)
      end)
    end
    for _, l in ipairs(EXT[id].log) do items[#items + 1] = { l, '·' } end
    items[#items + 1] = { 'Validator ✓   Critic: agree, no open Risks', '✓', 'DiagnosticOk', 800 }
    C.chain(f, items, function()
      local n = #C.revisions + 1
      C.pending = { n = n, kind = 'extension', reason = p.reason .. ' Replaces the Boundary with ' .. repo.id .. '’s Steps.', p = p, q = p.q,
        ops = ext_ops(id, repo), apply = function()
          register(repo)
          info.hist[#info.hist + 1] = 'resolved → ' .. repo.id .. ' (r' .. n .. ')'
          apply(id, 'r' .. n)
        end }
      f.state = 'pending'
      C.ov = { pending = true }
      C.fixlog(f, 'Pending revision r' .. n .. ' ready for review', '✓', 'DiagnosticOk')
      C.emit('graph')
    end)
  end
  C.start_fix(p)
end

-- ---------- shared text (content, not layout) ----------
function B.render_dive(c, w, ind, compact)
  ind = ind or ' '
  local parts = {}
  for _, s in ipairs(B.dive.stages) do
    local mk = s.st == 'done' and '✓' or (s.st == 'paused' and '⏸' or '⟳')
    parts[#parts + 1] = s.title .. ' ' .. mk
  end
  local head = ({ paused = '⏸ dive paused', running = '⟳ dive running', done = '✓ dive done' })[B.dive.state]
  local r = c.add(ind .. head .. '   ' .. table.concat(parts, '  ›  '), B.dive.state == 'paused' and 'DDRevChg' or (B.dive.state == 'running' and 'DiagnosticInfo' or 'DiagnosticOk'))
  c.hl(r, 'Comment', vim.fn.strchars(ind .. head) + 3)
  if compact then return end
  c.add('')
  for _, l in ipairs(B.dive.log) do
    local lines = C.wrap(l.text, w - 6 - vim.fn.strchars(ind))
    for i, t in ipairs(lines) do
      local icon = i == 1 and l.icon or ' '
      local rr = c.add(ind .. (icon == 'you' and 'you ' or (icon .. '   ')) .. t, l.hl)
      if i == 1 and icon == 'you' then c.hl(rr, 'DDYou', vim.fn.strchars(ind), vim.fn.strchars(ind) + 3) end
    end
  end
  if B.dive.state == 'running' then c.add(ind .. '⟳   …', 'DiagnosticInfo') end
end

-- the question + numbered repo choices; returns the candidate list (row -> candidate in c.cands)
function B.render_question(c, w, ind, keys)
  ind = ind or ' '
  local q = B.q
  if not q then return end
  local id = q.step
  c.cands = c.cands or {}
  local r = c.add(ind .. '⏸ ' .. G.steps[id].title .. '  ·  the dive waits for you', 'DDRevChg')
  for _, l in ipairs(C.wrap(q.text, w - 4 - vim.fn.strchars(ind))) do c.add(ind .. '  ' .. l) end
  local info = B.info[id] or {}
  if info.guess and info.guess.kind == 'external' then
    c.add(ind .. '  agent suggests  ↗ external · ' .. info.guess.why, 'DiagnosticHint')
  end
  B.render_cands(c, id, w, ind .. '  ')
  if keys then c.add(ind .. '  ' .. keys, 'DDKeyHint') end
  return r
end
local function U_trunc(s, n)
  if vim.fn.strdisplaywidth(s) <= n then return s end
  return vim.fn.strcharpart(s, 0, n - 1) .. '…'
end
function B.render_cands(c, id, w, ind)
  c.cands = c.cands or {}
  local list = B.candidates(id)
  for i, cd in ipairs(list) do
    local s = string.format('%s%d %s %-16s %-28s %s', ind, i, cd.star and '★' or ' ', cd.id, B.short(cd.path), cd.where)
    local r = c.add(s)
    c.hl(r, 'DDKey', vim.fn.strchars(ind), vim.fn.strchars(ind) + 1)
    c.hl(r, 'Title', vim.fn.strchars(ind) + 4, vim.fn.strchars(ind) + 20)
    c.hl(r, 'Comment', vim.fn.strchars(ind) + 21)
    c.cands[r] = cd
    if cd.why then c.add(ind .. '      ' .. U_trunc(cd.why, w - 8 - vim.fn.strchars(ind)), 'DDNote') end
  end
  return list
end
-- the Boundary's own facts: target, status, why, evidence, history
function B.render_facts(c, id, w, ind)
  ind = ind or ' '
  local st = G.steps[id]
  local s = B.status(id)
  local info = B.info[id] or {}
  local function row(label, text, hl)
    for i, l in ipairs(C.wrap(text, w - 12 - vim.fn.strchars(ind))) do
      local r = c.add(ind .. (i == 1 and string.format('%-9s', label) or string.rep(' ', 9)) .. ' ' .. l, hl)
      if i == 1 then c.hl(r, 'Comment', vim.fn.strchars(ind), vim.fn.strchars(ind) + 9) end
    end
  end
  if st.resolved then
    row('was', '⇢ boundary · ' .. st.resolved.transport .. ' · ' .. st.resolved.target, 'Comment')
    row('now', '▣ ' .. #G.children(id) .. ' Steps in ' .. st.resolved.repo .. (st.resolved.via == 'dive' and ' · resolved during the dive' or (' · Revision ' .. st.resolved.via)), 'DiagnosticOk')
  else
    row('target', st.boundary.transport .. ' · ' .. st.boundary.target)
    local lb = B.LABEL[s]
    row('status', lb[1], lb[2])
  end
  if info.why then row('why', info.why, 'Normal') end
  for i, a in ipairs(info.evidence or {}) do
    local r = c.add(ind .. (i == 1 and string.format('%-9s', 'evidence') or string.rep(' ', 9)) .. ' ↗ ' .. C.astr(a), 'Comment')
    c.hl(r, 'DDCite', vim.fn.strchars(ind) + 12)
    c.cites[r] = a
  end
  for i, h in ipairs(info.hist or {}) do row(i == 1 and 'history' or '', '· ' .. h, 'Comment') end
end

return B
