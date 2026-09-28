;; mada.log - error guard, debug log, notify-once, per-label timing rings.

(local M {})

(local notified {})
(local RING_N 100)
(local rings {})
(var on_error nil)

(fn ring_for [label]
  (or (. rings label) (let [r {:data [] :i 0}]
                        (tset rings label r)
                        r)))

(fn push [label ms]
  (let [r (ring_for label)]
    (set r.i (+ 1 (% r.i RING_N)))
    (tset r.data r.i ms)))

(fn M.set_on_error [callback]
  "Register the callback `guard` runs (with `buf`) after a caught error."
  (set on_error callback))

(fn M.notify_once [key msg level]
  "Send `msg` via `vim.notify` at most once per `key` for the session."
  (when (not (. notified key))
    (tset notified key true)
    (vim.notify msg level)))

(fn M.debug [cfg fmt ...]
  "Append a line to stdpath('log')/mada.log when `cfg.debug` is true. `cfg`
may be nil (treated as disabled)."
  (when (and cfg cfg.debug)
    (let [path (vim.fs.joinpath (vim.fn.stdpath :log) :mada.log)
          f (io.open path :a)]
      (when f
        (f:write (os.date "%Y-%m-%d %H:%M:%S ") (string.format fmt ...) "\n")
        (f:close)))))

(fn M.record_render [ms]
  "Append a render duration (ms) to the 100-entry `render` timing ring."
  (push :render ms))

(fn M.render_timings []
  "A copy of the `render` timing ring."
  (let [r (ring_for :render)]
    (icollect [_ v (ipairs r.data)] v)))

(fn M.clear_timings []
  "Empty every timing ring (bench/latency.lua: read then clear, so repeated
reads within one long phase never re-count a sample still sitting in a ring
that has not fully wrapped, and never lose one that has)."
  (each [label _ (pairs rings)]
    (tset rings label {:data [] :i 0})))

(fn M.timings []
  "{[label] = [ms ...]} for every label recorded this session: the
autocommand event names passed to `guard` (FileType, ModeChanged,
CursorMoved, WinScrolled, WinResized, TextChanged, BufEnter, BufReadPost,
…), plus `render` for render-pass durations."
  (let [out {}]
    (each [label r (pairs rings)]
      (tset out label (icollect [_ v (ipairs r.data)] v)))
    out))

(fn M.guard [label buf callback ...]
  "Run `callback ...` under `xpcall`, timing it (hrtime) into the `label`
ring. On error: debug-log the traceback, notify once per distinct message,
and invoke the registered on-error callback with `buf` (NFR-Q4), skipped
when `buf` is nil (no single buffer is at fault). Always returns nil: a
Neovim Lua autocommand callback that returns a truthy value gets deleted
after firing once, so callers must never end in a tail call to `guard`
whose result is itself returned."
  (let [t0 (vim.uv.hrtime)
        (ok err) (xpcall callback debug.traceback ...)]
    (push label (/ (- (vim.uv.hrtime) t0) 1000000))
    (when (not ok)
      (M.debug {:debug true} "error: %s" err)
      (M.notify_once err (.. "mada: " (tostring err)) vim.log.levels.ERROR)
      (when (and on_error buf)
        (pcall on_error buf)))
    nil))

M
