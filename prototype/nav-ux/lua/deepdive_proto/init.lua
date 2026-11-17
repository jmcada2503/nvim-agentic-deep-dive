-- PROTOTYPE (throwaway) v3: Deep dive panel docked to the right of the user's own editor,
-- plus hints in the editor (signs, end-of-line labels, cursor popover) for anchored code.
local G = require('deepdive_proto.graph')
local api = vim.api
local M = {}

local ns = api.nvim_create_namespace('dd_panel')
local ns_anim = api.nvim_create_namespace('dd_anim')
local ns_sel = api.nvim_create_namespace('dd_sel')   -- selected step's range, in the editor
local ns_hint = api.nvim_create_namespace('dd_hint') -- signs + eol hints, in the editor

local CFG = { toggle = '<leader>dd', open_here = '<leader>dg', hints = '<leader>dh' }
local S = { mode = 'map', sel = 'sf.submit', port = nil, hist = {}, auto = true, overlay = nil, cs = 0, hints = true }
local W = {}
M.hooks = {} -- PROTOTYPE qa-revisions: variant hooks (badge, node_hl, details, winbar, status, on_sync, on_open, help)
M.vkeys = {}  -- variant key dispatch (falls back to base keys)
local MODES = { map = {}, zen = {} }
local OFF = 1          -- blank rows above the map canvas
local MARGIN_R, MARGIN_C = 4, 6

-- ---------- helpers ----------
local function dw(s) return vim.fn.strdisplaywidth(s) end
local function trunc(s, n)
  if dw(s) <= n then return s end
  return vim.fn.strcharpart(s, 0, n - 1) .. '…'
end
local function pad(s, n) return s .. string.rep(' ', math.max(0, n - dw(s))) end
local function wrap(s, n)
  local out, cur = {}, ''
  for word in s:gmatch('%S+') do
    if #cur > 0 and #cur + #word + 1 > n then out[#out + 1] = cur; cur = word
    else cur = (#cur > 0 and (cur .. ' ') or '') .. word end
  end
  if #cur > 0 then out[#out + 1] = cur end
  return out
end
local function charbyte(line, ci)
  if ci >= vim.fn.strchars(line) then return #line end
  return vim.fn.byteidx(line, ci)
end
local function put(buf, lines, hls)
  -- unchanged text: only redo highlights (keeps cursor and Visual selection, e.g. while browsing a list)
  if not vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), lines) then
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
  end
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hls or {}) do
    local line = lines[h.row + 1] or ''
    local c0 = h.c0 and charbyte(line, h.c0) or 0
    local c1 = h.c1 and charbyte(line, h.c1) or #line
    api.nvim_buf_set_extmark(buf, ns, h.row, c0, { end_col = c1, hl_group = h.hl, priority = h.prio or 100 })
  end
end
local function keyname(k)
  local leader = vim.g.mapleader or '\\'
  return (k:gsub('<leader>', leader == ' ' and '␣' or leader))
end

local function icon(id)
  local st = G.steps[id]
  if st.kind == 'decision' then return '◆' end
  if st.kind == 'boundary' then return '⇢' end
  if G.is_composite(id) then return '▣' end
  return '○'
end
local function kind_label(id)
  local st = G.steps[id]
  if G.is_composite(id) then return 'composite · ' .. #G.children(id) .. ' inside' end
  if st.kind == 'boundary' then return 'boundary · ' .. st.boundary.status end
  if st.kind == 'decision' then return 'decision' end
  return 'leaf'
end
local function badges(id)
  local st, b = G.steps[id], ''
  local u = G.unresolved(id)
  if u > 0 then b = b .. ' ⚠' .. u end
  if st.kind == 'boundary' and st.boundary.status == 'unresolved' and G.waiting ~= id then b = b .. ' ⚠' end
  if st.rev then b = b .. ' Δ' end
  if M.hooks.badge then b = b .. (M.hooks.badge(id) or '') end
  return b
end
local function crumbs(id)
  local parts = { G.title }
  for _, a in ipairs(G.ancestors(id)) do parts[#parts + 1] = G.steps[a].title end
  return table.concat(parts, '  ›  ')
end
local function anchor_str(a) return a.repo .. ':' .. a.path .. ':' .. a.s .. (a.e ~= a.s and ('-' .. a.e) or '') end
local KIND_HL = { leaf = 'Normal', decision = 'Statement', composite = 'Type', boundary = 'DiagnosticWarn' }
local function style_of(id)
  local st = G.steps[id]
  if st.kind == 'boundary' then return 'boundary' end
  if st.kind == 'decision' then return 'decision' end
  if G.is_composite(id) then return 'composite' end
  return 'leaf'
end

-- ---------- data ports ----------
local function ports(id)
  local L = G.layout(G.steps[id].parent)
  return L.inn[id] or {}, L.out[id] or {}, L
end
local function cur_edge()
  if not S.port or S.port.i == 0 then return nil end
  local ins, outs = ports(S.sel)
  return (S.port.dir == 'in' and ins or outs)[S.port.i]
end
local function shape_name(e) return e.shape .. (e.card == 'many' and '[]' or '') end
local function edge_label(e) return (e.when and (e.when .. ' · ') or '') .. shape_name(e) end
local function field_names(shape)
  local t = {}
  for _, f in ipairs(G.shapes[shape] or {}) do t[#t + 1] = f:match('^([^:]+)') end
  return table.concat(t, ', ')
end
local function used(id, e, dir)
  local out = {}
  for _, r in ipairs((dir == 'in' and G.steps[id].reads or G.steps[id].writes) or {}) do
    if vim.startswith(r, e.shape .. '.') then out[#out + 1] = r end
  end
  return out
end
local function none_msg(id, dir)
  local top = not G.steps[id].parent
  if dir == 'in' then
    return top and '∅ none: start of the whole flow' or '∅ none here: entry of this level (gets the parent step’s input)'
  end
  return top and '∅ none: end of the whole flow' or '∅ none here: exit of this level (becomes the parent step’s output)'
end
local function kids_in_flow(id)
  local L, out = G.layout(id), {}
  for _, layer in ipairs(L.layers) do for _, k in ipairs(layer) do out[#out + 1] = k end end
  return out
end
local function site_of(cid) local s = G.steps[cid]; return s.callsite or s.anchor, s.callsite ~= nil end

-- =====================================================================
-- Editor side (the user's own windows)
-- =====================================================================
local function is_panel_win(w)
  if w == W.main or w == W.det then return true end
  local ok, b = pcall(api.nvim_win_get_buf, w)
  -- PROTOTYPE qa-revisions: any deepdive:// buffer (prompt, chat, review, card) is ours, never the code editor
  return ok and (b == W.mbuf or b == W.dbuf or vim.startswith(api.nvim_buf_get_name(b), 'deepdive://'))
end
local function panel_open() return W.main ~= nil and api.nvim_win_is_valid(W.main) end
local function editor_win()
  if W.editor and api.nvim_win_is_valid(W.editor) and not is_panel_win(W.editor) then return W.editor end
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if not is_panel_win(w) and api.nvim_win_get_config(w).relative == '' then W.editor = w; return w end
  end
end

-- signs + end-of-line labels on every anchored range / call site of a loaded buffer
local function decorate(buf)
  if not api.nvim_buf_is_valid(buf) then return end
  api.nvim_buf_clear_namespace(buf, ns_hint, 0, -1)
  local items = G.files[api.nvim_buf_get_name(buf)]
  if not S.hints or not items then return end
  local nlines = api.nvim_buf_line_count(buf)
  local eol = {}
  for _, it in ipairs(items) do
    local a, st = it.a, G.steps[it.id]
    if a.e <= nlines then
      if it.kind == 'anchor' then
        local prio = 100 + math.max(0, 200 - (a.e - a.s)) -- innermost range wins the sign column
        for l = a.s, a.e do
          api.nvim_buf_set_extmark(buf, ns_hint, l - 1, 0, { sign_text = l == a.s and icon(it.id) or '│',
            sign_hl_group = l == a.s and 'DDSign' or 'DDSignDim', priority = prio })
        end
        eol[a.s] = eol[a.s] or {}
        table.insert(eol[a.s], { icon(it.id) .. ' ' .. st.title .. badges(it.id), 'DDHint' })
      else
        eol[a.s] = eol[a.s] or {}
        table.insert(eol[a.s], { '↳ ' .. icon(it.id) .. ' ' .. st.title, 'DDHintCall' })
      end
    end
  end
  for l, parts in pairs(eol) do
    local chunks = {}
    for i, p in ipairs(parts) do
      chunks[#chunks + 1] = { (i == 1 and '    ' or '  ·  '), 'DDHint' }
      chunks[#chunks + 1] = p
    end
    api.nvim_buf_set_extmark(buf, ns_hint, l - 1, 0, { virt_text = chunks, virt_text_pos = 'eol', hl_mode = 'combine' })
  end
end
local function decorate_all()
  for _, b in ipairs(api.nvim_list_bufs()) do if api.nvim_buf_is_loaded(b) then decorate(b) end end
end

-- the selected step's range, highlighted in whatever buffer shows it
local function refresh_sel()
  if W.selbuf and api.nvim_buf_is_valid(W.selbuf) then api.nvim_buf_clear_namespace(W.selbuf, ns_sel, 0, -1) end
  W.selbuf = nil
  if not panel_open() then return end
  local a = G.steps[S.sel].anchor
  local b = vim.fn.bufnr(a.file)
  if b == -1 or not api.nvim_buf_is_loaded(b) then return end
  for l = a.s, math.min(a.e, api.nvim_buf_line_count(b)) do
    api.nvim_buf_set_extmark(b, ns_sel, l - 1, 0, { line_hl_group = 'DDSel', priority = 20 })
  end
  W.selbuf = b
end

local function flash(buf, a)
  local ids = {}
  for l = a.s, a.e do
    ids[#ids + 1] = api.nvim_buf_set_extmark(buf, ns_sel, l - 1, 0, { line_hl_group = 'DDFlash', priority = 30 })
  end
  vim.defer_fn(function()
    if api.nvim_buf_is_valid(buf) then for _, id in ipairs(ids) do pcall(api.nvim_buf_del_extmark, buf, ns_sel, id) end end
  end, 700)
end

-- open range `a` in the user's editor window (keeps the jumplist, so <C-o> goes back)
local function show_in_editor(a)
  local ew = editor_win()
  if not ew then return end
  api.nvim_win_call(ew, function()
    if api.nvim_buf_get_name(0) ~= a.file then
      vim.cmd("normal! m'")
      vim.cmd('edit ' .. vim.fn.fnameescape(a.file))
    end
    api.nvim_win_set_cursor(0, { a.s, 0 })
    vim.cmd('normal! zz')
    flash(api.nvim_get_current_buf(), a)
  end)
  refresh_sel()
end
local function jump(id) show_in_editor(G.steps[id].anchor) end

-- cursor popover: which step this code belongs to + the key that opens it in the graph
local function steps_at(buf, line)
  local items = G.files[api.nvim_buf_get_name(buf)]
  if not items then return {} end
  local hits = {}
  for _, it in ipairs(items) do
    if line >= it.a.s and line <= it.a.e then
      hits[#hits + 1] = { id = it.id, kind = it.kind, s = it.a.s, size = (it.kind == 'call' and -1 or (it.a.e - it.a.s)) }
    end
  end
  table.sort(hits, function(x, y) return x.size < y.size end)
  return hits
end
local function close_pop()
  if W.pop and api.nvim_win_is_valid(W.pop) then api.nvim_win_close(W.pop, true) end
  W.pop = nil
end
local function popover()
  close_pop()
  local win = api.nvim_get_current_win()
  if not S.hints or is_panel_win(win) or api.nvim_win_get_config(win).relative ~= '' then return end
  -- only on the first line of an anchor / call site (the line carrying the eol hint); ␣dg still works anywhere inside
  local lnum = api.nvim_win_get_cursor(win)[1]
  local h
  for _, x in ipairs(steps_at(api.nvim_get_current_buf(), lnum)) do
    if x.s == lnum then h = x; break end
  end
  if not h then return end
  local st = G.steps[h.id]
  local lines = {
    ' ' .. (h.kind == 'call' and 'calls  ' or '') .. icon(h.id) .. ' ' .. st.title .. badges(h.id) .. ' ',
    ' ' .. trunc(crumbs(h.id), 60) .. ' ',
    ' ' .. keyname(CFG.open_here) .. '  open in graph ',
  }
  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, dw(l)) end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_row = 1, hl_group = 'DDPopTitle' })
  api.nvim_buf_set_extmark(buf, ns, 1, 0, { end_row = 2, hl_group = 'Comment' })
  api.nvim_buf_set_extmark(buf, ns, 2, 1, { end_col = 1 + #keyname(CFG.open_here), hl_group = 'DDKey' })
  W.pop = api.nvim_open_win(buf, false, { relative = 'cursor', row = 1, col = 2, width = width, height = #lines,
    style = 'minimal', border = 'rounded', focusable = false, zindex = 60, noautocmd = true })
end

-- =====================================================================
-- Panel (right side): map/zen on top, details below
-- =====================================================================
local function describe(id)
  local st = G.steps[id]
  local ins, outs, L = ports(id)
  local lines, hls = {}, {}
  local function add(s, hl, prio)
    lines[#lines + 1] = s
    if hl then hls[#hls + 1] = { row = #lines - 1, hl = hl, prio = prio } end
    return #lines - 1
  end
  add(icon(id) .. ' ' .. st.title .. '   ' .. st.group .. ' · ' .. kind_label(id) .. badges(id), 'Title')
  for _, l in ipairs(wrap(st.summary, 90)) do add('  ' .. l) end
  if st.condition then add('  condition  ' .. st.condition) end
  add('')
  local function block(dir, edges)
    local label = dir == 'in' and ' in  ◂ ' or ' out ▸ '
    local lh = dir == 'in' and 'DDIn' or 'DDOut'
    local fdir = S.port and S.port.dir == dir
    if #edges == 0 then
      local r = add((fdir and '▶' or ' ') .. (dir == 'in' and ' in    ' or ' out   ') .. none_msg(id, dir), fdir and 'Visual' or 'Comment', 150)
      hls[#hls + 1] = { row = r, c0 = 1, c1 = 6, hl = lh, prio = 160 }
      return
    end
    for i, e in ipairs(edges) do
      local foc = fdir and S.port.i == i
      local other = dir == 'in' and e.from or e.to
      local r = add((foc and '▶' or ' ') .. label .. shape_name(e) .. ' {' .. field_names(e.shape) .. '}  ' ..
        (dir == 'in' and '←' or '→') .. ' ' .. G.steps[other].title ..
        (e.when and ('  [' .. e.when .. ']') or '') .. (L.back[e] and '  ↺' or ''), foc and 'Visual' or nil, 150)
      hls[#hls + 1] = { row = r, c0 = 1, c1 = 6, hl = lh, prio = 160 }
      if foc then
        for _, f in ipairs(G.shapes[e.shape] or {}) do add('          ' .. f, 'Special') end
        local u = used(id, e, dir)
        if #u > 0 then add('          ' .. (dir == 'in' and 'read here   ' or 'written here  ') .. table.concat(u, ', '), 'Comment') end
        if e.transport then add('          via ' .. e.transport, 'Comment') end
        local d = G.shape_defs[e.shape]
        add('          ' .. (d and ('defined  ' .. d.repo .. '/' .. d.path .. ':' .. d.s) or 'defined  inline (no named type)'), 'Comment')
      end
    end
  end
  block('in', ins)
  block('out', outs)
  add('')
  add('  code    ' .. anchor_str(st.anchor), 'Comment')
  if st.parent then
    local site, own = site_of(id)
    add('  called  ' .. (own and anchor_str(site) or 'inline in parent code'), 'Comment')
  end
  if st.kind == 'boundary' then
    add('  target  ' .. st.boundary.transport .. ' · ' .. st.boundary.target .. ' · ' .. st.boundary.status, 'DiagnosticWarn')
  end
  if st.rev then add('  Δ revised in r' .. st.rev.n .. ' (' .. st.rev.kind .. ')', 'DiagnosticHint') end
  return lines, hls
end

local function data_pane(id)
  local ins, outs, L = ports(id)
  local CW = 50
  local function col(dir, edges)
    local rows = {}
    local fdir = S.port and S.port.dir == dir
    rows[1] = { s = dir == 'in' and 'IN  ◂' or 'OUT ▸', hl = dir == 'in' and 'DDIn' or 'DDOut' }
    if #edges == 0 then
      for k, l in ipairs(wrap(none_msg(id, dir), CW - 4)) do
        rows[#rows + 1] = { s = (k == 1 and fdir and '▶ ' or '  ') .. l, hl = fdir and 'Visual' or 'Comment' }
      end
      return rows
    end
    for i, e in ipairs(edges) do
      local foc = fdir and S.port.i == i
      local other = dir == 'in' and e.from or e.to
      rows[#rows + 1] = { s = (foc and '▶ ' or '  ') .. shape_name(e) .. (e.when and ('  [' .. e.when .. ']') or '') .. (L.back[e] and '  ↺' or ''), hl = foc and 'Visual' or 'Title' }
      rows[#rows + 1] = { s = '    ' .. (dir == 'in' and '← ' or '→ ') .. trunc(G.steps[other].title, CW - 8), hl = 'Comment' }
      for _, f in ipairs(G.shapes[e.shape] or {}) do rows[#rows + 1] = { s = '    ' .. trunc(f, CW - 6), hl = 'Special' } end
    end
    return rows
  end
  local l, r = col('in', ins), col('out', outs)
  local lines, hls = {}, {}
  for i = 1, math.max(#l, #r) do
    local a, b = l[i], r[i]
    lines[i] = pad(a and a.s or '', CW) .. '│ ' .. (b and b.s or '')
    if a and a.hl then hls[#hls + 1] = { row = i - 1, c0 = 0, c1 = CW, hl = a.hl, prio = 150 } end
    if b and b.hl then hls[#hls + 1] = { row = i - 1, c0 = CW + 2, hl = b.hl, prio = 150 } end
  end
  return lines, hls
end

local function details()
  local lines, hls
  if M.hooks.details then
    lines, hls = M.hooks.details()
    if lines then put(W.dbuf, lines, hls) return end
  end
  if S.overlay then lines, hls = S.overlay.lines, S.overlay.hls
  elseif S.mode == 'zen' then lines, hls = data_pane(S.sel)
  else lines, hls = describe(S.sel) end
  put(W.dbuf, lines, hls)
end
local function overlay(lines, hls)
  S.overlay = { lines = lines, hls = hls or {} }
  details()
end

-- sticky title: the winbar never scrolls
local function bars()
  local esc = function(s) return (s:gsub('%%', '%%%%')) end
  vim.wo[W.main].winbar = '%#DDMode# ' .. (S.mode == 'map' and 'MAP' or 'ZEN') .. ' %#DDCrumbs# %<' .. esc(crumbs(S.sel)) ..
      ' %=%#DDKey# ⇥ %#DDCrumbs# tab  %#DDKey# ? %#DDCrumbs# help '
  local wb = M.hooks.winbar and M.hooks.winbar()
  if wb then vim.wo[W.main].winbar = wb end
  local e = cur_edge()
  local foc = S.port and (' │ focus ' .. S.port.dir .. (e and (': ' .. edge_label(e)) or ': none')) or ''
  vim.wo[W.main].statusline = '%#StatusLine# ' .. icon(S.sel) .. ' ' .. esc(G.steps[S.sel].title) .. foc ..
      '%= ' .. (M.hooks.status and M.hooks.status() or '') .. ' code ' .. (S.auto and 'follows' or 'manual') .. ' '
end

-- keep box f (0-based rows/char cols) inside the view with a margin, cursor on (f.cr, f.cc)
local function reveal(f, mr, mc)
  if not panel_open() or not f then return end
  mr, mc = mr or MARGIN_R, mc or MARGIN_C
  local win = W.main
  local h, w = api.nvim_win_get_height(win), api.nvim_win_get_width(win)
  local view = api.nvim_win_call(win, vim.fn.winsaveview)
  local top, left = view.topline, view.leftcol
  local r0, r1 = f.r0 + 1 - mr, f.r1 + 1 + mr
  if r1 - r0 + 1 > h then top = math.max(1, f.r0 + 1 - 1)
  elseif r0 < top then top = math.max(1, r0)
  elseif r1 > top + h - 1 then top = r1 - h + 1 end
  local c0, c1 = f.c0 - mc, f.c1 + mc
  if c1 - c0 + 1 > w then left = math.max(0, f.c0 - 1)
  elseif c0 < left then left = math.max(0, c0)
  elseif c1 > left + w - 1 then left = c1 - w + 1 end
  local line = api.nvim_buf_get_lines(W.mbuf, f.cr, f.cr + 1, false)[1] or ''
  api.nvim_win_call(win, function()
    vim.fn.winrestview({ topline = top, leftcol = left, lnum = f.cr + 1, col = charbyte(line, f.cc) })
  end)
end

local anim
local function stop_anim()
  if anim then anim.timer:stop(); if not anim.timer:is_closing() then anim.timer:close() end; anim = nil end
  if W.mbuf and api.nvim_buf_is_valid(W.mbuf) then api.nvim_buf_clear_namespace(W.mbuf, ns_anim, 0, -1) end
end

local function sync(opts)
  opts = opts or {}
  if not panel_open() then return end
  stop_anim()
  local lines, hls, focus, meta = MODES[S.mode].render()
  S.meta = meta
  put(W.mbuf, lines, hls)
  details()
  bars()
  if not opts.noreveal then reveal(focus) end
  if S.auto and S.jumped ~= S.sel and not opts.nojump then
    jump(S.sel)
    S.jumped = S.sel
  end
  refresh_sel()
  if M.hooks.on_sync then M.hooks.on_sync() end
end

local function select(id, no_hist)
  if not id or not G.steps[id] then return end
  if not no_hist and id ~= S.sel then table.insert(S.hist, S.sel) end
  S.sel, S.port, S.overlay, S.cs = id, nil, nil, 0
  sync()
end

-- a dot travels along the edge away from the selected node (with the data on out edges, against it on in edges);
-- the view follows it and rests on the node at the far end
local function animate(e, final, backwards)
  local cells = S.meta and S.meta.paths and S.meta.paths[e]
  if not cells or #cells == 0 then reveal(final) return end
  if backwards then
    local r = {}
    for i = #cells, 1, -1 do r[#r + 1] = cells[i] end
    cells = r
  end
  stop_anim()
  local stride = math.max(1, math.ceil(#cells / 45))
  local i = 1
  local timer = vim.uv.new_timer()
  anim = { timer = timer }
  timer:start(0, 18, vim.schedule_wrap(function()
    if not anim or anim.timer ~= timer then return end
    if not panel_open() then stop_anim() return end
    api.nvim_buf_clear_namespace(W.mbuf, ns_anim, 0, -1)
    if i > #cells + stride then stop_anim(); reveal(final); return end
    local k = math.min(i, #cells)
    for t = 3, 0, -1 do
      local c = cells[k - t * stride]
      if c then
        local row = OFF + c.y
        local line = api.nvim_buf_get_lines(W.mbuf, row, row + 1, false)[1] or ''
        if vim.fn.strchars(line) > c.x then
          api.nvim_buf_set_extmark(W.mbuf, ns_anim, row, charbyte(line, c.x), {
            virt_text = { { t == 0 and '●' or '•', t == 0 and 'DDDot' or 'DDTrail' } }, virt_text_pos = 'overlay', priority = 400 })
        end
      end
    end
    local c = cells[k]
    reveal({ r0 = OFF + c.y, r1 = OFF + c.y, c0 = c.x, c1 = c.x, cr = OFF + c.y, cc = c.x }, 6, 10)
    i = i + stride
  end))
end

-- ---------- MAP: one level as boxes + routed edges ----------
local MASKCH = { [0] = ' ', [1] = '│', [2] = '│', [3] = '│', [4] = '─', [8] = '─', [12] = '─',
  [5] = '┘', [6] = '┐', [9] = '└', [10] = '┌', [7] = '┤', [11] = '├', [13] = '┴', [14] = '┬', [15] = '┼' }
local STY = {
  leaf = { '┌', '─', '┐', '│', '└', '┘', '┬' },
  decision = { '╭', '─', '╮', '│', '╰', '╯', '┬' },
  composite = { '╔', '═', '╗', '║', '╚', '╝', '╤' },
  boundary = { '┌', '┄', '┐', '┆', '└', '┘', '┬' },
}

MODES.map.render = function()
  local L = G.layout(G.steps[S.sel].parent)
  local NW, NH, GAP = 28, 6, 3
  local nl = #L.layers
  local maxn = 0
  for _, l in ipairs(L.layers) do maxn = math.max(maxn, #l) end
  local adj, long, backs = {}, {}, {}
  for _, e in ipairs(L.edges) do
    if L.back[e] then backs[#backs + 1] = e
    elseif L.layer[e.to] - L.layer[e.from] == 1 then adj[#adj + 1] = e
    else long[#long + 1] = e end
  end
  local ch = {}
  for c = 0, nl - 2 do ch[c] = {} end
  local rowof, srcrow = {}, {}
  for _, e in ipairs(adj) do
    local c = L.layer[e.from]
    srcrow[c] = srcrow[c] or {}
    if not srcrow[c][e.from] then table.insert(ch[c], e.from); srcrow[c][e.from] = #ch[c] end
    rowof[e] = { adj = srcrow[c][e.from] }
  end
  for _, e in ipairs(long) do
    local c1 = L.layer[e.from]
    table.insert(ch[c1], e); rowof[e] = { out = #ch[c1] }
    local c2 = L.layer[e.to] - 1
    table.insert(ch[c2], e); rowof[e].inn = #ch[c2]
  end
  local ly, y = {}, 0
  for i = 0, nl - 1 do
    ly[i] = y
    y = y + NH + ((i <= nl - 2) and (#ch[i] + 1) or 0)
  end
  local total_h = y
  local LEFT = 3 + 2 * #backs + (#backs > 0 and 16 or 0)
  local maxw = maxn * (NW + GAP) - GAP
  local pos = {}
  for i = 0, nl - 1 do
    local l = L.layers[i + 1]
    local off = LEFT + math.floor((maxw - (#l * (NW + GAP) - GAP)) / 2)
    for k, id in ipairs(l) do pos[id] = { x = off + (k - 1) * (NW + GAP), y = ly[i] } end
  end
  local RIGHT0 = LEFT + maxw + 14
  local width = RIGHT0 + 2 * #long + 4

  local grid = {}
  for r = 1, total_h do
    grid[r] = {}
    for c = 1, width do grid[r][c] = { m = 0 } end
  end
  local ec, paths = {}, {}
  local function ecell(e, x, yy) if e then ec[e] = ec[e] or {}; table.insert(ec[e], { x = x, y = yy }) end end
  local function put_ch(x, yy, chr, e) local c = grid[yy + 1] and grid[yy + 1][x + 1]; if c then c.ch = chr; ecell(e, x, yy) end end
  local function seg(x0, y0, x1, y1, e)
    if y0 == y1 then
      local a, b = math.min(x0, x1), math.max(x0, x1)
      for x = a, b do
        local c = grid[y0 + 1][x + 1]
        if x > a then c.m = bit.bor(c.m, 4) end
        if x < b then c.m = bit.bor(c.m, 8) end
        ecell(e, x, y0)
      end
    else
      local a, b = math.min(y0, y1), math.max(y0, y1)
      for yy = a, b do
        local c = grid[yy + 1][x0 + 1]
        if yy > a then c.m = bit.bor(c.m, 1) end
        if yy < b then c.m = bit.bor(c.m, 2) end
        ecell(e, x0, yy)
      end
    end
  end
  -- ordered polyline (data direction) -> list of cells, used by the animation
  local function path(e, pts)
    local cells = {}
    for i = 1, #pts - 1 do
      local a, b = pts[i], pts[i + 1]
      local dx = b[1] > a[1] and 1 or (b[1] < a[1] and -1 or 0)
      local dy = b[2] > a[2] and 1 or (b[2] < a[2] and -1 or 0)
      local x, yy = a[1], a[2]
      while true do
        if #cells == 0 or cells[#cells].x ~= x or cells[#cells].y ~= yy then cells[#cells + 1] = { x = x, y = yy } end
        if x == b[1] and yy == b[2] then break end
        x, yy = x + dx, yy + dy
      end
    end
    paths[e] = cells
  end

  for id, p in pairs(pos) do
    local sty = STY[style_of(id)]
    local inner = NW - 2
    local function row(yy, s)
      local n = vim.fn.strchars(s)
      for i = 0, NW - 1 do put_ch(p.x + i, p.y + yy, i < n and vim.fn.strcharpart(s, i, 1) or ' ') end
    end
    local function shapes_of(edges, mk)
      local seen, t = {}, {}
      for _, e in ipairs(edges or {}) do
        if not seen[e.shape] then seen[e.shape] = true; t[#t + 1] = shape_name(e) end
      end
      return #t == 0 and '∅ none' or (mk .. ' ' .. table.concat(t, ', '))
    end
    row(0, sty[1] .. string.rep(sty[2], inner) .. sty[3])
    row(1, sty[4] .. pad(' ' .. icon(id) .. ' ' .. trunc(G.steps[id].title, inner - 4), inner) .. sty[4])
    local b = badges(id)
    row(2, sty[4] .. pad(' ' .. trunc(G.steps[id].group, inner - 2 - dw(b)), inner - dw(b)) .. b .. sty[4])
    row(3, sty[4] .. pad(' in  ' .. trunc(shapes_of(L.inn[id], '◂'), inner - 5), inner) .. sty[4])
    row(4, sty[4] .. pad(' out ' .. trunc(shapes_of(L.out[id], '▸'), inner - 5), inner) .. sty[4])
    row(5, sty[5] .. string.rep(sty[2], inner) .. sty[6])
  end

  local function bcx(id) return pos[id].x + math.floor(NW / 2) end
  local labels = {}
  local function arrow_label(tx, ya, e) labels[#labels + 1] = { x = tx + 2, y = ya, s = edge_label(e), e = e } end
  for _, e in ipairs(adj) do
    local c = L.layer[e.from]
    local y0 = ly[c] + NH
    local yy = y0 + rowof[e].adj - 1
    local ya = y0 + #ch[c]
    local sx, tx = bcx(e.from), bcx(e.to)
    put_ch(sx, pos[e.from].y + NH - 1, STY[style_of(e.from)][7], e)
    seg(sx, y0 - 1, sx, yy, e)
    if tx ~= sx then seg(sx, yy, tx, yy, e) end
    seg(tx, yy, tx, ya, e)
    put_ch(tx, ya, '▼', e)
    arrow_label(tx, ya, e)
    path(e, { { sx, y0 - 1 }, { sx, yy }, { tx, yy }, { tx, ya + 1 } })
  end
  for k, e in ipairs(long) do
    local laneX = RIGHT0 + 2 * (k - 1)
    local c1, c2 = L.layer[e.from], L.layer[e.to] - 1
    local y0a, y0b = ly[c1] + NH, ly[c2] + NH
    local y1, y2 = y0a + rowof[e].out - 1, y0b + rowof[e].inn - 1
    local ya = y0b + #ch[c2]
    local sx, tx = bcx(e.from), bcx(e.to)
    put_ch(sx, pos[e.from].y + NH - 1, STY[style_of(e.from)][7], e)
    seg(sx, y0a - 1, sx, y1, e); seg(sx, y1, laneX, y1, e)
    seg(laneX, y1, laneX, y2, e); seg(laneX, y2, tx, y2, e)
    seg(tx, y2, tx, ya, e)
    put_ch(tx, ya, '▼', e)
    arrow_label(tx, ya, e)
    path(e, { { sx, y0a - 1 }, { sx, y1 }, { laneX, y1 }, { laneX, y2 }, { tx, y2 }, { tx, ya + 1 } })
  end
  for k, e in ipairs(backs) do
    local laneX = 1 + 2 * (k - 1)
    local sp, tp = pos[e.from], pos[e.to]
    local sy, ty = sp.y + 1, tp.y + 1
    seg(sp.x - 1, sy, laneX, sy, e); seg(laneX, sy, laneX, ty, e); seg(laneX, ty, tp.x - 1, ty, e)
    put_ch(tp.x - 1, ty, '▶', e)
    put_ch(sp.x, sy, STY[style_of(e.from)][4] == '║' and '╣' or '┤', e)
    put_ch(tp.x, ty, STY[style_of(e.to)][4] == '║' and '╣' or '┤', e)
    labels[#labels + 1] = { x = laneX + 2, y = sp.y, s = '↺ ' .. edge_label(e), e = e }
    path(e, { { sp.x, sy }, { laneX, sy }, { laneX, ty }, { tp.x, ty } })
  end
  local merged, order = {}, {}
  for _, lb in ipairs(labels) do
    local k = lb.x .. ':' .. lb.y
    if merged[k] then
      if not merged[k].s:find(lb.s, 1, true) then merged[k].s = merged[k].s .. ' | ' .. lb.s end
      table.insert(merged[k].es, lb.e)
    else merged[k] = { x = lb.x, y = lb.y, s = lb.s, es = { lb.e } }; order[#order + 1] = k end
  end
  for _, k in ipairs(order) do
    local lb = merged[k]
    for i = 0, vim.fn.strchars(lb.s) - 1 do
      local c = grid[lb.y + 1] and grid[lb.y + 1][lb.x + 1 + i]
      if not c or c.m ~= 0 or c.ch then break end
      c.ch = vim.fn.strcharpart(lb.s, i, 1)
      for _, e in ipairs(lb.es) do ecell(e, lb.x + i, lb.y) end
    end
  end

  local lines, hls = {}, {}
  local whole = M.hooks.whole and M.hooks.whole() -- PROTOTYPE qa-revisions: whole-dive focus selects everything visible
  for _ = 1, OFF do lines[#lines + 1] = '' end
  for r = 1, total_h do
    local t = {}
    for c = 1, width do
      local cell = grid[r][c]
      t[c] = cell.ch or MASKCH[cell.m] or '│'
    end
    lines[#lines + 1] = table.concat(t):gsub('%s+$', '')
    hls[#hls + 1] = { row = #lines - 1, hl = whole and 'DDWhole' or 'Comment', prio = 10 }
  end
  for _ = 1, MARGIN_R + 2 do lines[#lines + 1] = '' end
  local se = cur_edge()
  local other = se and (S.port.dir == 'in' and se.from or se.to)
  for id, p in pairs(pos) do
    local selected = whole or id == S.sel
    local ov = M.hooks.node_hl and M.hooks.node_hl(id)
    for r = 0, NH - 1 do
      local edge_row = r == 0 or r == NH - 1
      hls[#hls + 1] = { row = OFF + p.y + r, c0 = p.x, c1 = p.x + NW,
        hl = (ov and (not selected or edge_row)) and ov or (selected and 'Visual' or (id == other and 'Search' or KIND_HL[style_of(id)])),
        prio = (ov and edge_row) and 230 or (selected and 200 or (id == other and 150 or 100)) }
    end
    hls[#hls + 1] = { row = OFF + p.y + 3, c0 = p.x + 2, c1 = p.x + 7, hl = 'DDIn', prio = 210 }
    hls[#hls + 1] = { row = OFF + p.y + 4, c0 = p.x + 2, c1 = p.x + 7, hl = 'DDOut', prio = 210 }
    if id == S.sel and S.port then
      hls[#hls + 1] = { row = OFF + p.y + (S.port.dir == 'in' and 3 or 4), c0 = p.x + 1, c1 = p.x + NW - 1, hl = 'DDPort', prio = 220 }
    end
  end
  if se and ec[se] then
    for _, c in ipairs(ec[se]) do
      hls[#hls + 1] = { row = OFF + c.y, c0 = c.x, c1 = c.x + 1, hl = 'DDEdge', prio = 300 }
    end
  end
  local function box(id)
    local p = pos[id]
    return { r0 = OFF + p.y, r1 = OFF + p.y + NH - 1, c0 = p.x, c1 = p.x + NW - 1, cr = OFF + p.y + 1, cc = p.x + 2 }
  end
  -- with an edge focused the view rests on the node at the far end (source for in, target for out)
  local focus = box(other or S.sel)
  return lines, hls, focus, { paths = paths, box = box }
end

local function B_L() return G.layout(G.steps[S.sel].parent) end
local function sibling(d)
  local L = B_L()
  local layer = L.layers[L.layer[S.sel] + 1]
  for i, id in ipairs(layer) do if id == S.sel and layer[i + d] then select(layer[i + d], true) return end end
end
local function next_step()
  local L = B_L()
  for _, e in ipairs(L.out[S.sel] or {}) do if not L.back[e] then select(e.to) return end end
  for _, e in ipairs(L.out[S.sel] or {}) do select(e.to) return end
end
local function prev_step()
  local L = B_L()
  for _, e in ipairs(L.inn[S.sel] or {}) do if not L.back[e] then select(e.from) return end end
end
local function open_step() if G.is_composite(S.sel) then select(G.entry_child(S.sel)) else jump(S.sel) end end
local function zoom_out() if G.steps[S.sel].parent then select(G.steps[S.sel].parent) end end
local function back() local p = table.remove(S.hist); if p then select(p, true) end end
local NODEKEYS = {
  j = next_step, k = prev_step, h = function() sibling(-1) end, l = function() sibling(1) end,
  enter = open_step, out = zoom_out, bs = back,
  digit = function(n)
    local e = (B_L().out[S.sel] or {})[n]
    if e then select(e.to) end
  end,
}

-- ---------- ZEN: one step, story on top, full data below ----------
MODES.zen.render = function()
  local id = S.sel
  local st = G.steps[id]
  local ins, outs, L = ports(id)
  local lines, hls = {}, {}
  local function add(s, hl, prio)
    lines[#lines + 1] = s
    if hl then hls[#hls + 1] = { row = #lines - 1, hl = hl, prio = prio } end
  end
  add('')
  local function list(dir, edges)
    local fdir = S.port and S.port.dir == dir
    add(dir == 'in' and '  IN  ◂' or '  OUT ▸', dir == 'in' and 'DDIn' or 'DDOut')
    if #edges == 0 then
      add((fdir and '  ▶ ' or '    ') .. none_msg(id, dir), fdir and 'Visual' or 'Comment', 150)
      return
    end
    for i, e in ipairs(edges) do
      local foc = fdir and S.port.i == i
      local other = dir == 'in' and e.from or e.to
      add(string.format('  %s%s %s %s  %s  %s%s', foc and '▶ ' or '  ', dir == 'out' and ('[' .. i .. ']') or '   ',
        icon(other), pad(trunc(G.steps[other].title, 30), 30), dir == 'in' and '←' or '→',
        edge_label(e), L.back[e] and '   ↺' or ''), foc and 'Visual' or nil, 150)
    end
  end
  list('in', ins)
  add('                    │', 'Comment')
  add('                    ▼', 'Comment')
  local W_ = 72
  local sty = STY[style_of(id)]
  local function boxline(s) return sty[4] .. pad(' ' .. s, W_ - 2) .. sty[4] end
  add('  ' .. sty[1] .. string.rep(sty[2], W_ - 2) .. sty[3], KIND_HL[style_of(id)])
  add('  ' .. boxline(icon(id) .. ' ' .. st.title .. badges(id)), 'Title')
  add('  ' .. boxline(st.group .. ' · ' .. kind_label(id)), 'Comment')
  add('  ' .. boxline(''))
  for _, l in ipairs(wrap(st.summary, W_ - 6)) do add('  ' .. boxline(l)) end
  if st.condition then add('  ' .. boxline('condition  ' .. st.condition)) end
  if st.reads then add('  ' .. boxline('reads      ' .. table.concat(st.reads, ', '))) end
  if st.writes then add('  ' .. boxline('writes     ' .. table.concat(st.writes, ', '))) end
  add('  ' .. boxline('code       ' .. trunc(anchor_str(st.anchor), W_ - 16)))
  if st.kind == 'boundary' then add('  ' .. boxline(st.boundary.target .. ' · ' .. st.boundary.status), 'DiagnosticWarn') end
  if st.rev then add('  ' .. boxline('Δ revised in r' .. st.rev.n .. ' (' .. st.rev.kind .. ')'), 'DiagnosticHint') end
  add('  ' .. sty[5] .. string.rep(sty[2], W_ - 2) .. sty[6], KIND_HL[style_of(id)])
  add('                    │', 'Comment')
  add('                    ▼', 'Comment')
  list('out', outs)
  return lines, hls, { r0 = 0, r1 = 0, c0 = 0, c1 = 0, cr = 0, cc = 0 }, nil
end

-- ---------- edge (data) focus ----------
local function focus_port(dir, d)
  local ins, outs = ports(S.sel)
  local list = dir == 'in' and ins or outs
  if S.port and S.port.dir == dir then
    if #list > 0 then S.port.i = (S.port.i - 1 + (d or 1)) % #list + 1 end
  else
    S.port = { dir = dir, i = #list > 0 and 1 or 0 }
  end
  S.overlay = nil
  local e = cur_edge()
  sync { nojump = true, noreveal = e ~= nil and S.mode == 'map' }
  if e and S.mode == 'map' then
    local back = dir == 'in'
    animate(e, S.meta.box(back and e.from or e.to), back)
  end
end
local function follow()
  local e = cur_edge()
  if e then select(S.port.dir == 'in' and e.from or e.to) end
end
local function leave() S.port = nil; S.overlay = nil; sync { nojump = true } end
local PORTKEYS = {
  j = function() focus_port(S.port.dir, 1) end,
  k = function() focus_port(S.port.dir, -1) end,
  enter = follow,
}

-- ---------- actions ----------
local function act_ask()
  local st = G.steps[S.sel]
  vim.ui.input({ prompt = 'Ask about “' .. st.title .. '”: ' }, function(q)
    if not q or q == '' then return end
    local ins, outs = ports(S.sel)
    local e = cur_edge()
    overlay({ 'Q: ' .. q, '', 'Context sent to the agent (stored graph only, no new research):',
      '  • step        ' .. st.title .. '  (' .. anchor_str(st.anchor) .. ')',
      '  • parents     ' .. crumbs(S.sel),
      '  • neighbours  ' .. #ins .. ' in, ' .. #outs .. ' out, with summaries and Anchors',
      e and ('  • edge        ' .. edge_label(e)) or '',
      '', 'A: (prototype stub) answer streams here; graph changes would appear as a Revision.' },
      { { row = 0, hl = 'Title' }, { row = 2, hl = 'Comment' } })
  end)
end
local function act_repo()
  local st = G.steps[S.sel]
  if st.kind ~= 'boundary' then overlay({ 'Only boundary steps (⇢) can be pointed at a repo.' }, { { row = 0, hl = 'DiagnosticWarn' } }) return end
  vim.ui.input({ prompt = 'Repo that answers “' .. st.boundary.target .. '” (empty = keep unresolved): ' }, function(p)
    if not p or p == '' then overlay({ 'Boundary stays unresolved.' }) return end
    overlay({ '(prototype stub) would register ' .. p .. ' in the Workspace, send the agent there,',
      'and log an `extension` Revision replacing this boundary with that repo\'s steps.' }, { { row = 0, hl = 'Title' } })
  end)
end
local function act_diff()
  local st = G.steps[S.sel]
  if not st.rev then overlay({ 'No revisions touch this step.' }) return end
  local r = st.rev
  overlay({ 'Revision r' .. r.n .. '  (' .. r.kind .. ')   ' .. st.title, '', 'reason  ' .. r.reason, '',
    '- anchor  ' .. r.before, '+ anchor  ' .. r.after },
    { { row = 0, hl = 'Title' }, { row = 4, hl = 'DiffDelete' }, { row = 5, hl = 'DiffAdd' } })
end
local function act_site()
  local id = S.sel
  local target
  if G.is_composite(id) then
    local kids = kids_in_flow(id)
    S.cs = S.cs % #kids + 1
    target = kids[S.cs]
  elseif G.steps[id].parent then
    target = id
  else
    overlay({ 'Top-level step: no parent code calls it.' })
    return
  end
  show_in_editor((site_of(target)))
end

-- ---------- help (static) ----------
local HELP = {
  { 'MOVE' },
  { 'j', 'next step' }, { 'k', 'previous step' }, { 'h', 'left neighbour' }, { 'l', 'right neighbour' },
  { '⏎', 'open (zoom in / show code)' }, { '-', 'zoom out' }, { '⌫', 'back' }, { '1-9', 'go to next step n' },
  { 'DATA' },
  { 'i', 'inputs (repeat: next)' }, { 'o', 'outputs (repeat: next)' },
  { 'j', 'next edge, while on edges' }, { 'k', 'previous edge, while on edges' },
  { '⏎', 'follow edge, while on edges' }, { 'Esc', 'leave edges' },
  { 'CODE' },
  { 'g', 'go to code (edge: its data type)' }, { 'c', 'show call site' }, { 'f', 'code follows selection on/off' },
  { 'MORE' },
  { 'z', 'map / zen' }, { 'a', 'ask' }, { 'r', 'set repo of boundary' }, { 'd', 'revision diff' },
  { '?', 'help' }, { 'q', 'close panel' },
  { 'EDITOR' },
  { CFG.toggle, 'open / focus / close panel' }, { CFG.open_here, 'open step under cursor' }, { CFG.hints, 'hints on/off' },
  { 'ICONS' },
  { '○', 'step' }, { '▣', 'has steps inside' }, { '◆', 'decision' }, { '⇢', 'leaves known code' },
  { '⚠', 'unresolved boundary' }, { 'Δ', 'revised' }, { '↺', 'loops back' },
  { '◂ ▸', 'data in / out' }, { '[]', 'many' }, { '∅', 'none' }, { '↳', 'call site (editor)' },
}
local function help()
  local lines, hls = {}, {}
  local rows = vim.list_extend(vim.deepcopy(HELP), M.hooks.help and M.hooks.help() or {})
  for _, h in ipairs(rows) do
    if not h[2] then
      if #lines > 0 then lines[#lines + 1] = '' end
      lines[#lines + 1] = ' ' .. h[1]
      hls[#hls + 1] = { row = #lines - 1, c0 = 0, hl = 'Title' }
    else
      local k = keyname(h[1])
      lines[#lines + 1] = '  ' .. pad(k, 6) .. ' ' .. h[2]
      hls[#hls + 1] = { row = #lines - 1, c0 = 2, c1 = 2 + vim.fn.strchars(k), hl = 'DDKey' }
    end
  end
  -- two columns so it fits on screen
  -- split at the section break closest to the middle
  local split, best = #lines, math.huge
  for i, l in ipairs(lines) do
    if l == '' and math.abs(i - #lines / 2) < best then split, best = i, math.abs(i - #lines / 2) end
  end
  local CW = 38
  local out, ohl = {}, {}
  local nleft, nright = split - 1, #lines - split
  for i = 1, math.max(nleft, nright) do
    out[i] = pad(i <= nleft and lines[i] or '', CW) .. (lines[split + i] or '')
  end
  for _, h in ipairs(hls) do
    if h.row < nleft then ohl[#ohl + 1] = { row = h.row, c0 = h.c0, c1 = h.c1, hl = h.hl }
    else
      ohl[#ohl + 1] = { row = h.row - split, c0 = CW + h.c0, c1 = h.c1 and (CW + h.c1) or nil, hl = h.hl }
    end
  end
  local width = 0
  for _, l in ipairs(out) do width = math.max(width, dw(l)) end
  width = width + 2
  local buf = api.nvim_create_buf(false, true)
  put(buf, out, ohl)
  local win = api.nvim_open_win(buf, true, { relative = 'editor', width = width, height = #out,
    row = math.floor((vim.o.lines - #out) / 2) - 1, col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal', border = 'rounded', title = ' Deep dive keys ', title_pos = 'center' })
  for _, key in ipairs({ 'q', '<Esc>', '?' }) do
    vim.keymap.set('n', key, function() if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end end, { buffer = buf, nowait = true })
  end
end

-- ---------- panel lifecycle ----------
local function setkeys(buf)
  local function key(k, name)
    vim.keymap.set('n', k, function()
      local f = (S.port and PORTKEYS[name]) or NODEKEYS[name]
      if S.port and not PORTKEYS[name] then S.port = nil end
      if f then f() end
    end, { buffer = buf, nowait = true, silent = true })
  end
  for _, p in ipairs({ { 'j', 'j' }, { 'k', 'k' }, { 'h', 'h' }, { 'l', 'l' }, { '<CR>', 'enter' }, { '<BS>', 'bs' }, { '-', 'out' } }) do
    key(p[1], p[2])
  end
  for n = 1, 9 do
    vim.keymap.set('n', tostring(n), function() NODEKEYS.digit(n) end, { buffer = buf, nowait = true, silent = true })
  end
  local function map(k, fn) vim.keymap.set('n', k, fn, { buffer = buf, nowait = true, silent = true }) end
  map('z', function() S.mode = S.mode == 'map' and 'zen' or 'map'; S.overlay = nil; sync { nojump = true } end)
  map('i', function() focus_port('in') end)
  map('o', function() focus_port('out') end)
  map('<Esc>', function() if S.port or S.overlay then leave() end end)
  map('c', act_site)
  -- g: show the code in the editor and put the cursor there (panel stays open).
  -- on a focused edge: the definition of the Data shape it carries
  map('g', function()
    local e = cur_edge()
    if e then
      local d = G.shape_defs[e.shape]
      if d then show_in_editor(d)
      else vim.notify(e.shape .. ' has no named definition (inline type)', vim.log.levels.INFO); return end
    else
      jump(S.sel); S.jumped = S.sel
    end
    local ew = editor_win()
    if ew then api.nvim_set_current_win(ew) end
  end)
  map('f', function() S.auto = not S.auto; S.jumped = nil; sync() end)
  map('a', act_ask)
  map('d', act_diff)
  -- PROTOTYPE qa-revisions: keys the active variant may claim; unclaimed ones fall back to the base action
  local BASE = { a = act_ask, r = act_repo, ['<Esc>'] = function() if S.port or S.overlay then leave() end end }
  for _, k in ipairs({ 'a', 'A', 'p', 'y', 'x', 'R', 'Q', 'H', 'W', 'X', 't', 'T', '<Tab>', 'K', '!', 'n', 'N', '[r', ']r', '{', '}', '<Esc>',
    'r', 's', 'e', 'S', 'L', 'u', 'b', 'B' }) do -- PROTOTYPE boundary: s e S L u b B r
    map(k, function()
      local f = M.vkeys[k]
      if f then f() elseif BASE[k] then BASE[k]() end
    end)
  end
  map('?', help)
  map('q', function() M.close() end)
end

local function scratch(name)
  local b = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(b, name)
  vim.bo[b].bufhidden = 'hide'
  vim.bo[b].modifiable = false
  return b
end

function M.open(focus)
  if panel_open() then
    if focus ~= false then api.nvim_set_current_win(W.main) end
    return
  end
  local ed = not is_panel_win(api.nvim_get_current_win()) and api.nvim_get_current_win() or W.editor
  if not (W.mbuf and api.nvim_buf_is_valid(W.mbuf)) then
    W.mbuf = scratch('deepdive://graph')
    W.dbuf = scratch('deepdive://details')
    setkeys(W.mbuf)
    vim.keymap.set('n', '?', help, { buffer = W.dbuf, nowait = true })
    vim.keymap.set('n', 'q', function() M.close() end, { buffer = W.dbuf, nowait = true })
  end
  W.main = api.nvim_open_win(W.mbuf, true, { split = 'right', win = -1, width = math.max(72, math.floor(vim.o.columns * 0.5)) })
  W.det = api.nvim_open_win(W.dbuf, false, { split = 'below', win = W.main, height = 14 })
  W.editor = ed -- WinEnter fired for the new split before it held the graph buffer
  for _, w in ipairs({ W.main, W.det }) do
    vim.wo[w].number = false
    vim.wo[w].relativenumber = false
    vim.wo[w].wrap = false
    vim.wo[w].signcolumn = 'no'
    vim.wo[w].foldcolumn = '0'
    vim.wo[w].list = false
    vim.wo[w].cursorline = false
    vim.wo[w].scrolloff = 0
    vim.wo[w].sidescrolloff = 0
    vim.wo[w].winfixwidth = true
  end
  vim.wo[W.det].winbar = '%#DDCrumbs# details'
  vim.wo[W.det].statusline = ' '
  S.jumped = S.sel -- opening never moves the user's editor
  if M.hooks.on_open then M.hooks.on_open() end
  sync()
  if focus == false and W.editor and api.nvim_win_is_valid(W.editor) then api.nvim_set_current_win(W.editor) end
end

function M.close()
  stop_anim()
  for _, w in ipairs({ W.det, W.main }) do
    if w and api.nvim_win_is_valid(w) and #api.nvim_tabpage_list_wins(0) > 1 then api.nvim_win_close(w, true) end
  end
  W.main, W.det = nil, nil
  refresh_sel()
  if W.editor and api.nvim_win_is_valid(W.editor) then api.nvim_set_current_win(W.editor) end
end

-- open -> focus (if the cursor is in the editor) -> close
function M.toggle()
  if not panel_open() then M.open()
  elseif not is_panel_win(api.nvim_get_current_win()) then api.nvim_set_current_win(W.main)
  else M.close() end
end

function M.open_here()
  local buf = api.nvim_get_current_buf()
  local hits = steps_at(buf, api.nvim_win_get_cursor(0)[1])
  if #hits == 0 then
    vim.notify('Deep dive: no step anchored here', vim.log.levels.INFO)
    return
  end
  close_pop()
  W.editor = api.nvim_get_current_win()
  local id = hits[1].id
  if id ~= S.sel then table.insert(S.hist, S.sel) end
  S.sel, S.port, S.overlay = id, nil, nil
  S.jumped = id -- you are already looking at its code
  if panel_open() then sync(); api.nvim_set_current_win(W.main) else M.open() end
end

function M.toggle_hints()
  S.hints = not S.hints
  close_pop()
  decorate_all()
end

function M.setup(opts)
  opts = opts or {}
  CFG = vim.tbl_extend('force', CFG, opts.keys or {})
  local hl = function(n, v) api.nvim_set_hl(0, n, v) end
  hl('DDIn', { fg = '#61afef', bold = true })
  hl('DDOut', { fg = '#d19a66', bold = true })
  hl('DDPort', { bold = true, underline = true })
  hl('DDEdge', { fg = '#1e1e1e', bg = '#e5c07b', bold = true })
  hl('DDDot', { fg = '#ff5f87', bold = true })
  hl('DDTrail', { fg = '#ff87af' })
  hl('DDKey', { fg = '#1e1e1e', bg = '#98c379', bold = true })
  hl('DDMode', { fg = '#1e1e1e', bg = '#c678dd', bold = true })
  hl('DDCrumbs', { link = 'Title' })
  hl('DDHint', { fg = '#5c6370', italic = true })
  hl('DDHintCall', { fg = '#56b6c2', italic = true })
  hl('DDSign', { fg = '#c678dd', bold = true })
  hl('DDSignDim', { fg = '#4b5263' })
  hl('DDSel', { bg = '#2c313c' })
  hl('DDFlash', { bg = '#3e4452' })
  hl('DDPopTitle', { bold = true })

  vim.keymap.set('n', CFG.toggle, M.toggle, { desc = 'Deep dive: toggle graph panel' })
  vim.keymap.set('n', CFG.open_here, M.open_here, { desc = 'Deep dive: open step under cursor' })
  vim.keymap.set('n', CFG.hints, M.toggle_hints, { desc = 'Deep dive: toggle hints' })

  local grp = api.nvim_create_augroup('deepdive_proto', { clear = true })
  api.nvim_create_autocmd({ 'BufWinEnter', 'BufReadPost' }, { group = grp, callback = function(a) decorate(a.buf); refresh_sel() end })
  api.nvim_create_autocmd('CursorHold', { group = grp, callback = popover })
  api.nvim_create_autocmd({ 'CursorMoved', 'InsertEnter', 'BufLeave', 'WinLeave' }, { group = grp, callback = close_pop })
  api.nvim_create_autocmd('WinEnter', { group = grp, callback = function()
    local w = api.nvim_get_current_win()
    if not is_panel_win(w) and api.nvim_win_get_config(w).relative == '' then W.editor = w end
  end })
  api.nvim_create_autocmd('WinClosed', { group = grp, callback = function(a)
    local w = tonumber(a.match)
    if w == W.main then
      vim.schedule(function() if W.det and api.nvim_win_is_valid(W.det) then pcall(api.nvim_win_close, W.det, true) end; W.det = nil; refresh_sel() end)
      W.main = nil
      stop_anim()
    end
  end })
  decorate_all()
end

M._S, M._W, M._sync, M._select = S, W, sync, select
M._ = { S = S, W = W, G = G, sync = sync, select = select, put = put, details = details, bars = bars, crumbs = crumbs,
  icon = icon, anchor_str = anchor_str, wrap = wrap, trunc = trunc, pad = pad, dw = dw, charbyte = charbyte,
  ports = ports, cur_edge = cur_edge, edge_label = edge_label, shape_name = shape_name, show_in_editor = show_in_editor,
  keyname = keyname, panel_open = panel_open, editor_win = editor_win, ns = ns, kind_label = kind_label, reveal = reveal,
  describe = describe, decorate_all = decorate_all, badges = badges, style_of = style_of }
return M
