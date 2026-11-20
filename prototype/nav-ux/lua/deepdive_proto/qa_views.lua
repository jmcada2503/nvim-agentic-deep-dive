-- PROTOTYPE (throwaway): three radically different layouts for Q&A threads, Revision proposals, Fix runs,
-- Pending-revision review, the Revision list and the graph diff overlay, on top of the nav-ux panel.
--   A  Tabs in the details pane   B  Chat at the bottom   C  On the graph (cards + review mode)
-- Switch: [v / ]v in the panel, or ␣dv / ␣dV anywhere. ␣dF toggles "first Fix run gets stuck".
-- All three drive the same scripted state (qa_core.lua), so a thread started in A shows up in B and C.
local P = require('deepdive_proto')
local U = P._
local C = require('deepdive_proto.qa_core')
local G = U.G
local api = vim.api
local V = { i = 1 }

-- ---------- shared helpers ----------
local function focus() return C.focus_of(U.S, U.cur_edge()) end
local function input(prompt, cb, allow_empty)
  vim.ui.input({ prompt = prompt }, function(s)
    if s and (s ~= '' or allow_empty) then cb(s) end
  end)
end
local function gsync() if U.panel_open() then U.sync { nojump = true, noreveal = true } end end
local function valid(w) return w and api.nvim_win_is_valid(w) end
local function scratch(name)
  local b = vim.fn.bufnr(name)
  if b ~= -1 then return b end
  b = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(b, name)
  vim.bo[b].bufhidden = 'hide'
  return b
end
local function winopts(w)
  for k, v in pairs({ number = false, relativenumber = false, signcolumn = 'no', foldcolumn = '0', list = false, wrap = false, cursorline = false }) do
    vim.wo[w][k] = v
  end
end
local function bmap(buf, k, fn, mode) vim.keymap.set(mode or 'n', k, fn, { buffer = buf, nowait = true, silent = true }) end
local function latest_prop(f)
  local t = f and C.threads[f.key]
  if t then
    for i = #t.msgs, 1, -1 do
      for _, b in ipairs(t.msgs[i].blocks or {}) do if b.t == 'prop' and b.p.status == 'open' then return b.p end end
    end
  end
  local o = C.open_props()
  return o[#o]
end
local function failed() return C.fix and C.fix.state == 'failed' end
local function cite_at(cv, win)
  if not (cv and valid(win)) then return end
  local row = api.nvim_win_get_cursor(win)[1] - 1
  local a = cv.cites[row]
  if a then U.show_in_editor(a) else vim.notify('no Anchor on this line') end
end

-- same meaning in every variant
local ACT = {}
function ACT.y()
  if C.pending then return C.accept_pending() end
  local p = latest_prop(focus())
  if p then C.accept(p) else vim.notify('Deep dive: nothing to accept') end
end
function ACT.x()
  if C.pending then return C.reject_pending() end
  local p = latest_prop(focus())
  if p then C.dismiss(p) end
end
function ACT.R()
  if C.pending then return input('Reject r' .. C.pending.n .. ' with feedback: ', C.reject_pending) end
  local p = latest_prop(focus())
  if p then input('Reply to ' .. p.id .. ' (the agent regenerates it): ', function(s) C.reply(p, s) end) end
end
function ACT.Q() if failed() then input('Ask the Fix run: ', C.clarify) end end
function ACT.H() if failed() then input('Hint, then retry: ', C.hint) end end
function ACT.W() if failed() then input('Widen scope to (empty = root level): ', C.widen, true) end end
function ACT.X() if failed() then C.abandon() end end
function ACT.p(f)
  f = f or focus()
  input('What is wrong or missing at “' .. (f.label) .. '”? ', function(s) C.report(f, s) end)
end

local function ov_set(from, to)
  local n = #C.revisions
  from, to = math.max(1, math.min(from, n)), math.max(1, math.min(to, n))
  C.ov = { from = math.min(from, to), to = math.max(from, to) }
end

local function badge(id)
  local b = ''
  local n = C.thread_count(id)
  if n > 0 then b = b .. ' ?' .. n end
  for _, p in ipairs(C.proposals) do
    if p.target == id then
      if p.status == 'open' then b = b .. ' !'
      elseif p.status == 'fixing' then b = b .. (C.pending and C.pending.p == p and ' ●' or (failed() and C.fix.p == p and ' ✗' or ' ⟳')) end
    end
  end
  return b
end

-- every Step id at every level the overlay marks, in flow order
local function changed_ids()
  local t, out = C.targets(), {}
  for _, s in ipairs(G.list) do if t[s.id] then out[#out + 1] = s.id end end
  return out
end

-- =====================================================================
-- A: tabs in the details pane, with a chat prompt under the Thread / Fix run tabs
-- =====================================================================
local A = { key = 'A', name = 'Tabs in the details pane', tab = 'details', dive = false, revrow = {}, mark = nil, dkeys = false }
-- PROTOTYPE boundary: A.extra (set by bd_views) may add tabs, tab names, content, prompt and hint-bar chips
-- four short tabs, always the same: Info · Ask · Run (the dive and Fix runs) · Revs
local function TABS_() return { 'details', 'thread', 'fix', 'revs' } end
local function a_focus() return A.dive and C.DIVE or focus() end
local function a_tabname(t)
  local xn = A.extra and A.extra.tabname(t)
  if xn then return xn end
  if t == 'thread' then
    local f = a_focus()
    local th = C.threads[f.key]
    return 'Ask' .. (f.kind == 'dive' and ' ◎' or '') .. (th and (' ' .. #th.msgs) or '')
  elseif t == 'fix' then
    if C.pending then return 'Run ●' end
    if C.fix then return failed() and 'Run ✗' or 'Run ⟳' end
    return 'Run'
  elseif t == 'revs' then
    return 'Revs ' .. #C.revisions .. (C.ov and not C.ov.pending and ' ◐' or '')
  end
  return 'Info'
end
local function a_has_prompt()
  if A.extra and A.extra.has_prompt then
    local r = A.extra.has_prompt(A.tab) -- true / false decide; nil = default
    if r ~= nil then return r end
  end
  return A.tab == 'thread' or A.tab == 'fix'
end
local function a_in_prompt() return valid(A.iw) and api.nvim_get_current_win() == A.iw end

-- the hint bar over the prompt: what you can do right now (C-style key chips, by state)
local function chip(k, label) return '%#DDKey# ' .. k .. ' %#Normal# ' .. label .. '  ' end
local function esc(s) return (s:gsub('%%', '%%%%')) end
local function a_hintbar()
  if not valid(A.iw) then return end
  local f = a_focus()
  local who = f.kind == 'dive' and '◎ whole dive' or ((f.kind == 'edge' and '⇄ ' or (U.icon(f.id) .. ' ')) .. U.trunc(f.label, 34))
  local left, right = '', ''
  local insert = a_in_prompt() and vim.fn.mode() == 'i'
  local xl, xr = nil, nil
  if A.extra and not A.imode then xl, xr = A.extra.hint(A.tab, insert) end
  if A.imode then
    left = '%#DDRevChg# ' .. A.imode.label .. ' %#Normal# '
    right = (A.imode.chips or '') .. chip('⏎', 'send') .. chip('Esc', 'cancel')
  elseif xl then
    left, right = xl, xr
  else
    if A.tab == 'fix' and failed() then
      left = '%#DiagnosticError# ✗ ' .. C.fix.p.id .. ' stuck %#Normal# ' .. (insert and 'typing asks the Fix run  ' or '')
    elseif A.tab == 'fix' and C.fix and not C.pending then
      left = '%#DiagnosticInfo# ⟳ ' .. C.fix.p.id .. ' %#Normal# '
    else
      left = '%#DDAgent# ask %#Normal# ' .. esc(who) .. '  '
    end
    if insert then
      right = chip('⏎', 'send') .. chip('^A', A.dive and 'selection' or 'whole dive') .. chip('⇥', 'graph') .. chip('Esc', 'actions')
    else
      local p = latest_prop(f)
      if C.pending then
        right = chip('y', 'accept r' .. C.pending.n) .. chip('R', 'reject + note') .. chip('x', 'reject')
      elseif failed() then
        right = chip('Q', 'ask it') .. chip('H', 'hint + retry') .. chip('W', 'widen scope') .. chip('X', 'abandon')
      elseif p then
        right = chip('y', 'accept ' .. p.id) .. chip('x', 'dismiss') .. chip('R', 'reply')
      end
      -- state-specific actions first; the generic ones only when there is room
      if right == '' then right = chip('i', 'type') .. chip('p', 'problem') .. chip('^A', A.dive and 'selection' or 'whole dive') .. chip('⇥', 'graph')
      else right = right .. chip('i', 'type') .. chip('⇥', 'graph') end
    end
  end
  vim.wo[A.iw].winbar = left .. '%=' .. right
end

local function a_close_prompt()
  if valid(A.iw) then api.nvim_win_close(A.iw, true) end
  A.iw = nil
end
local function a_prompt_win()
  if not (U.panel_open() and valid(U.W.det)) then return end
  if not a_has_prompt() then return a_close_prompt() end
  if valid(A.iw) then return end
  A.ibuf = A.ibuf or scratch('deepdive://ask')
  vim.bo[A.ibuf].modifiable = true
  A.iw = api.nvim_open_win(A.ibuf, false, { split = 'below', win = U.W.det, height = 1 })
  winopts(A.iw)
  vim.wo[A.iw].winfixheight = true
  vim.wo[A.iw].statusline = ' '
end
local function a_winbar()
  if not valid(U.W.det) then return end
  local s = ''
  local tabs = TABS_()
  local has = false
  for _, t in ipairs(tabs) do has = has or t == A.tab end
  if not has then A.tab = 'details' end
  for _, t in ipairs(tabs) do
    s = s .. (t == A.tab and '%#DDTabSel#' or '%#DDTab#') .. ' ' .. a_tabname(t) .. ' %#Normal# '
  end
  local here = api.nvim_get_current_win() == U.W.det or (valid(A.iw) and api.nvim_get_current_win() == A.iw)
  vim.wo[U.W.det].winbar = s .. '%=' .. chip('t T', 'tab') .. chip('⇥', here and 'graph' or 'focus')
  vim.wo[U.W.det].statusline = A.tab == 'revs' and A.revs_bar() or (A.extra and A.extra.statusline and A.extra.statusline(A.tab)) or ' '
  a_prompt_win()
  api.nvim_win_set_height(U.W.det, (A.tab == 'details' and not (A.extra and A.extra.tall(A.tab))) and 14 or 21)
  a_hintbar()
end
function A.details()
  if not valid(U.W.det) then return nil end
  local w = api.nvim_win_get_width(U.W.det) - 2
  local c = C.canvas()
  A.cv = c
  if A.extra and A.extra.render(A.tab, c, w) then return c.lines, c.hls end
  if A.tab == 'details' then return nil end
  if A.tab == 'thread' then
    local f = a_focus()
    c.add(' about  ' .. (f.kind == 'dive' and '◎ ' or '') .. f.label, 'Title')
    local th = C.threads[f.key]
    if not th then
      c.add('')
      c.add(' No questions here yet. Type below to ask' .. (f.kind == 'dive' and ' about the whole dive.' or ', or ^A for the whole dive.'), 'Comment')
    else
      for _, m in ipairs(th.msgs) do c.add(''); C.render_msg(c, m, w, ' ', { keys = 'see the bar below' }) end
    end
    local others = {}
    for k, t in pairs(C.threads) do if k ~= f.key then others[#others + 1] = t.focus.label .. ' (' .. #t.msgs .. ')' end end
    if #others > 0 then c.add(''); c.add(' other threads  ' .. table.concat(others, ' · '), 'Comment') end
  elseif A.tab == 'fix' then
    A.render_fix(c, w)
  elseif A.tab == 'revs' then
    A.render_revs(c, w)
  end
  return c.lines, c.hls
end
function A.render_fix(c, w)
  do
    if C.pending then
      C.render_review(c, w, ' ', nil)
      c.add(' (the graph shows the change)', 'Comment')
      c.add('')
      c.add(' Fix run log', 'Comment')
      C.render_fix(c, C.fix, w, '   ')
    elseif C.fix then
      c.add(' Fix run · ' .. C.fix.p.id .. ' · attempt ' .. C.fix.attempt .. ' · scope ' .. C.fix.p.scope, 'Title')
      C.render_fix(c, C.fix, w, ' ', ' ')
    else
      c.add(' No Fix run. Accept a Revision proposal (y) to start one.', 'Comment')
      local q = vim.tbl_filter(function(p) return p.status == 'queued' end, C.proposals)
      if #q > 0 then c.add(' queued: ' .. #q, 'Comment') end
    end
  end
end
function A.render_revs(c, w)
  do
    c.add(' graph colours', 'Comment')
    local r = #c.lines - 1
    c.lines[r + 1] = c.lines[r + 1] .. '   + added  ~ changed  - removed  ▒ has changes inside'
    local l = c.lines[r + 1]
    local function tag(s, hl) local i = l:find(s, 1, true); if i then c.hl(r, hl, vim.fn.strchars(l:sub(1, i - 1)), vim.fn.strchars(l:sub(1, i - 1)) + vim.fn.strchars(s)) end end
    tag('+ added', 'DDRevAdd'); tag('~ changed', 'DDRevChg'); tag('- removed', 'DDRevDel'); tag('▒ has changes inside', 'DDRevIn')
    c.add('')
    A.revrow, A.revhead = {}, {}
    for _, rv in ipairs(C.revisions) do
      local on = C.ov and not C.ov.pending and rv.n >= C.ov.from and rv.n <= C.ov.to
      local row = c.add(string.format(' ▌ r%-2d %-11s %s', rv.n, rv.kind, U.trunc(rv.reason, w - 20)), on and 'Normal' or 'Comment')
      c.hl(row, rv.kind == 'correction' and 'DiagnosticWarn' or 'DiagnosticInfo', 7, 18)
      c.hl(row, on and 'DDCardTitle' or 'DDDim', 1, 2)
      A.revrow[row] = rv.n
      A.revhead[#A.revhead + 1] = row
      local r2 = c.add(' ▌            asked “' .. rv.q .. '”  · ' .. #rv.ops .. ' op' .. (#rv.ops > 1 and 's' or ''), 'Comment')
      c.hl(r2, on and 'DDCardTitle' or 'DDDim', 1, 2)
      A.revrow[r2] = rv.n
    end
    A.revpend = nil
    if C.pending then
      A.revpend = c.add(string.format(' ● r%-2d %-11s %s', C.pending.n, C.pending.kind, 'pending · review it in Run (⏎)'), 'DDRevChg')
    end
    -- the revision under the cursor (or the one the graph shows), in full
    local n = valid(U.W.det) and A.revrow[api.nvim_win_get_cursor(U.W.det)[1] - 1]
    if not n and C.ov and not C.ov.pending then n = C.ov.to end
    local rv
    for _, r in ipairs(C.revisions) do if r.n == n then rv = r end end
    if rv then
      c.add('')
      c.add(' ' .. string.rep('─', w - 2), 'DDDim')
      c.add(' r' .. rv.n .. ' · ' .. rv.kind, 'DDCardTitle')
      for _, l in ipairs(C.wrap('reason  ' .. rv.reason, w - 4)) do c.add(' ' .. l) end
      c.add(' asked   “' .. rv.q .. '”', 'Comment')
      for _, op in ipairs(rv.ops) do
        local name = op.what == 'step' and ('“' .. (op.title or (G.steps[op.id] and G.steps[op.id].title) or op.id) .. '”') or op.id
        local sym = op.op == 'add' and '+' or (op.op == 'remove' and '-' or '~')
        c.add(' ' .. sym .. ' ' .. op.op .. ' ' .. op.what .. ' ' .. name .. (op.field and ('  · ' .. op.field) or ''), op.op == 'add' and 'DDRevAdd' or 'DDRevChg')
        if op.before then for _, l in ipairs(C.wrap(op.before, w - 8)) do c.add('    − ' .. l, 'DiffDelete') end end
        if op.after then for _, l in ipairs(C.wrap(op.after, w - 8)) do c.add('    + ' .. l, 'DiffAdd') end end
        if op.note then c.add('    ✎ ' .. op.note, 'DDNote') end
      end
    end
  end
end
local function a_redraw()
  if not U.panel_open() then return end
  a_winbar()
  U.details()
  -- chat-like: keep the newest message in view unless the user is reading the pane
  if a_has_prompt() and api.nvim_get_current_win() ~= U.W.det then
    -- a Pending revision reads top-down (reason first); threads and Fix-run logs follow the newest line
    local top
    if A.extra and A.extra.top then top = A.extra.top(A.tab) end
    if top == nil then top = A.tab == 'fix' and C.pending end
    pcall(api.nvim_win_set_cursor, U.W.det, { top and 1 or api.nvim_buf_line_count(U.W.dbuf), 0 })
    if top then api.nvim_win_call(U.W.det, function() vim.fn.winrestview({ topline = 1 }) end) end
  end
end
local function a_tab(t) A.tab = t; a_redraw() end

-- Revisions list: the cursor (or a V selection) is what the graph shows
function A.revs_bar()
  local shown = C.ov and not C.ov.pending and C.ov_label()
  return '%#DDMode# REVISIONS %#Normal# graph shows ' .. (shown and ('%#DDCardTitle#' .. shown .. '%#Normal#') or 'nothing') ..
    '%=' .. chip('j k', 'next / prev revision') .. chip('V', 'range') ..
    chip('⏎', 'keep on graph') .. chip('q', 'close') .. chip('⇥', 'graph, keep')
end
-- focus / tab switches never move the graph: the pane's CursorMoved previews only react to a real cursor move
-- (entering a window fires CursorMoved even when the cursor did not move)
local function a_moved()
  if vim.fn.mode():match('^[vV\22]') then A.entry = nil; return true end
  local c = api.nvim_win_get_cursor(0)
  if A.entry and A.entry[1] == c[1] and A.entry[2] == c[2] then return false end
  A.entry = nil
  return true
end
local function a_arm() if U.panel_open() then A.entry = api.nvim_win_get_cursor(U.W.det) end end
local function a_revs_preview()
  if V.cur() ~= A or A.tab ~= 'revs' or not U.panel_open() or api.nvim_get_current_win() ~= U.W.det then return end
  if not a_moved() then return end
  local a, b = vim.fn.line('.'), vim.fn.line('.')
  local m = vim.fn.mode()
  if m == 'V' or m == 'v' or m == '\22' then a = vim.fn.line('v') end
  local lo, hi
  for l = math.min(a, b), math.max(a, b) do
    local n = A.revrow[l - 1]
    if n then lo, hi = math.min(lo or n, n), math.max(hi or n, n) end
  end
  if not lo then return end
  if C.ov and not C.ov.pending and C.ov.from == lo and C.ov.to == hi then return end
  ov_set(lo, hi)
  -- the map walks into the revision under the cursor: its first changed step becomes the selection
  local n, tgt = A.revrow[vim.fn.line('.') - 1]
  for _, r in ipairs(C.revisions) do
    if r.n == n then
      for _, op in ipairs(r.ops) do if op.what == 'step' and G.steps[op.id] then tgt = op.id; break end end
    end
  end
  local cur = api.nvim_win_get_cursor(U.W.det)
  if tgt then
    U.S.sel, U.S.port, U.S.overlay = tgt, nil, nil
    U.sync { nojump = true }
  else gsync() end
  pcall(api.nvim_win_set_cursor, U.W.det, cur)
end
-- j/k in the list step between revisions, not lines (works in V too)
local function a_revs_step(dir)
  if A.tab ~= 'revs' or not A.revhead or #A.revhead == 0 then return dir > 0 and 'j' or 'k' end
  local cur = vim.fn.line('.') - 1
  local tgt
  if dir > 0 then
    for _, r in ipairs(A.revhead) do if r > cur then tgt = r; break end end
  else
    for i = #A.revhead, 1, -1 do if A.revhead[i] < cur and A.revrow[cur] ~= A.revrow[A.revhead[i]] then tgt = A.revhead[i]; break end end
  end
  if not tgt then return '' end
  local d = tgt - cur
  return math.abs(d) .. (d > 0 and 'j' or 'k')
end
local function a_revs_enter()
  if #C.revisions == 0 or not U.panel_open() then return a_tab('revs') end
  if A.tab ~= 'revs' or api.nvim_get_current_win() ~= U.W.det then A.prev_sel = U.S.sel end
  A.tab = 'revs'
  a_redraw()
  api.nvim_set_current_win(U.W.det)
  local last
  for row, n in pairs(A.revrow) do if n == #C.revisions and (not last or row < last) then last = row end end
  api.nvim_win_set_cursor(U.W.det, { (last or 0) + 1, 0 })
  a_revs_preview()
end
local function a_revs_leave(keep)
  if vim.fn.mode():match('^[vV\22]') then vim.cmd('normal! \27') end
  if not keep then
    C.ov = C.pending and { pending = true } or nil
    if A.prev_sel then U.S.sel = A.prev_sel end
  end
  A.prev_sel = nil
  if U.panel_open() then api.nvim_set_current_win(U.W.main) end
  if keep then gsync() elseif U.panel_open() then U.sync { nojump = true } end
end
local function a_dive(on) if A.dive ~= on then A.dive = on; gsync() end end

-- t / T: next / previous tab from the graph, the pane or the prompt; focus stays where it is
local function a_cycle(d)
  local T = TABS_()
  local i = 1
  for k, t in ipairs(T) do if t == A.tab then i = k end end
  local nxt = T[(i - 1 + d) % #T + 1]
  local cur = api.nvim_get_current_win()
  local in_pane = U.panel_open() and (cur == U.W.det or (valid(A.iw) and cur == A.iw))
  if A.tab == 'revs' then
    if vim.fn.mode():match('^[vV\22]') then vim.cmd('normal! \27') end
    if C.ov and not C.ov.pending then C.ov = C.pending and { pending = true } or nil end
    A.prev_sel = nil
  end
  vim.cmd('stopinsert')
  A.imode = nil
  A.tab = nxt
  if nxt == 'revs' then A.prev_sel = U.S.sel end
  gsync()
  a_redraw()
  if not U.panel_open() then return end
  if in_pane and not (valid(A.iw) and api.nvim_get_current_win() == A.iw) then api.nvim_set_current_win(U.W.det) end
  if nxt == 'revs' and #C.revisions > 0 then
    local last
    for row, n in pairs(A.revrow) do if n == #C.revisions and (not last or row < last) then last = row end end
    pcall(api.nvim_win_set_cursor, U.W.det, { (last or 0) + 1, 0 })
  end
  a_arm()
end
-- ⇥: graph <-> the focused tab (from the prompt or any card: back to the graph)
local function a_toggle()
  if not U.panel_open() then return end
  if api.nvim_get_current_win() == U.W.main then
    a_arm()
    api.nvim_set_current_win(U.W.det)
  else
    if vim.fn.mode():match('^[vV\22]') then vim.cmd('normal! \27') end
    vim.cmd('stopinsert')
    A.imode = nil
    api.nvim_set_current_win(U.W.main)
  end
  a_winbar()
end

-- the prompt: open the thread tab and put the cursor in the chat input
local function a_prompt(tab, imode, prefill)
  A.imode = imode
  if tab then A.tab = tab end
  gsync() -- map (whole-dive highlight), tabs, prompt window
  a_redraw()
  if not valid(A.iw) then return end
  api.nvim_set_current_win(A.iw)
  api.nvim_buf_set_lines(A.ibuf, 0, -1, false, { prefill or '' })
  vim.cmd('startinsert!')
  a_hintbar()
end
local function a_send()
  local text = vim.trim(table.concat(api.nvim_buf_get_lines(A.ibuf, 0, -1, false), ' '))
  api.nvim_buf_set_lines(A.ibuf, 0, -1, false, { '' })
  local im = A.imode
  A.imode = nil
  if text == '' and not (im and im.empty_ok) then a_hintbar() return end
  if im then im.send(text)
  elseif A.extra and A.extra.send and A.extra.send(A.tab, text) then -- PROTOTYPE boundary: Run talks to the focused run
  elseif A.tab == 'fix' and failed() then C.clarify(text)
  else
    if A.tab ~= 'thread' then A.tab = 'thread' end
    C.ask(a_focus(), text)
  end
  a_hintbar()
end
local function back_to_graph()
  vim.cmd('stopinsert')
  A.imode = nil
  if U.panel_open() then api.nvim_set_current_win(U.W.main) end
  a_hintbar()
end

-- actions that need text go through the prompt instead of a popup
local function a_reply()
  if C.pending then
    return a_prompt('fix', { label = 'reject r' .. C.pending.n .. ' with feedback', send = C.reject_pending })
  end
  local p = latest_prop(a_focus())
  if p then a_prompt('thread', { label = 'reply to ' .. p.id, send = function(s) C.reply(p, s) end }) end
end
local function a_problem()
  local f = a_focus()
  a_prompt('thread', { label = 'what is wrong or missing?', send = function(s) C.report(f, s) end })
end
local function a_stuck(kind)
  if not failed() then return end
  if kind == 'Q' then a_prompt('fix')
  elseif kind == 'H' then a_prompt('fix', { label = 'hint, then retry', send = C.hint })
  elseif kind == 'W' then a_prompt('fix', { label = 'widen scope to (empty = root level)', send = C.widen, empty_ok = true }) end
end

local ACTA = {
  y = function() ACT.y(); if C.fix then A.tab = 'fix' end; a_redraw() end,
  x = function() ACT.x(); a_redraw() end,
  R = a_reply, p = a_problem,
  Q = function() a_stuck('Q') end, H = function() a_stuck('H') end, W = function() a_stuck('W') end,
  X = function() ACT.X(); a_redraw() end,
}
local function a_prompt_keys()
  if A.pkeys or not A.ibuf then return end
  A.pkeys = true
  local b = A.ibuf
  for _, m in ipairs({ 'n', 'i' }) do
    bmap(b, '<CR>', a_send, m)
    bmap(b, '<Tab>', a_toggle, m)
    bmap(b, '<C-a>', function() a_dive(not A.dive); a_redraw() end, m)
  end
  bmap(b, '<Esc>', function() vim.cmd('stopinsert'); if A.imode then A.imode = nil end; vim.schedule(a_hintbar) end, 'i')
  for k, fn in pairs(ACTA) do bmap(b, k, fn) end
  bmap(b, 'q', back_to_graph)
  bmap(b, '<Esc>', back_to_graph)
  bmap(b, 't', function() a_cycle(1) end)
  bmap(b, 'T', function() a_cycle(-1) end)
  bmap(b, 'g', function() if valid(U.W.det) then cite_at(A.cv, U.W.det) end end)
  api.nvim_create_autocmd({ 'InsertEnter', 'InsertLeave', 'WinEnter', 'WinLeave' }, { buffer = b, callback = function() vim.schedule(a_hintbar) end })
end

local function a_det_keys()
  local b = U.W.dbuf
  if A.dkeys or not (b and api.nvim_buf_is_valid(b)) then return end
  A.dkeys = true
  local function row() return api.nvim_win_get_cursor(0)[1] - 1 end
  local K = {
    ['<CR>'] = function()
      if A.tab == 'revs' and A.revpend and row() == A.revpend and A.extra and A.extra.goto_pending then
        C.ov = { pending = true }
        return A.extra.goto_pending()
      end
      if A.tab == 'revs' then a_revs_leave(true) else cite_at(A.cv, 0) end
    end,
    ['<Esc>'] = function() if A.tab == 'revs' then a_revs_leave(false) end end,
    q = function()
      if A.tab == 'revs' then a_revs_leave(false)
      elseif U.panel_open() then api.nvim_set_current_win(U.W.main) end
    end,
    g = function() cite_at(A.cv, 0) end,
    t = function() a_cycle(1) end,
    T = function() a_cycle(-1) end,
    ['<Tab>'] = a_toggle,
    i = function() if a_has_prompt() then a_prompt() end end,
    y = ACTA.y, x = ACTA.x, R = ACTA.R, Q = ACTA.Q, H = ACTA.H, W = ACTA.W, X = ACTA.X,
  }
  A.dk = vim.tbl_keys(K)
  A.dk[#A.dk + 1] = 'j'; A.dk[#A.dk + 1] = 'k'
  for k, fn in pairs(K) do bmap(b, k, function() if V.cur() == A then fn() end end) end
  -- the same keys while a V range is selected
  for k, fn in pairs({ ['<CR>'] = K['<CR>'], q = K.q, ['<Tab>'] = a_toggle }) do bmap(b, k, function() if V.cur() == A then fn() end end, 'x') end
  A.dkx = { '<CR>', 'q', 'j', 'k', '<Tab>' }
  for _, k in ipairs({ 'j', 'k' }) do
    vim.keymap.set({ 'n', 'x' }, k, function()
      if V.cur() ~= A then return k end
      return a_revs_step(k == 'j' and 1 or -1)
    end, { buffer = b, expr = true, nowait = true, silent = true })
  end
  api.nvim_create_autocmd({ 'CursorMoved', 'ModeChanged' }, { buffer = b, callback = function() vim.schedule(a_revs_preview) end })
end
A.keys = {
  a = function() a_dive(false); a_prompt('thread') end,
  A = function() a_dive(true); a_prompt('thread') end,
  p = a_problem, y = ACTA.y, x = ACTA.x, R = ACTA.R, Q = ACTA.Q, H = ACTA.H, W = ACTA.W, X = ACTA.X,
  t = function() a_cycle(1) end,
  T = function() a_cycle(-1) end,
  ['<Tab>'] = a_toggle,
  ['<Esc>'] = function()
    if A.dive then a_dive(false); a_redraw()
    elseif C.ov and not C.ov.pending then C.ov = C.pending and { pending = true } or nil; gsync()
    else U.S.port = nil; U.S.overlay = nil; U.sync { nojump = true } end
  end,
}
-- whole-dive thread open: the map shows everything visible as selected
function A.whole() return A.dive and A.tab == 'thread' end
function A.winbar()
  if not A.whole() then return nil end
  return '%#DDMode# MAP %#DDWholeBar# ◎ whole dive · ' .. esc(G.title) .. ' %#Normal#%=%#Comment# A or Esc: back to the selection '
end
function A.render(what)
  if C.pending and A.seen ~= C.pending then A.seen = C.pending; A.tab = 'fix' end
  if what == 'graph' then gsync() else a_redraw() end
end
function A.on_sync()
  if U.panel_open() then a_winbar() end
end
function A.on_open()
  a_det_keys()
  api.nvim_create_autocmd('WinClosed', { pattern = tostring(U.W.det), once = true, callback = function() vim.schedule(a_close_prompt) end })
end
function A.activate()
  A.ibuf = A.ibuf or scratch('deepdive://ask')
  a_prompt_keys()
  if U.panel_open() then a_det_keys(); a_winbar() end
end
function A.deactivate()
  a_close_prompt()
  A.dive = false
  if U.panel_open() then
    vim.wo[U.W.det].winbar = '%#DDCrumbs# details'
    api.nvim_win_set_height(U.W.det, 14)
  end
  if A.dkeys and U.W.dbuf then
    for _, k in ipairs(A.dk) do pcall(vim.keymap.del, 'n', k, { buffer = U.W.dbuf }) end
    for _, k in ipairs(A.dkx) do pcall(vim.keymap.del, 'x', k, { buffer = U.W.dbuf }) end
    vim.wo[U.W.det].statusline = ' '
    vim.keymap.set('n', 'q', function() P.close() end, { buffer = U.W.dbuf, nowait = true })
  end
  A.dkeys = false
end
A.help = {
  { 'PANE' }, { '⇥', 'graph ↔ tab (also from prompt)' }, { 't T', 'next / previous tab' },
  { 'Q&A' }, { 'a', 'Ask: selection + prompt' }, { 'A', 'Ask: whole dive + prompt' }, { '^A', 'prompt: selection ↔ whole dive' },
  { 'p', 'report a problem' }, { 'y', 'accept proposal / revision' }, { 'x', 'dismiss / reject' },
  { 'R', 'reply / reject with note' }, { 'Q H W X', 'stuck: ask, hint, widen, abandon' },
  { 'REVS TAB' }, { 'j k', 'preview on graph' }, { 'V', 'select a range' },
  { '⏎ ⇥', 'keep on graph, back' }, { 'q Esc', 'colours off, back' },
}

-- =====================================================================
-- B: chat at the bottom (transcript + prompt line, slash commands)
-- =====================================================================
local B = { key = 'B', name = 'Chat at the bottom', dive = false }
local function b_focus() return B.dive and C.DIVE or focus() end
local function b_input_bar()
  if not valid(B.iw) then return end
  local f = b_focus()
  local lab = (f.kind == 'dive' and '◎ ' or (f.kind == 'edge' and '⇄ ' or (U.icon(f.id) .. ' '))) .. f.label
  local mode = failed() and '%#DiagnosticError# fix run stuck: plain text asks it %#Normal# ' or ''
  vim.wo[B.iw].winbar = '%#DDAgent# ask %#Normal# ' .. lab:gsub('%%', '%%%%') .. '  ' .. mode .. '%=%#Comment# ⇥ whole dive · ⏎ send · /help '
end
local function b_review()
  if not C.pending then
    if valid(B.rw) then api.nvim_win_close(B.rw, true) end
    B.rw = nil
    return
  end
  B.rbuf = B.rbuf or scratch('deepdive://review')
  if not valid(B.rw) then
    if not valid(B.tw) then return end
    B.rw = api.nvim_open_win(B.rbuf, false, { split = 'right', win = B.tw, width = math.floor(vim.o.columns * 0.55) })
    winopts(B.rw)
    vim.wo[B.rw].wrap = false
    for k, fn in pairs({ y = ACT.y, x = ACT.x, R = ACT.R, q = function() if valid(B.iw) then api.nvim_set_current_win(B.iw) end end }) do bmap(B.rbuf, k, fn) end
    bmap(B.rbuf, 'g', function() cite_at(B.rcv, 0) end)
  end
  local pr = C.pending
  local w = api.nvim_win_get_width(B.rw) - 2
  local c = C.canvas()
  B.rcv = c
  vim.wo[B.rw].winbar = '%#DDRevChg# r' .. pr.n .. ' pending %#Normal# ' .. pr.kind .. ' · ' .. pr.p.id .. '%=%#DDKey# y %#Normal# accept %#DDKey# R %#Normal# reject+note %#DDKey# x %#Normal# reject '
  for _, l in ipairs(C.wrap('reason  ' .. pr.reason, w)) do c.add(' ' .. l) end
  c.add(' asked   “' .. pr.q .. '”', 'Comment')
  if pr.feedback then c.add(' rerun   ' .. pr.feedback, 'Comment') end
  for _, op in ipairs(pr.ops) do
    c.add('')
    local name = op.what == 'step' and ('“' .. G.steps[op.id].title .. '”') or op.id
    local where = op.what == 'step' and ('   ' .. U.anchor_str(G.steps[op.id].anchor)) or ''
    c.add(' ' .. (op.op == 'add' and '+' or '~') .. ' ' .. op.what .. ' ' .. name .. where, 'DDCardTitle')
    c.add(' @@ ' .. op.field .. ' @@', 'DiagnosticInfo')
    for _, l in ipairs(C.wrap(op.before, w - 4)) do c.add(' - ' .. l, 'DiffDelete') end
    for _, l in ipairs(C.wrap(op.after, w - 4)) do c.add(' + ' .. l, 'DiffAdd') end
    c.add(' # ' .. op.note, 'DDNote')
  end
  U.put(B.rbuf, c.lines, c.hls)
end
local function b_render()
  if not (B.tbuf and valid(B.tw)) then return end
  local w = api.nvim_win_get_width(B.tw) - 2
  local c = C.canvas()
  B.cv = c
  if #C.log == 0 then
    c.add(' Ask about the selected step or edge in the prompt below (␣ in panel: a). ⇥ there switches to the whole dive.', 'Comment')
    c.add(' Commands: /accept /dismiss /reply … /reject [feedback] /problem … /hint … /widen … /abandon /revs', 'Comment')
  end
  local last
  for _, ev in ipairs(C.log) do
    if ev.k == 'msg' then
      if ev.th ~= last then
        c.add('')
        local f = ev.th.focus
        c.add(' ── ' .. (f.kind == 'dive' and '◎' or (f.kind == 'edge' and '⇄' or U.icon(f.id))) .. ' ' .. f.label .. ' ──', 'Title')
        last = ev.th
      end
      C.render_msg(c, ev.m, w, ' ', { keys = 'y accept · x dismiss · R reply   (/accept /dismiss /reply …)' })
    elseif ev.k == 'fix' then
      last = nil
      c.add('')
      c.add(' ── ⟳ Fix run · ' .. ev.f.p.id .. ' · scope ' .. ev.f.p.scope .. ' ──', 'DiagnosticInfo')
      C.render_fix(c, ev.f, w, '   ', 'stuck: type to ask it · /hint … · /widen … · /abandon')
      if ev.f.state == 'pending' and C.pending and C.pending.p == ev.f.p then
        c.add('   → r' .. C.pending.n .. ' opened on the right: y / R / x there, or /accept · /reject [feedback] here', 'DDKeyHint')
      end
    elseif ev.k == 'note' then
      last = nil
      c.add('')
      c.add(' ' .. ev.text, ev.hl)
    end
  end
  U.put(B.tbuf, c.lines, c.hls)
  api.nvim_win_set_cursor(B.tw, { #c.lines, 0 })
end
local CMDS = {
  accept = function() ACT.y() end, dismiss = function() ACT.x() end,
  reply = function(a) local p = latest_prop(b_focus()); if p and a ~= '' then C.reply(p, a) end end,
  reject = function(a) if C.pending then C.reject_pending(a) end end,
  problem = function(a) if a ~= '' then C.report(b_focus(), a) end end,
  hint = function(a) if failed() then C.hint(a) end end,
  widen = function(a) if failed() then C.widen(a) end end,
  abandon = function() if failed() then C.abandon() end end,
  revs = function() B.picker() end,
  help = function()
    table.insert(C.log, { k = 'note', hl = 'Comment', text = '/accept /dismiss /reply <text> /reject [feedback] /problem <text> /hint <text> /widen [areas] /abandon /revs   ·   plain text = ask (or, when a Fix run is stuck, ask the Fix run)' })
    C.emit('thread')
  end,
}
local function b_send()
  local text = vim.trim(table.concat(api.nvim_buf_get_lines(B.ibuf, 0, -1, false), ' '))
  api.nvim_buf_set_lines(B.ibuf, 0, -1, false, { '' })
  if text == '' then return end
  local cmd, arg = text:match('^/(%a+)%s*(.*)$')
  if cmd then
    if CMDS[cmd] then CMDS[cmd](arg) else vim.notify('unknown command /' .. cmd) end
  elseif failed() then C.clarify(text)
  else C.ask(b_focus(), text) end
end
local function b_prompt(prefill)
  if not valid(B.iw) then return end
  api.nvim_set_current_win(B.iw)
  if prefill then api.nvim_buf_set_lines(B.ibuf, 0, -1, false, { prefill }) end
  vim.cmd('startinsert!')
end
function B.picker()
  local buf = scratch('deepdive://revisions')
  local width = math.min(110, vim.o.columns - 8)
  local height = math.min(22, vim.o.lines - 6)
  local win = api.nvim_open_win(buf, true, { relative = 'editor', width = width, height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1, col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal', border = 'rounded', title = ' Revisions ', title_pos = 'center' })
  vim.wo[win].cursorline = true
  local mark
  local function render()
    local c = C.canvas()
    local cur = api.nvim_win_get_cursor(win)[1]
    for _, rv in ipairs(C.revisions) do
      local on = C.ov and not C.ov.pending and rv.n >= C.ov.from and rv.n <= C.ov.to
      local r = c.add(string.format(' %s r%-2d %-11s asked “%s”', mark == rv.n and '⇥' or (on and '●' or ' '), rv.n, rv.kind, rv.q))
      c.hl(r, rv.kind == 'correction' and 'DiagnosticWarn' or 'DiagnosticInfo', 7, 18)
    end
    local n = #C.revisions
    cur = math.min(cur, n)
    local rv = C.revisions[cur]
    c.add(string.rep('─', width), 'Comment')
    c.add(' overlay ' .. (C.ov_label() or 'off'), 'Title')
    if rv then
      for _, l in ipairs(C.wrap('reason  ' .. rv.reason, width - 4)) do c.add(' ' .. l) end
      for _, op in ipairs(rv.ops) do
        local name = op.what == 'step' and ('“' .. G.steps[op.id].title .. '”') or op.id
        c.add(' ' .. (op.op == 'add' and '+' or '~') .. ' ' .. op.what .. ' ' .. name .. (op.field and (' · ' .. op.field) or '') .. '   ✎ ' .. op.note, op.op == 'add' and 'DDRevAdd' or 'DDRevChg')
      end
    end
    c.add('')
    c.add(' ⏎ show on graph · ⇥ mark range start · q close (keeps overlay) · Esc close + overlay off', 'DDKeyHint')
    U.put(buf, c.lines, c.hls)
    api.nvim_win_set_cursor(win, { cur, 0 })
  end
  local function close() if valid(win) then api.nvim_win_close(win, true) end end
  bmap(buf, '<CR>', function()
    local n = api.nvim_win_get_cursor(0)[1]
    if n > #C.revisions then return end
    if mark then ov_set(mark, n); mark = nil else ov_set(n, n) end
    gsync(); render()
  end)
  bmap(buf, '<Tab>', function() mark = api.nvim_win_get_cursor(0)[1]; render() end)
  bmap(buf, 'q', close)
  bmap(buf, '<Esc>', function() C.ov = nil; gsync(); close() end)
  local grp = api.nvim_create_augroup('dd_picker', { clear = true })
  api.nvim_create_autocmd('CursorMoved', { group = grp, buffer = buf, callback = function()
    if api.nvim_win_get_cursor(win)[1] <= #C.revisions then render() end
  end })
  api.nvim_buf_set_lines(buf, 0, -1, false, { '' })
  vim.bo[buf].modifiable = false
  render()
end
function B.activate()
  B.tbuf = B.tbuf or scratch('deepdive://chat')
  B.ibuf = B.ibuf or scratch('deepdive://prompt')
  vim.bo[B.ibuf].modifiable = true
  local cur = api.nvim_get_current_win()
  B.tw = api.nvim_open_win(B.tbuf, false, { split = 'below', win = -1, height = 13 })
  B.iw = api.nvim_open_win(B.ibuf, false, { split = 'below', win = B.tw, height = 1 })
  winopts(B.tw); winopts(B.iw)
  vim.wo[B.tw].wrap = false
  vim.wo[B.tw].winbar = '%#DDCrumbs# Q&A · Fix runs   %#Comment#threads stay until nvim exits'
  vim.wo[B.tw].winfixheight = true
  vim.wo[B.iw].winfixheight = true
  for _, m in ipairs({ 'n', 'i' }) do
    bmap(B.ibuf, '<CR>', b_send, m)
    bmap(B.ibuf, '<Tab>', function() B.dive = not B.dive; b_input_bar() end, m)
  end
  bmap(B.ibuf, 'q', function() if U.panel_open() then api.nvim_set_current_win(U.W.main) end end)
  for k, fn in pairs({ y = ACT.y, x = ACT.x, R = ACT.R, D = B.picker, g = function() cite_at(B.cv, 0) end,
    ['<CR>'] = function() cite_at(B.cv, 0) end, i = function() b_prompt() end, a = function() b_prompt() end }) do
    bmap(B.tbuf, k, fn)
  end
  if valid(cur) then api.nvim_set_current_win(cur) end
  b_input_bar()
  b_render()
  b_review()
end
function B.deactivate()
  for _, w in ipairs({ B.rw, B.iw, B.tw }) do if valid(w) then api.nvim_win_close(w, true) end end
  B.rw, B.iw, B.tw = nil, nil, nil
end
function B.render(what)
  b_render()
  b_review()
  b_input_bar()
  if what == 'graph' then gsync() end
end
function B.on_sync() b_input_bar() end
B.keys = {
  a = function() B.dive = false; b_input_bar(); b_prompt() end,
  A = function() B.dive = true; b_input_bar(); b_prompt() end,
  p = function() B.dive = false; b_input_bar(); b_prompt('/problem ') end,
  y = ACT.y, x = ACT.x, R = ACT.R, Q = function() b_prompt() end, H = function() b_prompt('/hint ') end,
  W = function() b_prompt('/widen ') end, X = ACT.X, D = function() B.picker() end,
}
B.help = {
  { 'Q&A (B: chat)' }, { 'a', 'prompt: ask about selection' }, { 'A', 'prompt: whole dive' }, { 'p', 'prompt: /problem' },
  { 'y x R', 'accept / dismiss / reply' }, { 'D', 'Revisions picker' }, { '/help', 'in the prompt: commands' },
}

-- =====================================================================
-- C: on the graph (cards on nodes, review mode on the map, timeline)
-- =====================================================================
local Cv = { key = 'C', name = 'On the graph: cards + review mode', tl = false }
local function on_level(id) return id and G.steps[id] and G.steps[id].parent == G.steps[U.S.sel].parent end
local function c_close_card()
  if valid(Cv.cw) then api.nvim_win_close(Cv.cw, true) end
  Cv.cw, Cv.card = nil, nil
end
local function c_card_render()
  if not Cv.card or not U.panel_open() then return c_close_card() end
  local width = 64
  local c = C.canvas()
  Cv.cv = c
  local card = Cv.card
  local title, anchor_id
  if card.kind == 'fix' then
    if not C.fix then return c_close_card() end
    title = ' Fix run · ' .. C.fix.p.id .. ' · attempt ' .. C.fix.attempt .. ' '
    anchor_id = C.fix.p.target
    C.render_fix(c, C.fix, width, ' ')
  else
    local th = C.threads[card.f.key]
    title = ' ' .. U.trunc(card.f.label, 40) .. ' '
    anchor_id = card.f.id
    if not th then c.add(' no questions yet', 'Comment') else
      for i, m in ipairs(th.msgs) do if i > 1 then c.add('') end; C.render_msg(c, m, width, ' ') end
    end
    c.add('')
    c.add(' a follow-up · K enter card · Esc close', 'Comment')
  end
  Cv.buf = Cv.buf or scratch('deepdive://card')
  U.put(Cv.buf, c.lines, c.hls)
  local cfg = { relative = 'win', win = U.W.main, width = width, height = math.min(#c.lines, 18), border = 'rounded',
    title = title, title_pos = 'left', zindex = 70, style = 'minimal' }
  if U.S.mode == 'map' and on_level(anchor_id) and U.S.meta and U.S.meta.box then
    local b = U.S.meta.box(anchor_id)
    local line = api.nvim_buf_get_lines(U.W.mbuf, b.r1, b.r1 + 1, false)[1] or ''
    cfg.bufpos = { b.r1, U.charbyte(line, b.c0) }
    cfg.row, cfg.col = 1, 0
  else
    cfg.row, cfg.col = 1, math.max(0, api.nvim_win_get_width(U.W.main) - width - 3)
  end
  if valid(Cv.cw) then api.nvim_win_set_config(Cv.cw, cfg)
  else
    Cv.cw = api.nvim_open_win(Cv.buf, false, cfg)
    vim.wo[Cv.cw].wrap = false
    local back = function() if U.panel_open() then api.nvim_set_current_win(U.W.main) end end
    for k, fn in pairs({ q = back, ['<Esc>'] = function() back(); c_close_card() end, g = function() cite_at(Cv.cv, 0) end,
      ['<CR>'] = function() cite_at(Cv.cv, 0) end, y = ACT.y, x = ACT.x, R = ACT.R, Q = ACT.Q, H = ACT.H, W = ACT.W, X = ACT.X }) do
      bmap(Cv.buf, k, fn)
    end
  end
  local n = api.nvim_buf_line_count(Cv.buf)
  pcall(api.nvim_win_set_cursor, Cv.cw, { n, 0 })
end
local function c_card(card) Cv.card = card; c_card_render() end
local function c_mode() if C.pending then return 'review' elseif Cv.tl then return 'timeline' end end
function Cv.winbar()
  local m = c_mode()
  if m == 'review' then
    local pr = C.pending
    return '%#DDRevChg# REVIEW r' .. pr.n .. ' %#Normal#%< ' .. pr.kind .. ' · ' .. #pr.ops .. ' ops · ' .. U.trunc(pr.reason, 40):gsub('%%', '%%%%') ..
      '%=%#DDKey# y %#Normal# accept %#DDKey# R %#Normal# reject+note %#DDKey# x %#Normal# reject %#DDKey# n %#Normal# next change '
  elseif m == 'timeline' then
    local s = '%#DDMode# REVS %#Normal#%< '
    for i, rv in ipairs(C.revisions) do
      local on = C.ov and rv.n >= C.ov.from and rv.n <= C.ov.to
      s = s .. (i > 1 and '%#Comment#━' or '') .. (on and '%#DDTabSel#' or '%#DDTab#') .. ' r' .. rv.n .. ' ' .. rv.kind:sub(1, 4) .. ' '
    end
    return s .. '%=%#Comment# [r ]r move · { } range · n next change · Esc exit '
  end
end
function Cv.status()
  if not C.fix then return nil end
  if C.pending then return '%#DDRevChg# ● review r' .. C.pending.n .. ' %#StatusLine#' end
  if failed() then return '%#DiagnosticError# ✗ ' .. C.fix.p.id .. ' stuck: K %#StatusLine#' end
  local last = C.fix.log[#C.fix.log]
  return '%#DiagnosticInfo# ⟳ ' .. C.fix.p.id .. ' ' .. U.trunc(last and last.text or '', 30):gsub('%%', '%%%%') .. ' %#StatusLine#'
end
function Cv.details()
  local m = c_mode()
  if not m or not U.panel_open() then return nil end
  local w = api.nvim_win_get_width(U.W.det) - 2
  local c = C.canvas()
  local id = U.S.sel
  if m == 'review' then
    local here = C.ops_at(id)
    C.render_review(c, w, ' ', nil, #here > 0 and id or '__none__')
    if #here == 0 then c.add(' this step is unchanged · n next change (' .. #C.pending.ops .. ' ops in total)', 'Comment') end
  else
    for _, rv in ipairs(C.ov_revs()) do
      c.add(' r' .. rv.n .. ' ' .. rv.kind .. '   asked “' .. rv.q .. '”', 'DDCardTitle')
      for _, l in ipairs(C.wrap(rv.reason, w - 4)) do c.add('   ' .. l) end
    end
    local here = C.ops_at(id)
    c.add('')
    if #here == 0 then c.add(' “' .. G.steps[id].title .. '” is not touched by these revisions · n next change', 'Comment') end
    for _, h in ipairs(here) do
      local o = h.o
      c.add(' r' .. h.r.n .. ' ' .. (o.op == 'add' and '+ added' or '~ changed') .. ' ' .. (o.field or ''), o.op == 'add' and 'DDRevAdd' or 'DDRevChg')
      if o.before then c.add('   − ' .. o.before, 'DiffDelete') end
      if o.after and o.op ~= 'add' then c.add('   + ' .. o.after, 'DiffAdd') end
      c.add('   ✎ ' .. o.note, 'DDNote')
    end
  end
  return c.lines, c.hls
end
local function c_next(d)
  local ids = changed_ids()
  if #ids == 0 then return end
  local i = 0
  for k, id in ipairs(ids) do if id == U.S.sel then i = k end end
  local n = ((i - 1 + d) % #ids) + 1
  if i == 0 then n = d > 0 and 1 or #ids end
  U.select(ids[n])
end
local function c_tl_move(d)
  if not Cv.tl then return end
  local n = math.max(1, math.min(#C.revisions, (d > 0 and C.ov.to or C.ov.from) + d))
  ov_set(n, n); gsync()
end
Cv.keys = {
  a = function()
    local f = focus()
    input('Ask about “' .. f.label .. '”: ', function(q) C.ask(f, q); c_card { kind = 'thread', f = f } end)
  end,
  A = function() input('Ask about the whole dive: ', function(q) C.ask(C.DIVE, q); c_card { kind = 'thread', f = C.DIVE } end) end,
  p = function()
    local f = focus()
    input('What is wrong or missing at “' .. f.label .. '”? ', function(s) C.report(f, s); c_card { kind = 'thread', f = f } end)
  end,
  K = function()
    if valid(Cv.cw) then api.nvim_set_current_win(Cv.cw) return end
    local f = focus()
    if C.fix and C.fix.p.target == U.S.sel and not C.pending then c_card { kind = 'fix' }
    elseif C.threads[f.key] then c_card { kind = 'thread', f = f }
    else vim.notify('Deep dive: no thread here (a to ask)') return end
    if valid(Cv.cw) then api.nvim_set_current_win(Cv.cw) end
  end,
  ['!'] = function()
    local p = C.open_props()[1]
    if not p then vim.notify('Deep dive: no open proposals') return end
    local t = C.thread_of(p)
    U.select(p.target)
    c_card { kind = 'thread', f = t.focus }
  end,
  y = function() local was = C.pending; ACT.y(); if not was and C.fix then c_card { kind = 'fix' } end end,
  x = ACT.x, R = ACT.R, Q = ACT.Q, H = ACT.H, W = ACT.W, X = ACT.X,
  D = function()
    if #C.revisions == 0 then return end
    Cv.tl = not Cv.tl
    if Cv.tl then ov_set(#C.revisions, #C.revisions) else C.ov = nil end
    gsync()
  end,
  n = function() if c_mode() then c_next(1) end end,
  N = function() if c_mode() then c_next(-1) end end,
  ['[r'] = function() c_tl_move(-1) end,
  [']r'] = function() c_tl_move(1) end,
  ['{'] = function() if Cv.tl then ov_set(C.ov.from - 1, C.ov.to); gsync() end end,
  ['}'] = function() if Cv.tl then ov_set(C.ov.from, C.ov.to + 1); gsync() end end,
  ['<Esc>'] = function()
    if Cv.card then c_close_card()
    elseif Cv.tl then Cv.tl = false; C.ov = nil; gsync()
    else U.S.port = nil; U.S.overlay = nil; U.sync { nojump = true } end
  end,
}
function Cv.render(what)
  if C.fix and failed() and Cv.shown_fail ~= C.fix.attempt then
    Cv.shown_fail = C.fix.attempt
    if on_level(C.fix.p.target) or true then U.select(C.fix.p.target) end
    Cv.card = { kind = 'fix' }
  end
  if C.pending and Cv.seen ~= C.pending then
    Cv.seen = C.pending
    c_close_card()
    for _, op in ipairs(C.pending.ops) do if op.what == 'step' then U.select(op.id) break end end
  end
  if Cv.card and Cv.card.kind == 'fix' and (not C.fix or C.pending) then c_close_card() end
  if what == 'graph' then gsync() else
    if U.panel_open() then U.bars() end
    c_card_render()
  end
end
function Cv.on_sync()
  if Cv.card and Cv.card.kind == 'thread' and Cv.card.f.kind ~= 'dive' and Cv.card.f.key ~= focus().key then c_close_card() end
  c_card_render()
end
function Cv.badge(id)
  local b = badge(id)
  local t = C.ov and C.targets()[id]
  if t then b = b .. (t.op == 'add' and ' +' or ' ~') end
  return b
end
function Cv.activate() end
function Cv.deactivate() c_close_card(); Cv.tl = false; if C.ov and not C.ov.pending then C.ov = nil end end
Cv.help = {
  { 'Q&A (C: on the graph)' }, { 'a', 'ask: card on the node' }, { 'A', 'ask about whole dive' }, { 'K', 'open / enter card' },
  { '!', 'go to next open proposal' }, { 'y x R', 'accept / dismiss / reply' }, { 'D', 'revision timeline' },
  { 'n N', 'next / prev change' }, { '[r ]r { }', 'timeline move / range' }, { 'Q H W X', 'stuck: ask, hint, widen, abandon' },
}

-- =====================================================================
-- switcher + wiring
-- =====================================================================
-- PROTOTYPE boundary: the Q&A ticket picked A; B and C stay in the file but are no longer switchable.
-- [v ]v and the pill now belong to bd_views (Boundary variants).
local VARS = { A }
function V.cur() return VARS[V.i] end
V.A = A
V.api = { moved = function() return a_moved() end, arm = function() return a_arm() end, render_fix = function(c, w) return A.render_fix(c, w) end, cycle = function(d) return a_cycle(d) end,
  toggle = function() return a_toggle() end, prompt = function(...) return a_prompt(...) end, redraw = function() return a_redraw() end,
  tab = function(t) return a_tab(t) end, chip = chip, esc = esc, hintbar = function() return a_hintbar() end,
  gsync = gsync, focus = focus, cite_at = cite_at, bmap = bmap, scratch = scratch, winopts = winopts, valid = valid,
  back_to_graph = function() return back_to_graph() end }

local function pill()
  local v = V.cur()
  local text = ' ◀ [v   ' .. v.key .. ' · ' .. v.name .. '   ]v ▶    fail-sim ' .. (C.sim_fail and 'on' or 'off') .. ' (' .. U.keyname('<leader>dF') .. ') '
  V.pbuf = V.pbuf or api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(V.pbuf, 0, -1, false, { text })
  api.nvim_buf_clear_namespace(V.pbuf, U.ns, 0, -1)
  api.nvim_buf_set_extmark(V.pbuf, U.ns, 0, 0, { end_col = #text, hl_group = 'DDPill' })
  local w = vim.fn.strdisplaywidth(text)
  -- top-right of the code side, clear of the panel's bars
  local cfg = { relative = 'editor', row = 0, col = math.max(0, math.floor(vim.o.columns * 0.5) - w - 2), width = w, height = 1,
    style = 'minimal', focusable = false, zindex = 200, border = 'none' }
  if valid(V.pw) then api.nvim_win_set_config(V.pw, cfg) else
    cfg.noautocmd = true
    V.pw = api.nvim_open_win(V.pbuf, false, cfg)
  end
end

function V.switch(d)
  V.cur().deactivate()
  V.i = (V.i - 1 + d) % #VARS + 1
  V.cur().activate()
  pill()
  gsync()
end

function V.setup()
  C.hl_setup()
  P.hooks.badge = function(id) local v = V.cur(); return (v.badge or badge)(id) end
  P.hooks.node_hl = function(id) return C.node_hl(id) end
  P.hooks.details = function() local v = V.cur(); if v.details then return v.details() end end
  P.hooks.winbar = function() local v = V.cur(); if v.winbar then return v.winbar() end end
  P.hooks.status = function() local v = V.cur(); if v.status then return v.status() end end
  P.hooks.whole = function() local v = V.cur(); return v.whole and v.whole() end
  P.hooks.on_sync = function() local v = V.cur(); if v.on_sync then v.on_sync() end end
  P.hooks.on_open = function()
    local v = V.cur(); if v.on_open then v.on_open() end
  end
  P.hooks.help = function()
    return vim.list_extend({ { '<leader>dF', 'Q&A fail-sim on/off' } }, V.cur().help or {})
  end
  P.vkeys = setmetatable({}, { __index = function(_, k) return V.cur().keys[k] end })
  C.on(function(what) V.cur().render(what) end)
  vim.keymap.set('n', '<leader>dF', function() C.sim_fail = not C.sim_fail end, { desc = 'Deep dive proto: toggle fail-sim' })
  V.i = 1
  vim.schedule(function() V.cur().activate() end)
end

return V
