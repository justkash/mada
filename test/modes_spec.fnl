;; test.modes_spec - AT-2, AT-3, AT-4, AT-25; FR-M3 keep/raw rules.
;;
;; AT-2, AT-3 and both FR-M3 cases must observe state while Nvim is still
;; parked in Insert or command-line mode. `nvim_feedkeys(keys, "...!", ...)`
;; (the "!" flag that keeps Insert mode open, or any keys that leave Nvim
;; waiting in command-line mode) never returns to the calling Lua when run
;; in-process under `nvim --headless -u NONE -l`: confirmed with a minimal,
;; plugin-free repro (a single such feedkeys call ends the whole process,
;; silently, exit 0, before the next Lua statement runs - this is what left
;; modes_spec silent: the very first test's very first feed call ended the
;; process). test/events_spec.fnl hits the same class of problem for
;; CursorMoved/WinScrolled/TextChanged and works around it by driving a real
;; `--embed` child over RPC (its `with-child`/`input-sync` helpers); the same
;; approach reliably keeps a real child parked in Insert/cmdline mode
;; (test-at23 there checks the namespace mid-Insert this way), so this file
;; duplicates a small local copy of that pattern for AT-2/AT-3/FR-M3. AT-4
;; and AT-25 never need to observe a parked mode - AT-4 only moves the
;; cursor, and AT-25's `i` alone (no "!") already round-trips through Insert
;; and Nvim's own synthetic <Esc> in one feedkeys call - so both stay
;; in-process via test/helpers.fnl.

(local h (require :helpers))
(local mada (require :mada))
(local config (require :mada.config))

;; AT-25's in-process `i` round trip still touches real Insert mode for one
;; call; suppress the "-- INSERT --" mode message so it can never land on
;; stderr mid-write and visually merge with an adjacent stdout "ok" line
;; when a caller redirects both streams together (test/run.lua's own output
;; is unaffected either way: it writes straight to stdout with an explicit
;; flush per line).
(set vim.o.showmode false)

(fn scratch_md [lines]
  (let [buf (vim.api.nvim_create_buf true false)]
    (vim.api.nvim_buf_set_lines buf 0 -1 false lines)
    (vim.api.nvim_win_set_buf 0 buf)
    (set vim.bo.filetype :markdown)
    buf))

(local heading_lines [:intro "" "# Heading" "" :para])

(fn test_AT4_cursor_row_shows_raw []
  (mada.setup {:headings {:conceal_markers true}})
  (let [buf (scratch_md heading_lines)]
    (h.eq " Heading" (h.screen_row 3 8))
    (h.feed :3G)
    (h.eq "# Heading" (h.screen_row 3 9))
    (h.feed :gg)
    (h.eq " Heading" (h.screen_row 3 8))))

(fn test_AT25_cursor_and_topline_preserved []
  (config.setup {})
  (let [lines (fcollect [i 1 60] (.. "line " i))
        buf (scratch_md lines)
        win (vim.api.nvim_get_current_win)]
    (vim.api.nvim_win_set_cursor win [30 0])
    (vim.cmd "normal! zz")
    (let [before (vim.fn.winsaveview)]
      ;; "i" alone, no "!": Nvim enters Insert then immediately behaves as
      ;; if <Esc> were typed (documented feedkeys() 'x' behavior), so this
      ;; one call is the full i/<Esc> round trip.
      (h.feed :i)
      (let [after (vim.fn.winsaveview)]
        (h.eq before.lnum after.lnum)
        (h.eq before.topline after.topline)))))

;; --- real --embed child over RPC, for AT-2, AT-3 and FR-M3: mirrors
;; test/events_spec.fnl's local pattern (duplicated here; that file is
;; owned elsewhere and exposes no reusable module). ------------------------

(fn start-child []
  "Start a child Neovim with --embed over RPC and load the built plugin,
mirroring interactive startup."
  (let [ch (vim.fn.jobstart [:nvim
                             :--embed
                             :--headless
                             :-n
                             :-i
                             :NONE
                             :-u
                             :NONE] {:rpc true})]
    (vim.rpcrequest ch :nvim_exec_lua "vim.o.columns = 80
vim.o.lines = 30
vim.o.swapfile = false
local rtp = os.getenv('MADA_RTP')
vim.opt.runtimepath:prepend(rtp)
vim.cmd.source(rtp .. '/plugin/mada.lua')
vim.cmd('filetype on')" [])
    ch))

(fn sync [ch]
  "Reach the child's idle loop so deferred autocommands fire before this
call returns (OQ-5)."
  (vim.rpcrequest ch :nvim_eval :1))

(fn input [ch keys]
  (vim.rpcrequest ch :nvim_input keys))

(fn input-sync [ch keys]
  (input ch keys)
  (sync ch))

(fn exec [ch code ?args]
  (vim.rpcrequest ch :nvim_exec_lua code (or ?args [])))

(fn with-child [f]
  "Run `f` with a fresh child, always stopping it afterwards (even on
failure)."
  (let [ch (start-child)
        (ok err) (pcall f ch)]
    (pcall vim.fn.jobstop ch)
    (when (not ok) (error err 0))))

(fn scratch-md-child [ch lines]
  (exec ch "local lines = ...
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
vim.api.nvim_win_set_buf(0, buf)
vim.bo.filetype = 'markdown'" [lines]))

(fn marks-of [ch]
  "Number of marks in mada's namespace for the child's current buffer."
  (exec ch "local ns = require('mada.state').ns()
local raw = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {details = true})
return #raw"))

(fn conceallevel-of [ch]
  (exec ch
        "local win = vim.api.nvim_get_current_win()
return vim.api.nvim_get_option_value('conceallevel', {scope = 'local', win = win})"))

(fn mode-of [ch]
  (exec ch "return vim.fn.mode(1)"))

(fn check [cond msg]
  (when (not cond) (error msg 0)))

(fn test_AT2_insert_clears_namespace []
  (with-child (fn [ch]
                (scratch-md-child ch heading_lines)
                (check (> (marks-of ch) 0)
                       "AT-2 precondition: marks should be present before Insert")
                (input-sync ch :i)
                (check (= 0 (marks-of ch))
                       "AT-2: the namespace should be empty in Insert mode")
                (check (= 0 (conceallevel-of ch))
                       "AT-2: conceallevel should be restored to 0 in Insert mode")
                (input-sync ch :<Esc>))))

(fn test_AT3_esc_renders_immediately []
  (with-child (fn [ch]
                (scratch-md-child ch heading_lines)
                (input-sync ch :i)
                (check (= 0 (marks-of ch))
                       "AT-3 precondition: the namespace should be empty in Insert mode")
                (input-sync ch :<Esc>)
                (check (> (marks-of ch) 0)
                       "AT-3: marks should be present immediately after <Esc>, no timer wait"))))

(fn test_FRM3_cmdline_keeps_rendered []
  (with-child (fn [ch]
                (scratch-md-child ch heading_lines)
                (check (> (marks-of ch) 0)
                       "FR-M3 precondition: marks should be present before command-line mode")
                (input-sync ch ":")
                (check (> (marks-of ch) 0)
                       "FR-M3: command-line mode should keep the rendered state")
                (input-sync ch :<Esc>))))

(fn test_FRM3_ctrl_o_stays_raw []
  (with-child (fn [ch]
                (scratch-md-child ch heading_lines)
                (input-sync ch :i)
                (check (= 0 (marks-of ch))
                       "FR-M3 <C-o>: the namespace should be empty in Insert mode")
                (input-sync ch :<C-o>)
                (let [mode (mode-of ch)]
                  (check (vim.startswith mode :ni)
                         (.. "FR-M3 <C-o>: mode should start with 'ni', got "
                             mode)))
                (check (= 0 (marks-of ch))
                       "FR-M3 <C-o>: the namespace should stay empty in ni* mode")
                (input-sync ch :l)
                (check (= 0 (marks-of ch))
                       "FR-M3 <C-o>: the namespace should stay empty after the one-shot Normal command")
                (input-sync ch :<Esc>))))

[["AT-2 Insert clears the namespace and restores conceallevel"
  test_AT2_insert_clears_namespace]
 ["AT-3 <Esc> renders immediately" test_AT3_esc_renders_immediately]
 ["AT-4 cursor row shows raw, other rows unchanged"
  test_AT4_cursor_row_shows_raw]
 ["AT-25 cursor and topline unchanged across i/<Esc>"
  test_AT25_cursor_and_topline_preserved]
 ["FR-M3 command-line keeps the rendered state"
  test_FRM3_cmdline_keeps_rendered]
 ["FR-M3 <C-o> (ni* mode) stays raw" test_FRM3_ctrl_o_stays_raw]]
