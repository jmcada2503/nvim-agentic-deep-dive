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
require('deepdive_proto.qa_views').setup() -- Q&A: variant A (decided)
require('deepdive_proto.bd_views').setup() -- boundary prototype: variant B (decided)
vim.api.nvim_create_autocmd('VimEnter', { callback = function()
  vim.api.nvim_echo({ { 'Deep dive prototype: ', 'Title' }, { 'the dive is paused at a Boundary: Run tab · ⇥ graph/tab · t T tabs · ? keys', 'Comment' } }, false, {})
end })
