;; mada.query - query strings (requirements §7.2), compiled once per setup.
;; Node names confirmed against the grammars bundled with Neovim 0.12.5
;; (OQ-3): unchanged from architecture §7.2.

(local log (require :mada.log))

(local M {})

(local markdown_src "
(atx_heading (atx_h1_marker) @h1.marker) @h1
(atx_heading (atx_h2_marker) @h2.marker) @h2
(atx_heading (atx_h3_marker) @h3.marker) @h3
(atx_heading (atx_h4_marker) @h4.marker) @h4
(atx_heading (atx_h5_marker) @h5.marker) @h5
(atx_heading (atx_h6_marker) @h6.marker) @h6
(setext_heading (setext_h1_underline) @setext.underline) @setext.h1
(setext_heading (setext_h2_underline) @setext.underline) @setext.h2
(list_item [(list_marker_minus) (list_marker_plus) (list_marker_star)] @bullet)
(list_item [(list_marker_dot) (list_marker_parenthesis)] @ordered)
(list_item (task_list_marker_unchecked) @task.todo)
(list_item (task_list_marker_checked) @task.done) @task.done.item
(block_quote (block_quote_marker) @quote.marker) @quote
(fenced_code_block
  (fenced_code_block_delimiter) @code.fence
  (info_string (language) @code.lang)?
  (code_fence_content)? @code.body) @code.block
(indented_code_block) @code.indented
(thematic_break) @rule
(pipe_table (pipe_table_header) @table.header) @table
(pipe_table (pipe_table_delimiter_row) @table.delim)
(pipe_table (pipe_table_row) @table.row)
(html_block) @html
(minus_metadata) @metadata
(plus_metadata) @metadata
")

(local markdown_inline_src "
(emphasis (emphasis_delimiter) @emph.delim) @emph
(strong_emphasis (emphasis_delimiter) @strong.delim) @strong
(strikethrough (emphasis_delimiter) @strike.delim) @strike
(code_span (code_span_delimiter) @code.delim) @code.span
(inline_link) @link
(image) @image
(full_reference_link (link_text) @link.text) @link.ref
(collapsed_reference_link (link_text) @link.text) @link.ref
(shortcut_link (link_text) @link.text) @link.ref
(uri_autolink) @autolink
(email_autolink) @autolink
(backslash_escape) @escape
(entity_reference) @entity
(numeric_character_reference) @entity
(hard_line_break) @hardbreak
(html_tag) @html
")

(fn split_patterns [src]
  "Split a query string into its top-level parenthesized patterns."
  (let [pats []
        n (length src)]
    (var depth 0)
    (var start nil)
    (for [i 1 n]
      (let [c (src:sub i i)]
        (when (and (= c "(") (= depth 0))
          (set start i))
        (when (= c "(")
          (set depth (+ depth 1)))
        (when (= c ")")
          (set depth (- depth 1))
          (when (and (= depth 0) start)
            (table.insert pats (src:sub start i))
            (set start nil)))))
    pats))

(fn compile [lang src cfg]
  "Compile `src` for `lang`. If the whole string fails (a grammar renamed a
node), drop the patterns that fail on their own and compile the rest,
logging dropped patterns at debug (NFR-C1)."
  (let [(ok q) (pcall vim.treesitter.query.parse lang src)]
    (if ok
        q
        (let [good []]
          (each [_ pat (ipairs (split_patterns src))]
            (let [(ok2 _) (pcall vim.treesitter.query.parse lang pat)]
              (if ok2
                  (table.insert good pat)
                  (log.debug cfg "query: dropping %s pattern: %s" lang pat))))
          (if (> (length good) 0)
              (vim.treesitter.query.parse lang (table.concat good "\n"))
              nil)))))

(var markdown nil)
(var markdown_inline nil)
(var compiled false)

(fn M.setup [cfg]
  "Compile both queries once per session, storing them for
`M.markdown`/`M.markdown_inline`. A no-op on every call after the first:
nothing in the queries depends on config, so recompiling on a later
`setup()` call (FR-C2) would only repeat the same work. `cfg` from the
first call (whichever of `M.setup`/`M.markdown`/`M.markdown_inline` runs
first) is what per-pattern fallback logging sees (`cfg.debug`, NFR-C1)."
  (when (not compiled)
    (set compiled true)
    (set markdown (compile :markdown markdown_src cfg))
    (set markdown_inline (compile :markdown_inline markdown_inline_src cfg)))
  nil)

(fn M.markdown []
  "The compiled markdown-language query. Compiles with no config on first
use if `M.setup` was never called (FR-C6: zero configuration)."
  (when (not markdown)
    (M.setup nil))
  markdown)

(fn M.markdown_inline []
  "The compiled markdown_inline-language query. Same lazy fallback as
`M.markdown`."
  (when (not markdown_inline)
    (M.setup nil))
  markdown_inline)

M
