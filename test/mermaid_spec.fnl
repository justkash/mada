;; test.mermaid_spec - M1: AT-7, AT-9-AT-13, AT-28; FR-D17; placement "off";
;; `:Mada render!`; detach dropping late results (FR-M8); a width-bucket
;; crossing; invariant 2 on test/fixtures/mermaid.md. AT-9, AT-13 and AT-28
;; need real CursorMoved/TextChanged (OQ-5), so they drive a real child
;; Neovim over RPC, in the style of test.events_spec.
;;
;; A Mermaid block's *content* rows are never hidden (OQ-1, mada.mermaid's
;; `emit_diagram_rows`): the diagram is drawn as `virt_text_win_col = 0`
;; overlays over the block's own content rows only -- open+1..close-1, or to
;; the buffer's last row for an unterminated block (mada.screen, the same
;; draw-over-source design test.tables_spec uses), one overlay per screen
;; row, padded blank past the diagram's own lines; only lines beyond the
;; content rows' own screen-row count (T) attach as `virt_lines` below the
;; *first content row* (keeps the diagram contiguous on screen -- a hidden
;; row directly behind scrollable filler used to make Neovim's topline snap
;; back down, OQ-1). The fence rows themselves are always hidden by mada
;; (`conceal_line`, cursor-position-independent, same as an ordinary fenced
;; code block's `code.hide_fences`): this is what keeps the diagram's
;; overlays/overflow off a row a runtime tree-sitter highlighter might also
;; be concealing (Neovim 0.12's `ftplugin/markdown.lua` starts one on every
;; markdown buffer by default, `filetype plugin on`) and what keeps the
;; block's total height the same whether the cursor is inside it or not
;; (AT-9). So most of this file reconstructs the diagram from overlay marks,
;; not from a virt_lines mark; `virt-lines-mark` still applies to the
;; pending/error-without-diagram state (always `virt_lines`, since there is
;; no diagram yet) and to a diagram's own overflow tail.

(local h (require :helpers))
(local mada (require :mada))
(local config (require :mada.config))
(local state (require :mada.state))
(local render (require :mada.render))
(local mermaid (require :mada.mermaid))

(local fake-cmd (.. (vim.fn.getcwd) :/test/bin/fake-termaid))

;; `M.on_filetype` (plugin/mada.lua's bootstrap FileType autocommand) lazily
;; calls `mada.setup({})` on the *first* markdown FileType event ever seen in
;; this process (FR-C6), which re-applies the plain defaults and would
;; clobber a `config.setup` call an earlier test already made (this file's
;; own tests are the first in this process to need non-default mermaid
;; config from their very first buffer). Force that lazy init here, once,
;; before any test's config.setup runs.
(mada.setup {})
(fn check [cond msg]
  (when (not cond) (error msg 0)))

;; ---- shared mark helpers ----

(fn virt-lines-mark [marks]
  "The first mark carrying `virt_lines` (there is at most one Mermaid
attach-row mark per render), or nil."
  (var found nil)
  (each [_ m (ipairs marks)]
    (when (and (not found) m.opts.virt_lines) (set found m)))
  found)

(fn conceal-line-rows [marks]
  (icollect [_ m (ipairs marks)] (if m.opts.conceal_lines m.row nil)))

(fn kind-of [opts]
  "mada.mermaid draws its diagram as `virt_text_win_col = 0` overlays
(mada.screen, the same draw-over-source design as mada.tables): those marks
report their own virt_text_pos as \"win_col\" (verified), not \"overlay\"."
  (if (and opts.virt_text
           (or (= opts.virt_text_pos :overlay) (= opts.virt_text_pos :win_col)))
      :overlay
      (not= opts.virt_lines nil)
      :virt_lines
      :other))

(fn overlays-of [ms]
  "`ms`'s overlay marks, sorted by (row, col): one per screen row of the
block, in on-screen order."
  (let [out (icollect [_ m (ipairs ms)]
              (when (= (kind-of m.opts) :overlay) m))]
    (table.sort out
                (fn [a b]
                  (if (= a.row b.row) (< a.col b.col) (< a.row b.row))))
    out))

(fn flat-text [chunks]
  (accumulate [s "" _ c (ipairs chunks)] (.. s (. c 1))))

(fn rtrim [s] (pick-values 1 (s:gsub "%s+$" "")))

(fn overlay-text [overlays]
  "Every overlay's own text, joined in on-screen order (one per screen row),
right-trimmed (an overlay is always padded to ctx.width, mada.screen.
pad_chunks_to): the diagram's displayed lines, the same shape `chunk-text`
produces for a virt_lines mark's lines."
  (table.concat (icollect [_ m (ipairs overlays)]
                  (rtrim (flat-text m.opts.virt_text))) "\n"))

(fn overlay-groups [overlays]
  (let [out {}]
    (each [_ m (ipairs overlays)]
      (each [_ chunk (ipairs m.opts.virt_text)]
        (when (. chunk 2) (tset out (. chunk 2) true))))
    out))

(fn is-blank? [s] (= nil (s:find "%S")))

(fn block-rows [buf]
  "(open_row close_row), 0-based inclusive: the first fenced_code_block
whose opening fence line is literally \"```mermaid\", found by a plain line
scan (test-only helper; mada.mermaid itself uses the parse tree). close_row
is the buffer's last row when no closing fence is found (unterminated
block)."
  (let [lines (vim.api.nvim_buf_get_lines buf 0 -1 false)]
    (var open nil)
    (var close nil)
    (each [i l (ipairs lines)]
      (when (and (not open) (l:find "^```mermaid"))
        (set open (- i 1)))
      (when (and open (not close) (not= (- i 1) open) (l:find "^```%s*$"))
        (set close (- i 1))))
    (values open (or close (- (length lines) 1)))))

(fn block-height [win osr csr]
  "T: total screen rows block rows osr..csr occupy -- the same measure
mada.mermaid's own `diagram_height` uses (`nvim_win_text_height`, `.all -
.fill`)."
  (let [t (vim.api.nvim_win_text_height win {:start_row osr :end_row csr})]
    (- t.all t.fill)))

(fn chunk-groups [vl]
  "The set of hl_group names used across a virt_lines mark's chunks."
  (let [out {}]
    (each [_ line (ipairs vl.opts.virt_lines)]
      (each [_ chunk (ipairs line)] (tset out (. chunk 2) true)))
    out))

(fn chunk-text [vl]
  (let [parts []]
    (each [_ line (ipairs vl.opts.virt_lines)]
      (each [_ chunk (ipairs line)] (table.insert parts (. chunk 1))))
    (table.concat parts "\n")))

(fn diagram-groups [ms]
  "Every hl_group used across a drawn diagram's marks: overlays plus its own
overflow `virt_lines`, if any -- the overflow now attaches below the first
content row (OQ-1), so it may hold a line from the middle of the diagram,
not just its tail, and a group once found only in the overlays can now show
up only in the overflow instead."
  (let [out (overlay-groups (overlays-of ms))
        vl (virt-lines-mark ms)]
    (when vl
      (each [g _ (pairs (chunk-groups vl))]
        (tset out g true)))
    out))

(fn full-diagram-text [ms]
  "A drawn diagram's whole text: overlays plus its own overflow `virt_lines`
if any, concatenated (order does not matter for the equality/substring
checks this is used for, only content)."
  (let [vl (virt-lines-mark ms)]
    (.. (overlay-text (overlays-of ms)) "\n" (if vl (chunk-text vl) ""))))

(fn contains? [s needle]
  "Plain substring test. Written as a named function, not `(s:find ...)`
inline on a compound expression: Fennel's colon method-call sugar only
binds to a symbol token, not to the result of a parenthesized call, so
`((f x):find ...)` does not do what it looks like it does."
  (not= nil (s:find needle 1 true)))

;; ---- in-process helpers (config.setup + scratch buffers) ----

(fn set-env [opts]
  "Set the fake-termaid environment for the next vim.system spawn from this
process; \"\" means unset (the script treats empty the same as unset)."
  (vim.fn.setenv :FAKE_OUT (or opts.out ""))
  (vim.fn.setenv :FAKE_SLEEP (or opts.sleep ""))
  (vim.fn.setenv :FAKE_ERR (or opts.err ""))
  (vim.fn.setenv :FAKE_CODE (or opts.code "")))

(fn setup-mermaid [extra]
  (config.setup (vim.tbl_deep_extend :force
                                     {:mermaid {:cmd [fake-cmd]
                                                :timeout_ms 2000
                                                :width_bucket 10
                                                :pending_text "rendering diagram…"}}
                                     (or extra {}))))

(fn scratch-md [lines]
  (let [buf (vim.api.nvim_create_buf true false)]
    (vim.api.nvim_buf_set_lines buf 0 -1 false lines)
    (vim.api.nvim_win_set_buf 0 buf)
    (set vim.bo.filetype :markdown)
    buf))

(fn mermaid-lines [body]
  (let [out ["# Diagram" "" "```mermaid"]]
    (each [_ l (ipairs body)] (table.insert out l))
    (table.insert out "```")
    (table.insert out "")
    (table.insert out :after)
    out))

;; ---- AT-7: flowchart, backend present ----

(fn test-at7 []
  (set-env {})
  (setup-mermaid {})
  (let [buf (scratch-md (mermaid-lines ["graph LR" "  A --> B"]))
        win (vim.api.nvim_get_current_win)]
    (check (h.wait_diagram buf) "AT-7: expected MadaDiagram to fire")
    (let [ms (h.marks buf)]
      (check (= 2 (length (conceal-line-rows ms)))
             "AT-7: a drawn diagram hides both fence rows itself (same as a highlighter would), never a content row")
      (let [(osr csr) (block-rows buf)
            t (block-height win osr csr)
            overlays (overlays-of ms)]
        (check (= t (length overlays))
               (: "AT-7: expected one overlay per screen row (T=%d), got %d"
                  :format t (length overlays)))
        (let [groups (diagram-groups ms)]
          (check (. groups :MadaDiagramLine)
                 "AT-7: expected box-drawing chunks coloured MadaDiagramLine")
          (check (. groups :MadaDiagramText)
                 "AT-7: expected label chunks coloured MadaDiagramText"))))))

;; ---- AT-10: backend missing ----

(fn test-at10 []
  (set-env {})
  (config.setup {:mermaid {:cmd [:/nonexistent/mada-fake-termaid-missing]}})
  (var notified nil)
  (let [orig vim.notify]
    (set vim.notify (fn [msg level] (set notified [msg level])))
    (let [buf (scratch-md (mermaid-lines ["graph LR" "  A --> B"]))]
      (set vim.notify orig)
      (let [ms (h.marks buf)]
        (check (= nil (virt-lines-mark ms))
               "AT-10: no diagram/pending/error virt_lines when the backend is missing")
        (check (> (length (icollect [_ m (ipairs ms)]
                            (if (= m.opts.line_hl_group :MadaCodeBlock) m.row)))
                  0)
               "AT-10: the block should render as an ordinary code block")))
    (check (not= notified nil) "AT-10: expected a WARN notification")
    (check (= (. notified 2) vim.log.levels.WARN)
           "AT-10: the notification should be WARN")))

;; ---- AT-11: backend exits 1 ----

(fn test-at11 []
  (set-env {:code :1 :err "bad diagram"})
  (setup-mermaid {})
  (let [buf (scratch-md (mermaid-lines ["graph LR" "  A --> B"]))]
    (check (h.wait_diagram buf) "AT-11: expected MadaDiagram to fire")
    (let [ms (h.marks buf)
          (_osr csr) (block-rows buf)
          vl (virt-lines-mark ms)]
      (check (not= vl nil) "AT-11: expected an error virt_lines row")
      (check (= vl.row (- csr 1))
             "AT-11: the error row should attach below the last content row, never the closing fence")
      (check (contains? (chunk-text vl) "bad diagram")
             "AT-11: the error row should include the backend's message")
      (check (. (chunk-groups vl) :MadaDiagramError)
             "AT-11: the error row should use MadaDiagramError"))
    (let [before (h.marks buf)]
      (mada.render buf)
      (h.eq before (h.marks buf)
            "AT-11: should not retry the same failing key without render!"))))

;; ---- AT-12: backend hangs beyond timeout_ms ----

(fn test-at12 []
  (set-env {:sleep :0.3})
  (setup-mermaid {:mermaid {:timeout_ms 50}})
  (let [t0 (vim.uv.hrtime)
        buf (scratch-md (mermaid-lines ["graph LR" "  A --> B"]))
        render-ms (/ (- (vim.uv.hrtime) t0) 1000000)]
    (check (< render-ms 30)
           "AT-12: attach/render must not block on the backend")
    (check (h.wait_diagram buf 3000)
           "AT-12: expected MadaDiagram (timeout) to fire")
    (let [ms (h.marks buf)
          vl (virt-lines-mark ms)]
      (check (not= vl nil) "AT-12: expected a timeout error row")
      (check (contains? (chunk-text vl) :timeout)
             "AT-12: the error row should report the timeout"))
    ;; No leaked process: vim.system's own timeout kills it (code 124, which
    ;; parse_result turns into "timeout"); direct process-table inspection
    ;; is out of scope for a portable spec.
    (let [t1 (vim.uv.hrtime)]
      (mada.render buf)
      (check (< (/ (- (vim.uv.hrtime) t1) 1000000) 30)
             "AT-12: a later render must not block either (editing never blocked)"))))

;; ---- FR-D17: key change keeps the diagram, no pending flash ----

(fn has-pending? [ms]
  (var found false)
  (each [_ m (ipairs ms)]
    (when m.opts.virt_lines
      (each [_ line (ipairs m.opts.virt_lines)]
        (each [_ chunk (ipairs line)]
          (when (= (. chunk 2) :MadaDiagramPending) (set found true))))))
  found)

(fn test-frd17-key-change-keeps-diagram []
  (set-env {:out :V1})
  (setup-mermaid {})
  (let [buf (scratch-md (mermaid-lines ["graph LR" "  A --> B"]))]
    (check (h.wait_diagram buf) "FR-D17: expected the first diagram")
    (let [overlays1 (overlays-of (h.marks buf))]
      (check (contains? (overlay-text overlays1) :V1)
             "FR-D17 precondition: the first diagram should show V1"))
    (set-env {:out :V2})
    ;; Edit the block's content row directly (nvim_buf_set_lines) rather
    ;; than through Insert mode: entering/leaving Insert via feedkeys after
    ;; this file's earlier RPC-child tests have started and stopped child
    ;; processes crashes this harness (a `-l` script issue, not a mada bug;
    ;; tracked separately). This still exercises a real Normal-mode-style
    ;; edit and changedtick bump; TextChanged is fired exactly as
    ;; `test.helpers`' own `feed` does for a `-l` script (OQ-5).
    (vim.api.nvim_buf_set_lines buf 3 4 false ["  A --> B extra"])
    (vim.api.nvim_exec_autocmds :TextChanged {:buffer buf})
    (let [ms (h.marks buf)]
      (check (not (has-pending? ms))
             "FR-D17: no pending row should flash while the key is changing")
      (let [overlays (overlays-of ms)]
        (check (> (length overlays) 0)
               "FR-D17: a diagram should stay shown right after the edit")
        (check (contains? (overlay-text overlays) :V1)
               "FR-D17: the previous diagram should stay until the new job completes")))
    (check (h.wait_diagram buf) "FR-D17: expected the replacement diagram")
    (let [overlays2 (overlays-of (h.marks buf))]
      (check (contains? (overlay-text overlays2) :V2)
             "FR-D17: the new diagram (V2) should replace the previous one"))))

;; ---- placement "off" ----

(fn test-placement-off []
  (set-env {})
  (setup-mermaid {:mermaid {:placement :off}})
  (let [buf (scratch-md (mermaid-lines ["graph LR" "  A --> B"]))]
    (let [ms (h.marks buf)]
      (check (= nil (virt-lines-mark ms)) "off: no diagram virt_lines")
      ;; code.hide_fences (default true) conceals the fence rows of any
      ;; ordinary fenced code block, mermaid or not; that is unrelated to
      ;; mermaid.placement. Only the *content* rows must carry no
      ;; conceal_lines (they get line_hl MadaCodeBlock instead).
      (check (= 2 (length (conceal-line-rows ms)))
             "off: only the two fence rows should carry conceal_lines")
      (check (> (length (icollect [_ m (ipairs ms)]
                          (if (= m.opts.line_hl_group :MadaCodeBlock) m.row)))
                0)
             "off: content rows should render as an ordinary code block"))
    (check (not (h.wait_diagram buf 200)) "off: no job should ever spawn")))

;; ---- `:Mada render!` retries a failed key ----

(fn test-render-bang-retries-failed []
  (set-env {:code :1 :err :boom})
  (setup-mermaid {})
  (let [buf (scratch-md (mermaid-lines ["graph LR" "  A --> B"]))]
    (check (h.wait_diagram buf) "render!: expected the first (failing) job")
    (set-env {})
    (mada.render buf {:force true})
    (check (h.wait_diagram buf) "render!: expected a retry after :Mada render!")
    (let [ms (h.marks buf)
          overlays (overlays-of ms)]
      (check (> (length overlays) 0)
             "render!: expected diagram overlays after the retry")
      (check (not (. (overlay-groups overlays) :MadaDiagramError))
             "render!: no overlay should use MadaDiagramError after a successful retry")
      (let [vl (virt-lines-mark ms)]
        (check (or (= vl nil) (not (. (chunk-groups vl) :MadaDiagramError)))
               "render!: the error row should be gone after a successful retry (any remaining virt_lines mark is the diagram's own overflow, not an error)")))))

;; ---- NFR-Q4: the job-exit callback runs under log.guard ----

(fn test-mermaid-job-exit-guarded []
  (set-env {})
  (setup-mermaid {})
  (let [orig-parse mermaid.parse_result
        notifications []
        orig-notify vim.notify]
    (set mermaid.parse_result (fn [...] (error "boom: stubbed parse_result" 0)))
    (set vim.notify (fn [msg level] (table.insert notifications [msg level])))
    (let [buf (scratch-md (mermaid-lines ["graph LR" "  A --> B"]))]
      (check (vim.wait 5000 (fn [] (= nil (state.get buf))) 10)
             "MermaidJob guard: expected buf to be disabled after the job callback threw")
      (set mermaid.parse_result orig-parse)
      (set vim.notify orig-notify)
      (check (= 1 (length notifications))
             "MermaidJob guard: expected exactly one ERROR notification")
      (check (= (. notifications 1 2) vim.log.levels.ERROR)
             "MermaidJob guard: the notification should be ERROR")
      (check (= 0 (length (h.marks buf)))
             "MermaidJob guard: no marks should remain once the buffer is disabled"))))

;; ---- detach drops a late result (FR-M8) ----

(fn test-detach-drops-late-results []
  (set-env {:sleep :0.2})
  (setup-mermaid {:mermaid {:timeout_ms 5000}})
  (let [buf (scratch-md (mermaid-lines ["graph LR" "  A --> B"]))]
    (mada.disable buf)
    (h.eq nil (state.get buf) "detach: state should be released immediately")
    (vim.wait 500 (fn [] false) 50)
    (h.eq nil (state.get buf)
          "detach: a late job result must not resurrect state")
    (h.eq 0 (length (h.marks buf))
          "detach: no marks should appear from the dropped result")))

;; ---- width-bucket crossing re-runs the diagram ----

(fn test-width-bucket-crossing []
  ;; A lone window always fills `columns`: neither `nvim_win_set_width` nor
  ;; changing `vim.o.columns` actually changes its reported width headless
  ;; with no UI attached. A vsplit gives a window whose width really can be
  ;; set, so text_width(win) (= win width - textoff) really crosses a
  ;; width_bucket (10) multiple.
  (set-env {})
  (setup-mermaid {})
  (vim.cmd.vsplit)
  (let [win (vim.api.nvim_get_current_win)]
    (vim.api.nvim_win_set_width win 60)
    (let [buf (scratch-md (mermaid-lines ["graph LR" "  A --> B"]))]
      (check (h.wait_diagram buf) "bucket: expected the first job")
      (let [txt1 (full-diagram-text (h.marks buf))]
        (vim.api.nvim_win_set_width win 30)
        (mada.render buf)
        (check (h.wait_diagram buf)
               "bucket: expected a new job after crossing a width_bucket boundary")
        (let [txt2 (full-diagram-text (h.marks buf))]
          (check (not= txt1 txt2)
                 "bucket: crossing a width_bucket boundary should re-run the diagram")))))
  (vim.cmd.only))

;; ---- drawn diagram longer than the block's own rows: overflow virt_lines --
;; below the *first* content row (OQ-1: scrolling the topline into a hidden
;; closing fence row's filler used to snap it back down; the overflow now
;; sits right after the first content row instead, keeping the diagram
;; contiguous end to end).

(fn test-drawn-overlay-and-overflow []
  (set-env {:out "L1\nL2\nL3\nL4\nL5\nL6"})
  (setup-mermaid {})
  (let [buf (scratch-md (mermaid-lines ["graph LR" "  A --> B"]))
        win (vim.api.nvim_get_current_win)]
    (check (h.wait_diagram buf) "overflow: expected MadaDiagram to fire")
    (let [ms (h.marks buf)
          (osr csr) (block-rows buf)
          t (block-height win osr csr)
          s_first (block-height win (+ osr 1) (+ osr 1))
          overlays (overlays-of ms)
          vl (virt-lines-mark ms)]
      (check (= 2 (length (conceal-line-rows ms)))
             "overflow: a drawn diagram hides both fence rows itself, never a content row")
      (check (= t (length overlays))
             (: "overflow: expected one overlay per screen row (T=%d), got %d"
                :format t (length overlays)))
      ;; T now covers only the block's content rows (fences are concealed,
      ;; contributing 0), so it is smaller than the diagram's 6 lines by
      ;; more than before (OQ-1: overlays/overflow never touch a fence row).
      ;; The first content row's own S_first screen rows show the diagram's
      ;; first S_first lines; the overflow (6 - T lines) attaches below it;
      ;; the remaining content rows' overlays show the rest, so the whole
      ;; diagram still reads top to bottom: overlays[1..S_first], then the
      ;; overflow virt_lines, then overlays[S_first+1..T].
      (let [all [:L1 :L2 :L3 :L4 :L5 :L6]
            overflow-n (- 6 t)
            first-part (icollect [i l (ipairs all)] (if (<= i s_first) l))
            overflow-part (icollect [i l (ipairs all)]
                            (if (and (> i s_first)
                                     (<= i (+ s_first overflow-n)))
                                l))
            rest-part (icollect [i l (ipairs all)]
                        (if (> i (+ s_first overflow-n)) l))]
        (check (= (overlay-text overlays)
                  (table.concat [(table.concat first-part "\n")
                                 (table.concat rest-part "\n")]
                                "\n"))
               "overflow: the first content row's own lines, then the rest, should be shown as overlays, in order")
        (check (not= vl nil) "overflow: expected an overflow virt_lines mark")
        (check (= vl.row (+ osr 1))
               "overflow: the overflow lines should attach below the first content row, keeping the diagram contiguous (OQ-1)")
        (check (= (chunk-text vl) (table.concat overflow-part "\n"))
               "overflow: the lines between the first content row's own share and the rest should be shown in order")))))

;; ---- drawn diagram with the runtime tree-sitter highlighter active -------
;; (Neovim 0.12's `ftplugin/markdown.lua` calls `vim.treesitter.start()` on
;; every markdown buffer by default, `filetype plugin on`; mada's own
;; treesitter.highlight default is `false`, so this simulates that runtime
;; highlighter as a second, independent highlighter, exactly like AT-20's
;; "user already started one" scenario.)

(fn test-drawn-with-runtime-highlighter []
  (set-env {:out "L1\nL2\nL3\nL4\nL5\nL6"})
  (setup-mermaid {})
  (let [buf (scratch-md (mermaid-lines ["graph LR" "  A --> B"]))
        win (vim.api.nvim_get_current_win)]
    (vim.treesitter.start buf :markdown)
    (let [ok (h.wait_diagram buf)]
      (check ok "highlighter: expected MadaDiagram to fire")
      (let [ms (h.marks buf)
            (osr csr) (block-rows buf)
            overlays (overlays-of ms)
            vl (virt-lines-mark ms)
            overflow-n (if vl (length vl.opts.virt_lines) 0)]
        (check (= 2 (length (conceal-line-rows ms)))
               "highlighter: mada conceals both fence rows itself regardless of the runtime highlighter also concealing them")
        (each [_ m (ipairs (overlays-of ms))]
          (check (not (or (= m.row osr) (= m.row csr)))
                 "highlighter: no diagram overlay is ever anchored on a fence row"))
        (check (= (+ (length overlays) overflow-n) 6)
               "highlighter: every diagram line is visible: overlays over the content rows plus overflow virt_lines together equal the diagram's 6 lines")
        (when vl
          (check (not (or (= vl.row osr) (= vl.row csr)))
                 "highlighter: the overflow virt_lines mark is never anchored on a fence row")))
      (vim.treesitter.stop buf))))

;; ---- short diagram: overlays past its own lines are blank -----------------

(fn test-blank-padding-overlays []
  (set-env {:out :L1})
  (setup-mermaid {})
  (let [buf (scratch-md (mermaid-lines ["graph LR" "  A --> B"]))
        win (vim.api.nvim_get_current_win)]
    (check (h.wait_diagram buf) "blank padding: expected MadaDiagram to fire")
    (let [ms (h.marks buf)
          (osr csr) (block-rows buf)
          t (block-height win osr csr)
          overlays (overlays-of ms)]
      (check (= t (length overlays))
             (: "blank padding: expected one overlay per screen row (T=%d), got %d"
                :format t (length overlays)))
      (check (contains? (flat-text (. overlays 1 :opts :virt_text)) :L1)
             "blank padding: the first overlay should show the diagram's only line")
      (for [i 2 t]
        (check (is-blank? (flat-text (. overlays i :opts :virt_text)))
               (: "blank padding: overlay %d (past the diagram's own lines) should be blank"
                  :format i))))))

;; ---- unterminated block: overlays reach the buffer's last row ------------

(fn test-unterminated-block []
  (set-env {:out :X})
  (setup-mermaid {})
  (let [buf (scratch-md ["# T" "" "```mermaid" "graph LR" "  A --> B"])]
    (check (h.wait_diagram buf) "unterminated: expected MadaDiagram to fire")
    (let [ms (h.marks buf)
          win (vim.api.nvim_get_current_win)
          (osr csr) (block-rows buf)
          t (block-height win osr csr)
          overlays (overlays-of ms)]
      (check (= 1 (length (conceal-line-rows ms)))
             "unterminated: a drawn diagram hides its opening fence (there is no closing fence to hide)")
      (check (= csr (- (vim.api.nvim_buf_line_count buf) 1))
             "unterminated: the block should extend to the buffer's last row")
      (check (= t (length overlays))
             "unterminated: expected overlays covering every row to the buffer's last row")
      (check (contains? (overlay-text overlays) :X)
             "unterminated: expected the diagram drawn over the unterminated block"))))

;; ---- pending/error-without-diagram: line below the closing fence --------

(fn test-pending-below-close-fence []
  (set-env {:sleep :0.5})
  (setup-mermaid {:mermaid {:pending_text "rendering…" :timeout_ms 5000}})
  (let [buf (scratch-md (mermaid-lines ["graph LR" "  A --> B"]))]
    (let [ms (h.marks buf)
          (_osr csr) (block-rows buf)
          vl (virt-lines-mark ms)]
      (check (= 2 (length (conceal-line-rows ms)))
             "pending: an ordinary fenced code block (code.hide_fences) hides both fence rows")
      (check (not= vl nil) "pending: expected the pending line")
      (check (= vl.row (- csr 1))
             "pending: the pending line should attach below the last content row, never the closing fence")
      (check (. (chunk-groups vl) :MadaDiagramPending)
             "pending: expected MadaDiagramPending"))
    (check (h.wait_diagram buf 3000)
           "pending: expected the diagram to eventually arrive")))

;; ---- invariant 2 on test/fixtures/mermaid.md ----

(fn multiset-keys [marks]
  (let [ks (icollect [_ m (ipairs marks)] (vim.inspect m))]
    (table.sort ks)
    ks))

(fn test-invariant2-mermaid-fixture []
  (set-env {})
  (setup-mermaid {:anti_conceal false})
  (set vim.o.columns 80)
  (let [path :test/fixtures/mermaid.md
        nlines (length (vim.fn.readfile path))]
    (set vim.o.lines (math.max 60 (+ nlines 10))))
  (let [buf (h.open :mermaid.md)]
    (check (h.wait_diagram buf) "invariant 2: expected the diagram to arrive")
    (let [win (vim.api.nvim_get_current_win)
          nl (vim.api.nvim_buf_line_count buf)]
      (render.render buf win 0 (- nl 1))
      (let [full (h.marks buf)]
        (vim.api.nvim_buf_clear_namespace buf (state.ns) 0 -1)
        (for [r 0 (- nl 1)]
          (render.render buf win r r))
        (let [per-row (h.marks buf)]
          (h.eq (multiset-keys per-row) (multiset-keys full)
                "invariant 2 mismatch: mermaid.md"))))))

;; ---- RPC-child scenarios: AT-9, AT-13, AT-28 (need real events, OQ-5) ----

(fn start-child []
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

(fn start-child-highlighter []
  "Like `start-child`, but `filetype plugin on` instead of `filetype on`:
Neovim 0.12's own `ftplugin/markdown.lua` runs `vim.treesitter.start()` on
the FileType event this fires, so the runtime highlighter is already active
before `edit` ever opens a file (no separate, racy `vim.treesitter.start`
call after the diagram's job may already have completed)."
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
vim.cmd('filetype plugin on')" [])
    ch))

(fn sync [ch] (vim.rpcrequest ch :nvim_eval :1))
(fn input [ch keys] (vim.rpcrequest ch :nvim_input keys))

(fn input-sync [ch keys]
  (input ch keys)
  (sync ch))

(fn exec [ch code ?args]
  (vim.rpcrequest ch :nvim_exec_lua code (or ?args [])))

(fn edit [ch path]
  (exec ch "local path = ...\nvim.cmd.edit(path)" [path])
  (sync ch))

(fn with-child [f]
  (let [ch (start-child)
        (ok err) (pcall f ch)]
    (pcall vim.fn.jobstop ch)
    (when (not ok) (error err 0))))

(fn with-child-highlighter [f]
  (let [ch (start-child-highlighter)
        (ok err) (pcall f ch)]
    (pcall vim.fn.jobstop ch)
    (when (not ok) (error err 0))))

(fn child-setup-mermaid [ch cmd]
  ;; `require('mada').setup(...)`, not `require('mada.config').setup(...)`:
  ;; the plugin bootstrap's FileType autocommand lazily calls
  ;; `mada.setup({})` on the *first* markdown buffer it ever sees in this
  ;; (fresh child) process (FR-C6), which would otherwise clobber a plain
  ;; `mada.config.setup` call back to the plain defaults before `edit`
  ;; even opens the fixture.
  (exec ch
        "local cmd = ...
require('mada').setup({mermaid = {cmd = {cmd}, timeout_ms = 2000, width_bucket = 10, pending_text = 'rendering diagram…'}})"
        [cmd]))

(fn child-setenv [ch name val]
  (exec ch "local name, val = ...\nvim.fn.setenv(name, val)" [name (or val "")]))

(fn child-reset-env [ch]
  (each [_ v (ipairs [:FAKE_OUT :FAKE_SLEEP :FAKE_ERR :FAKE_CODE])]
    (child-setenv ch v "")))

(fn child-wait-diagram [ch buf timeout]
  ;; `buffer` cannot be combined with an explicit `pattern` in
  ;; nvim_create_autocmd (any event), so this filters data.buf itself,
  ;; mirroring the fix in test/helpers.fnl's wait_diagram.
  (exec ch "local buf, timeout = ...
local fired = false
local id = vim.api.nvim_create_autocmd('User', {pattern = 'MadaDiagram', callback = function(ev) if ev.data.buf == buf then fired = true end end})
vim.wait(timeout or 5000, function() return fired end, 10)
pcall(vim.api.nvim_del_autocmd, id)
return fired" [buf (or timeout 5000)]))

(fn child-arm-diagram-wait [ch buf]
  "Register the `MadaDiagram` listener *before* the caller does anything
that could let a fast job (no FAKE_SLEEP) complete and fire it -- across an
RPC round trip (unlike the in-process `h.wait_diagram`, which registers
before its own first `vim.wait`), a job can complete during an earlier
round trip (`edit`, or a slower one under `filetype plugin on`) before a
post-hoc listener ever reaches the child. Returns an opaque token for
`child-wait-diagram-armed`."
  (exec ch "local buf = ...
local fired = false
local id = vim.api.nvim_create_autocmd('User', {pattern = 'MadaDiagram', callback = function(ev) if ev.data.buf == buf then fired = true end end})
MADA_TEST_ARMED = MADA_TEST_ARMED or {}
MADA_TEST_ARMED[id] = {buf = buf, fired = function() return fired end}
return id" [buf]))

(fn child-wait-diagram-armed [ch id timeout]
  (exec ch "local id, timeout = ...
local armed = MADA_TEST_ARMED[id]
vim.wait(timeout or 5000, function() return armed.fired() end, 10)
local ok = armed.fired()
pcall(vim.api.nvim_del_autocmd, id)
MADA_TEST_ARMED[id] = nil
return ok" [id (or timeout 5000)]))

(fn child-marks [ch buf]
  (exec ch "local buf = ...
local ns = require('mada.state').ns()
local raw = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {details = true})
local out = {}
for _, m in ipairs(raw) do table.insert(out, {row = m[2], col = m[3], opts = m[4]}) end
return out" [buf]))

(fn child-buf [ch] (exec ch "return vim.api.nvim_get_current_buf()"))
(fn child-win [ch] (exec ch "return vim.api.nvim_get_current_win()"))

(fn child-block-rows [ch buf]
  "(open_row close_row), 0-based inclusive: mirrors `block-rows` above, run
inside the child process."
  (exec ch "local buf = ...
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local open, close
for i, l in ipairs(lines) do
  if not open and l:match('^```mermaid') then open = i - 1 end
  if open and not close and (i - 1) ~= open and l:match('^```%s*$') then close = i - 1 end
end
return {open, close or (#lines - 1)}" [buf]))

(fn child-win-height [ch win a b]
  (exec ch "local win, a, b = ...
local t = vim.api.nvim_win_text_height(win, {start_row = a, end_row = b})
return t.all - t.fill" [win a b]))

(fn test-at9 []
  (with-child (fn [ch]
                (child-reset-env ch)
                (child-setup-mermaid ch fake-cmd)
                (edit ch :test/fixtures/mermaid.md)
                (let [buf (child-buf ch)
                      win (child-win ch)]
                  (check (child-wait-diagram ch buf)
                         "AT-9: expected the diagram to arrive")
                  (let [rows (child-block-rows ch buf)
                        osr (. rows 1)
                        csr (. rows 2)
                        h-out (child-win-height ch win osr csr)]
                    (check (> (length (overlays-of (child-marks ch buf))) 0)
                           "AT-9: expected diagram overlays before the cursor enters the block")
                    (input-sync ch :6G)
                    (let [ms (child-marks ch buf)
                          h-in (child-win-height ch win osr csr)]
                      (check (= 2 (length (conceal-line-rows ms)))
                             "AT-9: the fence rows stay hidden (like an ordinary fenced code block) while the cursor is inside the block; only the content rows show raw source")
                      (check (= 0 (length (overlays-of ms)))
                             "AT-9: no diagram overlays should be drawn while the cursor is inside the block (anti-conceal, whole source, no diagram)")
                      (check (= h-out h-in)
                             "AT-9: the block's total height must not change when the cursor enters it"))
                    (input-sync ch :gg)
                    (let [ms (child-marks ch buf)
                          h-back (child-win-height ch win osr csr)]
                      (check (> (length (overlays-of ms)) 0)
                             "AT-9: leaving the block should re-draw its diagram overlays")
                      (check (= 2 (length (conceal-line-rows ms)))
                             "AT-9: a drawn diagram hides both fence rows itself, never a content row")
                      (check (= h-out h-back)
                             "AT-9: the block's total height must not change when the cursor leaves it")))))))

;; ---- cursor into/out of a drawn block, runtime highlighter active -------
;; Same as AT-9, but the child also starts a runtime tree-sitter highlighter
;; before the diagram ever renders (Neovim 0.12's `ftplugin/markdown.lua`,
;; `filetype plugin on`): the block's height must stay the same either way.

(fn test-at9-with-runtime-highlighter []
  (with-child-highlighter (fn [ch]
                            (child-reset-env ch)
                            (child-setup-mermaid ch fake-cmd)
                            (let [buf (child-buf ch)
                                  armed (child-arm-diagram-wait ch buf)]
                              (edit ch :test/fixtures/mermaid.md)
                              (check (child-wait-diagram-armed ch armed)
                                     "AT-9+highlighter: expected the diagram to arrive")
                              (let [win (child-win ch)
                                    rows (child-block-rows ch buf)
                                    osr (. rows 1)
                                    csr (. rows 2)
                                    h-out (child-win-height ch win osr csr)]
                                (check (> (length (overlays-of (child-marks ch
                                                                            buf)))
                                          0)
                                       "AT-9+highlighter: expected diagram overlays before the cursor enters the block")
                                (input-sync ch :6G)
                                (let [h-in (child-win-height ch win osr csr)]
                                  (check (= h-out h-in)
                                         "AT-9+highlighter: the block's total height must not change when the cursor enters it")
                                  (check (= 0
                                            (length (overlays-of (child-marks ch
                                                                              buf))))
                                         "AT-9+highlighter: no diagram overlays while the cursor is inside the block"))
                                (input-sync ch :gg)
                                (let [h-back (child-win-height ch win osr csr)]
                                  (check (> (length (overlays-of (child-marks ch
                                                                              buf)))
                                            0)
                                         "AT-9+highlighter: leaving the block should re-draw its diagram overlays")
                                  (check (= h-out h-back)
                                         "AT-9+highlighter: the block's total height must not change when the cursor leaves it")))))))

(fn test-at13 []
  (with-child (fn [ch]
                (child-reset-env ch)
                (child-setenv ch :FAKE_OUT :V1)
                (child-setup-mermaid ch fake-cmd)
                (edit ch :test/fixtures/mermaid.md)
                (let [buf (child-buf ch)]
                  (check (child-wait-diagram ch buf)
                         "AT-13: expected the first diagram")
                  (child-setenv ch :FAKE_OUT :V2)
                  (input-sync ch :6G)
                  (input-sync ch "A extra")
                  (input-sync ch :<Esc>)
                  ;; The cursor is still inside the block right after <Esc>
                  ;; (anti-conceal, FR-AC3, AT-9: no diagram overlay is drawn
                  ;; while the cursor is inside it, by design); `gg` leaves it,
                  ;; still before the new job can plausibly have completed.
                  (input-sync ch :gg)
                  (let [overlays (overlays-of (child-marks ch buf))]
                    (check (> (length overlays) 0)
                           "AT-13: a diagram should be shown at once once the cursor leaves the block")
                    (check (not (. (overlay-groups overlays)
                                   :MadaDiagramPending))
                           "AT-13: no pending row should flash")
                    (check (contains? (overlay-text overlays) :V1)
                           "AT-13: the previous diagram (V1) should be shown immediately"))
                  (check (child-wait-diagram ch buf)
                         "AT-13: expected the replacement diagram")
                  (let [overlays2 (overlays-of (child-marks ch buf))]
                    (check (contains? (overlay-text overlays2) :V2)
                           "AT-13: the new diagram (V2) should replace the previous one"))))))

(fn test-at28 []
  (with-child (fn [ch]
                (child-reset-env ch)
                (child-setup-mermaid ch fake-cmd)
                (edit ch :test/fixtures/mermaid.md)
                (let [buf (child-buf ch)]
                  (check (child-wait-diagram ch buf)
                         "AT-28: expected the first diagram")
                  (input-sync ch :6G)
                  (input-sync ch "A BREAK")
                  (input-sync ch :<Esc>)
                  (check (child-wait-diagram ch buf)
                         "AT-28: expected the failing job to complete")
                  ;; Leave the block: no diagram overlay is drawn while the
                  ;; cursor is inside it (anti-conceal, AT-9).
                  (input-sync ch :gg)
                  (let [ms (child-marks ch buf)
                        overlays (overlays-of ms)
                        vl (virt-lines-mark ms)]
                    (check (> (length overlays) 0)
                           "AT-28: the previous diagram should stay shown")
                    (let [groups (overlay-groups overlays)
                          vl-groups (if vl (chunk-groups vl) {})]
                      (check (or (. groups :MadaDiagramLine)
                                 (. groups :MadaDiagramText))
                             "AT-28: the previous diagram's chunks should still be present")
                      (check (or (. groups :MadaDiagramError)
                                 (. vl-groups :MadaDiagramError))
                             "AT-28: one error line should be added (as an overlay if it still fits the block's own rows, else an overflow virt_lines line)")))))))

[["AT-7: flowchart with backend present, no conceal_lines, overlays coloured"
  test-at7]
 ["AT-9: cursor into the block, source visible, no diagram overlays, height unchanged"
  test-at9]
 ["AT-10: backend missing, code block plus a single WARN" test-at10]
 ["AT-11: backend exits 1, error row below the closing fence, no retry without render!"
  test-at11]
 ["AT-12: backend hangs, timeout error row, no leaked process, editing not blocked"
  test-at12]
 ["AT-13: edit a rendered diagram in Insert, <Esc> shows it at once, replaced later"
  test-at13]
 ["AT-28: break a rendered diagram's syntax, previous diagram stays plus one error line"
  test-at28]
 ["FR-D17: key change keeps the diagram, no pending flash"
  test-frd17-key-change-keeps-diagram]
 ["placement off: ordinary code block, no job" test-placement-off]
 [":Mada render! retries a failed key" test-render-bang-retries-failed]
 ["detach drops a late job result (FR-M8)" test-detach-drops-late-results]
 ["NFR-Q4: the job-exit callback runs under log.guard (disabled, one ERROR notification, no raw error)"
  test-mermaid-job-exit-guarded]
 ["width-bucket crossing re-runs the diagram" test-width-bucket-crossing]
 ["drawn diagram longer than the block's own rows: overflow virt_lines below the first content row"
  test-drawn-overlay-and-overflow]
 ["drawn diagram with the runtime tree-sitter highlighter active: every line visible, nothing anchored on a fence row"
  test-drawn-with-runtime-highlighter]
 ["AT-9 with the runtime highlighter active: cursor in/out of the block, height unchanged"
  test-at9-with-runtime-highlighter]
 ["short diagram: overlays past its own lines are blank"
  test-blank-padding-overlays]
 ["unterminated block: overlays reach the buffer's last row"
  test-unterminated-block]
 ["pending/error-without-diagram: line below the closing fence"
  test-pending-below-close-fence]
 ["invariant 2 on test/fixtures/mermaid.md" test-invariant2-mermaid-fixture]]
