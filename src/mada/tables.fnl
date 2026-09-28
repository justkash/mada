;; mada.tables - pipe tables (FR-R13, AT-30). `tables.style = "off"`: `|`
;; and header cells highlighted in place, no layout (unchanged from the
;; original block.fnl implementation). `tables.style = "unicode"` (default):
;; the whole table is laid out as a boxed grid drawn in virtual text, over
;; the source rows rather than in place of them: no source row is ever
;; concealed or hidden. Each source row keeps its own text and occupies its
;; natural screen rows (S_r, `nvim_win_text_height`, honours `wrap`); the
;; row's laid-out grid lines are drawn one per screen row as
;; `virt_text_win_col = 0` overlays anchored at a byte column on that screen
;; row, and any grid lines that do not fit attach below as one `virt_lines`
;; mark. See architecture §7.1's Table row and requirements FR-R13/AT-30 for
;; the full spec this module implements.

(local mark (require :mada.mark))
(local inline (require :mada.inline))
(local query (require :mada.query))
(local screen (require :mada.screen))

(local M {})

(local TEXT 100)
(local CONCEAL 120)

;; --- generic tree helpers ------------------------------------------------

(fn children_of_type [node type_name]
  (let [out []]
    (each [child (node:iter_children)]
      (when (= (child:type) type_name) (table.insert out child)))
    out))

(fn table_row_range [node]
  "(first_row last_row), inclusive, of `node`'s source span. Same rule as
block.fnl's node_rows: container nodes end at column 0 of the row after
their content."
  (let [(sr _sc er ec) (node:range)]
    (values sr (if (and (> er sr) (= ec 0)) (- er 1) er))))

(fn in_range [ctx row] (and (>= row ctx.a) (<= row ctx.b)))

;; --- tables.style = "off" -------------------------------------------------

(fn line_at [ctx row]
  (. ctx.lines (+ (- row ctx.a) 1)))

(fn table_pipes [node] (children_of_type node "|"))
(fn header_cell_nodes [node] (children_of_type node :pipe_table_cell))

(fn hl_pipes [ctx marks node]
  "tables.style = off: highlight each `|` in place, no glyph substitution."
  (each [_ p (ipairs (table_pipes node))]
    (let [(row col _er ecol) (p:range)]
      (when (line_at ctx row)
        (table.insert marks (mark.hl row col ecol :MadaTableBorder TEXT))))))

(fn header_hl [ctx marks header]
  (each [_ cell (ipairs (header_cell_nodes header))]
    (let [(row col _er ecol) (cell:range)]
      (when (line_at ctx row)
        (table.insert marks (mark.hl row col ecol :MadaTableHead TEXT))))))

(fn off_mode [ctx marks header delim rows]
  (when header (header_hl ctx marks header))
  (when header (hl_pipes ctx marks header))
  (when delim (hl_pipes ctx marks delim))
  (each [_ r (ipairs rows)] (hl_pipes ctx marks r)))

;; --- tables.style = "unicode": cells ---------------------------------------

(fn row_cell_spans [row]
  "[sc ec] spans for every cell of `row` (header/body: pipe_table_cell;
delimiter: pipe_table_delimiter_cell), walking children in source order. A
run of two `|` with nothing meaningful between them yields an empty span."
  (let [spans []]
    (var pending nil)
    (each [child (row:iter_children)]
      (let [t (child:type)]
        (if (= t "|")
            (let [(_sr sc _er ec) (child:range)]
              (when pending (table.insert spans [pending sc]))
              (set pending ec))
            (or (= t :pipe_table_cell) (= t :pipe_table_delimiter_cell))
            (let [(_sr sc _er ec) (child:range)]
              (table.insert spans [sc ec])
              (set pending nil))
            nil)))
    spans))

(fn pad_spans [spans ncols]
  "`spans` padded with `false` (missing cell: `table.insert` with a bare nil
does not grow a Lua array, silently corrupting every later index) or
truncated to `ncols`."
  (let [out []]
    (for [i 1 ncols]
      (table.insert out (or (. spans i) false)))
    out))

(fn delim_aligns [delim]
  "One of :left/:right/:center per pipe_table_delimiter_cell of `delim`, in
source order."
  (let [out []]
    (each [child (delim:iter_children)]
      (when (= (child:type) :pipe_table_delimiter_cell)
        (var left false)
        (var right false)
        (each [c (child:iter_children)]
          (when (= (c:type) :pipe_table_align_left) (set left true))
          (when (= (c:type) :pipe_table_align_right) (set right true)))
        (table.insert out (if (and left right) :center
                              right :right
                              left :left
                              :left))))
    out))

(fn pad_aligns [aligns ncols]
  (let [out []]
    (for [i 1 ncols]
      (table.insert out (or (. aligns i) :left)))
    out))

;; --- projecting a cell into styled units -----------------------------------

(fn kind_of [opts]
  (if (not= opts.conceal nil) :conceal
      (and opts.virt_text (= opts.virt_text_pos :overlay)) :overlay
      (and opts.virt_text (= opts.virt_text_pos :inline)) :inline
      opts.hl_group :hl
      nil))

(fn index_row_marks [row_marks]
  "One-time per-row projection of `row_marks` into column-indexed lookup
tables (FR-P3, item 1): inline-anchored marks and conceal/overlay starts
keyed by column for O(1) lookup -- the old `inline_marks_at`/`find_start`
rescanned every mark of the *whole row* at *every character of every
cell*. hl marks are kept sorted by start column so a cell only sweeps the
marks that can cover its own span, not the whole row's. `row_units` builds
this once per row; every one of that row's `project_cell` calls shares it."
  (let [inline_by_col {}
        conceal_by_col {}
        overlay_by_col {}
        hl []
        marker_set {}]
    (each [_ m (ipairs row_marks)]
      (let [k (kind_of m.opts)]
        (if (= k :inline)
            (do
              (let [lst (or (. inline_by_col m.col) [])]
                (table.insert lst m)
                (tset inline_by_col m.col lst))
              (tset marker_set m.col true))
            (= k :conceal)
            (do
              (when (= (. conceal_by_col m.col) nil)
                (tset conceal_by_col m.col m))
              (tset marker_set m.col true))
            (= k :overlay)
            (do
              (when (= (. overlay_by_col m.col) nil)
                (tset overlay_by_col m.col m))
              (tset marker_set m.col true))
            (= k :hl)
            (table.insert hl m)
            nil)))
    (each [_ lst (pairs inline_by_col)]
      (table.sort lst
                  (fn [a b] (< (or a.opts.priority 0) (or b.opts.priority 0)))))
    (table.sort hl (fn [a b] (< a.col b.col)))
    (let [marker_cols (icollect [col _ (pairs marker_set)] col)]
      (table.sort marker_cols)
      {: inline_by_col : conceal_by_col : overlay_by_col : hl : marker_cols})))

(fn cell_hl_marks [ridx sc ec]
  "hl marks from `ridx.hl` overlapping [sc, ec): filtered once per cell
instead of rescanned once per character (item 1)."
  (icollect [_ m (ipairs ridx.hl)]
    (when (and (< m.col ec) (> m.opts.end_col sc)) m)))

(fn active_hl_groups [hl_marks c]
  "hl_group of every `hl_marks` entry covering column `c`, ordered by
ascending priority (later groups win, matching virt_text's own [text, [g1,
g2]] semantics)."
  (let [items []]
    (each [_ m (ipairs hl_marks)]
      (when (and (<= m.col c) (< c m.opts.end_col))
        (table.insert items
                      {:group m.opts.hl_group :priority (or m.opts.priority 0)})))
    (table.sort items (fn [a b] (< a.priority b.priority)))
    (icollect [_ it (ipairs items)] it.group)))

(fn next_boundary [ridx hl_marks c ec]
  "Smallest column > `c` (capped at `ec`) where the plain run starting at
`c` must stop: a mark starting there (`ridx.marker_cols`, a sorted array
covering the whole row) or an hl mark's start/end column (`hl_marks`, this
cell's already-narrowed candidates from `cell_hl_marks`)."
  (var b ec)
  (each [_ col (ipairs ridx.marker_cols)]
    (when (and (> col c) (< col b)) (set b col)))
  (each [_ m (ipairs hl_marks)]
    (when (and (> m.col c) (< m.col b)) (set b m.col))
    (when (and (> m.opts.end_col c) (< m.opts.end_col b))
      (set b m.opts.end_col)))
  b)

(fn project_cell [ridx line sc ec]
  "Walk [sc, ec) of `line`, producing a list of {: text : groups} units as
the screen would show it (requirements FR-R13 step c): inline-anchored
virt_text first, then a conceal's replacement (or nothing, skipping to its
end_col), then an overlay's virt_text (skipping to its end_col), else a run
of plain characters sharing the same covering hl groups, grabbed with one
`string.sub` instead of one substring per character (FR-P3, item 1: the
common case -- a cell with few or no marks -- used to allocate one unit per
source byte)."
  (let [units []
        hl_marks (cell_hl_marks ridx sc ec)]
    (var c sc)
    (while (< c ec)
      (each [_ m (ipairs (or (. ridx.inline_by_col c) []))]
        (let [text (. m.opts.virt_text 1 1)
              grp (. m.opts.virt_text 1 2)]
          (when (> (length text) 0)
            (table.insert units {: text :groups (if grp [grp] [])}))))
      (let [cm (. ridx.conceal_by_col c)
            ov (. ridx.overlay_by_col c)]
        (if cm
            (do
              (when (and cm.opts.conceal (> (length cm.opts.conceal) 0))
                (table.insert units {:text cm.opts.conceal :groups []}))
              (set c (math.min ec cm.opts.end_col)))
            ov
            (do
              (let [text (. ov.opts.virt_text 1 1)
                    grp (. ov.opts.virt_text 1 2)]
                (table.insert units {: text :groups (if grp [grp] [])}))
              (set c (math.min ec ov.opts.end_col)))
            (let [hls (active_hl_groups hl_marks c)
                  b (next_boundary ridx hl_marks c ec)
                  text (line:sub (+ c 1) b)]
              (table.insert units {: text :groups hls})
              (set c b)))))
    units))

(fn is_ws [s] (not= nil (s:match "^%s+$")))

(fn trim_units [units]
  "Leading/trailing whitespace stripped from the projected cell (requirement
FR-R13 step c): a whole unit that is nothing but whitespace is dropped, and
-- since `project_cell` (item 1) now batches a run of same-group plain
characters into one unit, so a cell's padding space can share a unit with
its word instead of being its own 1-character unit -- a leading/trailing
whitespace *prefix/suffix* of the remaining edge unit's text is stripped
too, leaving any inner content untouched."
  (while (and (> (length units) 0) (is_ws (. units 1 :text)))
    (table.remove units 1))
  (when (> (length units) 0)
    (let [first (. units 1)]
      (tset first :text (first.text:gsub "^%s+" ""))))
  (while (and (> (length units) 0) (is_ws (. units (length units) :text)))
    (table.remove units))
  (when (> (length units) 0)
    (let [last (. units (length units))]
      (tset last :text (last.text:gsub "%s+$" ""))))
  units)

(fn prepend_head [units]
  (each [_ u (ipairs units)] (table.insert u.groups 1 :MadaTableHead))
  units)

(fn group_by_row [ms]
  (let [by {}]
    (each [_ m (ipairs ms)]
      (let [lst (or (. by m.row) [])]
        (table.insert lst m)
        (tset by m.row lst)))
    by))

(fn sub_line [subctx row]
  (or (. subctx.lines (+ (- row subctx.a) 1)) ""))

(fn row_units [subctx by_row row_node spans ncols header?]
  "Per-column list (length ncols) of trimmed, projected unit lists for
`row_node`, given its raw cell `spans` (already read once by the caller via
`row_cell_spans`, so a row's tree-sitter children are walked exactly once
per build, FR-P3). nil-span (missing/padded) columns get an empty list."
  (let [(row) (row_node:range)
        line (sub_line subctx row)
        spans (pad_spans spans ncols)
        ridx (index_row_marks (or (. by_row row) []))]
    (icollect [_ span (ipairs spans)]
      (if span
          (let [units (project_cell ridx line (. span 1) (. span 2))]
            (when header? (prepend_head units))
            (trim_units units))
          []))))

(fn cell_width [units]
  (accumulate [s 0 _ u (ipairs units)] (+ s (mark.width u.text))))

(fn natural_widths [header_units body_units_list ncols]
  (let [nat []]
    (for [c 1 ncols]
      (var w (cell_width (. header_units c)))
      (each [_ bu (ipairs body_units_list)]
        (set w (math.max w (cell_width (. bu c)))))
      (table.insert nat (math.max 1 w)))
    nat))

;; --- column width distribution (FR-R13 step d) ------------------------------

(fn sum_capped [natural c]
  (accumulate [s 0 _ w (ipairs natural)] (+ s (math.min w c))))

(fn distribute_widths [natural avail]
  (let [n (length natural)
        total (accumulate [s 0 _ w (ipairs natural)] (+ s w))]
    (if (<= total avail)
        (icollect [_ w (ipairs natural)] w)
        (if (> (sum_capped natural 1) avail)
            (icollect [_ _ (ipairs natural)] 1)
            (let [maxnat (accumulate [m 0 _ w (ipairs natural)] (math.max m w))]
              (var lo 1)
              (var hi maxnat)
              (var best 1)
              (while (<= lo hi)
                (let [mid (math.floor (/ (+ lo hi) 2))]
                  (if (<= (sum_capped natural mid) avail)
                      (do
                        (set best mid)
                        (set lo (+ mid 1)))
                      (set hi (- mid 1)))))
              (let [widths (icollect [_ w (ipairs natural)] (math.min w best))]
                (var used (accumulate [s 0 _ w (ipairs widths)] (+ s w)))
                (var rem (- avail used))
                (var i 1)
                (while (and (> rem 0) (<= i n))
                  (when (< (. widths i) (. natural i))
                    (tset widths i (+ (. widths i) 1))
                    (set rem (- rem 1)))
                  (set i (+ i 1)))
                widths))))))

;; --- word wrap (FR-R13 step e) ---------------------------------------------

(fn groups_equal [a b]
  (and (= (length a) (length b))
       (accumulate [ok true i g (ipairs a)]
         (and ok (= g (. b i))))))

(fn ascii_run? [s] (not (s:find "[^ -~]")))

(fn run_width [s]
  "Display width of `s`, a (possibly multi-character) run sharing one
group: printable-ASCII-only runs (the common case -- most word-wrap
tokens, item 4) are their own byte length, skipping the character loop
entirely, the same fast path `mark.width` uses; anything else falls back
to `char_width` summed per UTF-8 character (a run's width without a
per-character {ch groups w} table for every character, item 2)."
  (var w 0)
  (if (ascii_run? s)
      (length s)
      (do
        (each [ch (s:gmatch "[%z\001-\127\194-\244][\128-\191]*")]
          (set w (+ w (screen.char_width ch))))
        w)))

(fn flatten_frags [frags]
  "`frags` ({: text : groups} run fragments of one overlong word) flattened
to one entry per UTF-8 character: only `break_word` needs char
granularity, so this only ever runs on a single overlong word, not a whole
cell (FR-P3, item 2)."
  (let [out []]
    (each [_ f (ipairs frags)]
      (each [ch (f.text:gmatch "[%z\001-\127\194-\244][\128-\191]*")]
        (table.insert out {: ch :groups f.groups :w (screen.char_width ch)})))
    out))

(fn merge_chars [chars]
  (let [out []]
    (each [_ c (ipairs chars)]
      (let [last (. out (length out))]
        (if (and last (groups_equal last.groups c.groups))
            (set last.text (.. last.text c.ch))
            (table.insert out {:text c.ch :groups c.groups}))))
    out))

(fn break_word [chars width]
  "Split an overlong word's chars into width-limited char-lists."
  (let [lines []]
    (var cur [])
    (var cw 0)
    (each [_ c (ipairs chars)]
      (if (and (> (length cur) 0) (> (+ cw c.w) width))
          (do
            (table.insert lines cur)
            (set cur [c])
            (set cw c.w))
          (do
            (table.insert cur c)
            (set cw (+ cw c.w)))))
    (when (> (length cur) 0) (table.insert lines cur))
    lines))

(fn break_word_frags [frags width]
  "An overlong word's `frags` split at character boundaries (item 2: the
one path that still needs per-character work), returned as a list of
{: text : groups} fragment-lists, one per width-limited line."
  (icollect [_ pc (ipairs (break_word (flatten_frags frags) width))]
    (merge_chars pc)))

(fn merge_frags [frags]
  "Adjacent `frags` entries with equal groups merged into one {: text :
groups}: the same job the old per-character `merge_chars` did, over
already (possibly multi-character) run fragments instead of one entry per
character (item 2: no per-character tables on the common path)."
  (let [out []]
    (each [_ f (ipairs frags)]
      (let [last (. out (length out))]
        (if (and last (groups_equal last.groups f.groups))
            (set last.text (.. last.text f.text))
            (table.insert out {:text f.text :groups f.groups}))))
    out))

(fn split_ws [text]
  "`text` split into ordered {:space? bool :text piece} substrings on a
literal ASCII space: the word-wrap path only ever treats a plain \" \" as
a break (mirrors the old per-character tokenizer's own space test, not
`is_ws`'s broader `%s`, which is only for `trim_units`)."
  (let [out []
        n (length text)]
    (var i 1)
    (while (<= i n)
      (let [sp (= (text:sub i i) " ")]
        (var j i)
        (while (and (<= j n) (= (= (text:sub j j) " ") sp))
          (set j (+ j 1)))
        (table.insert out {:space? sp :text (text:sub i (- j 1))})
        (set i j)))
    out))

(fn cell_tokens [units]
  "`units` split into word/space tokens (FR-P3 word wrap, item 2): a token
is a run of same space?-ness pieces, possibly spanning several
units/groups (e.g. `**bold**plain` with no space between is one word
token with two fragments) -- the same way the old char-level tokenizer's
per-character groups did, without ever flattening to one entry per
character. A space token keeps only its first piece's groups: rendering
only ever consumes exactly one rendered space per run, matching the old
`wrap_chars`, which only ever re-inserted the first char of a space run.
Word tokens carry their fragments and total display width (`run_width`,
no per-character {ch groups w} table, item 2)."
  (let [tokens []]
    (each [_ u (ipairs units)]
      (when (> (length u.text) 0)
        (each [_ piece (ipairs (split_ws u.text))]
          (let [last (. tokens (length tokens))]
            (if (and last (= last.space? piece.space?))
                (table.insert last.frags {:text piece.text :groups u.groups})
                (table.insert tokens
                              {:space? piece.space?
                               :frags [{:text piece.text :groups u.groups}]}))))))
    (each [_ t (ipairs tokens)]
      (when (not t.space?)
        (tset t :w (accumulate [s 0 _ f (ipairs t.frags)]
                     (+ s (run_width f.text))))))
    tokens))

(fn append_frags [cur frags]
  (each [_ f (ipairs frags)] (table.insert cur f)))

(fn wrap_tokens [tokens width]
  "`tokens` (from `cell_tokens`) greedily wrapped at spaces to `width`
display columns; a word wider than `width` breaks at character boundaries
(`break_word_frags`, item 2). Returns a list of lines, each a merged {:
text : groups} fragment list. Always returns at least one (possibly
empty) line."
  (let [width (math.max 1 width)
        lines []]
    (var cur [])
    (var cw 0)
    (each [_ t (ipairs tokens)]
      (if t.space?
          (when (and (> (length cur) 0) (< cw width))
            (table.insert cur {:text " " :groups (. t.frags 1 :groups)})
            (set cw (+ cw 1)))
          (if (<= (+ cw t.w) width)
              (do
                (append_frags cur t.frags)
                (set cw (+ cw t.w)))
              (do
                (when (and (> (length cur) 0)
                           (= (. cur (length cur) :text) " "))
                  (set cw (- cw 1))
                  (table.remove cur))
                (when (> (length cur) 0)
                  (table.insert lines cur)
                  (set cur [])
                  (set cw 0))
                (if (<= t.w width)
                    (do
                      (append_frags cur t.frags)
                      (set cw t.w))
                    (let [pieces (break_word_frags t.frags width)]
                      (for [pi 1 (- (length pieces) 1)]
                        (table.insert lines (. pieces pi)))
                      (let [last (. pieces (length pieces))]
                        (set cur last)
                        (set cw
                             (accumulate [s 0 _ f (ipairs last)]
                               (+ s (run_width f.text)))))))))))
    (table.insert lines cur)
    (icollect [_ l (ipairs lines)] (merge_frags l))))

(fn wrap_cell [units width] (wrap_tokens (cell_tokens units) width))

(fn wrap_row [units_row widths]
  (icollect [c u (ipairs units_row)] (wrap_cell u (. widths c))))

(fn row_height [wrapped_cols]
  (var h 1)
  (each [_ col (ipairs wrapped_cols)]
    (set h (math.max h (length col))))
  h)

;; --- assembling grid rows and rules (FR-R13 step g) -------------------------

(fn chunk_for [text groups]
  (if (or (not groups) (= (length groups) 0)) [text]
      (= (length groups) 1) [text (. groups 1)]
      [text groups]))

(fn push_chunk [line text groups]
  (when (> (length text) 0) (table.insert line (chunk_for text groups))))

(fn pad_lines [lines height]
  (let [out (icollect [_ l (ipairs lines)] l)]
    (for [i (+ (length out) 1) height]
      (table.insert out []))
    out))

(fn pad_align [line width align]
  (let [w (accumulate [s 0 _ u (ipairs line)] (+ s (mark.width u.text)))
        pad (math.max 0 (- width w))
        out []]
    (if (= align :right)
        (do
          (when (> pad 0)
            (table.insert out {:text (string.rep " " pad) :groups []}))
          (each [_ u (ipairs line)] (table.insert out u)))
        (= align :center)
        (let [lp (math.floor (/ pad 2))
              rp (- pad lp)]
          (when (> lp 0)
            (table.insert out {:text (string.rep " " lp) :groups []}))
          (each [_ u (ipairs line)] (table.insert out u))
          (when (> rp 0)
            (table.insert out {:text (string.rep " " rp) :groups []})))
        (do
          (each [_ u (ipairs line)] (table.insert out u))
          (when (> pad 0)
            (table.insert out {:text (string.rep " " pad) :groups []}))))
    out))

(fn build_padded_cols [wrapped_cols widths aligns height]
  (let [out []]
    (for [c 1 (length wrapped_cols)]
      (let [lines (pad_lines (. wrapped_cols c) height)
            w (. widths c)
            al (. aligns c)
            padded []]
        (each [_ l (ipairs lines)] (table.insert padded (pad_align l w al)))
        (table.insert out padded)))
    out))

(fn assemble_row [cfg widths padded_cols height]
  "-> list of `height` flat virt_text chunk-lists (one full grid row line
each): blank outer edges, padded cells, and interior vertical separators."
  (let [out []
        bv cfg.tables.border.v]
    (for [k 1 height]
      (let [line []]
        (push_chunk line " " [])
        (for [c 1 (length widths)]
          (push_chunk line " " [])
          (each [_ u (ipairs (. (. padded_cols c) k))]
            (push_chunk line u.text u.groups))
          (push_chunk line " " [])
          (if (< c (length widths))
              (push_chunk line bv [:MadaTableBorder])
              (push_chunk line " " [])))
        (table.insert out line)))
    out))

(fn build_rule [cfg widths left mid right]
  (let [parts []
        n (length widths)]
    (table.insert parts left)
    (for [i 1 n]
      (table.insert parts (string.rep cfg.tables.border.h (+ (. widths i) 2)))
      (when (< i n) (table.insert parts mid)))
    (table.insert parts right)
    (table.concat parts)))

(fn rule_line [text]
  [(chunk_for text [:MadaTableBorder])])

(fn prefix_chunks [ctx prefix]
  "Chunks reproducing an enclosing block quote's visual prefix on a
synthetic virt_lines row (FR-R13 step h): `quote` glyph under each `>`,
spaces elsewhere."
  (let [chunks []]
    (for [i 1 (length prefix)]
      (let [ch (prefix:sub i i)]
        (if (= ch ">")
            (table.insert chunks (chunk_for ctx.cfg.quote [:MadaQuote]))
            (table.insert chunks
                          (chunk_for (string.rep " " (mark.width ch)) [])))))
    chunks))

(fn prefixed [pchunks line]
  "`pchunks` prepended to `line` (both flat virt_text chunk-lists). `line` is
always a table freshly built for this one call site and never reused
afterward, so when `pchunks` is empty (no enclosing block quote, the common
case) `line` is returned as-is instead of copied (FR-P3)."
  (if (= (length pchunks) 0)
      line
      (let [out []]
        (each [_ c (ipairs pchunks)] (table.insert out c))
        (each [_ c (ipairs line)] (table.insert out c))
        out)))

;; --- layout (tables.style = unicode) ---------------------------------------

(fn row_grid [cfg units widths aligns]
  "-> (lines height) for a row's already-projected `units` (one entry per
column): `lines` is a list of `height` flat virt_text chunk-lists (the
boxed rendering of one source row)."
  (let [wrapped (wrap_row units widths)
        height (row_height wrapped)
        padded (build_padded_cols wrapped widths aligns height)]
    (values (assemble_row cfg widths padded height) height)))

(fn prepare_grid [ctx subctx by_row header delim rows]
  "Everything shared by both layout paths: column widths/alignment, rule
strings and the prefix chunks, or nil when the header has no cells."
  (let [header_spans (row_cell_spans header)
        ncols (length header_spans)]
    (when (> ncols 0)
      (let [aligns (pad_aligns (delim_aligns delim) ncols)
            (hrow hcol) (header:range)
            hline (sub_line subctx hrow)
            prefix (hline:sub 1 hcol)
            prefix_w (mark.width prefix)
            avail (- ctx.width prefix_w (+ (* 3 ncols) 1))
            header_units (row_units subctx by_row header header_spans ncols
                                    true)
            body_units (icollect [_ r (ipairs rows)]
                         (row_units subctx by_row r (row_cell_spans r) ncols
                                    false))
            natural (natural_widths header_units body_units ncols)
            widths (distribute_widths natural avail)
            pchunks (prefix_chunks ctx prefix)
            header_rule (build_rule ctx.cfg widths " "
                                    ctx.cfg.tables.border.cross " ")]
        {: ncols
         : aligns
         : hrow
         : hcol
         : hline
         : widths
         : pchunks
         :header_line (rule_line header_rule)
         : header_units
         : body_units}))))

;; --- screen-row anchor columns (draw-over-source design) --------------------
;; A source row is never concealed or hidden. Each source row keeps its own
;; text and occupies its natural screen rows (S_r, `nvim_win_text_height`);
;; the laid-out grid lines for that row are drawn one per screen row, as
;; `virt_text_win_col = 0` overlays anchored at a byte column that lands on
;; that screen row (verified: virt_text_win_col draws at window column 0 of
;; whichever wrapped screen row contains the mark's anchor byte). Lines that
;; do not fit go to one `virt_lines` mark below the row. This one path
;; replaces both the old `nowrap` per-row conceal+inline path and the old
;; `wrap` conceal_lines/anchor path: with `nowrap`, S_r is always 1, so it
;; degenerates to "overlay line 1 + virt_lines below" (the old nowrap shape).
;; S_r and the anchor-column emulation live in mada.screen, shared with
;; mada.mermaid.

;; --- layout: tables.style = unicode (draw-over-source) ----------------------

(fn blank_grid_line [cfg widths]
  "One grid line of empty cells at `widths`: used to pad
a row's display lines up to its S_r screen rows."
  (let [line []
        bv cfg.tables.border.v]
    (push_chunk line " " [])
    (for [c 1 (length widths)]
      (push_chunk line (string.rep " " (+ (. widths c) 2)) [])
      (if (< c (length widths))
          (push_chunk line bv [:MadaTableBorder])
          (push_chunk line " " [])))
    line))

(fn build_grid_layout [ctx g header delim rows]
  "Everything the emit step needs, computed once per changedtick/width/cfg
(FR-P3 layout cache): the header/delimiter/body rows' already-prefixed grid
content lines and header rule (S_r/anchor columns are window- and cursor-
dependent, so they are computed fresh at emit time, not cached)."
  (let [(hrow hcol) (header:range)
        (hlines) (row_grid ctx.cfg g.header_units g.widths g.aligns)
        header_content (icollect [_ l (ipairs hlines)] (prefixed g.pchunks l))
        (drow dcol) (delim:range)
        delim_rule_line (prefixed g.pchunks g.header_line)
        blank_line (prefixed g.pchunks (blank_grid_line ctx.cfg g.widths))
        row_entries (icollect [i r (ipairs rows)]
                      (let [(rrow rcol) (r:range)
                            (rlines) (row_grid ctx.cfg (. g.body_units i)
                                               g.widths g.aligns)
                            content (icollect [_ l (ipairs rlines)]
                                      (prefixed g.pchunks l))]
                        {: rrow : rcol : content}))]
    {: hrow
     : hcol
     : header_content
     : drow
     : dcol
     : delim_rule_line
     : blank_line
     :rows row_entries}))

(fn build_d [content rule_line blank_line s_r kind]
  "The lines row `kind` displays, padded with `blank_line` up to `s_r`
lines: header -> content then blanks; delimiter -> its rule then blanks;
body -> content then blanks."
  (if (= kind :delim)
      (let [out [rule_line]]
        (for [i 2 s_r] (table.insert out blank_line))
        out)
      (let [out (icollect [_ l (ipairs content)] l)]
        (for [i (+ (length out) 1) s_r]
          (table.insert out blank_line))
        out)))

(fn cursor_tail [tail kind blank_line]
  "The cursor row's overlays are dropped (anti-conceal), so its below-lines
keep the same count as the laid-out case (no height jump when the cursor
enters/leaves) but with content replaced by blank grid lines."
  (if (= kind :delim) tail (icollect [_ _ (ipairs tail)] blank_line)))

(fn emit_table_row [ctx marks win row col kind content rule_line blank_line]
  "Overlay + virt_lines marks for one source row (FR-R13): first S_r display
lines become `virt_text_win_col = 0` overlays, one per screen row; any
remaining lines become one `virt_lines` mark below the row."
  (when (in_range ctx row)
    (let [line (line_at ctx row)]
      (when line
        (let [s_r (screen.s_r_for win row)
              d (build_d content rule_line blank_line s_r kind)
              anchors (screen.row_anchor_cols win ctx.buf line s_r ctx.width)
              cursor? (= row ctx.cursor)]
          (for [k 1 s_r]
            (let [chunks (screen.pad_chunks_to (. d k) ctx.width)]
              (table.insert marks
                            (mark.overlay_win_col row (. anchors k) chunks
                                                  CONCEAL))))
          (let [tail (let [out []]
                       (for [i (+ s_r 1) (length d)]
                         (table.insert out (. d i)))
                       out)]
            (when (> (length tail) 0)
              (let [final_tail (if cursor? (cursor_tail tail kind blank_line)
                                   tail)]
                (table.insert marks
                              (mark.virt_lines row final_tail CONCEAL false
                                               false)))))
          (when (not cursor?) (tset ctx.owned row col)))))))

(fn emit_grid [ctx marks L]
  (let [win ctx.win]
    (emit_table_row ctx marks win L.hrow L.hcol :header L.header_content nil
                    L.blank_line)
    (emit_table_row ctx marks win L.drow L.dcol :delim [] L.delim_rule_line
                    L.blank_line)
    (each [_ r (ipairs L.rows)]
      (emit_table_row ctx marks win r.rrow r.rcol :body r.content nil
                      L.blank_line))))

;; --- layout cache (FR-P3) ----------------------------------------------------
;; buf -> {: tick : width : cfg : layouts} where `layouts` maps a table's
;; first row to its build_grid_layout result (or `false` when the header has
;; no cells, i.e. prepare_grid returned nil). Dropped whole whenever
;; changedtick, ctx.width or the cfg table (compared by identity: mada.config
;; .setup always replaces it wholesale) differs from what it was built with.
;; S_r and anchor columns are window/cursor-dependent and computed fresh at
;; emit time (cheap), so the cache is not sensitive to `wrap`, `linebreak`,
;; `showbreak` or `breakindent`; toggling those still needs a fresh render
;; pass (mada.events' OptionSet autocommand), just not a fresh layout.
(local layout_cache {})

(fn get_table_cache [ctx]
  (let [buf ctx.buf
        tick (vim.api.nvim_buf_get_changedtick buf)
        cached (. layout_cache buf)]
    (if (and cached (= cached.tick tick) (= cached.width ctx.width)
             (= cached.cfg ctx.cfg))
        cached
        (let [fresh {: tick :width ctx.width :cfg ctx.cfg :layouts {}}]
          (tset layout_cache buf fresh)
          fresh))))

(fn build_layout [ctx header delim rows first last]
  (ctx.ensure_parsed first last)
  (let [subctx (ctx.sub first last)
        by_row (group_by_row (inline.collect subctx))
        g (prepare_grid ctx subctx by_row header delim rows)]
    (if (not g) false (build_grid_layout ctx g header delim rows))))

(fn M.detach [buf]
  "Release buf's layout cache (NFR-P5): layout_cache grows one entry per
buffer that ever renders a pipe table and is otherwise never cleared."
  (tset layout_cache buf nil))

(fn M.cached? [buf]
  "Whether `buf` has a layout cache entry. Exposed for tests (NFR-P5)."
  (not= (. layout_cache buf) nil))

;; --- entry point -------------------------------------------------------------

(fn M.render [ctx marks node]
  "Mark records for one pipe_table `node` (FR-R13)."
  (var header nil)
  (var delim nil)
  (let [rows []]
    (each [child (node:iter_children)]
      (let [t (child:type)]
        (if (= t :pipe_table_header) (set header child)
            (= t :pipe_table_delimiter_row) (set delim child)
            (= t :pipe_table_row) (table.insert rows child))))
    (if (= ctx.cfg.tables.style :off)
        (off_mode ctx marks header delim rows)
        (when (and header delim)
          (let [(first last) (table_row_range node)
                cache (get_table_cache ctx)
                cached_L (. cache.layouts first)
                L (if (not= cached_L nil) cached_L
                      (let [built (build_layout ctx header delim rows first
                                                last)]
                        (tset cache.layouts first built)
                        built))]
            (when L (emit_grid ctx marks L)))))))

;; --- top-level collector -----------------------------------------------------

(fn M.collect [ctx]
  "Table marks for pipe_table nodes overlapping ctx.a-1..ctx.b+1, clamped.
Marks are emitted only for rows in ctx.a..ctx.b (every table row now carries
only its own overlay/virt_lines marks, no cross-row anchor)."
  (let [marks []
        q (query.markdown)]
    (when (and q ctx.root)
      (let [total (vim.api.nvim_buf_line_count ctx.buf)
            lo (math.max 0 (- ctx.a 1))
            hi (math.min (- total 1) (+ ctx.b 1))]
        (each [id node (q:iter_captures ctx.root ctx.buf lo (+ hi 1))]
          (when (= (. q.captures id) :table) (M.render ctx marks node)))))
    marks))

M
