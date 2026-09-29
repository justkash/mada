;; mada.block - block element recipes (architecture §7.1). Iterates
;; mada.query's markdown query, dispatches on capture name, appends mark
;; records built with mada.mark. `M.mermaid_block?` and `M.fenced_code` are
;; also the seam mada.mermaid (M1) calls into: M.collect skips Mermaid
;; blocks entirely so mermaid.collect owns their rows.

(local query (require :mada.query))
(local mark (require :mada.mark))

(local M {})

(local BG 90)
(local TEXT 100)
(local CONCEAL 120)

(local h-groups {:h1 :MadaH1
                 :h2 :MadaH2
                 :h3 :MadaH3
                 :h4 :MadaH4
                 :h5 :MadaH5
                 :h6 :MadaH6})

(local h-levels {:h1 1 :h2 2 :h3 3 :h4 4 :h5 5 :h6 6})
(local setext-levels {:setext.h1 1 :setext.h2 2})

;; --- generic tree/row helpers -----------------------------------------

(fn line_at [ctx row]
  "Buffer line text for `row`, or nil when `row` is outside ctx.lines (the
current render range)."
  (. ctx.lines (+ (- row ctx.a) 1)))

(fn node_rows [node]
  "(first_row last_row), inclusive, of `node`'s source span. Container block
nodes end at column 0 of the row after their content; leaf/inline nodes end
on their own last row with a real column. Handles both."
  (let [(sr _sc er ec) (node:range)]
    (values sr (if (and (> er sr) (= ec 0)) (- er 1) er))))

(fn children_of_type [node type_name]
  "Direct children of `node` (named or anonymous) whose `:type()` is
`type_name`, in order."
  (let [out []]
    (each [child (node:iter_children)]
      (when (= (child:type) type_name) (table.insert out child)))
    out))

(fn find_child [node type_name]
  "First direct child of `node` whose `:type()` is `type_name`, or nil."
  (var found nil)
  (each [child (node:iter_children)]
    (when (and (not found) (= (child:type) type_name))
      (set found child)))
  found)

(fn buffer_line [ctx row]
  "One buffer line, read directly (not via ctx.lines): for text that must be
correct regardless of ctx.a..ctx.b, such as a fence's info string, which can
live outside the row range a single-row render covers."
  (or (. (vim.api.nvim_buf_get_lines ctx.buf row (+ row 1) false) 1) ""))

;; --- ATX headings (M0) --------------------------------------------------

(fn closing_hashes [line start_col]
  "Byte column where a trailing ` ##` closing sequence starts within `line`,
counted from `start_col` (0-based), or nil if there is none."
  (let [rest (line:sub (+ start_col 1))
        (s _e) (rest:find "%s+#+%s*$")]
    (and s (+ start_col s -1))))

(fn heading [ctx marks name heading_node]
  (let [row (heading_node:range)
        line (or (. ctx.lines (+ (- row ctx.a) 1)) "")
        marker (heading_node:named_child 0)
        text_node (heading_node:named_child 1)
        (msr msc _mer mec) (marker:range)
        (_tsr tsc _ter _tec) (if text_node (text_node:range)
                                 (values row mec row mec))
        close_col (closing_hashes line tsc)
        content_end (or close_col (length line))]
    (if ctx.cfg.headings.conceal_markers
        (table.insert marks (mark.conceal row msc mec CONCEAL))
        (table.insert marks (mark.hl row msc mec :MadaHeadingMarker TEXT)))
    (table.insert marks (mark.hl row tsc content_end (. h-groups name) TEXT))
    (when close_col
      (table.insert marks (mark.conceal row close_col (length line) CONCEAL)))))

;; --- setext headings (FR-R2) --------------------------------------------

(fn setext [ctx marks name node]
  (let [level (. setext-levels name)
        text_node (find_child node :paragraph)
        underline_type (if (= level 1) :setext_h1_underline
                           :setext_h2_underline)
        underline (find_child node underline_type)
        text_group (if (= level 1) :MadaH1 :MadaH2)]
    (when text_node
      (let [(first last) (node_rows text_node)]
        (for [r (math.max first ctx.a) (math.min last ctx.b)]
          (let [line (line_at ctx r)]
            (when line
              (table.insert marks (mark.hl r 0 (length line) text_group TEXT)))))))
    (when underline
      (let [(urow ucol _uer uec) (underline:range)]
        (when (line_at ctx urow)
          (let [utext (ctx.text underline)
                replacement (string.rep ctx.cfg.rule ctx.width)]
            (each [_ m (ipairs (mark.overlay_fit urow ucol uec utext
                                                 replacement :MadaHeadingMarker
                                                 CONCEAL))]
              (table.insert marks m))))))))

;; --- lists: bullets, ordered markers, tasks (FR-R7, FR-R8) --------------

(fn list_level [node]
  "1-based nesting level: the number of `list` ancestors of `node`."
  (var n 0)
  (var cur (node:parent))
  (while cur
    (when (= (cur:type) :list) (set n (+ n 1)))
    (set cur (cur:parent)))
  n)

(fn task_item_marker [node]
  "`node`'s parent list_item's task_list_marker_unchecked/checked child, or
nil when `node`'s item is not a task item."
  (let [item (node:parent)]
    (and item (or (find_child item :task_list_marker_unchecked)
                  (find_child item :task_list_marker_checked)))))

(fn bullet [ctx marks node]
  (let [(row col _er ecol) (node:range)]
    (when (line_at ctx row)
      (if (task_item_marker node)
          ;; FR-R7/FR-R8: a task item's checkbox takes the bullet's place, so
          ;; conceal the whole marker (bullet + trailing spaces) instead of
          ;; overlaying a glyph over it.
          (table.insert marks (mark.conceal row col ecol CONCEAL))
          (let [level (list_level node)
                bullets ctx.cfg.bullets
                n (length bullets)
                glyph (. bullets (+ (% (- level 1) n) 1))
                line (line_at ctx row)
                mchar (line:sub (+ col 1) (+ col 1))]
            (each [_ m (ipairs (mark.overlay_fit row col (+ col 1) mchar glyph
                                                 :MadaBullet CONCEAL))]
              (table.insert marks m)))))))

(fn ordered [ctx marks node]
  (let [(row col _er ecol) (node:range)]
    (when (line_at ctx row)
      (table.insert marks (mark.hl row col ecol :MadaBullet TEXT)))))

(fn task [ctx marks node done]
  (let [(row col _er ecol) (node:range)]
    (when (line_at ctx row)
      (let [line (line_at ctx row)
            span (line:sub (+ col 1) ecol)
            glyph (if done ctx.cfg.checkbox.done ctx.cfg.checkbox.todo)
            group (if done :MadaTaskDone :MadaTaskTodo)]
        (each [_ m (ipairs (mark.overlay_fit row col ecol span glyph group
                                             CONCEAL))]
          (table.insert marks m))))))

(fn task_done_item [ctx marks node]
  "`node` is the list_item of a checked task (the query captures it directly
as `@task.done.item`, so this reaches only items overlapping ctx.a..ctx.b:
no whole-tree walk, invariant 2 handled per row instead): `hl
MadaTaskDoneText` on every row of its own paragraph (not a nested block's)
that falls in ctx.a..ctx.b."
  (let [para (find_child node :paragraph)]
    (when para
      (let [(first last) (node_rows para)]
        (for [r (math.max first ctx.a) (math.min last ctx.b)]
          (let [pline (line_at ctx r)]
            (when pline
              (table.insert marks
                            (mark.hl r 0 (length pline) :MadaTaskDoneText TEXT)))))))))

;; --- block quotes (FR-R9) ------------------------------------------------

(fn find_gt_positions [text]
  "0-based byte columns of every '>' in `text`."
  (let [out []
        n (length text)]
    (for [i 1 n]
      (when (= (text:sub i i) ">") (table.insert out (- i 1))))
    out))

(fn top_level_quote? [node]
  (let [p (node:parent)]
    (or (= p nil) (not= (p:type) :block_quote))))

(fn walk_quote [ctx node marks rows]
  "Recurse `node`'s subtree; every `block_quote_marker`/`block_continuation`
row whose text contains '>' gets one overlay per '>' and updates `rows`
(row -> prefix end column, the max end column of any such node on that row)."
  (let [t (node:type)]
    (when (or (= t :block_quote_marker) (= t :block_continuation))
      (let [(row col er ec) (node:range)]
        (when (and (= row er) (>= row ctx.a) (<= row ctx.b))
          (let [text (ctx.text node)]
            (when (text:find ">")
              (each [_ gcol (ipairs (find_gt_positions text))]
                (table.insert marks
                              (mark.overlay row (+ col gcol) (+ col gcol 1)
                                            ctx.cfg.quote :MadaQuote CONCEAL)))
              (tset rows row (math.max (or (. rows row) 0) ec)))))))
    (each [child (node:iter_children)] (walk_quote ctx child marks rows))))

(fn block_quote [ctx marks node]
  (when (top_level_quote? node)
    (let [rows {}]
      (walk_quote ctx node marks rows)
      (each [row prefix_end (pairs rows)]
        (let [line (line_at ctx row)]
          (when (and line (< prefix_end (length line)))
            (table.insert marks
                          (mark.hl row prefix_end (length line) :MadaQuoteText
                                   TEXT))))))))

;; --- fenced code / Mermaid seam (FR-R10, FR-D1) -------------------------

(fn language_text [ctx node]
  "The fenced_code_block's info-string language token (the grammar already
isolates it to before whitespace or `{`), or nil. Reads its own row directly:
a fence's info string can live outside ctx.a..ctx.b when a content row deep
in the block is rendered alone (anti-conceal, invariant 2 per-row renders)."
  (let [info (find_child node :info_string)
        lang (and info (find_child info :language))]
    (when lang
      (let [(row col _er ec) (lang:range)
            line (buffer_line ctx row)]
        (line:sub (+ col 1) ec)))))

(fn M.mermaid_block? [ctx node]
  "True when `node` (a fenced_code_block) is a Mermaid block: its info
string's first token equals `mermaid`, case-insensitively (FR-D1)."
  (and (= (node:type) :fenced_code_block)
       (let [lang (language_text ctx node)]
         (and lang (= (lang:lower) :mermaid)))))

(fn code_row [marks row col]
  "Band a code row and inset its content by one cell. Keep container
prefixes before `col` in place, and let anti-conceal drop the inline mark."
  (table.insert marks (mark.line_hl row :MadaCodeBlock BG))
  (table.insert marks (mark.inline row col " " :MadaCodeBlock TEXT)))

(fn code_padding [ctx marks first last ?top ?bottom]
  "A shaded screen row above and below the block's content when its fences
do not already provide those rows."
  (when (<= first last)
    (let [blank [[[(string.rep " " ctx.width) :MadaCodeBlock]]]]
      (when (and ?top (line_at ctx first))
        (table.insert marks (mark.virt_lines first blank BG true)))
      (when (and ?bottom (line_at ctx last))
        (table.insert marks (mark.virt_lines last blank BG))))))

(fn code_fence_row [ctx marks row col]
  "Use a fence's own source row for vertical padding. Conceal the fence and
info string while leaving quote/list container prefixes in place."
  (let [line (line_at ctx row)]
    (when line
      (table.insert marks (mark.line_hl row :MadaCodeBlock BG))
      (when (< col (length line))
        (table.insert marks (mark.conceal row col (length line) CONCEAL))))))

(fn quote_depth [node]
  "Number of quote containers around a code block. A literal `>` in code
content must not be mistaken for another quote prefix."
  (var depth 0)
  (var parent (node:parent))
  (while parent
    (when (= (parent:type) :block_quote) (set depth (+ depth 1)))
    (set parent (parent:parent)))
  depth)

(fn code_space? [line col]
  (let [ch (line:sub (+ col 1) (+ col 1))]
    (or (= ch " ") (= ch "\t"))))

(fn code_prefix_col [line maxcol depth]
  "End of this row's quote/list prefix. Quote markers can omit the space
present on the opening fence, so matching its bytes is insufficient."
  (var col 0)
  (var valid true)
  (for [_ 1 depth]
    (when valid
      (while (and (< col (length line)) (code_space? line col))
        (set col (+ col 1)))
      (if (= (line:sub (+ col 1) (+ col 1)) ">")
          (do
            (set col (+ col 1))
            (when (code_space? line col)
              (set col (+ col 1))))
          (set valid false))))
  (if (not valid)
      0
      (do
        (while (and (< col maxcol) (code_space? line col))
          (set col (+ col 1)))
        col)))

(fn M.fenced_code [ctx node]
  "Mark records for a fenced code block (FR-R10): fence rows become shaded
padding when `code.hide_fences`; `line_hl MadaCodeBlock` on content rows; with
`code.show_language`, the language right-aligned on the first content row.
Returns a list."
  (let [marks []
        delims (children_of_type node :fenced_code_block_delimiter)
        open (. delims 1)]
    (if (not open)
        marks
        (let [(open_row open_col) (open:range)
              depth (quote_depth node)
              close (. delims 2)
              terminated (not= close nil)
              (_first last) (node_rows node)
              (close_row) (if terminated (close:range) nil)
              content_start (+ open_row 1)
              content_end (if terminated (- close_row 1) last)]
          (when ctx.cfg.code.hide_fences
            (code_fence_row ctx marks open_row open_col)
            (when terminated
              (let [(_close_row close_col) (close:range)]
                (code_fence_row ctx marks close_row close_col))))
          (for [r (math.max content_start ctx.a) (math.min content_end ctx.b)]
            (let [line (line_at ctx r)]
              (when line
                (code_row marks r (code_prefix_col line open_col depth)))))
          (code_padding ctx marks content_start content_end
                        (not ctx.cfg.code.hide_fences)
                        (or (not ctx.cfg.code.hide_fences) (not terminated)))
          (when (and ctx.cfg.code.show_language (<= content_start content_end)
                     (line_at ctx content_start))
            (let [lang (language_text ctx node)]
              (when (and lang (> (length lang) 0))
                (table.insert marks
                              (mark.right_align content_start (.. lang " ")
                                                :MadaCodeLang TEXT)))))
          marks))))

(fn fenced_code_dispatch [ctx marks node]
  "M.collect's own use of M.fenced_code: skip Mermaid blocks entirely
(mermaid.collect owns their rows)."
  (when (not (M.mermaid_block? ctx node))
    (each [_ m (ipairs (M.fenced_code ctx node))]
      (table.insert marks m))))

;; --- indented code (FR-R11) ----------------------------------------------

(fn indented_code [ctx marks node]
  (let [(first col) (node:range)
        (_ last) (node_rows node)
        depth (quote_depth node)]
    (for [r (math.max first ctx.a) (math.min last ctx.b)]
      (let [line (line_at ctx r)]
        (when line
          (code_row marks r (code_prefix_col line col depth)))))
    (code_padding ctx marks first last true true)))

;; --- thematic break (FR-R12) ----------------------------------------------

(fn thematic_break [ctx marks node]
  (let [(row col) (node:range)]
    (when (line_at ctx row)
      (let [line (line_at ctx row)
            ecol (length line)
            span (line:sub (+ col 1) ecol)
            replacement (string.rep ctx.cfg.rule ctx.width)]
        (each [_ m (ipairs (mark.overlay_fit row col ecol span replacement
                                             :MadaRule CONCEAL))]
          (table.insert marks m))))))

;; --- pipe tables (FR-R13) -- mada.tables is its own top-level collector
;; (mada.render calls tables.collect directly, mirroring mermaid.collect):
;; the `wrap`-mode anchor row can lie past ctx.b, so M.collect's own
;; ctx.a..ctx.b+1 capture range is too narrow (invariant 2).

;; --- HTML comments (FR-R14) ------------------------------------------------

(fn starts_with_comment? [ctx node]
  "True if `node` (an html_block) begins with `<!--`. Reads its own start
row directly: the row can lie outside ctx.a..ctx.b when a later row of a
multi-row comment is rendered alone."
  (let [(row col) (node:range)
        line (buffer_line ctx row)
        rest (line:sub (+ col 1))]
    (= (rest:sub 1 4) "<!--")))

(fn html_comment [ctx marks node]
  (when (starts_with_comment? ctx node)
    (let [(first last) (node_rows node)]
      (for [r (math.max first ctx.a) (math.min last ctx.b)]
        (let [line (line_at ctx r)]
          (when line
            (table.insert marks (mark.hl r 0 (length line) :MadaComment TEXT))))))))

;; --- front matter (FR-R15) --------------------------------------------------

(fn front_matter [ctx marks node]
  (let [(first last) (node_rows node)]
    (for [r (math.max first ctx.a) (math.min last ctx.b)]
      (when (line_at ctx r)
        (table.insert marks (mark.line_hl r :MadaComment BG))))))

;; --- collect ----------------------------------------------------------------

(fn M.collect [ctx]
  "Block-level marks for rows ctx.a..ctx.b."
  (let [marks []
        q (query.markdown)]
    (when q
      (each [id node (q:iter_captures ctx.root ctx.buf ctx.a (+ ctx.b 1))]
        (let [name (. q.captures id)]
          (if (. h-levels name) (heading ctx marks name node)
              (. setext-levels name) (setext ctx marks name node)
              (= name :bullet) (bullet ctx marks node)
              (= name :ordered) (ordered ctx marks node)
              (= name :task.todo) (task ctx marks node false)
              (= name :task.done) (task ctx marks node true)
              (= name :task.done.item) (task_done_item ctx marks node)
              (= name :quote) (block_quote ctx marks node)
              (= name :code.block) (fenced_code_dispatch ctx marks node)
              (= name :code.indented) (indented_code ctx marks node)
              (= name :rule) (thematic_break ctx marks node)
              (= name :html) (html_comment ctx marks node)
              (= name :metadata) (front_matter ctx marks node)))))
    marks))

M
