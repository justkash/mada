-- bench/latency.lua - AT-24: latency of a scripted session on the reference
-- document, with and without the plugin, reported against requirements
-- §5.1 budgets. Hand-written Lua (like plugin/mada.lua), not compiled.
--
-- Usage: nvim --headless -u NONE -l bench/latency.lua <reference.md>
-- Env:   MADA_RTP - the built plugin, prepended to the child's runtimepath
--
-- `CursorMoved`/`WinScrolled`/`TextChanged` are deferred autocommands: they
-- never fire from `nvim_feedkeys` in a `-l` script (architecture.md §15,
-- OQ-5). So this script drives a *child* Neovim over RPC instead: real
-- `nvim_input` reaches the child's own event loop, where those handlers do
-- fire before the child answers the next request.
--
-- Exits 0 regardless of PASS/FAIL: this is a report, not a `nix flake check`.

local doc = arg[1]
if not doc then
  io.stderr:write("usage: nvim --headless -u NONE -l bench/latency.lua <reference.md>\n")
  os.exit(0)
end
doc = vim.fn.fnamemodify(doc, ":p")

local mada_rtp = os.getenv("MADA_RTP")
if not mada_rtp then
  io.stderr:write("warning: MADA_RTP not set; the plugin run will not attach the plugin\n")
end

-- ------------------------------------------------------------------ child

--- Spawn a headless, embedded child Neovim; returns its RPC channel id.
--- No UI is attached: an early version of this script attached one (to
--- make redraw - and so the tree-sitter highlighter's on_win/on_line -
--- actually run for the P6 measurement below), but a real scripted session
--- produces enough `redraw` notification traffic back to this process's own
--- embedding channel to hang it. `nvim__redraw` (below) gets the same
--- decoration-provider effect without a UI or any notification stream.
local function spawn()
  -- `-n -i NONE`: this script kills the child with jobstop rather than
  -- letting it exit cleanly, which otherwise leaves a swap file behind in
  -- `stdpath("state")/swap` on every run; later runs then open the
  -- reference document against a pile of stale swap files, which measurably
  -- degrades TextChanged latency run over run (verified: P10 crept
  -- 12 -> 19 -> 23 -> 39 ms across runs against a swap-littered state dir).
  local chan = vim.fn.jobstart(
    { "nvim", "--embed", "--headless", "-n", "-i", "NONE", "-u", "NONE" },
    { rpc = true }
  )
  if chan <= 0 then
    error("failed to start child nvim (jobstart returned " .. tostring(chan) .. ")")
  end
  return chan
end

-- Hard wall-clock timeout for every synchronous request to a child: this is
-- a report, not something the caller should ever have to `C-c` or kill by
-- hand. Neovim's blocking RPC wait still pumps the event loop, so a uv
-- timer armed just before it fires on schedule even while it blocks;
-- jobstop force-closes the channel, which unblocks the pending request with
-- an error instead of hanging forever.
local RPC_TIMEOUT_MS = 4000

local function safe_rpcrequest(chan, ...)
  local timer = vim.uv.new_timer()
  timer:start(RPC_TIMEOUT_MS, 0, function()
    pcall(vim.fn.jobstop, chan)
  end)
  local ok, result = pcall(vim.rpcrequest, chan, ...)
  timer:stop()
  timer:close()
  if not ok then
    error("rpc timed out or errored: " .. tostring(result))
  end
  return result
end

--- One round trip to the child. Forces it to process any pending typeahead
--- and run deferred autocommands before replying (the idiom requirements.md
--- OQ-5 verifies: `nvim_input` then a synchronous request).
local function sync(chan)
  return safe_rpcrequest(chan, "nvim_eval", "1")
end

local function input(chan, keys)
  safe_rpcrequest(chan, "nvim_input", keys)
  return sync(chan)
end

local function exec_lua(chan, code, args)
  return safe_rpcrequest(chan, "nvim_exec_lua", code, args or {})
end

--- One `nvim_input` + sync round trip, plus a forced redraw, timed with
--- vim.uv.hrtime. Returns ms. The redraw is what makes this measure NFR-P6
--- honestly: no UI is attached (see `spawn`), so without it Neovim would
--- never redraw at all, and the tree-sitter highlighter's per-keystroke
--- decoration-provider cost (on_win/on_line) - exactly what NFR-P6 budgets
--- - would never run. `nvim__redraw({flush = true})` is the same headless,
--- no-UI-needed mechanism Neovim's own functional tests use to force it.
--- Both the baseline and the plugin session pay for the same extra round
--- trip, so it cancels out of the delta.
local function timed_input(chan, keys)
  local t0 = vim.uv.hrtime()
  input(chan, keys)
  exec_lua(chan, "vim.api.nvim__redraw({flush = true})")
  return (vim.uv.hrtime() - t0) / 1e6
end

--- Read `require("mada.log").timings()` from the child, then clear its
--- rings in the same round trip (atomic: nothing can fire between the read
--- and the clear). Tolerates a missing module or API (nil), since the
--- plugin's `log.fnl` may not have landed `timings()`/`clear_timings()` yet.
--- Rings hold only the last 100 samples per label; reading-then-clearing
--- every phase (`accumulate`, below) means a phase producing more than 100
--- events of one label never silently drops the earliest ones, and a label
--- already read is never counted again in a later phase's read.
local function read_timings(chan)
  local ok, result = pcall(exec_lua, chan, [[
    local ok, log = pcall(require, "mada.log")
    if not ok or type(log.timings) ~= "function" then return nil end
    local t = log.timings()
    if type(log.clear_timings) == "function" then log.clear_timings() end
    return t
  ]])
  if ok then
    return result
  end
  return nil
end

--- Merge b's {[label] = {ms, ...}} into a, in place.
local function merge_timings(a, b)
  for label, samples in pairs(b or {}) do
    a[label] = a[label] or {}
    for _, v in ipairs(samples) do
      table.insert(a[label], v)
    end
  end
end

-- ------------------------------------------------------------------ session

--- Run the AT-24 scripted session against child `chan`: open, 200 x j,
--- 20 x <C-e> (one-line scroll, NFR-P7), 20 x <C-f> (page scroll,
--- informational only: NFR-P7 budgets a one-line scroll, not a full-page
--- render), G, gg, 10 x (dd, u), i + 500 typed characters, <Esc>. When `acc`
--- is given, per-label timings are read from the child and merged into it
--- after every phase (the log ring holds only the last 100 samples per
--- label, so reading only at the end would lose CursorMoved/WinScrolled
--- history from earlier phases). `WinScrolled` samples from the one-line
--- and the page/jump (page scroll plus G/gg) phases are read and cleared
--- separately, right after each phase, and stored under distinct keys
--- (`WinScrolled:oneline`, `WinScrolled:page`) so the two never mix even
--- though `events.fnl` records both under the same `WinScrolled` label.
--- Every event is also timed end-to-end (input + sync + a forced
--- `nvim__redraw` flush, via `timed_input`), so callers can see both the
--- plugin callback's own cost (`acc`) and what a user actually waits for
--- including redraw/decoration-provider work (`e2e`): the two can differ
--- substantially when a tree-sitter highlighter is active (FR-M10), because
--- its per-redraw parse/query cost is invisible to the plugin callback
--- timer but not to the user. Returns `{keystrokes, e2e = {FileType,
--- CursorMoved, WinScrolledLine, WinScrolledPage, TextChanged}}` (each an ms
--- array).
local function run_session(chan, acc)
  --- Read-and-clear the child's timing rings; when `relabel` is given, the
  --- `WinScrolled` samples of this phase (if any) are stored under
  --- `relabel` instead of `WinScrolled`, so a later phase's WinScrolled
  --- samples never merge with this phase's.
  local function accumulate(relabel)
    if acc then
      local t = read_timings(chan)
      if relabel and t and t.WinScrolled then
        acc[relabel] = acc[relabel] or {}
        for _, v in ipairs(t.WinScrolled) do
          table.insert(acc[relabel], v)
        end
        t.WinScrolled = nil
      end
      merge_timings(acc, t)
    end
  end

  local e2e = {
    FileType = {},
    CursorMoved = {},
    WinScrolledLine = {},
    WinScrolledPage = {},
    TextChanged = {},
  }

  table.insert(e2e.FileType, timed_input(chan, ":edit " .. vim.fn.fnameescape(doc) .. "<CR>"))
  accumulate()

  -- 200 CursorMoved events: read (and clear) the 100-entry ring in chunks
  -- so no sample is dropped (see read_timings).
  for _ = 1, 4 do
    for _ = 1, 50 do
      table.insert(e2e.CursorMoved, timed_input(chan, "j"))
    end
    accumulate()
  end

  -- NFR-P7: a one-line scroll only.
  for _ = 1, 20 do
    table.insert(e2e.WinScrolledLine, timed_input(chan, "<C-e>"))
  end
  accumulate("WinScrolled:oneline")

  -- Informational only, not NFR-P7: a full-page scroll and large jumps
  -- render much more than a one-line scroll's newly exposed rows.
  for _ = 1, 20 do
    table.insert(e2e.WinScrolledPage, timed_input(chan, "<C-f>"))
  end
  input(chan, "G")
  input(chan, "gg")
  accumulate("WinScrolled:page")

  for _ = 1, 10 do
    table.insert(e2e.TextChanged, timed_input(chan, "dd"))
    table.insert(e2e.TextChanged, timed_input(chan, "u"))
  end
  accumulate()

  input(chan, "i")
  accumulate()

  local keystrokes = {}
  local text = "the quick brown fox jumps over the lazy dog while mada renders markdown in place "
  for i = 1, 500 do
    local c = text:sub(((i - 1) % #text) + 1, ((i - 1) % #text) + 1)
    table.insert(keystrokes, timed_input(chan, c))
  end

  input(chan, "<Esc>")
  accumulate()

  return { keystrokes = keystrokes, e2e = e2e }
end

--- Baseline: syntax on, filetype plugin on (Neovim 0.12's real default:
--- `ftplugin/markdown.lua` starts a tree-sitter highlighter on every
--- markdown buffer this way), no plugin. `filetype plugin on`, not just
--- `filetype on`, so both the baseline and the plugin child pay for the
--- same runtime highlighter cost (NFR-P6) instead of measuring a
--- configuration nobody actually runs.
local function init_baseline(chan)
  exec_lua(chan, [[
    vim.cmd("syntax on")
    vim.cmd("filetype plugin on")
    vim.o.columns = 80
    vim.o.lines = 82
  ]])
end

--- Plugin: MADA_RTP prepended to rtp, plugin/mada.lua sourced explicitly
--- (`-u NONE` sets 'loadplugins' off, so runtimepath/plugin/ is not
--- auto-sourced), then filetype plugin on (same real default as the
--- baseline above) so `:edit` attaches the plugin and Neovim's own
--- `ftplugin/markdown.lua` starts its runtime highlighter alongside it.
local function init_plugin(chan, rtp)
  exec_lua(chan, string.format([[
    vim.opt.rtp:prepend(%q)
    vim.cmd("source " .. %q .. "/plugin/mada.lua")
    vim.cmd("filetype plugin on")
    vim.o.columns = 80
    vim.o.lines = 82
  ]], rtp, rtp))
end

--- Run `body(chan)` against a freshly spawned child; always stops it.
--- Returns `ok, result_or_error`.
local function with_child(body)
  local chan = spawn()
  local ok, result = pcall(body, chan)
  pcall(vim.fn.jobstop, chan)
  return ok, result
end

local baseline_keys, baseline_e2e = {}, {}
local ok, result = with_child(function(chan)
  init_baseline(chan)
  return run_session(chan, nil)
end)
if ok then
  baseline_keys, baseline_e2e = result.keystrokes, result.e2e
else
  io.stderr:write("baseline session failed: " .. tostring(result) .. "\n")
end

local plugin_keys, plugin_timings, plugin_e2e = {}, {}, {}
ok, result = with_child(function(chan)
  init_plugin(chan, mada_rtp or "")
  return run_session(chan, plugin_timings)
end)
if ok then
  plugin_keys, plugin_e2e = result.keystrokes, result.e2e
else
  io.stderr:write("plugin session failed: " .. tostring(result) .. "\n")
end

-- ------------------------------------------------------------------ report

--- p `(0-1)` percentile of a numeric list (copied and sorted ascending).
local function percentile(samples, p)
  if not samples or #samples == 0 then
    return nil
  end
  local sorted = vim.deepcopy(samples)
  table.sort(sorted)
  local idx = math.max(1, math.min(#sorted, math.ceil(p * #sorted)))
  return sorted[idx]
end

local function stats(samples)
  if not samples or #samples == 0 then
    return nil
  end
  return { n = #samples, p95 = percentile(samples, 0.95), max = percentile(samples, 1.0) }
end

local function fmt(v)
  if v == nil then
    return "n/a"
  end
  return string.format("%.2f", v)
end

-- requirements.md §5.1
local budgets = {
  P1 = { p95 = 10, max = 16 },
  P2 = { p95 = 1, max = 2 },
  P3 = { p95 = 0.5, max = 2 },
  P6 = { p95 = 2, max = 8 },
  P7 = { p95 = 1.5, max = 4 },
  P8 = { p95 = 50, max = 60 },
  P10 = { p95 = 25, max = 40 },
}

-- ID, displayed event name, timings() label. `events.fnl` records the two
-- ModeChanged directions under distinct labels (entering raw is NFR-P2;
-- entering rendered mode is a full render -- graded P10, since leaving
-- Insert is a parse-bound edit-adjacent event), so they no longer mix.
-- `WinScrolled:oneline` (NFR-P7) and `WinScrolled:page` (NFR-P1: a full
-- viewport-range render with no pending edit -- jump/page scroll) are
-- relabeled by `run_session`, not `events.fnl` (both come from the same
-- `WinScrolled` autocommand label there).
local rows = {
  { id = "P1", event = "WinScrolled (page/jump)", label = "WinScrolled:page" },
  { id = "P10", event = "TextChanged", label = "TextChanged" },
  { id = "P10", event = "ModeChanged (rendered)", label = "ModeChanged:rendered" },
  { id = "P2", event = "ModeChanged (raw)", label = "ModeChanged:raw" },
  { id = "P3", event = "CursorMoved", label = "CursorMoved" },
  { id = "P7", event = "WinScrolled (1-line)", label = "WinScrolled:oneline" },
  { id = "P8", event = "FileType", label = "FileType" },
}

-- Informational only (no §5.1 budget): the generic `render` ring mixes
-- non-edit renders (NFR-P1) with parse-bound edit renders (NFR-P10), so no
-- single budget applies to it.
local info_rows = {
  { event = "render (all, mixed)", label = "render" },
}

local function pass_fail(st, budget)
  if not st then
    return "n/a"
  end
  return (st.p95 <= budget.p95 and st.max <= budget.max) and "PASS" or "FAIL"
end

print(string.format("AT-24 latency report: %s", doc))
print(string.format(
  "%-4s %-20s %8s %10s %10s %18s %6s",
  "ID", "Event", "Samples", "p95(ms)", "max(ms)", "Budget(p95/max)", "Result"
))

for _, row in ipairs(rows) do
  local st = stats(plugin_timings[row.label])
  local budget = budgets[row.id]
  print(string.format(
    "%-4s %-20s %8s %10s %10s %8s / %-7s %6s",
    row.id, row.event,
    st and tostring(st.n) or "n/a",
    fmt(st and st.p95), fmt(st and st.max),
    fmt(budget.p95), fmt(budget.max),
    pass_fail(st, budget)
  ))
end

for _, row in ipairs(info_rows) do
  local st = stats(plugin_timings[row.label])
  print(string.format(
    "%-4s %-20s %8s %10s %10s %8s / %-7s %6s",
    "-", row.event,
    st and tostring(st.n) or "n/a",
    fmt(st and st.p95), fmt(st and st.max),
    "n/a", "n/a", "info"
  ))
end

-- NFR-P6: keystroke latency added over Neovim without the plugin. p95/max
-- of the delta, using each run's own percentile (not a per-sample pairing:
-- the two sessions run in separate child processes).
do
  local bk, pk = stats(baseline_keys), stats(plugin_keys)
  local budget = budgets.P6
  if bk and pk then
    local delta = { p95 = pk.p95 - bk.p95, max = pk.max - bk.max }
    print(string.format(
      "%-4s %-20s %8s %10s %10s %8s / %-7s %6s",
      "P6", "keystroke (delta)", string.format("%d/%d", pk.n, bk.n),
      fmt(delta.p95), fmt(delta.max), fmt(budget.p95), fmt(budget.max),
      pass_fail(delta, budget)
    ))
  else
    print(string.format(
      "%-4s %-20s %8s %10s %10s %8s / %-7s %6s",
      "P6", "keystroke (delta)", "n/a", "n/a", "n/a", fmt(budget.p95), fmt(budget.max), "n/a"
    ))
  end
end

-- End-to-end table: what the user actually waits for (input + sync + a
-- forced redraw flush), with-mada (default config) vs baseline (no plugin,
-- `syntax on`). Differs from the plugin-callback table above because a
-- tree-sitter highlighter's per-redraw parse/query cost (FR-M10) happens
-- during the forced redraw, outside the plugin callback the timer above
-- measures, but is not invisible to the user (M5b investigation).
print()
print("End-to-end (input + sync + redraw flush): with-mada (default) vs baseline")
print(string.format(
  "%-4s %-16s %8s %10s %10s %8s %10s %10s",
  "ID", "Event", "N(mada)", "p95(mada)", "max(mada)", "N(base)", "p95(base)", "max(base)"
))
local e2e_rows = {
  { id = "P8", event = "FileType", key = "FileType" },
  { id = "P3", event = "CursorMoved", key = "CursorMoved" },
  { id = "P7", event = "WinScrolled (1-line)", key = "WinScrolledLine" },
  { id = "P1", event = "WinScrolled (page/jump)", key = "WinScrolledPage" },
  { id = "P10", event = "TextChanged", key = "TextChanged" },
}
for _, row in ipairs(e2e_rows) do
  local ms, bs = stats(plugin_e2e[row.key]), stats(baseline_e2e[row.key])
  print(string.format(
    "%-4s %-16s %8s %10s %10s %8s %10s %10s",
    row.id, row.event,
    ms and tostring(ms.n) or "n/a", fmt(ms and ms.p95), fmt(ms and ms.max),
    bs and tostring(bs.n) or "n/a", fmt(bs and bs.p95), fmt(bs and bs.max)
  ))
end
do
  local ms, bs = stats(plugin_keys), stats(baseline_keys)
  print(string.format(
    "%-4s %-16s %8s %10s %10s %8s %10s %10s",
    "P6", "keystroke",
    ms and tostring(ms.n) or "n/a", fmt(ms and ms.p95), fmt(ms and ms.max),
    bs and tostring(bs.n) or "n/a", fmt(bs and bs.p95), fmt(bs and bs.max)
  ))
end

print()
print("P9 (startup cost with no Markdown buffer) is not measured here; skipped per plan.")

os.exit(0)
