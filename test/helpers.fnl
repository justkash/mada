;; test.helpers - shared spec helpers (architecture §15).

(local M {})

;; Fixed screen size for every spec.
(set vim.o.columns 80)
(set vim.o.lines 30)
(set vim.o.swapfile false)

(fn M.eq [a b ?msg]
  "Assert deep equality; raises with both values on mismatch."
  (when (not (vim.deep_equal a b))
    (error (.. (or ?msg "values differ") "\nexpected: " (vim.inspect b)
               "\nactual:   " (vim.inspect a)) 0)))

(fn M.open [name]
  "Open test/fixtures/<name> in the current window; set filetype markdown
(attaches mada via the real FileType autocommand). Returns buf."
  (vim.cmd.edit (.. :test/fixtures/ name))
  (let [buf (vim.api.nvim_get_current_buf)]
    (set vim.bo.filetype :markdown)
    buf))

(fn M.feed [keys ?flags]
  "nvim_feedkeys(keys, flags or \"xt\", false). \"xt\" ends Insert mode at
the end of the keys; \"xt!\" does not. CursorMoved, WinScrolled and
TextChanged never fire from feedkeys in a -l script (OQ-5); this fires
TextChanged and CursorMoved itself when their precondition (changedtick,
cursor position) changed, so specs exercise the real handlers. WinScrolled
depends on v:event data this harness cannot fabricate: cover it with
test/events_spec.fnl's real-input child instead."
  (let [buf (vim.api.nvim_get_current_buf)
        win (vim.api.nvim_get_current_win)
        before_tick (vim.api.nvim_buf_get_changedtick buf)
        before_cursor (vim.api.nvim_win_get_cursor win)
        flags (or ?flags :xt)]
    (vim.api.nvim_feedkeys (vim.api.nvim_replace_termcodes keys true false true)
                           flags false)
    (let [after_tick (vim.api.nvim_buf_get_changedtick buf)
          after_cursor (vim.api.nvim_win_get_cursor win)]
      (when (not= after_tick before_tick)
        (vim.api.nvim_exec_autocmds :TextChanged {:buffer buf}))
      (when (or (not= (. after_cursor 1) (. before_cursor 1))
                (not= (. after_cursor 2) (. before_cursor 2)))
        (vim.api.nvim_exec_autocmds :CursorMoved {:buffer buf})))))

(fn M.marks [buf]
  "nvim_buf_get_extmarks in mada's namespace, without ids, sorted by
(row, col)."
  (let [state (require :mada.state)
        raw (vim.api.nvim_buf_get_extmarks buf (state.ns) 0 -1 {:details true})
        out (icollect [_ m (ipairs raw)]
              {:row (. m 2) :col (. m 3) :opts (. m 4)})]
    (table.sort out
                (fn [a b]
                  (if (= a.row b.row) (< a.col b.col) (< a.row b.row))))
    out))

(fn snapshot_path [name]
  (.. :test/snapshots/ name :.lua))

(fn M.snapshot [name data]
  "Compare `data` with test/snapshots/<name>.lua; rewrite it when
UPDATE_SNAPSHOTS=1 is set. A missing snapshot fails unless updating."
  (let [path (snapshot_path name)]
    (if (= (os.getenv :UPDATE_SNAPSHOTS) :1)
        (let [f (assert (io.open path :w))]
          (f:write "return " (vim.inspect data) "\n")
          (f:close))
        (let [(ok existing) (pcall dofile path)]
          (if (not ok)
              (error (.. "missing snapshot " path
                         ": run with UPDATE_SNAPSHOTS=1 to write it")
                     0)
              (M.eq data existing (.. "snapshot mismatch: " name)))))))

(fn M.wait_diagram [buf ?timeout]
  "Wait for `User MadaDiagram` on buf (mermaid jobs, M1). `buffer` cannot be
combined with an explicit `pattern` in `nvim_create_autocmd` (any event), so
this filters `data.buf` inside the callback instead."
  (var fired false)
  (let [id (vim.api.nvim_create_autocmd :User
                                        {:pattern :MadaDiagram
                                         :callback (fn [ev]
                                                     (when (= ev.data.buf buf)
                                                       (set fired true)))})]
    (vim.wait (or ?timeout 5000) (fn [] fired) 10)
    (pcall vim.api.nvim_del_autocmd id)
    fired))

(fn M.screen_row [row width]
  "The screen row's text, column 1..width, after a redraw."
  (vim.cmd.redraw)
  (let [chars []]
    (for [c 1 width]
      (table.insert chars (vim.fn.screenstring row c)))
    (table.concat chars)))

(fn M.render_stats []
  "{: renders : parses} from mada.render, for asserting on the parser
counter (AT-5)."
  ((. (require :mada.render) :stats)))

M
