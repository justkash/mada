-- mada - hand-written Lua sourced at startup, before the compiled modules
-- under lua/ load; must not require() them directly. Commands and the
-- FileType autocommand live here.
--
-- Loads nothing (NFR-P9): the FileType autocommand and the already-loaded-
-- buffer scan below only require("mada") when a markdown buffer is actually
-- found. setup() may run before or after this file is sourced; the two
-- never clobber each other because they use separate augroups ("mada" is
-- owned by events.fnl, re-created on every setup() call) and attach() is
-- idempotent (FR-M1), so redundant attach calls from both paths are safe.

if vim.g.loaded_mada then
  return
end
vim.g.loaded_mada = true

local subcommands = { "enable", "disable", "toggle", "render", "clear" }

vim.api.nvim_create_user_command("Mada", function(cmd)
  require("mada").command(cmd)
end, {
  nargs = "+",
  bang = true,
  complete = function(arglead)
    return vim.tbl_filter(function(s)
      return s:sub(1, #arglead) == arglead
    end, subcommands)
  end,
})

-- Route through mada.log's guard so attach-plus-first-render (NFR-P8) is
-- timed and, like every other plugin callback, fail-safe (NFR-Q4): an error
-- here must not go uncaught just because it runs before the compiled
-- modules are otherwise touched.
local function guarded_on_filetype(buf)
  require("mada.log").guard("FileType", buf, function()
    require("mada").on_filetype(buf)
  end)
end

local grp = vim.api.nvim_create_augroup("mada.bootstrap", { clear = true })
vim.api.nvim_create_autocmd("FileType", {
  group = grp,
  pattern = "markdown",
  callback = function(ev)
    guarded_on_filetype(ev.buf)
  end,
})

-- Lazy-load coverage: this file may be sourced after a markdown buffer's
-- FileType event already fired (e.g. a lazy plugin manager). Only require()
-- the plugin if a matching buffer is actually found.
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "markdown" then
    guarded_on_filetype(buf)
  end
end
