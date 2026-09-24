-- mada - hand-written Lua sourced at startup, before the compiled modules
-- under lua/ load; must not require() them directly. Commands and the
-- FileType autocommand live here.

if vim.g.loaded_mada then
  return
end
vim.g.loaded_mada = true
