-- PROTOTYPE (throwaway): minimal nvim config for trying the deep-dive panel on the demo workspace.
local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
vim.opt.rtp:prepend(here)
if vim.g.mapleader == nil then vim.g.mapleader = ' ' end
vim.o.termguicolors = true
vim.o.swapfile = false
vim.o.updatetime = 400
vim.o.signcolumn = 'yes'
vim.o.number = true
vim.o.laststatus = 2
vim.cmd('syntax on | filetype plugin on')
require('deepdive_proto').setup()
require('deepdive_proto.qa_views').setup() -- qa-revisions prototype: Q&A + Revision variants
vim.api.nvim_create_autocmd('VimEnter', { callback = function()
  vim.api.nvim_echo({ { 'Deep dive prototype: ', 'Title' }, { '␣dd graph panel   ? keys (in panel)   [v ]v layout variant   try: select “Retry?” inside “Charge card”, press a', 'Comment' } }, false, {})
end })
