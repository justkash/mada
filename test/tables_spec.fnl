;; test.tables_spec - FR-R13, AT-30: pipe tables laid out as a boxed grid,
;; drawn over the source rows rather than in place of them. Reconstructs
;; displayed lines from extmarks (no real screen redraw needed for most
;; cases) so assertions read like the diagram in the design: a source row's
;; `virt_text_win_col = 0` overlays (one per screen row, sorted by anchor
;; column) become one output line each; a row with no overlays (the cursor
;; row: anti-conceal drops them) shows its raw source; virt_lines/
;; virt_lines_above splice in around their own row.

(local h (require :helpers))
(local mada (require :mada))
(local state (require :mada.state))
(local events (require :mada.events))

(fn check [cond msg]
  (when (not cond) (error msg 0)))

(fn scratch-md [lines]
  (let [buf (vim.api.nvim_create_buf true false)]
    (vim.api.nvim_buf_set_lines buf 0 -1 false lines)
    (vim.api.nvim_win_set_buf 0 buf)
    (set vim.bo.filetype :markdown)
    buf))

(fn sized-win [cols ?wrap]
  "A window whose reported width really is `cols` (a lone window always
fills `columns` headless with no UI attached; a vsplit's width can really be
set, mirrors test.mermaid_spec's width-bucket test)."
  (vim.cmd.vsplit)
  (let [win (vim.api.nvim_get_current_win)]
    (vim.api.nvim_win_set_width win cols)
    (when (not= ?wrap nil)
      (tset vim.wo win :wrap ?wrap))
    win))

(fn set-cursor! [buf win row]
  "0-based row. Pokes st.cursor directly, mirroring what a real
CursorMoved would do: a scripted nvim_win_set_cursor does not itself fire
CursorMoved synchronously in this headless harness (test.helpers' M.feed
works around the same gap for other specs)."
  (vim.api.nvim_win_set_cursor win [(+ row 1) 0])
  (let [st (state.get buf)]
    (when st (set st.cursor row))))

(fn render! [buf win] (events.render_view buf win))

;; ---- reconstructing display lines from extmarks ---------------------------

(fn chunk-text [chunks]
  (accumulate [s "" _ c (ipairs chunks)] (.. s (. c 1))))

(fn kind-of [opts]
  (if (not= opts.conceal nil)
      :conceal
      (and opts.virt_text (= opts.virt_text_pos :overlay))
      :overlay
      ;; `virt_text_win_col` marks report their own virt_text_pos as
      ;; "win_col" (verified), not "overlay": mada.tables' draw-over-source
      ;; grid lines (FR-R13) are always this kind.
      (and opts.virt_text (= opts.virt_text_pos :win_col))
      :overlay
      (and opts.virt_text (= opts.virt_text_pos :inline))
      :inline
      :other))

(fn reconstruct-row [line ms]
  "Visible text of buffer row `line`: its conceal/overlay marks applied
(removed or replaced) and inline marks inserted, walked left to right."
  (let [n (length line)]
    (var out "")
    (var c 0)
    (while (< c n)
      (each [_ m (ipairs ms)]
        (when (and (= m.col c) (= (kind-of m.opts) :inline))
          (set out (.. out (chunk-text m.opts.virt_text)))))
      (var handled false)
      (each [_ m (ipairs ms)]
        (when (and (not handled) (= m.col c))
          (let [k (kind-of m.opts)]
            (if (= k :conceal)
                (do
                  (set out (.. out (or m.opts.conceal "")))
                  (set c m.opts.end_col)
                  (set handled true))
                (= k :overlay)
                (do
                  (set out (.. out (chunk-text m.opts.virt_text)))
                  (set c m.opts.end_col)
                  (set handled true))))))
      (when (not handled)
        (set out (.. out (line:sub (+ c 1) (+ c 1))))
        (set c (+ c 1))))
    ;; an inline mark anchored exactly at end-of-line
    (each [_ m (ipairs ms)]
      (when (and (= m.col n) (= (kind-of m.opts) :inline))
        (set out (.. out (chunk-text m.opts.virt_text)))))
    out))

(fn reconstruct [buf]
  "One string per screen row mada would draw for `buf`: a table row's own
`virt_text_win_col` overlays, sorted by anchor column (one per screen row,
FR-R13), each becomes its own output line; a row with no such overlays (the
cursor row, anti-conceal) falls back to the old conceal/inline substitution
over its raw text; virt_lines/virt_lines_above splice in around their own
row."
  (let [nlines (vim.api.nvim_buf_line_count buf)
        raw (vim.api.nvim_buf_get_lines buf 0 -1 false)
        marks (h.marks buf)
        by-row {}]
    (each [_ m (ipairs marks)]
      (let [lst (or (. by-row m.row) [])]
        (table.insert lst m)
        (tset by-row m.row lst)))
    (let [out []]
      (for [r 0 (- nlines 1)]
        (let [ms (or (. by-row r) [])]
          (each [_ m (ipairs ms)]
            (when (and m.opts.virt_lines m.opts.virt_lines_above)
              (each [_ l (ipairs m.opts.virt_lines)]
                (table.insert out (chunk-text l)))))
          (let [overlays (icollect [_ m (ipairs ms)]
                           (when (= (kind-of m.opts) :overlay) m))]
            (table.sort overlays (fn [a b] (< a.col b.col)))
            (if (> (length overlays) 0)
                (each [_ m (ipairs overlays)]
                  (table.insert out (chunk-text m.opts.virt_text)))
                (table.insert out (reconstruct-row (. raw (+ r 1)) ms))))
          (each [_ m (ipairs ms)]
            (when (and m.opts.virt_lines (not m.opts.virt_lines_above))
              (each [_ l (ipairs m.opts.virt_lines)]
                (table.insert out (chunk-text l)))))))
      out)))

(fn row-overlays [buf row]
  "This row's `virt_text_win_col` overlay marks, sorted by anchor column
(one per screen row, in order, FR-R13)."
  (let [overlays (icollect [_ m (ipairs (h.marks buf))]
                   (when (and (= m.row row) (= (kind-of m.opts) :overlay))
                     m))]
    (table.sort overlays (fn [a b] (< a.col b.col)))
    overlays))

(fn s_r_of [win row]
  "Screen rows `row` occupies in `win`, the same measure mada.tables uses
(nvim_win_text_height, .all - .fill)."
  (let [t (vim.api.nvim_win_text_height win {:start_row row :end_row row})]
    (math.max 1 (- t.all t.fill))))

(fn find-substr [lines needle]
  (var found false)
  (each [_ l (ipairs lines)] (when (l:find needle 1 true) (set found true)))
  found)

;; ---- AT-30: fits a narrow window, wraps, re-lays-out on resize -----------

(local wide-lines ["# T"
                   ""
                   "| Name | Description | Status |"
                   "| :--- | :--- | ---: |"
                   "| foo | a long description that certainly will not fit into a narrow window at all | **ok** |"
                   "| `bar` | short | b\\|c |"
                   "| baz |  | [link](http://x.y) |"
                   ""
                   :after])

(fn test-at30-fits-and-wraps []
  (mada.setup {:anti_conceal false})
  (let [buf (scratch-md wide-lines)
        win (sized-win 60 false)]
    (render! buf win)
    (let [lines60 (reconstruct buf)]
      (each [_ l (ipairs lines60)]
        (check (<= (vim.fn.strdisplaywidth l) 60)
               (: "AT-30: line %q wider than the 60-column window" :format l)))
      (check (find-substr lines60 :narrow)
             "AT-30: the wrapped 'Description' cell should still contain every word")
      (check (find-substr lines60 "┌") "AT-30: expected a top border")
      (check (find-substr lines60 "└") "AT-30: expected a bottom border")
      ;; widening the window (a vsplit window's width is bounded by the
      ;; terminal's total columns headless, test.mermaid_spec's width-bucket
      ;; test note, so this stays within it) re-lays-out to wider, natural
      ;; columns: the wrapped cell now needs fewer continuation lines.
      (vim.api.nvim_win_set_width win 75)
      (render! buf win)
      (let [lines75 (reconstruct buf)]
        (check (not (vim.deep_equal lines60 lines75))
               "AT-30: widening the window should change the layout")))))

;; ---- alignment --------------------------------------------------------------

(fn test-alignment []
  (mada.setup {:anti_conceal false})
  (let [buf (scratch-md ["| L | C | R |"
                         "| :--- | :---: | ---: |"
                         "| a | centered | right-aligned |"])
        win (sized-win 40 false)]
    (render! buf win)
    (let [lines (reconstruct buf)]
      (check (find-substr lines "│ a")
             "left: content should hug the left border")
      (check (find-substr lines "│    C     │")
             "center: 'C' should be padded both sides, extra space on the right")
      (check (find-substr lines "R │")
             "right: content should hug the right border"))))

;; ---- inline styling, escapes, code spans -----------------------------------

(fn test-inline-styling []
  (mada.setup {:anti_conceal false})
  (let [buf (scratch-md ["| H |"
                         "| --- |"
                         "| **b** |"
                         "| x\\|y |"
                         "| `code` |"])
        win (sized-win 40 false)]
    (render! buf win)
    (let [marks (h.marks buf)]
      (var strong false)
      (var code false)
      (each [_ m (ipairs marks)]
        (when m.opts.virt_text
          (each [_ c (ipairs m.opts.virt_text)]
            (when (and (= (. c 1) :b) (. c 2)
                       (or (= (. c 2) :MadaStrong)
                           (and (= (type (. c 2)) :table)
                                (vim.tbl_contains (. c 2) :MadaStrong))))
              (set strong true))
            (when (and (= (. c 1) :code) (. c 2)
                       (or (= (. c 2) :MadaCode)
                           (and (= (type (. c 2)) :table)
                                (vim.tbl_contains (. c 2) :MadaCode))))
              (set code true)))))
      (check strong "expected the bold cell's 'b' chunk tagged MadaStrong")
      (check code "expected the code-span cell's 'code' chunk tagged MadaCode"))
    (let [lines (reconstruct buf)]
      (check (find-substr lines :x|y)
             "escaped pipe should show unescaped as x|y"))))

;; ---- empty / missing / extra cells ------------------------------------------

(fn test-cell-counts []
  (mada.setup {:anti_conceal false})
  (let [buf (scratch-md ["| A | B |"
                         "| --- | --- |"
                         "| only |"
                         "| x | y | z |"
                         "|  | w |"])
        win (sized-win 40 false)]
    (render! buf win)
    (let [lines (reconstruct buf)]
      (check (find-substr lines "│ only │   │")
             "missing trailing cell should render empty, not drop the row")
      (check (not (find-substr lines :z))
             "an extra cell beyond the header's count should be ignored")
      (check (find-substr lines "│      │ w")
             "an empty leading cell should render blank"))))

;; ---- cursor row raw; rule/top border kept; height unchanged (nowrap) ------

(fn test-cursor-nowrap []
  (mada.setup {:anti_conceal true})
  (let [buf (scratch-md ["| A | B |" "| --- | --- |" "| a | b |" "| c | d |"])
        win (sized-win 40 false)]
    (set-cursor! buf win 1)
    (render! buf win)
    (let [lines-baseline (reconstruct buf)]
      ;; cursor away from row 2: baseline total screen-line count.
      (set-cursor! buf win 2)
      (render! buf win)
      (let [lines (reconstruct buf)]
        (check (find-substr lines "| a | b |")
               "cursor row: expected raw source shown")
        (check (find-substr lines "┌") "cursor row: top border should stay")
        (check (find-substr lines "├")
               "cursor row: the rule below it should stay")
        (check (= (length lines) (length lines-baseline))
               "cursor row: total screen-line count should not change (no height jump)")))
    (set-cursor! buf win 0)
    (render! buf win)
    (let [lines (reconstruct buf)]
      (check (find-substr lines "| A | B |")
             "cursor on header: expected raw source shown")
      (check (find-substr lines "┌")
             "cursor on header: top border should stay"))))

;; ---- wrap window: no blank screen rows inside the grid; toggling `wrap`/
;; `linebreak` re-lays out (AT-32) -------------------------------------------

(fn test-wrap-grid-no-blank-rows []
  (mada.setup {:anti_conceal true})
  (let [buf (scratch-md ["| A | B |"
                         "| --- | --- |"
                         "| a | b |"
                         "| c | d |"
                         ""
                         :after])
        win (sized-win 40 true)]
    (set-cursor! buf win 0)
    (render! buf win)
    (let [lines (reconstruct buf)]
      (check (find-substr lines "┌") "wrap: expected a top border")
      (check (find-substr lines "│ a │ b │")
             "wrap: expected the styled body row")
      ;; only the grid's own lines (top border .. bottom border) must have
      ;; no blank screen row; a blank buffer line after the table is fine.
      (var in-grid false)
      (each [_ l (ipairs lines)]
        (when (l:find "┌" 1 true) (set in-grid true))
        (when in-grid
          (check (not (l:match "^%s*$"))
                 "wrap: no blank screen row should appear inside the grid"))
        (when (l:find "└" 1 true) (set in-grid false))))
    ;; cursor on a body row: that row shows raw, no anchor/split needed.
    (set-cursor! buf win 2)
    (render! buf win)
    (let [lines (reconstruct buf)]
      (check (find-substr lines "| a | b |")
             "wrap, cursor on body row: expected raw source shown"))
    nil)
  ;; toggling `wrap`/`linebreak` re-lays out: same cached column layout,
  ;; different emitted marks (S_r/anchor columns are computed at emit time,
  ;; not cached) -- a row long enough to actually wrap under a narrow
  ;; window, so the two options actually change something to compare.
  (let [buf2 (scratch-md wide-lines)
        win2 (sized-win 30 true)]
    (set-cursor! buf2 win2 0)
    (render! buf2 win2)
    (let [ms1 (h.marks buf2)]
      (tset vim.wo win2 :linebreak true)
      (render! buf2 win2)
      (check (not (vim.deep_equal ms1 (h.marks buf2)))
             "toggling linebreak should re-lay out the grid")
      (tset vim.wo win2 :linebreak false)
      (tset vim.wo win2 :wrap false)
      (render! buf2 win2)
      (check (not (vim.deep_equal ms1 (h.marks buf2)))
             "toggling wrap should re-lay out the grid"))))

;; ---- FR-P3: incremental cursor-move update matches a full re-render -------

(fn test-wrap-incremental-cursor-matches-full []
  (mada.setup {:anti_conceal true})
  (let [buf (scratch-md ["| A | B |"
                         "| --- | --- |"
                         "| a | b |"
                         "| c | d |"
                         ""
                         :after])
        win (sized-win 40 true)]
    (set-cursor! buf win 2)
    (render! buf win)
    ;; move the real cursor without poking st.cursor first, so
    ;; events.on_cursor_moved sees a real prev -> row transition and takes
    ;; the incremental path (prev row, new row).
    (vim.api.nvim_win_set_cursor win [4 1])
    (events.on_cursor_moved buf)
    (let [incremental (h.marks buf)]
      (render! buf win)
      (h.eq incremental (h.marks buf)
            "incremental cursor update should match a full re-render"))))

;; ---- table ending the buffer: full grid, no blank rows ---------------------

(fn test-eof-full-grid []
  (mada.setup {:anti_conceal false})
  (let [buf (scratch-md ["| A | B |" "| --- | --- |" "| a | b |"])
        win (sized-win 40 true)]
    (render! buf win)
    (let [lines (reconstruct buf)]
      (check (find-substr lines "┌")
             "eof: expected a top border even with no row after the table")
      (check (find-substr lines "└") "eof: expected a bottom border")
      (each [_ l (ipairs lines)]
        (check (not (l:match "^%s*$"))
               "eof: no blank screen row should appear inside the grid")))))

;; ---- a row whose raw source wraps taller than its laid-out content is -----
;; ---- padded with blank grid lines ------------------------------------------

(fn test-wrap-pads-short-content []
  (mada.setup {:anti_conceal false})
  (let [buf (scratch-md ["| a | b | c | d | e | f | g | h | i | j |"
                         "| - | - | - | - | - | - | - | - | - | - |"
                         "| 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 0 |"])
        win (sized-win 16 true)]
    (render! buf win)
    (let [s_r (s_r_of win 2)
          overlays (row-overlays buf 2)]
      (check (> s_r 2) (: "expected the raw source row to wrap past its 2-line laid-out content (1 content + 1 rule), got S_r=%d"
                          :format s_r))
      (check (= (length overlays) s_r)
             (: "expected one overlay per screen row: S_r=%d, got %d overlays"
                :format s_r (length overlays)))
      (let [last-text (chunk-text (. overlays (length overlays) :opts
                                     :virt_text))]
        (check (last-text:find "└")
               "expected the bottom border on the row's last screen row"))
      ;; a middle screen row (padding, not the border) should be a blank
      ;; grid line: border glyphs with nothing but spaces between.
      (let [mid-text (chunk-text (. overlays 2 :opts :virt_text))]
        (check (not (mid-text:find "[1-9]"))
               "expected a blank grid line (no cell content) as padding")))))

;; ---- `linebreak` on still places one overlay per screen row ---------------

(fn test-linebreak-one-overlay-per-row []
  (mada.setup {:anti_conceal false})
  (let [buf (scratch-md wide-lines)
        win (sized-win 30 true)]
    (tset vim.wo win :linebreak true)
    (render! buf win)
    (let [s_r (s_r_of win 4)
          overlays (row-overlays buf 4)]
      (check (> s_r 1)
             "expected the long description row to wrap to more than one screen row")
      (check (= (length overlays) s_r)
             (: "linebreak: expected one overlay per screen row: S_r=%d, got %d"
                :format s_r (length overlays))))))

;; ---- table inside a block quote: prefix carries the quote glyph -----------

(fn test-blockquote-prefix []
  (mada.setup {:anti_conceal false})
  (let [buf (scratch-md ["> | A | B |" "> | --- | --- |" "> | a | b |"])
        win (sized-win 40 false)]
    (render! buf win)
    (let [lines (reconstruct buf)]
      (check (find-substr lines "│ ┌")
             "quoted table: expected the quote bar before the top border"))))

;; ---- image in a cell draws its icon once (owned filtering) ----------------

(fn test-image-once []
  (mada.setup {:anti_conceal false})
  (let [buf (scratch-md ["| A |" "| --- |" "| ![alt](x.png) |"])
        win (sized-win 40 false)]
    (render! buf win)
    (let [lines (reconstruct buf)]
      (var n 0)
      (each [_ l (ipairs lines)]
        (each [_m (l:gmatch "▣")] (set n (+ n 1))))
      (check (= n 1) (: "expected the image icon to appear exactly once, got %d"
                        :format n)))))

;; ---- ASCII glyphs -----------------------------------------------------------

(fn test-ascii []
  (mada.setup {:ascii true :anti_conceal false})
  (let [buf (scratch-md ["| A | B |" "| --- | --- |" "| a | b |"])
        win (sized-win 40 false)]
    (render! buf win)
    (let [lines (reconstruct buf)]
      (check (find-substr lines "+") "ascii: expected '+' corner/cross glyphs")
      (check (find-substr lines "|") "ascii: expected '|' vertical glyphs")
      (check (not (find-substr lines "┌")) "ascii: no unicode border glyphs")))
  (mada.setup {}))

[["AT-30: table fits a 60-col window, wraps intact, re-lays-out at 100 cols"
  test-at30-fits-and-wraps]
 ["alignment: left/center/right from the delimiter row" test-alignment]
 ["inline styling inside cells: bold, escaped pipe, code span"
  test-inline-styling]
 ["empty/missing/extra cells" test-cell-counts]
 ["cursor row raw, rule/top border kept, height unchanged (nowrap)"
  test-cursor-nowrap]
 ["AT-32: wrap window, no blank screen rows inside the grid; toggling wrap/linebreak re-lays out"
  test-wrap-grid-no-blank-rows]
 ["FR-P3: incremental cursor-move update matches a full re-render"
  test-wrap-incremental-cursor-matches-full]
 ["a table ending the buffer renders the full grid, no blank rows"
  test-eof-full-grid]
 ["a row whose source wraps taller than its laid-out content is padded with blank grid lines"
  test-wrap-pads-short-content]
 ["linebreak on still places one overlay per screen row"
  test-linebreak-one-overlay-per-row]
 ["a table in a block quote: prefix carries the quote glyph"
  test-blockquote-prefix]
 ["an image in a cell draws its icon once" test-image-once]
 ["ascii = true: ascii border glyphs" test-ascii]]
