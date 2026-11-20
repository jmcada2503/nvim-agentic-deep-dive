-- PROTOTYPE (throwaway): three radically different layouts for Boundaries, the dive's needs_input pause and
-- "specify repo", on top of the Q&A variant A conventions (tabs in the details pane, prompt + hint bar, badges).
-- Tabs are always Info · Ask · Run · Revs; Run holds the staged dive and any Fix run. ⇥ graph <-> tab, t / T cycle.
--   A  Info + Run          the Boundary's facts and choices live in its Info tab; the dive log + question sit in
--                           Run; specify repo = the prompt, prefilled with the agent's guess (^X^F completes)
--   B  Inbox in Run         Run lists every Boundary by status (needs you / unresolved / settled);
--                           moving the cursor walks the map; specify repo = a picker float
--   C  On the map           a dotted "far side" ghost next to each Boundary box; the question is a card under the
--                           box; specify repo picks inside the card; the dive streams into the card
-- Switch: [v / ]v in the panel, or ␣dv / ␣dV anywhere. All three drive the same scripted state (bd_core.lua).
local P = require('deepdive_proto')
local U = P._
local C = require('deepdive_proto.qa_core')
local V = require('deepdive_proto.qa_views')
local B = require('deepdive_proto.bd_core')
local G = U.G
local api = vim.api
local QA = V.A
local X = V.api
local chip, esc, valid, bmap = X.chip, X.esc, X.valid, X.bmap
local BV = { i = 1 }

-- ---------- shared helpers ----------
local function sel() return U.S.sel end
local function sel_bd() local s = sel(); if B.status(s) then return s end end
local function title(id) return G.steps[id].title end
local function gsync() X.gsync() end
local function warn(msg) vim.notify('Deep dive: ' .. msg, vim.log.levels.INFO) end
local function open_status(id) local s = B.status(id); return s == 'unresolved' or s == 'waiting' or s == 'external' or s == 'declined' end
local function pick(id, cd)
  if not cd then return end
  B.specify(id, { id = cd.id, path = cd.path })
end
local function pick_n(id, n)
  if not id or not open_status(id) then return warn('select a Boundary (⇢) first') end
  pick(id, B.candidates(id)[n])
end
local function with_path(id, text)
  local r, err = B.from_path(text)
  if not r then return warn(err) end
  B.specify(id, r)
end
local function ask_path(id)
  local info = B.info[id] or {}
  local def = info.guess and info.guess.kind == 'repo' and info.guess.path or (G.root .. '/')
  vim.ui.input({ prompt = 'Repo serving ' .. (G.steps[id].boundary and G.steps[id].boundary.target or title(id)) .. ': ', default = def, completion = 'dir' },
    function(s) if s and s ~= '' then with_path(id, s) end end)
end
local function mark(id, status)
  if not id then return warn('select a Boundary (⇢) first') end
  local s = B.status(id)
  if s == 'resolved' then return warn('“' .. title(id) .. '” is already resolved; u to reopen') end
  B.mark(id, status)
end
local function later() if B.q then B.answer('later') else warn('the dive is not waiting') end end
local function reopen(id) if id then B.reopen(id) else warn('select a Boundary (⇢) first') end end
local function every_bd()
  local out = {}
  for _, s in ipairs(G.list) do if B.status(s.id) then out[#out + 1] = s.id end end
  return out
end
local function where(id)
  local a = G.ancestors(id)
  return #a == 0 and 'root' or title(a[#a])
end
local function status_chips(id, s, n, path_label)
  if s == 'waiting' then
    return chip('1-' .. n, 'pick') .. chip('s', path_label) .. chip('e', 'external') .. chip('S', 'don’t follow') .. chip('L', 'later')
  elseif s == 'unresolved' then
    return chip('1-' .. n, 'pick') .. chip('s', path_label) .. chip('e', 'external') .. chip('S', 'don’t follow')
  elseif s == 'external' or s == 'declined' then
    return chip('u', 'reopen') .. chip('s', path_label)
  elseif s == 'resolved' then
    return chip('u', 'reopen') .. chip('⏎', 'zoom in')
  elseif s == 'pending' then
    return chip('y', 'accept') .. chip('R', 'reject + note')
  end
  return ''
end
local function status_left(id, s)
  local lb = B.LABEL[s]
  local short = ({ waiting = '⏸ dive waits', reading = '⟳ dive reading', extending = '⟳ extension run', pending = '● review',
    unresolved = '⚠ boundary', external = '↗ external', declined = '⊘ declined', resolved = '✓ resolved' })[s]
  return '%#' .. lb[2] .. '# ' .. short .. ' %#Normal# ' .. esc(U.trunc(title(id), 26)) .. '  '
end

local function run_name(t)
  if t ~= 'fix' or C.fix or C.pending then return nil end
  return 'Run' .. ({ paused = ' ⏸', running = ' ⟳', done = '' })[B.dive.state]
end

-- =====================================================================
-- A: Info + Run, answers through the prompt
-- =====================================================================
local VA = { key = 'A', name = 'Info + Run (prompt)' }
local function va_id()
  if QA.tab == 'fix' then return B.q and B.q.step end
  return sel_bd()
end
local function va_specify(id)
  id = id or va_id() or sel_bd()
  if not id then return warn('select a Boundary (⇢) first') end
  if not open_status(id) then return warn('“' .. title(id) .. '” is ' .. B.status(id)) end
  if sel() ~= id then U.select(id) end
  local info = B.info[id] or {}
  local pre = info.guess and info.guess.kind == 'repo' and info.guess.path or (G.root .. '/')
  X.prompt(QA.tab == 'fix' and 'fix' or 'details', {
    label = 'repo path for “' .. U.trunc(title(id), 22) .. '”', chips = chip('^X^F', 'complete'),
    send = function(text) with_path(id, text) end }, pre)
end
VA.extra = {
  tabname = run_name,
  has_prompt = function(t) if t == 'details' and sel_bd() then return true end end,
  tall = function(t) return t == 'details' and sel_bd() ~= nil end,
  render = function(t, c, w)
    if t == 'fix' then
      -- a review reads top-down; a running Fix run or the dive log follows its newest line
      if C.pending then X.render_fix(c, w); c.add('') end
      B.render_dive(c, w, ' ', C.fix ~= nil)
      if B.q then c.add(''); B.render_question(c, w, ' ') end
      if C.fix and not C.pending then c.add(''); X.render_fix(c, w) end
      return true
    end
    local id = t == 'details' and sel_bd()
    if not id then return false end
    local lines, hls = U.describe(id)
    for _, l in ipairs(lines) do c.add(l) end
    for _, h in ipairs(hls) do c.hls[#c.hls + 1] = h end
    c.add('')
    c.add(' ⇢ BOUNDARY', 'DiagnosticWarn')
    B.render_facts(c, id, w, '   ')
    local s = B.status(id)
    if s == 'waiting' then
      c.add(''); B.render_question(c, w, ' ')
    elseif s == 'unresolved' or s == 'external' or s == 'declined' then
      c.add('')
      c.add('   specify repo: a number, or s to type a path', 'Comment')
      B.render_cands(c, id, w, '   ')
    elseif s == 'reading' then
      c.add(''); c.add('   ⟳ the dive is reading it: see the Run tab', 'DiagnosticInfo')
    elseif s == 'extending' or s == 'pending' then
      c.add(''); c.add('   ' .. B.LABEL[s][1] .. ': see the Run tab', B.LABEL[s][2])
    end
    return true
  end,
  hint = function(t, insert)
    if insert then return nil end
    if t == 'fix' and (C.fix or C.pending) then return nil end
    if t == 'fix' and not B.q then
      if B.dive.state == 'running' then return '%#DiagnosticInfo# ⟳ dive running %#Normal# ', chip('⇥', 'graph') end
      return '%#DiagnosticOk# ✓ dive done %#Normal# ', chip('t', 'next tab') .. chip('⇥', 'graph')
    end
    local id = va_id()
    if not id or (t ~= 'fix' and t ~= 'details') then return nil end
    local s = B.status(id)
    return status_left(id, s), status_chips(id, s, #B.candidates(id), 'type path') .. chip('⇥', 'graph')
  end,
}
local function va_goto()
  if not G.waiting then return warn('the dive is not waiting') end
  U.select(G.waiting)
  X.tab('fix')
end
VA.keys = {
  s = va_specify, r = va_specify,
  e = function() mark(va_id() or sel_bd(), 'external') end,
  S = function() mark(va_id() or sel_bd(), 'declined') end,
  L = later, u = function() reopen(sel_bd()) end, b = va_goto, B = va_goto,
}
VA.dkeys = vim.tbl_extend('force', {}, VA.keys)
for n = 1, 9 do VA.dkeys[tostring(n)] = function() pick_n(va_id(), n) end end
VA.pkeys = VA.dkeys -- the prompt buffer, in normal mode
function VA.render(what)
  if B.q and VA.seen ~= B.q then
    if U.panel_open() then VA.seen = B.q; U.select(B.q.step); X.tab('fix') else QA.tab = 'fix' end
  end
  if C.fix and C.fix.p.bd and VA.fixseen ~= C.fix.p then VA.fixseen = C.fix.p; X.tab('fix') end
end
VA.help = {
  { 'BOUNDARY (A: Info + Run)' }, { 's', 'specify repo: prompt, prefilled' }, { '1-9', 'pick a listed repo (pane)' },
  { 'e', 'mark external' }, { 'S', 'don’t follow (declined)' }, { 'L', 'later (dive goes on)' }, { 'u', 'reopen' },
  { 'b', 'go to the waiting Boundary' },
}

-- =====================================================================
-- B (chosen): Run = what the agent is doing or waiting on, for the whole dive
--   strip · NEEDS YOU (dive question, Pending revision, stuck Fix run) · IN PROGRESS (Fix run, Boundary being read)
--   · UNRESOLVED · SETTLED · facts of the selected Boundary.  The prompt talks to the focused run.
-- =====================================================================
local VB = { key = 'B', name = 'Run: needs you + Boundaries', rows = {}, heads = {}, chats = {}, seen_t = {} }
local ICON = { waiting = '⏸', reading = '⟳', extending = '⟳', pending = '●', unresolved = '⚠', external = '↗', declined = '⊘', resolved = '✓' }
local BSECT = { { 'UNRESOLVED', { unresolved = 1 } }, { 'SETTLED', { external = 1, declined = 1, resolved = 1 } } }

-- ---------- run items: what an agent is doing or waiting on ----------
local function stamp(key) VB.seen_t[key] = VB.seen_t[key] or vim.uv.hrtime(); return VB.seen_t[key] end
local function run_items()
  local needs, prog = {}, {}
  if B.q then needs[#needs + 1] = { key = 'q:' .. B.q.step, kind = 'question', step = B.q.step, run = true } end
  if C.pending then
    needs[#needs + 1] = { key = 'pend:' .. C.pending.n, kind = 'pending', step = C.pending.p.target, run = true }
  elseif C.fix and C.fix.state == 'failed' then
    needs[#needs + 1] = { key = 'fix:' .. C.fix.p.id, kind = 'stuck', step = C.fix.p.target, run = true }
  elseif C.fix then
    prog[#prog + 1] = { key = 'fix:' .. C.fix.p.id, kind = 'running', step = C.fix.p.target, run = true }
  end
  for _, it in ipairs(needs) do it.t = stamp(it.key) end
  table.sort(needs, function(a, b) return a.t < b.t end) -- oldest first
  return needs, prog
end
local function row_item()
  if QA.tab ~= 'fix' or not valid(U.W.det) then return nil end
  return VB.rows[api.nvim_win_get_cursor(U.W.det)[1] - 1]
end
-- focus: the cursor row in the pane; the selection from the graph; otherwise the oldest
local function focus_run()
  local needs, prog = run_items()
  local all = vim.list_extend(vim.list_extend({}, needs), prog)
  if #all == 0 then return nil end
  if U.panel_open() and api.nvim_get_current_win() ~= U.W.main then
    local r = row_item()
    if r and r.run then for _, it in ipairs(all) do if it.key == r.key then return it end end end
  end
  for _, it in ipairs(all) do if it.step == sel() then return it end end
  return all[1]
end
-- single keys on a row: the row's Boundary, else the selected one
local function vb_id()
  local r = row_item()
  if r and r.step and B.status(r.step) then return r.step end
  return sel_bd()
end

-- ---------- inline chat under an item ----------
local function chat(key) VB.chats[key] = VB.chats[key] or {}; return VB.chats[key] end
local function say(key, who, text) table.insert(chat(key), { who = who, text = text }); C.emit('thread') end
local function render_chat(c, key, w)
  local ch = VB.chats[key]
  if not ch or #ch == 0 then return end
  local from = math.max(1, #ch - 3)
  if from > 1 then c.add('     ╶ ' .. (from - 1) .. ' earlier', 'Comment') end
  for k = from, #ch do
    local m = ch[k]
    local lab = m.who == 'you' and 'you  ' or 'agent'
    for i, l in ipairs(C.wrap(m.text, w - 14)) do
      local r = c.add('     ' .. (i == 1 and lab or '     ') .. '  ' .. l, m.who == 'you' and 'DDYouText' or nil)
      if i == 1 then c.hl(r, m.who == 'you' and 'DDYou' or 'DDAgent', 5, 10) end
    end
  end
end

-- ---------- the picker (specify repo) ----------
function VB.picker(id)
  id = id or vb_id()
  if not id then return warn('select a Boundary (⇢) first') end
  if not open_status(id) then return warn('“' .. title(id) .. '” is ' .. B.status(id)) end
  local list = B.candidates(id)
  local st = G.steps[id]
  local c = C.canvas()
  local rows = {}
  local width = 84
  if B.q and B.q.step == id then
    for _, l in ipairs(C.wrap(B.q.text, width - 4)) do c.add('  ' .. l, 'DDRevChg') end
    c.add('')
  end
  for i, cd in ipairs(list) do
    local r = c.add(string.format('  %d %s %-16s %-30s %s', i, cd.star and '★' or ' ', cd.id, B.short(cd.path), cd.where))
    c.hl(r, 'DDKey', 2, 3); c.hl(r, 'Title', 6, 22); c.hl(r, 'Comment', 23)
    rows[r] = cd
    if cd.why then c.add('        ' .. U.trunc(cd.why, width - 10), 'DDNote') end
  end
  local rp = c.add('  p   type a path…')
  c.hl(rp, 'DDKey', 2, 3)
  rows[rp] = 'path'
  c.add('')
  c.add('  ⏎ pick · p path · e external · S don’t follow' .. (B.q and B.q.step == id and ' · L later' or '') .. ' · q close', 'DDKeyHint')
  local buf = X.scratch('deepdive://bd-picker')
  vim.bo[buf].modifiable = true
  U.put(buf, c.lines, c.hls)
  local win = api.nvim_open_win(buf, true, { relative = 'editor', width = width, height = #c.lines,
    row = math.floor((vim.o.lines - #c.lines) / 2) - 1, col = math.max(0, vim.o.columns - width - 6),
    style = 'minimal', border = 'rounded', title = ' specify repo · ' .. (st.boundary and st.boundary.target or title(id)) .. ' ', title_pos = 'center' })
  vim.wo[win].cursorline = true
  local first
  for r in pairs(rows) do if not first or r < first then first = r end end
  api.nvim_win_set_cursor(win, { (first or 0) + 1, 0 })
  local function close() if valid(win) then api.nvim_win_close(win, true) end end
  local function choose(v)
    close()
    if v == 'path' then ask_path(id) elseif v then pick(id, v) end
  end
  bmap(buf, '<CR>', function() choose(rows[api.nvim_win_get_cursor(0)[1] - 1]) end)
  for n = 1, 9 do bmap(buf, tostring(n), function() if list[n] then choose(list[n]) end end) end
  bmap(buf, 'p', function() choose('path') end)
  bmap(buf, 'e', function() close(); mark(id, 'external') end)
  bmap(buf, 'S', function() close(); mark(id, 'declined') end)
  bmap(buf, 'L', function() close(); later() end)
  bmap(buf, 'q', close); bmap(buf, '<Esc>', close)
end

-- ---------- Run tab ----------
local function bd_row(c, id, w)
  local s = B.status(id)
  local st = G.steps[id]
  local tgt = st.boundary and st.boundary.target or ('→ ' .. st.resolved.repo .. ' · ' .. #G.children(id) .. ' Steps')
  local r = c.add(string.format('  %s %-26s %-40s in %s', ICON[s], U.trunc(st.title, 26), U.trunc(tgt, 40), where(id)))
  c.hl(r, B.LABEL[s][2], 2, 3)
  c.hl(r, id == sel() and 'Visual' or 'Normal', 4, 30)
  c.hl(r, 'Comment', 31)
  if s == 'reading' then
    local l = B.dive.log[#B.dive.log]
    c.add('     ⟳ ' .. U.trunc(l and l.text or '', w - 8), 'DiagnosticInfo')
  end
end
local function item_hint(it, insert)
  local left
  if it.kind == 'question' then left = '%#DDRevChg# ⏸ answer the dive %#Normal# ' .. esc(U.trunc(title(it.step), 24)) .. '  '
  elseif it.kind == 'pending' then left = '%#DDRevChg# ● r' .. C.pending.n .. ' %#Normal# ask about it  '
  elseif it.kind == 'stuck' then left = '%#DiagnosticError# ✗ ' .. C.fix.p.id .. ' stuck %#Normal# clarify  '
  else left = '%#DiagnosticInfo# ⟳ ' .. C.fix.p.id .. ' %#Normal# ask it  ' end
  if insert then return left, chip('⏎', 'send') .. chip('⇥', 'graph') .. chip('Esc', 'keys') end
  local right
  if it.kind == 'question' then
    right = chip('1-' .. #B.candidates(it.step), 'pick') .. chip('s', 'picker') .. chip('e', 'external') .. chip('S', 'don’t follow') .. chip('L', 'later')
  elseif it.kind == 'pending' then
    right = chip('y', 'accept') .. chip('R', 'reject + note') .. chip('x', 'reject')
  elseif it.kind == 'stuck' then
    right = chip('H', 'hint + retry') .. chip('W', 'widen') .. chip('X', 'abandon')
  else right = '' end
  return left, right .. chip('i', 'type') .. chip('⇥', 'graph')
end
VB.extra = {
  tabname = run_name,
  has_prompt = function(t)
    if t ~= 'fix' then return nil end
    local n, p = run_items()
    return #n + #p > 0
  end,
  tall = function() return false end,
  top = function(t) if t == 'fix' then return true end end,
  render = function(t, c, w)
    if t ~= 'fix' then return false end
    VB.rows, VB.heads = {}, {}
    local function mapr(from, item) for k = from, #c.lines - 1 do VB.rows[k] = item end end
    B.render_dive(c, w, ' ', true)
    local needs, prog = run_items()
    if #needs > 0 then
      c.add(''); c.add(' NEEDS YOU', 'Title')
      for i, it in ipairs(needs) do
        if i > 1 then c.add('') end
        local from = #c.lines
        VB.heads[it.key] = from
        if it.kind == 'question' then
          c.add('  ⏸ ' .. title(it.step) .. '  ·  the dive waits for you  ·  in ' .. where(it.step), 'DDRevChg')
          for _, l in ipairs(C.wrap(B.q.text, w - 8)) do c.add('     ' .. l) end
          local info = B.info[it.step] or {}
          if info.guess and info.guess.kind == 'external' then c.add('     agent suggests  ↗ external · ' .. info.guess.why, 'DiagnosticHint') end
          B.render_cands(c, it.step, w, '     ')
        elseif it.kind == 'pending' then
          c.add('  ● review  ·  on “' .. title(it.step) .. '”', 'DDRevChg')
          C.render_review(c, w, '     ', nil)
        else
          c.add('  ✗ Fix run ' .. C.fix.p.id .. ' stuck  ·  attempt ' .. C.fix.attempt .. '  ·  on “' .. title(it.step) .. '”', 'DiagnosticError')
          C.render_fix(c, C.fix, w, '     ', ' ')
        end
        render_chat(c, it.key, w)
        mapr(from, it)
      end
    end
    local reading = vim.tbl_filter(function(id) return B.status(id) == 'reading' end, every_bd())
    if #prog + #reading > 0 then
      c.add(''); c.add(' IN PROGRESS', 'Title')
      for _, it in ipairs(prog) do
        local from = #c.lines
        VB.heads[it.key] = from
        c.add('  ⟳ Fix run ' .. C.fix.p.id .. '  ·  on “' .. title(it.step) .. '”  ·  scope ' .. C.fix.p.scope, 'DiagnosticInfo')
        C.render_fix(c, C.fix, w, '     ')
        render_chat(c, it.key, w)
        mapr(from, it)
      end
      for _, id in ipairs(reading) do
        local from = #c.lines
        bd_row(c, id, w)
        mapr(from, { key = 'bd:' .. id, step = id })
      end
    end
    for _, sec in ipairs(BSECT) do
      local mine = vim.tbl_filter(function(id) return sec[2][B.status(id)] end, every_bd())
      if #mine > 0 then
        c.add(''); c.add(' ' .. sec[1], 'Title')
        for _, id in ipairs(mine) do
          local from = #c.lines
          bd_row(c, id, w)
          mapr(from, { key = 'bd:' .. id, step = id })
        end
      end
    end
    local cur = sel_bd()
    if cur then
      c.add('')
      c.add(' ' .. string.rep('─', w - 2), 'DDDim')
      c.add(' ⇢ ' .. title(cur), 'DiagnosticWarn')
      B.render_facts(c, cur, w, ' ')
    end
    return true
  end,
  hint = function(t, insert)
    if t ~= 'fix' then return nil end
    local it = focus_run()
    if not it then return nil end
    VB.fkey = it.key
    return item_hint(it, insert)
  end,
  -- the Boundary row under the cursor: its keys, in the pane's status line
  statusline = function(t)
    if t ~= 'fix' then return nil end
    local r = row_item()
    local id = not (r and r.run) and vb_id()
    if not id then return '%#DDMode# RUN %#Normal#%=' .. chip('j k', 'walk') .. chip('⇥', 'graph') end
    local s = B.status(id)
    return status_left(id, s) .. '%=' .. status_chips(id, s, #B.candidates(id), 'picker') .. chip('j k', 'walk')
  end,
  -- free text in Run's prompt goes to the focused run
  send = function(t, text)
    if t ~= 'fix' then return false end
    local it = focus_run()
    if not it then return false end
    if it.kind == 'stuck' then C.clarify(text); return true end
    say(it.key, 'you', text)
    if it.kind == 'question' then
      local key = it.key
      vim.defer_fn(function()
        local reply = B.answer_text(text)
        if reply and B.q and ('q:' .. B.q.step) == key then say(key, 'agent', reply) end
      end, 400)
    elseif it.kind == 'pending' then
      local pr = C.pending
      vim.defer_fn(function()
        if C.pending ~= pr then return end
        say(it.key, 'agent', 'r' .. pr.n .. ' makes ' .. #pr.ops .. ' change' .. (#pr.ops > 1 and 's' or '') ..
          ' because: ' .. pr.reason .. ' If that is wrong, R rejects it with your note as feedback.')
      end, 600)
    else
      vim.defer_fn(function()
        local l = C.fix and C.fix.log[#C.fix.log]
        say(it.key, 'agent', 'Still running. Last step: ' .. (l and l.text or '…') .. '. Your note does not change the run.')
      end, 500)
    end
    return true
  end,
}

-- jump the pane cursor (and the graph) to an item; enter = focus the pane
local function go_item(key, step, enter)
  if not U.panel_open() then return end
  if step and sel() ~= step then U.select(step) end
  X.tab('fix')
  local r = VB.heads[key]
  if r then pcall(api.nvim_win_set_cursor, U.W.det, { r + 1, 0 }) end
  if enter then api.nvim_set_current_win(U.W.det) end
  X.arm()
  X.redraw()
  VB.snap = key
end
VB.extra.goto_pending = function() if C.pending then go_item('pend:' .. C.pending.n, C.pending.p.target, true) end end
-- a dive pause: open the panel on Run, focused on the question; never while you are typing
local function jump_to_pause()
  local q = B.q
  if not q then return end
  if vim.fn.mode():match('^[iR]') then
    if VB.wait_insert then return end
    VB.wait_insert = true
    api.nvim_create_autocmd('InsertLeave', { once = true, callback = function()
      VB.wait_insert = false
      vim.schedule(jump_to_pause)
    end })
    return
  end
  if not U.panel_open() then P.open() end
  go_item('q:' .. q.step, q.step, true)
end
local function vb_open()
  if B.q then return go_item('q:' .. B.q.step, B.q.step, true) end
  X.tab('fix')
  if U.panel_open() then api.nvim_set_current_win(U.W.det) end
end
VB.keys = {
  s = function() if sel_bd() then VB.picker(sel_bd()) else vb_open() end end,
  e = function() mark(sel_bd(), 'external') end, S = function() mark(sel_bd(), 'declined') end,
  L = later, u = function() reopen(sel_bd()) end,
  b = vb_open, B = vb_open,
}
VB.keys.r = VB.keys.s
VB.dkeys = {
  s = function() VB.picker(vb_id()) end, e = function() mark(vb_id(), 'external') end,
  S = function() mark(vb_id(), 'declined') end, L = later, u = function() reopen(vb_id()) end,
  b = vb_open,
}
for n = 1, 9 do VB.dkeys[tostring(n)] = function() pick_n(vb_id(), n) end end
-- walking the list walks the map
local function vb_preview()
  if BV.cur() ~= VB or QA.tab ~= 'fix' or not U.panel_open() or api.nvim_get_current_win() ~= U.W.det then return end
  if not X.moved() then return end
  local it = row_item()
  if it and it.step and it.step ~= sel() then
    local cur = api.nvim_win_get_cursor(U.W.det)
    U.S.sel, U.S.port, U.S.overlay = it.step, nil, nil
    U.sync { nojump = true }
    pcall(api.nvim_win_set_cursor, U.W.det, cur)
  end
  vim.wo[U.W.det].statusline = VB.extra.statusline('fix')
  X.hintbar()
  VB.snap = VB.fkey
end
function VB.on_open()
  if VB.au then return end
  VB.au = api.nvim_create_autocmd('CursorMoved', { buffer = U.W.dbuf, callback = function() vim.schedule(vb_preview) end })
end
function VB.render()
  local paused = false
  if B.q and VB.seen ~= B.q then
    VB.seen = B.q
    paused = true
    vim.schedule(jump_to_pause)
  end
  -- the focused item was resolved: move to the next one that needs you, the graph follows
  local needs = run_items()
  local live = {}
  for _, it in ipairs(needs) do live[it.key] = true end
  -- (VB.snap: the focus as it was after the last render / cursor move; the hint bar may already have moved VB.fkey)
  local f = VB.snap
  if f and not live[f] then
    if not paused and #needs > 0 and U.panel_open() then -- a new dive question jumps by itself
      local it = needs[1]
      vim.schedule(function() go_item(it.key, it.step, api.nvim_get_current_win() == U.W.det) end)
    end
    VB.snap = nil
  else
    VB.snap = VB.fkey
  end
end
VB.help = {
  { 'RUN TAB' }, { 'b', 'Run, on what needs you' }, { 'j k', 'walk (map follows)' }, { 'i', 'type to the focused run' },
  { 's', 'specify repo: picker' }, { '1-9', 'pick a listed repo' }, { 'e', 'mark external' }, { 'S', 'don’t follow (declined)' },
  { 'L', 'later' }, { 'u', 'reopen' },
}

-- =====================================================================
-- C: on the map: far-side ghosts + an answer card under the Boundary box
-- =====================================================================
local VC = { key = 'C', name = 'On the map (ghost + card)', ghosts = {} }
VC.extra = {
  tabname = run_name,
  has_prompt = function() end,
  tall = function() return false end,
  hint = function() return nil end,
  render = function(t, c, w)
    if t ~= 'fix' or C.fix or C.pending then return false end
    B.render_dive(c, w, ' ')
    if B.q then c.add(''); c.add(' ⏸ the dive waits at “' .. title(B.q.step) .. '”: answer on the map (b)', 'DDRevChg') end
    return true
  end,
}
local DOTTED = { '┌', '┄', '┐', '┆', '┘', '┄', '└', '┆' }
local function vc_close_ghosts()
  for _, w in ipairs(VC.ghosts) do if valid(w) then pcall(api.nvim_win_close, w, true) end end
  VC.ghosts = {}
end
local function vc_close_card()
  if valid(VC.cw) then api.nvim_win_close(VC.cw, true) end
  VC.cw, VC.cid = nil, nil
end
local function on_level(id) return G.steps[id] and G.steps[id].parent == G.steps[sel()].parent end
local function ghost_lines(id)
  local s = B.status(id)
  local st = G.steps[id]
  local L = {}
  if s == 'resolved' then
    L = { { '⇢✓ ' .. st.resolved.repo, 'DiagnosticOk' }, { 'was ' .. U.trunc(st.resolved.target, 30), 'Comment' } }
  elseif s == 'waiting' then
    L = { { '⏸ far side: ?', 'DDRevChg' }, { U.trunc(st.boundary.target, 34), 'Comment' }, { 'the dive asks you below', 'DDRevChg' } }
  elseif s == 'reading' then
    L = { { '⟳ reading the far side…', 'DiagnosticInfo' } }
    local n = #B.dive.log
    for k = math.max(1, n - 1), n do L[#L + 1] = { U.trunc(B.dive.log[k].text, 34), 'Comment' } end
  elseif s == 'extending' or s == 'pending' then
    L = { { B.LABEL[s][1], B.LABEL[s][2] }, { C.pending and ('y accept · R reject+note · x reject') or '…', 'DDKeyHint' } }
  elseif s == 'unresolved' then
    L = { { '? far side unknown', 'DiagnosticWarn' }, { U.trunc(st.boundary.target, 34), 'Comment' }, { 's repo · e external · S skip', 'DDKeyHint' } }
  elseif s == 'external' then
    L = { { '↗ external · third party', 'Comment' }, { 'not followed · u reopen · s repo', 'DDKeyHint' } }
  elseif s == 'declined' then
    L = { { '⊘ not followed', 'Comment' }, { 'u reopen · s repo', 'DDKeyHint' } }
  end
  return L
end
local function vc_ghosts()
  vc_close_ghosts()
  if BV.cur() ~= VC or not U.panel_open() or U.S.mode ~= 'map' or not (U.S.meta and U.S.meta.box) then return end
  local parent = G.steps[sel()].parent
  local Lay = G.layout(parent)
  for _, id in ipairs(Lay.ids) do
    local s = B.status(id)
    if s and s ~= 'resolved' then
      -- to the right of the rightmost box in the Boundary's layer, so it never covers a sibling
      local right, b = 0, U.S.meta.box(id)
      for _, sib in ipairs(Lay.layers[Lay.layer[id] + 1]) do right = math.max(right, U.S.meta.box(sib).c1) end
      local gl = ghost_lines(id)
      local lines, width = {}, 0
      for _, l in ipairs(gl) do lines[#lines + 1] = ' ' .. l[1] .. ' '; width = math.max(width, vim.fn.strdisplaywidth(lines[#lines])) end
      local buf = api.nvim_create_buf(false, true)
      api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      for i, l in ipairs(gl) do api.nvim_buf_set_extmark(buf, U.ns, i - 1, 0, { end_row = i, hl_group = l[2] }) end
      local line = api.nvim_buf_get_lines(U.W.mbuf, b.r0, b.r0 + 1, false)[1] or ''
      local col = U.charbyte(line, math.min(right, vim.fn.strchars(line)))
      local ok, w = pcall(api.nvim_open_win, buf, false, { relative = 'win', win = U.W.main, bufpos = { b.r0, col },
        row = 0, col = 3 + math.max(0, right - vim.fn.strchars(line)), width = width, height = #lines, border = DOTTED, style = 'minimal',
        focusable = false, zindex = 55, noautocmd = true,
        title = (id == sel() and ' ⇢ ' or ' ') .. U.trunc(title(id), 24) .. ' ', title_pos = 'left' })
      if ok then
        vim.wo[w].winhighlight = 'FloatBorder:' .. (s == 'waiting' and 'DDRevChg' or (s == 'unresolved' and 'DiagnosticWarn' or 'Comment')) .. ',NormalFloat:Normal'
        VC.ghosts[#VC.ghosts + 1] = w
      end
    end
  end
end

-- the card: the question (or the pick list), and the dive streaming while it reads the repo
function VC.card_render()
  local id = VC.cid
  if not id or not U.panel_open() then return vc_close_card() end
  local s = B.status(id)
  if not s or s == 'resolved' or s == 'external' or s == 'declined' or s == 'extending' or s == 'pending' then return vc_close_card() end
  local width = 78
  local c = C.canvas()
  VC.cv = c
  if s == 'waiting' then
    B.render_question(c, width - 2, ' ')
  elseif s == 'reading' then
    c.add(' ⟳ the dive is reading the repo you named', 'DiagnosticInfo')
    local n = #B.dive.log
    for k = math.max(1, n - 6), n do
      local l = B.dive.log[k]
      c.add('   ' .. (l.icon == 'you' and 'you' or l.icon) .. '  ' .. U.trunc(l.text, width - 10), l.hl)
    end
  else
    c.add(' specify repo for ' .. G.steps[id].boundary.target, 'Title')
    B.render_cands(c, id, width - 2, ' ')
  end
  if s ~= 'reading' then
    c.rows_p = c.add('   p   type a path…')
    c.hl(c.rows_p, 'DDKey', 3, 4)
    c.add('')
    c.add(' 1-9/⏎ pick · p path · e external · S skip' .. (s == 'waiting' and ' · L later' or '') .. ' · q map · Esc close', 'DDKeyHint')
  end
  VC.buf = VC.buf or X.scratch('deepdive://bd-card')
  vim.bo[VC.buf].modifiable = true
  U.put(VC.buf, c.lines, c.hls)
  local cfg = { relative = 'win', win = U.W.main, width = width, height = math.min(#c.lines, 18), border = 'rounded',
    title = ' ' .. (s == 'waiting' and '⏸ ' or '⇢ ') .. U.trunc(title(id), 40) .. ' ', title_pos = 'left', zindex = 70, style = 'minimal' }
  if U.S.mode == 'map' and on_level(id) and U.S.meta and U.S.meta.box then
    local b = U.S.meta.box(id)
    local line = api.nvim_buf_get_lines(U.W.mbuf, b.r1, b.r1 + 1, false)[1] or ''
    cfg.bufpos = { b.r1, U.charbyte(line, b.c0) }
    cfg.row, cfg.col = 1, 0
  elseif api.nvim_get_current_win() ~= VC.cw then
    -- off its level: hide (the winbar says where the dive waits; b brings it back)
    if valid(VC.cw) then api.nvim_win_close(VC.cw, true) end
    VC.cw = nil
    return
  else
    cfg.row, cfg.col = 1, math.max(0, api.nvim_win_get_width(U.W.main) - width - 3)
  end
  if valid(VC.cw) then api.nvim_win_set_config(VC.cw, cfg)
  else
    VC.cw = api.nvim_open_win(VC.buf, false, cfg)
    vim.wo[VC.cw].cursorline = true
    vim.wo[VC.cw].winhighlight = 'FloatBorder:' .. (s == 'waiting' and 'DDRevChg' or 'DiagnosticWarn')
  end
end
local function vc_card(id, focus)
  if not id then return warn('select a Boundary (⇢) first') end
  if not open_status(id) and B.status(id) ~= 'reading' then return warn('“' .. title(id) .. '” is ' .. B.status(id)) end
  if sel() ~= id then U.select(id) end
  VC.cid = id
  VC.card_render()
  if focus and valid(VC.cw) then
    api.nvim_set_current_win(VC.cw)
    local first
    for r in pairs(VC.cv.cands or {}) do if not first or r < first then first = r end end
    if first then api.nvim_win_set_cursor(VC.cw, { first + 1, 0 }) end
  end
end
local function vc_card_keys()
  if VC.ckeys then return end
  VC.ckeys = true
  local buf = VC.buf or X.scratch('deepdive://bd-card')
  VC.buf = buf
  local function back() if U.panel_open() then api.nvim_set_current_win(U.W.main) end end
  bmap(buf, 'q', back)
  bmap(buf, '<Tab>', back)
  bmap(buf, '<Esc>', function() back(); vc_close_card() end)
  bmap(buf, '<CR>', function()
    local r = api.nvim_win_get_cursor(0)[1] - 1
    if r == VC.cv.rows_p then back(); return ask_path(VC.cid) end
    local cd = VC.cv.cands and VC.cv.cands[r]
    if cd then local id = VC.cid; back(); pick(id, cd) end
  end)
  for n = 1, 9 do bmap(buf, tostring(n), function() local id = VC.cid; back(); pick_n(id, n) end) end
  bmap(buf, 'p', function() local id = VC.cid; back(); ask_path(id) end)
  bmap(buf, 'e', function() local id = VC.cid; back(); mark(id, 'external') end)
  bmap(buf, 'S', function() local id = VC.cid; back(); mark(id, 'declined') end)
  bmap(buf, 'L', function() back(); later() end)
end
VC.keys = {
  s = function() vc_card(sel_bd(), true) end,
  K = function()
    if valid(VC.cw) then return api.nvim_set_current_win(VC.cw) end
    vc_card(sel_bd() or G.waiting, true)
  end,
  e = function() mark(sel_bd(), 'external') end, S = function() mark(sel_bd(), 'declined') end,
  L = later, u = function() reopen(sel_bd()) end,
  b = function() if G.waiting then vc_card(G.waiting, false) else warn('the dive is not waiting') end end,
  ['<Esc>'] = function()
    if valid(VC.cw) then vc_close_card() else U.S.port = nil; U.S.overlay = nil; U.sync { nojump = true } end
  end,
}
VC.keys.r = VC.keys.s
VC.keys.B = VC.keys.b
function VC.status()
  if B.dive.state == 'paused' then return '%#DDRevChg# ⏸ dive waits: b %#StatusLine#' end
  if B.dive.state == 'running' then return '%#DiagnosticInfo# ⟳ dive %#StatusLine#' end
end
function VC.winbar()
  if not G.waiting or on_level(G.waiting) then return nil end
  return '%#DDMode# ' .. (U.S.mode == 'map' and 'MAP' or 'ZEN') .. ' %#DDCrumbs# %<' .. esc(U.crumbs(sel())) ..
    ' %=%#DDRevChg# ⏸ dive waits in “' .. esc(where(G.waiting)) .. '” · b %#Normal# %#DDKey# ⇥ %#DDCrumbs# tab  %#DDKey# ? %#DDCrumbs# help '
end
function VC.on_sync()
  vc_ghosts()
  if VC.cid then VC.card_render() end
end
function VC.render(what)
  if B.q and VC.seen ~= B.q then
    if U.panel_open() then VC.seen = B.q; U.select(B.q.step) end
    VC.cid = B.q.step
  end
  if B.dive.reading then VC.cid = B.dive.reading end
  if C.fix and C.fix.p.bd and VC.fixseen ~= C.fix.p then VC.fixseen = C.fix.p; vc_close_card(); X.tab('fix') end
  vc_card_keys()
  VC.on_sync()
end
function VC.deactivate() vc_close_ghosts(); vc_close_card() end
function VC.activate() vc_card_keys() end
VC.help = {
  { 'BOUNDARY (C: on the map)' }, { 's', 'specify repo: card on the box' }, { 'K', 'enter the card' },
  { 'b', 'go to the waiting Boundary' }, { 'e', 'mark external' }, { 'S', 'don’t follow (declined)' }, { 'L', 'later' }, { 'u', 'reopen' },
}

-- =====================================================================
-- switcher + wiring
-- =====================================================================
local VARS = { VB } -- decided: B. A and C stay in the file (and in git history) for the record
function BV.cur() return VARS[BV.i] end

local function pill()
  local v = BV.cur()
  local text = ' ◀ [v   Boundary ' .. v.key .. ' · ' .. v.name .. '   ]v ▶ '
  BV.pbuf = BV.pbuf or api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(BV.pbuf, 0, -1, false, { text })
  api.nvim_buf_clear_namespace(BV.pbuf, U.ns, 0, -1)
  api.nvim_buf_set_extmark(BV.pbuf, U.ns, 0, 0, { end_col = #text, hl_group = 'DDPill' })
  local w = vim.fn.strdisplaywidth(text)
  local cfg = { relative = 'editor', row = 0, col = math.max(0, math.floor(vim.o.columns * 0.5) - w - 2), width = w, height = 1,
    style = 'minimal', focusable = false, zindex = 200, border = 'none' }
  if valid(BV.pw) then api.nvim_win_set_config(BV.pw, cfg) else
    cfg.noautocmd = true
    BV.pw = api.nvim_open_win(BV.pbuf, false, cfg)
  end
end

local function activate()
  local v = BV.cur()
  QA.extra = v.extra
  if v.activate then v.activate() end
  v.render('graph')
  if U.panel_open() then X.redraw() end
  gsync()
end
function BV.switch(d)
  local v = BV.cur()
  if v.deactivate then v.deactivate() end
  QA.extra = nil
  BV.i = (BV.i - 1 + d) % #VARS + 1
  activate()
  pill()
end

-- letters + digits in the details pane and the prompt go to the active Boundary variant
local DK = { 's', 'e', 'S', 'L', 'u', 'b', '1', '2', '3', '4', '5', '6', '7', '8', '9' }
local function pane_keys()
  for _, k in ipairs(DK) do
    bmap(U.W.dbuf, k, function()
      local f = BV.cur().dkeys and BV.cur().dkeys[k]
      if f then f() end
    end)
  end
  local ib = X.scratch('deepdive://ask')
  for _, k in ipairs(DK) do
    bmap(ib, k, function()
      local f = BV.cur().pkeys and BV.cur().pkeys[k]
      if f then f() end
    end)
  end
end

function BV.setup()
  local qa = { badge = P.hooks.badge, winbar = P.hooks.winbar, status = P.hooks.status, on_sync = P.hooks.on_sync,
    on_open = P.hooks.on_open, help = P.hooks.help, vkeys = P.vkeys }
  P.hooks.badge = function(id) return (qa.badge(id) or '') .. B.badge(id) end
  P.hooks.winbar = function() local v = BV.cur(); return (v.winbar and v.winbar()) or qa.winbar() end
  P.hooks.status = function()
    local v = BV.cur()
    return ((v.status and v.status()) or '') .. (qa.status() or '')
  end
  P.hooks.on_sync = function() qa.on_sync(); local v = BV.cur(); if v.on_sync then v.on_sync() end end
  P.hooks.on_open = function()
    qa.on_open()
    for _, b in ipairs({ U.W.mbuf, U.W.dbuf }) do
      bmap(b, '[v', function() BV.switch(-1) end)
      bmap(b, ']v', function() BV.switch(1) end)
    end
    pane_keys()
    for _, v in ipairs(VARS) do if v.on_open then v.on_open() end end
    vim.schedule(function() BV.cur().render('graph') end)
  end
  P.hooks.help = function()
    return vim.list_extend(qa.help(), BV.cur().help or {})
  end
  P.vkeys = setmetatable({}, { __index = function(_, k)
    local f = BV.cur().keys[k]
    if f then return f end
    return qa.vkeys[k]
  end })
  C.on(function(what) BV.cur().render(what) end)
  vim.keymap.set('n', '<leader>dv', function() BV.switch(1) end, { desc = 'Deep dive proto: next Boundary variant' })
  vim.keymap.set('n', '<leader>dV', function() BV.switch(-1) end, { desc = 'Deep dive proto: previous Boundary variant' })
  api.nvim_create_autocmd('VimResized', { callback = pill })
  local start = (vim.env.DD_VARIANT or 'A'):upper()
  for k, v in ipairs(VARS) do if v.key == start then BV.i = k end end
  vim.schedule(function() vim.schedule(function() activate() end) end)
end

return BV
