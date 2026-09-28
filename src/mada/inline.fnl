;; mada.inline - inline element recipes (architecture §7.1, requirements
;; FR-R3-FR-R6, FR-R14, FR-R16, FR-R18-FR-R20). M.collect walks every
;; markdown_inline tree meeting ctx.a..ctx.b, runs mada.query's
;; markdown_inline query with iter_captures restricted to ctx.a..ctx.b+1, and
;; dispatches on capture name. Unknown/child captures (delimiters, link
;; text/url pieces) are ignored: their container capture walks the node's
;; children itself, per architecture §7.2.

(local query (require :mada.query))
(local mark (require :mada.mark))

(local M {})

(local INLINE_HL 110)
(local CONCEAL 120)

;; Common named-character entities (requirements FR-R19). Others are left
;; untouched.
(local entity_codepoints {:amp 38
                          :lt 60
                          :gt 62
                          :quot 34
                          :apos 39
                          :nbsp 160
                          :copy 169
                          :reg 174
                          :trade 8482
                          :hellip 8230
                          :mdash 8212
                          :ndash 8211
                          :laquo 171
                          :raquo 187
                          :middot 183
                          :deg 176
                          :plusmn 177
                          :times 215
                          :divide 247
                          :euro 8364
                          :pound 163
                          :yen 165})

;; buf -> {: tick : labels} cache of link_reference_definition labels
;; (normalized -> true), rebuilt only when changedtick moves.
(local def_cache {})

;; buf -> {: tick : arr} index of a buffer's markdown_inline injection trees
;; (architecture §13 "index inline trees by row"), rebuilt whenever
;; changedtick moves or `M.invalidate` is called (a ranged `ltree:parse`
;; injects new trees without bumping changedtick). Filtering
;; `ltree:children().markdown_inline:trees()` by row used to walk every
;; inline tree in the document on every render, however small the range (a
;; CursorMoved re-render of one or two rows still paid for the whole
;; document); caching the array avoids repeating that walk.
(local tree_index_cache {})

(fn in_range [ctx row]
  (and (>= row ctx.a) (<= row ctx.b)))

(fn line_len [ctx row]
  (length (or (. ctx.lines (+ (- row ctx.a) 1)) "")))

(fn node_text [ctx node]
  "ctx.text when node lies fully inside ctx.a..ctx.b (the fast, required
path); vim.treesitter.get_node_text for a node outside that range (reference
definitions elsewhere in the buffer, or a link spanning into it)."
  (let [(sr _sc er _ec) (node:range)]
    (if (and (>= sr ctx.a) (<= er ctx.b))
        (ctx.text node)
        (vim.treesitter.get_node_text node ctx.buf))))

(fn split_hl [ctx marks sr sc er ec group priority]
  "hl [sr,sc)-(er,ec), one mark per row, clipped to ctx.a..ctx.b (invariant
2: every mark sits on one row)."
  (if (= sr er)
      (when (in_range ctx sr)
        (table.insert marks (mark.hl sr sc ec group priority)))
      (for [r (math.max sr ctx.a) (math.min er ctx.b)]
        (let [c0 (if (= r sr) sc 0)
              c1 (if (= r er) ec (line_len ctx r))]
          (table.insert marks (mark.hl r c0 c1 group priority))))))

(fn split_conceal [ctx marks sr sc er ec priority ?repl]
  "conceal [sr,sc)-(er,ec), one mark per row, clipped to ctx.a..ctx.b."
  (if (= sr er)
      (when (in_range ctx sr)
        (table.insert marks (mark.conceal sr sc ec priority ?repl)))
      (for [r (math.max sr ctx.a) (math.min er ctx.b)]
        (let [c0 (if (= r sr) sc 0)
              c1 (if (= r er) ec (line_len ctx r))]
          (table.insert marks (mark.conceal r c0 c1 priority ?repl))))))

(fn find_delims [node type]
  "Named children of `node` whose type is `type`, in order."
  (let [out []]
    (for [i 0 (- (node:named_child_count) 1)]
      (let [c (node:named_child i)]
        (when (= (c:type) type) (table.insert out c))))
    out))

(fn find_child [node type]
  "First named child of `node` whose type is `type`, or nil."
  (var found nil)
  (for [i 0 (- (node:named_child_count) 1)]
    (when (not found)
      (let [c (node:named_child i)]
        (when (= (c:type) type) (set found c)))))
  found)

(fn emph_depth [node]
  "Number of emphasis/strong/strike ancestors of `node`, capped at 9 so
priority 110 + depth never exceeds 119."
  (var depth 0)
  (var p (node:parent))
  (while p
    (let [t (p:type)]
      (when (or (= t :emphasis) (= t :strong_emphasis) (= t :strikethrough))
        (set depth (+ depth 1))))
    (set p (p:parent)))
  (math.min depth 9))

(fn touching? [a b]
  "True when node `b` starts exactly where node `a` ends: adjacent siblings
with no gap between them."
  (let [(_asr _asc aer aec) (a:range)
        (bsr bsc _ber _bec) (b:range)]
    (and (= aer bsr) (= aec bsc))))

(fn run_end [delims start]
  "Index of the last node of the maximal contiguous (touching) run of
`delims` starting at index `start`."
  (var i start)
  (while (and (< i (length delims)) (touching? (. delims i) (. delims (+ i 1))))
    (set i (+ i 1)))
  i)

(fn run_start [delims last]
  "Index of the first node of the maximal contiguous (touching) run of
`delims` ending at index `last`."
  (var i last)
  (while (and (> i 1) (touching? (. delims (- i 1)) (. delims i)))
    (set i (- i 1)))
  i)

(fn handle_emph [ctx marks node group]
  "Emphasis, strong emphasis and strikethrough (FR-R3): conceal the whole
leading and trailing delimiter run as one mark each, hl the content between
them at 110 + nesting depth. A multi-character delimiter (`**`, `__`, `~~`,
the outer pair of `***`) is not one node: the grammar gives each marker
character its own sibling `emphasis_delimiter` node (confirmed by dumping
the parse tree, e.g. `**bold**` is `(strong_emphasis (emphasis_delimiter)
(emphasis_delimiter) (emphasis_delimiter) (emphasis_delimiter))`, two
1-character nodes per side). Concealing only the first and last of `delims`
(the previous approach) left the *inner* marker character of each run
visible and inside the highlighted text (a real bug, caught by
test.highlighter_spec's collision guard: the runtime highlighter's own
`highlights.scm` also conceals every individual `emphasis_delimiter` node,
which happened to paper over the gap when a highlighter was active, but not
when `treesitter.highlight = false`). Grouping into contiguous runs first
covers every marker character on each side regardless of how many nodes the
grammar splits it into."
  (let [delims (find_delims node :emphasis_delimiter)]
    (when (>= (length delims) 2)
      (let [n (length delims)
            lead_end (run_end delims 1)
            trail_start (run_start delims n)
            first (. delims 1)
            lead_last (. delims lead_end)
            trail_first (. delims trail_start)
            last (. delims n)
            (fsr fsc _flr _flc) (first:range)
            (_llr _llc fer fec) (lead_last:range)
            (tsr tsc _tlr _tlc) (trail_first:range)
            (_lsr _lsc ler lec) (last:range)
            priority (+ 110 (emph_depth node))]
        (split_hl ctx marks fer fec tsr tsc group priority)
        (split_conceal ctx marks fsr fsc fer fec CONCEAL)
        (split_conceal ctx marks tsr tsc ler lec CONCEAL)))))

(fn handle_code_span [ctx marks node]
  "Code span (FR-R4): conceal both code_span_delimiter nodes (single or
multi-backtick), hl the content MadaCode."
  (let [delims (find_delims node :code_span_delimiter)]
    (when (>= (length delims) 2)
      (let [first (. delims 1)
            last (. delims (length delims))
            (fsr fsc fer fec) (first:range)
            (lsr lsc ler lec) (last:range)]
        (split_hl ctx marks fer fec lsr lsc :MadaCode INLINE_HL)
        (split_conceal ctx marks fsr fsc fer fec CONCEAL)
        (split_conceal ctx marks lsr lsc ler lec CONCEAL)))))

(fn handle_inline_link [ctx marks node]
  "Inline link (FR-R5): conceal [ and ](url \"title\") when links.conceal;
hl the link text MadaLink always; links.show_url appends \" (url)\" as
inline virtual text MadaUrl."
  (let [text (find_child node :link_text)
        dest (find_child node :link_destination)
        (sr sc er ec) (node:range)]
    (when text
      (let [(tsr tsc ter tec) (text:range)]
        (if ctx.cfg.links.conceal
            (do
              (split_conceal ctx marks sr sc tsr tsc CONCEAL)
              (split_hl ctx marks tsr tsc ter tec :MadaLink INLINE_HL)
              (split_conceal ctx marks ter tec er ec CONCEAL))
            (split_hl ctx marks tsr tsc ter tec :MadaLink INLINE_HL))
        (when (and ctx.cfg.links.show_url dest (in_range ctx er))
          (let [(dsr _dsc _der _dec) (dest:range)]
            (when (in_range ctx dsr)
              (let [url (node_text ctx dest)]
                (table.insert marks
                              (mark.inline er ec (.. " (" url ")") :MadaUrl
                                           CONCEAL))))))))))

(fn normalize_label [s]
  "CommonMark label matching: case-fold, collapse internal whitespace, trim."
  (let [lower (s:lower)
        collapsed (pick-values 1 (lower:gsub "%s+" " "))
        trimmed (pick-values 1 (collapsed:gsub "^%s+" ""))]
    (pick-values 1 (trimmed:gsub "%s+$" ""))))

(fn strip_brackets [s]
  "A link_label node's text includes its surrounding [ and ]; link_text does
not. Strip them so both sides of the definition check compare the same
thing."
  (let [s1 (pick-values 1 (s:gsub "^%[" ""))]
    (pick-values 1 (s1:gsub "%]$" ""))))

;; Compiled once: `link_reference_definition` labels, whole buffer. A
;; recursive Lua walk of the whole tree (the previous approach) cost as much
;; as the rest of a small render combined (measured ~1.7-2.8ms p95 on
;; reference.md, `bench/latency.lua`); iter_captures runs the equivalent
;; search at C speed inside tree-sitter.
(local link_def_query_src "(link_reference_definition (link_label) @label)")
(var link_def_query nil)

(fn get_link_def_query []
  (when (not link_def_query)
    (set link_def_query
         (vim.treesitter.query.parse :markdown link_def_query_src)))
  link_def_query)

(fn walk_definitions [ctx labels]
  (let [q (get_link_def_query)]
    (each [_ node (q:iter_captures ctx.root ctx.buf 0 -1)]
      (tset labels (normalize_label (strip_brackets (node_text ctx node))) true))))

(fn get_definitions [ctx]
  "Labels of every link_reference_definition in the buffer, normalized,
cached per buffer and changedtick so a render never rescans the document.
Only called when the render range actually contains a reference-style link
(the query capture that reaches `handle_ref_link` is itself restricted to
ctx.a..ctx.b): a render with no reference-style link in range never pays
this cost at all."
  (let [tick (vim.api.nvim_buf_get_changedtick ctx.buf)
        cached (. def_cache ctx.buf)]
    (if (and cached (= cached.tick tick))
        cached.labels
        (let [labels {}]
          (walk_definitions ctx labels)
          (tset def_cache ctx.buf {: tick : labels})
          labels))))

(fn ref_label_text [ctx node kind text_node]
  (if (= kind :full_reference_link)
      (let [label (find_child node :link_label)]
        (and label (strip_brackets (node_text ctx label))))
      (node_text ctx text_node)))

(fn handle_ref_link [ctx marks node]
  "Full, collapsed and shortcut reference links (FR-R5): hl the text
MadaLink and conceal brackets/label, but only when a matching
link_reference_definition exists (UR-3: only real syntax is styled)."
  (let [kind (node:type)
        text (find_child node :link_text)]
    (when text
      (let [label_txt (ref_label_text ctx node kind text)]
        (when label_txt
          (let [defs (get_definitions ctx)]
            (when (. defs (normalize_label label_txt))
              (let [(sr sc er ec) (node:range)
                    (tsr tsc ter tec) (text:range)]
                (split_conceal ctx marks sr sc tsr tsc CONCEAL)
                (split_hl ctx marks tsr tsc ter tec :MadaLink INLINE_HL)
                (split_conceal ctx marks ter tec er ec CONCEAL)))))))))

(fn handle_autolink [ctx marks node]
  "uri_autolink / email_autolink (FR-R5): conceal < and >, hl the rest
MadaUrl."
  (let [(sr sc er ec) (node:range)]
    (split_conceal ctx marks sr sc sr (+ sc 1) CONCEAL)
    (split_hl ctx marks sr (+ sc 1) er (- ec 1) :MadaUrl INLINE_HL)
    (split_conceal ctx marks er (- ec 1) er ec CONCEAL)))

(fn handle_image [ctx marks node]
  "Image (FR-R6): conceal the whole ![alt](src) span; inline image_icon ..
alt at the span's start, MadaImage. Concealing the span (rather than
overlaying it) keeps the result independent of how much of it the runtime
tree-sitter highlighter also conceals (its highlights.scm hides the image's
!, [, ], ( destination and ), which would otherwise shrink the visible span
under an overlay and spill text past it)."
  (let [alt (find_child node :image_description)
        (sr sc er ec) (node:range)]
    (split_conceal ctx marks sr sc er ec CONCEAL)
    (when (in_range ctx sr)
      (let [alt_txt (if alt (node_text ctx alt) "")
            replacement (.. ctx.cfg.image_icon alt_txt)]
        (table.insert marks (mark.inline sr sc replacement :MadaImage CONCEAL))))))

(fn handle_escape [ctx marks node]
  "Backslash escape (FR-R18): conceal the backslash."
  (let [(sr sc er ec) (node:range)]
    (split_conceal ctx marks sr sc sr (+ sc 1) CONCEAL)))

(fn decode_entity [ctx node]
  "Decoded character for an entity_reference or numeric_character_reference,
or nil when it is not a single recognised codepoint."
  (let [txt (node_text ctx node)
        body (txt:sub 2 -2)]
    (if (= (node:type) :numeric_character_reference)
        (let [hex (body:match "^#[xX](%x+)$")
              dec (body:match "^#(%d+)$")]
          (if hex (vim.fn.nr2char (tonumber hex 16))
              (if dec (vim.fn.nr2char (tonumber dec)) nil)))
        (let [cp (. entity_codepoints body)]
          (and cp (vim.fn.nr2char cp))))))

(fn handle_entity [ctx marks node]
  "Entity and numeric character references (FR-R19): conceal with the
decoded character only when it is a single character of display width 1."
  (let [decoded (decode_entity ctx node)]
    (when (and decoded (= (mark.width decoded) 1))
      (let [(sr sc er ec) (node:range)]
        (split_conceal ctx marks sr sc er ec CONCEAL decoded)))))

(fn handle_hardbreak [ctx marks node]
  "Hard line break (FR-R20): conceal the backslash only for a backslash
break; trailing-space breaks are left alone (already invisible)."
  (let [txt (node_text ctx node)]
    (when (= (txt:sub 1 1) "\\")
      (let [(sr sc er ec) (node:range)]
        (split_conceal ctx marks sr sc sr (+ sc 1) CONCEAL)))))

(fn handle_html [ctx marks node]
  "Inline html_tag (FR-R14): hl MadaComment only when it is an HTML comment;
other tags are untouched."
  (let [txt (node_text ctx node)]
    (when (= (txt:sub 1 4) "<!--")
      (let [(sr sc er ec) (node:range)]
        (split_hl ctx marks sr sc er ec :MadaComment INLINE_HL)))))

(local handlers {:emph (fn [ctx marks node]
                         (handle_emph ctx marks node :MadaEmph))
                 :strong (fn [ctx marks node]
                           (handle_emph ctx marks node :MadaStrong))
                 :strike (fn [ctx marks node]
                           (handle_emph ctx marks node :MadaStrike))
                 :code.span handle_code_span
                 :link handle_inline_link
                 :link.ref handle_ref_link
                 :image handle_image
                 :autolink handle_autolink
                 :escape handle_escape
                 :entity handle_entity
                 :hardbreak handle_hardbreak
                 :html handle_html})

(fn build_tree_index [itree]
  "{: sr : er : tree} array for every tree in `itree` (one entry per
markdown_inline injection). Walks `itree:trees()` with `pairs`, not
`ipairs`: in Neovim 0.12, once more than one ranged `ltree:parse` has run,
`trees()` is a sparse table (later injections land at non-contiguous
indices), and `ipairs` silently stops at the first gap. Order is not
guaranteed and does not matter: `trees_in_range` filters this array
linearly and every tree's captures are dispatched independently."
  (let [arr []]
    (each [_ tree (pairs (itree:trees))]
      (let [root (tree:root)
            (sr _sc er _ec) (root:range)]
        (table.insert arr {: sr : er : tree})))
    arr))

(fn get_tree_index [ctx itree]
  "arr from `build_tree_index`, cached per buffer and changedtick (and
dropped early by `M.invalidate` when a ranged parse injects new trees
without moving changedtick): a render never re-walks `itree:trees()` (each
call re-fetches every injection's range) more than once per edit. Filtering
it is a linear scan (below), not a sorted/binary-searched index: measured on
a 20,000-line document (9173 inline trees), building a sorted index cost
~4.5-4.8ms per edit (every changedtick misses the cache) against ~2.5ms for
the same array unsorted, while a linear scan of the *cached* array costs
~0.03ms regardless of range width -- negligible next to the array-build cost
it shares with the sorted version. The previous linear approach with no
cache at all cost ~1.6ms on every call including CursorMoved (which calls
this twice, prev and new row), well over NFR-P3; caching without sorting
keeps CursorMoved cheap without paying the sort on every edit."
  (let [tick (vim.api.nvim_buf_get_changedtick ctx.buf)
        cached (. tree_index_cache ctx.buf)]
    (if (and cached (= cached.tick tick))
        cached.arr
        (let [arr (build_tree_index itree)]
          (tset tree_index_cache ctx.buf {: tick : arr})
          arr))))

(fn trees_in_range [arr a b]
  "Trees of `arr` overlapping [a, b], in order: a linear scan of the cached
array (see `get_tree_index`)."
  (let [out []]
    (each [_ e (ipairs arr)]
      (when (and (>= e.er a) (<= e.sr b)) (table.insert out e.tree)))
    out))

(fn M.invalidate [buf]
  "Drop only buf's tree_index_cache entry, not def_cache: called after a
ranged `ltree:parse` injects new markdown_inline trees, which does not bump
changedtick, so `get_tree_index`'s tick-keyed cache would otherwise keep
serving a stale array that misses the newly parsed trees."
  (tset tree_index_cache buf nil))

(fn M.detach [buf]
  "Release buf's per-buffer caches (NFR-P5): def_cache and tree_index_cache
grow one entry per buffer that ever renders and are otherwise never
cleared."
  (tset def_cache buf nil)
  (tset tree_index_cache buf nil))

(fn M.cached? [buf]
  "(def-cached? tree-cached?) for `buf`. Exposed for tests (NFR-P5)."
  (values (not= (. def_cache buf) nil) (not= (. tree_index_cache buf) nil)))

(fn M.collect [ctx]
  "Inline-level marks for rows ctx.a..ctx.b (architecture §5, §7.2)."
  (let [marks []
        q (query.markdown_inline)]
    (when q
      (let [children (ctx.ltree:children)
            itree (. children :markdown_inline)]
        (when itree
          (let [seen {}
                arr (get_tree_index ctx itree)
                trees (trees_in_range arr ctx.a ctx.b)]
            (each [_ tree (ipairs trees)]
              (each [id node (q:iter_captures (tree:root) ctx.buf ctx.a
                                              (+ ctx.b 1))]
                (let [name (. q.captures id)
                      handler (. handlers name)]
                  (when handler
                    (let [key (.. name "\000" (node:id))]
                      (when (not (. seen key))
                        (tset seen key true)
                        (handler ctx marks node)))))))))))
    marks))

M
