-- test/run.lua <spec.fnl> - runs under `nvim --headless -u NONE -l`.
-- Installs fennel (from LUA_PATH), prepends $MADA_RTP to runtimepath and
-- sources its plugin/mada.lua, then runs the spec's [name fn] pairs in
-- order, printing "ok name" or "FAIL name: err" for each. Writes directly to
-- the process's stdout with io.stdout:write + flush (not print/vim.print):
-- those route through Nvim's message/redraw machinery, which a mode change
-- (e.g. entering Insert) can clobber before it reaches the terminal, losing
-- output silently. Always ends with a "N tests, M failed" summary line and
-- an explicit os.exit, so a spec that errors while loading, defines zero
-- tests, or dies mid-run (never reaching the summary) is visibly a failure
-- rather than a silent, exit-0 no-op.

local fennel = require("fennel")
fennel.install()
fennel.path = fennel.path .. ";test/?.fnl"

local mada_rtp = os.getenv("MADA_RTP")
assert(mada_rtp and mada_rtp ~= "", "MADA_RTP must point at the built plugin")
vim.opt.runtimepath:prepend(mada_rtp)
vim.cmd.source(mada_rtp .. "/plugin/mada.lua")

local specpath = arg[1]
assert(specpath, "usage: nvim --headless -u NONE -l test/run.lua <spec.fnl>")

local function report(line)
  io.stdout:write(line, "\n")
  io.stdout:flush()
end

-- Return to Normal mode (and cancel any pending command-line) between
-- tests, so one test staying in Insert/cmdline mode cannot swallow the
-- next test's output or input.
local function cleanup()
  pcall(vim.cmd.stopinsert)
  pcall(vim.api.nvim_feedkeys,
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "xt",
        false)
end

local total = 0
local failed_count = 0

local load_ok, spec_or_err = pcall(fennel.dofile, specpath)
if not load_ok then
  report("FAIL " .. specpath .. ": failed to load spec: " ..
         tostring(spec_or_err))
  failed_count = failed_count + 1
else
  local spec = spec_or_err
  total = #spec
  if total == 0 then
    report("FAIL " .. specpath .. ": spec defines zero tests")
    failed_count = failed_count + 1
  else
    for _, pair in ipairs(spec) do
      local name, fn = pair[1], pair[2]
      local ok, err = xpcall(fn, debug.traceback)
      if ok then
        report("ok " .. name)
      else
        report("FAIL " .. name .. ": " .. tostring(err))
        failed_count = failed_count + 1
      end
      cleanup()
    end
  end
end

report(total .. " tests, " .. failed_count .. " failed")

os.exit(failed_count > 0 and 1 or 0)
