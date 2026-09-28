;; mada.mermaid - detection, block state, jobs, placement, termaid argv and
;; parsing (architecture §8). Requires mada.block, never the reverse: block
;; owns FR-D1 detection (`mermaid_block?`) and ordinary fenced-code marks
;; (`fenced_code`); this module owns everything else about Mermaid blocks.

(local state (require :mada.state))
(local block (require :mada.block))
(local mark (require :mada.mark))
(local screen (require :mada.screen))
(local log (require :mada.log))

(local M {})

;; priority (architecture §5): a Mermaid block's overlays, pending/error line
;; and the diagram's own virt_lines all share 140. A Mermaid block's source
;; rows are never hidden (OQ-1: `conceal_line`d rows used to hang the drawn
;; diagram's virt_lines on the row before the block, and scrolling past that
;; hidden row through topfill made Neovim's cursor-visibility correction snap
;; the topline back down in an endless cycle); the diagram is drawn as
;; `virt_text_win_col = 0` overlays directly over the block's own rows
;; instead (mada.screen, the same draw-over-source design tables.fnl uses).
;;
;; Revised: Neovim 0.12's runtime `ftplugin/markdown.lua` starts a
;; tree-sitter highlighter on every markdown buffer by default
;; (`filetype plugin on`), whose bundled `highlights.scm` conceals fenced
;; code's fence rows on its own, independent of mada. A diagram's overlays
;; and overflow `virt_lines` used to anchor on those same fence rows, so
;; whether the highlighter runs at all silently determined whether the
;; diagram's first/overflow lines were visible. Now: when a diagram is drawn
;; (cursor outside the block), mada conceals both fence rows itself (same as
;; the highlighter would), so the layout never depends on whether a
;; highlighter happens to be running; overlays and the overflow `virt_lines`
;; attach only to the block's own *content* rows (open+1..close-1, or to the
;; buffer's last row for an unterminated block), never to a fence row.
;;
;; Revised again: the overflow `virt_lines` (and the cursor-in-block blank
;; padding) used to hang below the *last* content row. Scrolling the window's
;; topline into a hidden closing fence row's filler still made Neovim scroll
;; into it and then snap back down, the same OQ-1 symptom one row over: the
;; fence row is invisible, but the filler above it is real screen space, so
;; the topline can land inside it. Both now attach below the *first* content
;; row instead, keeping the diagram contiguous end to end: the first content
;; row's own screen rows, then the overflow/padding, then the remaining
;; content rows -- never a hidden row directly behind any filler.
(local ROW_PRIORITY 140)

(fn in_range [ctx row] (and (>= row ctx.a) (<= row ctx.b)))

;; box-drawing / arrow ranges plus the ASCII set, for chunk colourisation
;; (FR-D14).
(fn line-char? [ch]
  (or (ch:find "^[%-|+<>^v]$")
      (let [cp (vim.fn.char2nr ch)]
        (or (and (>= cp 9472) (<= cp 9631)) (and (>= cp 9632) (<= cp 9727))
            (and (>= cp 8592) (<= cp 8703))))))

(fn chunk_line [line]
  "Split `line` into runs of box-drawing/arrow characters (MadaDiagramLine)
and everything else (MadaDiagramText); built once per result (FR-D14)."
  (let [n (vim.fn.strchars line)
        chunks []]
    (var i 0)
    (var cur_group nil)
    (var cur_text "")
    (while (< i n)
      (let [ch (vim.fn.strcharpart line i 1)
            grp (if (line-char? ch) :MadaDiagramLine :MadaDiagramText)]
        (if (= grp cur_group)
            (set cur_text (.. cur_text ch))
            (do
              (when cur_group
                (table.insert chunks [cur_text cur_group]))
              (set cur_group grp)
              (set cur_text ch))))
      (set i (+ i 1)))
    (when cur_group
      (table.insert chunks [cur_text cur_group]))
    (if (> (length chunks) 0) chunks [["" :MadaDiagramText]])))

;; ---- result parsing (§8.3) ----

(fn trim_blank_edges [lines]
  "Drop leading and trailing blank lines (real termaid may start with
blanks; deviation from the architecture's original text, which only
mentioned trailing)."
  (var s 1)
  (var e (length lines))
  (while (and (<= s e) (= (. lines s) ""))
    (set s (+ s 1)))
  (while (and (<= s e) (= (. lines e) ""))
    (set e (- e 1)))
  (let [out []]
    (for [i s e] (table.insert out (. lines i)))
    out))

(fn expand_tabs [line]
  (if (not (line:find "\t"))
      line
      (let [out []]
        (var col 0)
        (line:gsub "." (fn [c]
                         (if (= c "\t")
                             (let [n (- 8 (% col 8))]
                               (table.insert out (string.rep " " n))
                               (set col (+ col n)))
                             (do
                               (table.insert out c)
                               (set col (+ col 1))))))
        (table.concat out))))

(fn first_stderr_line [s]
  (if (or (not s) (= s ""))
      nil
      (let [nl (s:find "\n")]
        (if nl (s:sub 1 (- nl 1)) s))))

(fn M.parse_result [obj]
  "(ok, chunks-or-message) from a completed `vim.system` job (§8.3).
Exposed for tests."
  (if (= obj.code 124)
      (values false :timeout)
      (if (not= obj.code 0)
          (values false
                  (or (first_stderr_line obj.stderr)
                      (.. "exit " (tostring obj.code))))
          (let [raw (vim.split (or obj.stdout "") "\n" {:plain true})
                expanded (icollect [_ l (ipairs raw)] (expand_tabs l))
                trimmed (trim_blank_edges expanded)]
            (if (= (length trimmed) 0)
                (values false "empty output")
                (values true (icollect [_ l (ipairs trimmed)] (chunk_line l))))))))

;; ---- tree helpers ----

(fn fenced_children [node]
  "(open body close) named children of a fenced_code_block node; close is
nil for an unterminated fence (edge cases, architecture §14)."
  (var open nil)
  (var close nil)
  (var body nil)
  (for [i 0 (- (node:named_child_count) 1)]
    (let [child (node:named_child i)
          t (child:type)]
      (if (= t :fenced_code_block_delimiter)
          (if open (set close child) (set open child))
          (= t :code_fence_content)
          (set body child))))
  (values open body close))

(fn block_bounds [buf node]
  "(open_row close_row fence_col) 0-based inclusive rows of `node`, or nil
if it has no opening delimiter."
  (let [(open _body close) (fenced_children node)]
    (when open
      (let [(osr osc _oer _oec) (open:range)
            total (vim.api.nvim_buf_line_count buf)]
        (if close
            (let [(csr _csc _cer _cec) (close:range)]
              (values osr csr osc))
            (values osr (- total 1) osc))))))

(fn block_source [buf open_row close_row fence_col has_close?]
  "Content rows with the fence's column stripped (§8.1); empty string if
there are no content rows."
  (let [content_start (+ open_row 1)
        content_end (if has_close? (- close_row 1) close_row)]
    (if (> content_start content_end)
        ""
        (let [raw (vim.api.nvim_buf_get_lines buf content_start
                                              (+ content_end 1) false)
              stripped (icollect [_ l (ipairs raw)] (l:sub (+ fence_col 1)))]
          (table.concat stripped "\n")))))

(fn node_text [buf node]
  "Text of `node`, fetched directly from the buffer (never ctx.lines: the
search window can extend past the rows a render pass loaded, invariant 2)."
  (let [(sr sc er ec) (node:range)
        total (vim.api.nvim_buf_line_count buf)]
    (if (or (< sr 0) (>= sr total))
        ""
        (let [er2 (math.min er (- total 1))
              (ok lines) (pcall vim.api.nvim_buf_get_text buf sr sc er2 ec {})]
          (if (and ok lines) (table.concat lines "\n") "")))))

(fn detect_ctx [buf]
  {: buf :text (fn [node] (node_text buf node))})

(fn mermaid_node? [buf node]
  (block.mermaid_block? (detect_ctx buf) node))

(local fence_query_src "(fenced_code_block) @block")
(var fence_query nil)

(fn get_fence_query []
  (when (not fence_query)
    (set fence_query (vim.treesitter.query.parse :markdown fence_query_src)))
  fence_query)

(fn find_block_node [root row]
  "Walk up from the smallest node at (row, 0) to its fenced_code_block
ancestor, or nil."
  (var node (root:named_descendant_for_range row 0 row 0))
  (var result nil)
  (while (and node (not result))
    (if (= (node:type) :fenced_code_block) (set result node)
        (set node (node:parent))))
  result)

(fn current_root [buf]
  "The root of buf's existing markdown parse tree, without parsing."
  (let [(ok ltree) (pcall vim.treesitter.get_parser buf :markdown)]
    (if (not (and ok ltree))
        nil
        (let [trees (ltree:trees)]
          (if (> (length trees) 0) (: (. trees 1) :root) nil)))))

(fn M.block_at [buf row]
  "The Mermaid fenced_code_block node containing `row`, or nil (FR-AC3,
anti-conceal). Uses the existing parse tree, no parse call."
  (let [root (current_root buf)]
    (if (not root)
        nil
        (let [node (find_block_node root row)]
          (if (and node (mermaid_node? buf node)) node nil)))))

(fn M.block_range [buf node]
  "(open_row close_row), 0-based inclusive rows of the block's fence rows."
  (let [(osr csr _fc) (block_bounds buf node)]
    (values (or osr 0) (or csr 0))))

(fn M.render_range [buf node]
  "Block rows (osr..close_row): a Mermaid block's diagram/pending/error line
now always attaches as `virt_lines` below its own closing fence row, never
above the opening fence (OQ-1), so re-rendering the block's own rows is
always enough (no attach-row union needed any more)."
  (M.block_range buf node))

;; ---- block key and width bucket (§8.1) ----

(fn bucket_for [width step]
  (if (or (not step) (<= step 0)) width (- width (% width step))))

(fn block_key [source width step ascii]
  (.. source "\000" (tostring (bucket_for width step)) "\000" (tostring ascii)))

;; ---- termaid presence (checked once per session, per binary) ----

(local termaid_checked {})

(fn normalize_cmd [cmd]
  (if (= (type cmd) :string) [cmd] cmd))

(fn termaid_available? [cmd]
  (let [bin (. (normalize_cmd cmd) 1)
        cached (. termaid_checked bin)]
    (if (= cached nil)
        (let [found (not= (vim.fn.exepath bin) "")]
          (tset termaid_checked bin found)
          found)
        cached)))

;; ---- jobs (§8.3) ----

(fn build_argv [cmd bucket ascii args]
  (let [argv []]
    (each [_ c (ipairs (normalize_cmd cmd))]
      (table.insert argv c))
    (table.insert argv :--width)
    (table.insert argv (tostring bucket))
    (when ascii (table.insert argv :--ascii))
    (each [_ a (ipairs args)] (table.insert argv a))
    argv))

(fn anchor_open_row [buf anchor]
  (let [pos (vim.api.nvim_buf_get_extmark_by_id buf (state.anchor_ns) anchor {})]
    (if (> (length pos) 0) (. pos 1) nil)))

(fn rerender_anchor [buf anchor]
  "Re-render the block's rows (found from the anchor row) after its job
completes (§8.3)."
  (let [row (anchor_open_row buf anchor)]
    (when row
      (let [root (current_root buf)]
        (when root
          (let [node (find_block_node root row)]
            (when node
              (let [(lo hi) (M.render_range buf node)
                    render (require :mada.render)]
                (each [_ w (ipairs (vim.api.nvim_list_wins))]
                  (when (= (vim.api.nvim_win_get_buf w) buf)
                    (render.render buf w lo hi false)))))))))))

(fn on_job_exit [buf anchor key obj expected_state]
  "Runs on vim.schedule. Drops the result if the buffer's state is gone or
was replaced (FR-M8)."
  (let [st (state.get buf)]
    (when (= st expected_state)
      (let [bs (. st.blocks anchor)]
        (when bs
          (tset bs :job nil)
          (let [(ok result) (M.parse_result obj)]
            (if ok
                (do
                  (tset bs :diagram {: key :chunks result})
                  (tset bs :err nil))
                (tset bs :err {: key :msg result})))
          (rerender_anchor buf anchor)
          (vim.api.nvim_exec_autocmds :User
                                      {:pattern :MadaDiagram
                                       :data {: buf
                                              :row (or (anchor_open_row buf
                                                                        anchor)
                                                       -1)
                                              :status (if ok :ok :error)}}))))))

(fn spawn [ctx anchor key source st]
  (let [buf ctx.buf
        cfg ctx.cfg
        bucket (bucket_for ctx.width cfg.mermaid.width_bucket)
        argv (build_argv cfg.mermaid.cmd bucket cfg.ascii cfg.mermaid.args)]
    (tset (. st.blocks anchor) :job key)
    (log.debug cfg "mermaid: spawn buf=%s anchor=%s argv=%s" (tostring buf)
               (tostring anchor) (table.concat argv " "))
    (vim.system argv {:stdin source :text true :timeout cfg.mermaid.timeout_ms}
                (fn [obj]
                  (vim.schedule (fn []
                                  (log.guard :MermaidJob buf on_job_exit buf
                                             anchor key obj st)))))))

;; ---- mark building per state (§8.2) ----

(fn ensure_block_state [st anchor]
  (or (. st.blocks anchor) (let [nb {:diagram nil :err nil :job nil}]
                             (tset st.blocks anchor nb)
                             nb)))

(fn pending_marks [ctx bs key attach_row]
  "The pending-text or (no-diagram-yet) error line, `virt_lines` below the
block's own last content row `attach_row` (never on a fence row, OQ-1)."
  (if (and bs.err (= bs.err.key key))
      [(mark.virt_lines attach_row
                        [[[(.. "[termaid] " bs.err.msg) :MadaDiagramError]]]
                        ROW_PRIORITY false)]
      (if (and ctx.cfg.mermaid.pending_text
               (not= ctx.cfg.mermaid.pending_text ""))
          [(mark.virt_lines attach_row
                            [[[ctx.cfg.mermaid.pending_text
                               :MadaDiagramPending]]]
                            ROW_PRIORITY false)]
          [])))

(fn diagram_lines [bs key]
  "Flat virt_text chunk-lists to draw for `bs`'s diagram (one per display
line), `bs.err`'s message appended as one more line when it matches `key`
(AT-28: the previous diagram stays, plus one error line)."
  (let [lines (icollect [_ l (ipairs bs.diagram.chunks)] l)]
    (when (and bs.err (= bs.err.key key))
      (table.insert lines [[(.. "[termaid] " bs.err.msg) :MadaDiagramError]]))
    lines))

(fn in_block_range [osr close_row row] (and (>= row osr) (<= row close_row)))

(fn buffer_line_or [buf row]
  (let [(ok lines) (pcall vim.api.nvim_buf_get_lines buf row (+ row 1) false)]
    (if (and ok lines (> (length lines) 0)) (. lines 1) "")))

(fn blank_lines [n] (fcollect [_ 1 n] []))

(fn diagram_height [ctx osr close_row]
  "T: total screen rows the block's own rows (osr..close_row) occupy
(mada.screen.s_r_for, win/row-only -- independent of ctx.a..ctx.b, so a
partial render of one row of the block computes the same T a full render
would, invariant 2)."
  (var t 0)
  (for [r osr close_row]
    (set t (+ t (screen.s_r_for ctx.win r))))
  t)

(fn emit_diagram_rows [ctx marks content_start content_end lines]
  "Overlay marks for the drawn diagram, one `virt_text_win_col = 0` overlay
per screen row of the block's own *content* rows content_start..content_end
(mada.screen, the tables.fnl draw-over-source design; never a fence row, so
this never depends on whether a highlighter conceals the fence rows or mada
does). `lines` beyond the content rows' own T screen rows (the overflow)
attach as one `virt_lines` mark below `content_start` (the *first* content
row, never a fence row): scrolling into a hidden closing fence's filler used
to snap the topline back down (OQ-1 regression), so the diagram now stays
contiguous on screen by showing content_start's own S_first lines, then the
overflow immediately below it, then the rest of the content rows in order --
never a gap between two chunks of the diagram with a hidden row behind it.
With exactly one content row content_start = content_end, so this is the
same attach row as before. Screen rows past the diagram's own lines get a
blank overlay. Returns T (consumed), the content rows' own screen-row
count."
  (let [win ctx.win
        buf ctx.buf
        total (length lines)]
    ;; Pass 1: T and the first content row's own S_first, independent of
    ;; ctx.a..ctx.b (invariant 2: a partial render of one row must compute
    ;; the same split a full render would).
    (var t 0)
    (var s_first 0)
    (for [r content_start content_end]
      (let [s_r (screen.s_r_for win r)]
        (when (= r content_start) (set s_first s_r))
        (set t (+ t s_r))))
    (let [overflow (math.max 0 (- total t))]
      (when (in_range ctx content_start)
        (let [line (buffer_line_or buf content_start)
              anchors (screen.row_anchor_cols win buf line s_first ctx.width)]
          (for [k 1 s_first]
            (let [src (or (. lines k) [])
                  chunks (screen.pad_chunks_to src ctx.width)]
              (table.insert marks
                            (mark.overlay_win_col content_start (. anchors k)
                                                  chunks ROW_PRIORITY))))
          (when (> overflow 0)
            (let [tail (let [out []]
                         (for [i (+ s_first 1) (+ s_first overflow)]
                           (table.insert out (. lines i)))
                         out)]
              (table.insert marks
                            (mark.virt_lines content_start tail ROW_PRIORITY
                                             false))))))
      (var consumed (+ s_first overflow))
      (for [r (+ content_start 1) content_end]
        (let [s_r (screen.s_r_for win r)]
          (when (in_range ctx r)
            (let [line (buffer_line_or buf r)
                  anchors (screen.row_anchor_cols win buf line s_r ctx.width)]
              (for [k 1 s_r]
                (let [idx (+ consumed k)
                      src (or (. lines idx) [])
                      chunks (screen.pad_chunks_to src ctx.width)]
                  (table.insert marks
                                (mark.overlay_win_col r (. anchors k) chunks
                                                      ROW_PRIORITY))))))
          (set consumed (+ consumed s_r))))
      t)))

(fn append [dst src]
  (each [_ m (ipairs src)] (table.insert dst m)))

(fn collect_block [ctx st node marks]
  (let [buf ctx.buf
        cfg ctx.cfg
        (osr close_row fence_col) (block_bounds buf node)]
    (when osr
      (let [(_o _b close) (fenced_children node)
            terminated? (not= close nil)
            source (block_source buf osr close_row fence_col terminated?)]
        (when (not= source "")
          (let [available? (termaid_available? cfg.mermaid.cmd)
                ;; Content rows: open+1..close-1 (terminated) or open+1..
                ;; close_row (unterminated, block_bounds already reports
                ;; close_row as the buffer's last row then). Never a fence
                ;; row (OQ-1): a diagram's overlays/overflow and the
                ;; pending/error line all attach here, never on osr/close_row.
                last_content_row (if terminated? (- close_row 1) close_row)]
            (if (or (= cfg.mermaid.placement :off) (not available?))
                (do
                  (when (and (not available?) (not= cfg.mermaid.placement :off))
                    (log.notify_once :termaid_missing
                                     "mada: termaid not found; Mermaid blocks render as code blocks"
                                     vim.log.levels.WARN))
                  (append marks (block.fenced_code ctx node)))
                (let [width (or ctx.width 0)
                      key (block_key source width cfg.mermaid.width_bucket
                                     cfg.ascii)
                      anchor (M.get_anchor buf osr)
                      bs (ensure_block_state st anchor)]
                  (when (and (or (not bs.diagram) (not= bs.diagram.key key))
                             (not bs.job)
                             (or (not bs.err) (not= bs.err.key key)))
                    (spawn ctx anchor key source st))
                  (if (not bs.diagram)
                      (do
                        ;; Pending/error, no diagram yet: an ordinary fenced
                        ;; code block (fence hiding follows cfg.code.hide_
                        ;; fences like any other fenced code block; no longer
                        ;; stripped), plus the pending/error line below the
                        ;; last content row.
                        (append marks (block.fenced_code ctx node))
                        (append marks
                                (pending_marks ctx bs key last_content_row)))
                      (let [cursor_in? (and (not= ctx.cursor -1)
                                            (in_block_range osr close_row
                                                            ctx.cursor))
                            lines (diagram_lines bs key)]
                        ;; A diagram's own block hides its fences the same
                        ;; way an ordinary fenced code block does
                        ;; (cfg.code.hide_fences), cursor-position-
                        ;; independent (render.fnl's own anti-conceal already
                        ;; reveals whichever single row the cursor sits on
                        ;; exactly): this is what keeps the block's total
                        ;; height the same whether the cursor is inside it
                        ;; or not (AT-9), and keeps a diagram's own overlays/
                        ;; overflow off the fence rows regardless of whether
                        ;; a highlighter is also concealing them.
                        (when cfg.code.hide_fences
                          (table.insert marks
                                        (mark.conceal_line osr ROW_PRIORITY))
                          (when terminated?
                            (table.insert marks
                                          (mark.conceal_line close_row
                                                             ROW_PRIORITY))))
                        (if cursor_in?
                            ;; Whole source shown, no diagram overlays: blank
                            ;; padding below the first content row (same row
                            ;; a drawn diagram's own overflow would use, OQ-1)
                            ;; keeps the block's total height the same as the
                            ;; drawn case.
                            (let [t (diagram_height ctx osr close_row)
                                  m (math.max t (length lines))
                                  pad (math.max 0 (- m t))
                                  first_content_row (+ osr 1)]
                              (when (and (> pad 0)
                                         (in_range ctx first_content_row))
                                (table.insert marks
                                              (mark.virt_lines first_content_row
                                                               (blank_lines pad)
                                                               ROW_PRIORITY
                                                               false))))
                            (emit_diagram_rows ctx marks (+ osr 1)
                                               last_content_row lines)))))))))))
  nil)

(fn M.get_anchor [buf row]
  "Return the id of the invisible identity mark on `row` in mada.anchor,
creating it if this is the first time this block is seen (§8.2)."
  (let [ns (state.anchor_ns)
        existing (vim.api.nvim_buf_get_extmarks buf ns [row 0] [row -1] {})]
    (if (> (length existing) 0)
        (. (. existing 1) 1)
        (vim.api.nvim_buf_set_extmark buf ns row 0
                                      {:invalidate true :undo_restore false}))))

(fn M.collect [ctx]
  "Mermaid marks for blocks meeting ctx.a..ctx.b, considering rows *or*
anchor row (invariant 2): searches ctx.a-1..ctx.b+2, clamped. Spawns a
termaid job per block whose key has no current diagram, error or running
job (FR-D6)."
  (let [marks []
        st (state.get ctx.buf)]
    (when (and st ctx.root)
      (let [total (vim.api.nvim_buf_line_count ctx.buf)
            lo (math.max 0 (- ctx.a 1))
            hi (math.min (- total 1) (+ ctx.b 2))
            q (get_fence_query)]
        (each [_ node (q:iter_captures ctx.root ctx.buf lo (+ hi 1))]
          (when (mermaid_node? ctx.buf node)
            (collect_block ctx st node marks)))))
    marks))

(fn M.reset [buf]
  "Clear every block's error and current diagram key so the next render
re-runs every diagram, including failed ones (`:Mada render!`)."
  (let [st (state.get buf)]
    (when st
      (each [_ bs (pairs st.blocks)]
        (tset bs :err nil)
        (when bs.diagram (tset bs.diagram :key nil))))))

(fn M.detach [_buf]
  "No per-block resource needs releasing beyond state[buf].blocks, which
`state.clear` drops (FR-M8): a running job checks the state table's
identity on completion and drops its result once it no longer matches
(no cancellation, architecture D5/§8.3)."
  nil)

M
