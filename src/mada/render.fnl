;; mada.render - render(buf, win, a, b), ctx, apply.
;;
;; Collector contract: `render` calls `block.collect(ctx)`, `tables.collect
;; (ctx)`, `inline.collect(ctx)` and `mermaid.collect(ctx)` (in that order)
;; and concatenates their results. Each must return a plain list of mark
;; records; `mermaid.collect` may also spawn a termaid job as a side effect
;; (FR-D6); `tables.collect` searches ctx.a-1..ctx.b+2 like
;; `mermaid.collect`, since a table's `wrap`-mode anchor row can lie just
;; past ctx.b (FR-R13). `ctx` is:
;;
;;   {: buf : win : a : b : cfg : lines : width : cursor : root : ltree : text
;;    : ensure_parsed : sub : owned}
;;
;;   buf, win       the buffer and the window that triggered the render
;;   a, b           inclusive 0-based row range being rendered
;;   cfg            the buffer's resolved config (state[buf].cfg)
;;   lines          buffer lines a..b (nvim_buf_get_lines buf a (b+1) false),
;;                  1-indexed from row a
;;   width          usable text width of win (nvim_win_get_width - textoff)
;;   cursor         0-based cursor row in win if win is the current window and
;;                  cfg.anti_conceal, else -1 (never matches a mark's row)
;;   root           root node of the buffer's markdown parse tree
;;   ltree          the buffer's LanguageTree (vim.treesitter.get_parser)
;;   text           (ctx.text node) slices node's source text out of
;;                  ctx.lines; never use vim.treesitter's get_node_text
;;                  (architecture §5)
;;   ensure_parsed  (ctx.ensure_parsed r0 r1) makes sure injections (inline
;;                  trees) for rows r0..r1 outside a..b are parsed, for a
;;                  recipe that needs rows beyond its own range (e.g. a table
;;                  extending past a..b). A cheap no-op when already valid,
;;                  so it never actually calls the parser in steady state
;;                  (FR-AC2).
;;   sub            (ctx.sub r0 r1) returns a fresh ctx for rows r0..r1: same
;;                  buf/win/cfg/width/root/ltree/ensure_parsed/sub, :a r0
;;                  :b r1, lines/text over those rows, cursor -1, a fresh
;;                  owned {}. Used to run inline.collect (etc.) over rows
;;                  extending beyond a..b, e.g. a whole table.
;;   owned          row -> byte col map. A block recipe sets
;;                  (tset ctx.owned row col) for a row whose content from
;;                  col on it draws itself as virtual text; render then
;;                  drops every mark inline.collect produced whose row is
;;                  owned and whose col >= that column (block and mermaid
;;                  marks are never filtered this way).
;;
;; Mark record: {: row : col : opts : shifting}. row/col are 0-based buffer
;; positions; opts is passed to nvim_buf_set_extmark; shifting is true for
;; marks that change the column mapping on their row (conceal, overlay,
;; inline, conceal_line) so render can drop them from the cursor row under
;; anti-conceal. Build records with `mada.mark`'s constructors.

(local state (require :mada.state))
(local block (require :mada.block))
(local tables (require :mada.tables))
(local inline (require :mada.inline))
(local mermaid (require :mada.mermaid))
(local log (require :mada.log))

(local M {})
(local stats {:renders 0 :parses 0})

(fn M.stats []
  "A copy of the render counters, for tests."
  {:renders stats.renders :parses stats.parses})

(fn M.reset_stats []
  "Zero the render counters (tests only)."
  (set stats.renders 0)
  (set stats.parses 0))

(fn text_width [win]
  (let [w (vim.api.nvim_win_get_width win)
        info (vim.fn.getwininfo win)
        row (and info (. info 1))
        textoff (if row row.textoff 0)]
    (- w textoff)))

(fn slice [lines a node]
  (let [(sr sc er ec) (node:range)]
    (if (= sr er)
        (let [line (or (. lines (+ (- sr a) 1)) "")]
          (line:sub (+ sc 1) ec))
        (let [parts []]
          (for [r sr er]
            (let [line (or (. lines (+ (- r a) 1)) "")
                  s (if (= r sr) sc 0)
                  e (if (= r er) ec (length line))]
              (table.insert parts (line:sub (+ s 1) e))))
          (table.concat parts "\n")))))

(fn append [dst src]
  (each [_ m (ipairs src)] (table.insert dst m)))

(fn has_rendered_listener? []
  "Whether a `User MadaRendered` autocommand is registered (FR-A3): renders
happen far more often than anyone listens for them, so `nvim_exec_autocmds`
(match + dispatch) is worth skipping when nothing would run."
  (> (length (vim.api.nvim_get_autocmds {:event :User :pattern :MadaRendered}))
     0))

(fn ensure_parsed [ltree buf r0 r1]
  "Parse `ltree` over rows r0..r1 when any injection touching that range is
unparsed, and invalidate `inline`'s tree-index cache when it does (a ranged
`ltree:parse` can inject new markdown_inline trees without bumping
changedtick, which would otherwise leave `inline.collect` serving a stale
index). `is_valid(false, {r0, r1+1})` reports validity for that range alone;
the no-argument form reports invalid whenever *any* injection anywhere in
the buffer is unparsed (almost always), so checking a range instead is what
lets a re-render of an already-parsed viewport (CursorMoved, WinScrolled
onto rows already covered) skip the parser entirely."
  (when (not (ltree:is_valid false [r0 (+ r1 1)]))
    (ltree:parse [r0 (+ r1 1)])
    (inline.invalidate buf)
    (set stats.parses (+ stats.parses 1))))

(fn M.render [buf win a b ?parse]
  "Render rows a..b (inclusive, 0-based) of buf in win. Parses the buffer
unless ?parse is false (anti-conceal re-renders without parsing, FR-AC2). A
no-op if buf is not attached or is in raw mode (FR-T3)."
  (let [st (state.get buf)]
    (when (and st (not st.raw))
      (let [t0 (vim.uv.hrtime)
            parse? (if (= ?parse nil) true ?parse)
            (ok ltree) (pcall vim.treesitter.get_parser buf :markdown)]
        (when (and ok ltree)
          (when parse?
            (ensure_parsed ltree buf a b)
            (set st.tick (vim.api.nvim_buf_get_changedtick buf)))
          (let [trees (ltree:trees)
                root (: (. trees 1) :root)
                cur-win (vim.api.nvim_get_current_win)
                width (text_width win)
                cursor (if (and st.cfg.anti_conceal (= win cur-win)) st.cursor
                           -1)]
            (var make_ctx nil)
            (set make_ctx (fn [r0 r1 crow]
                            (let [lines (vim.api.nvim_buf_get_lines buf r0
                                                                    (+ r1 1)
                                                                    false)
                                  ctx {: buf
                                       : win
                                       :a r0
                                       :b r1
                                       :cfg st.cfg
                                       : lines
                                       : width
                                       :cursor crow
                                       : root
                                       : ltree
                                       :text (fn [node] (slice lines r0 node))
                                       :owned {}}]
                              (tset ctx :ensure_parsed
                                    (fn [rr0 rr1]
                                      (ensure_parsed ltree buf rr0 rr1)))
                              (tset ctx :sub
                                    (fn [rr0 rr1] (make_ctx rr0 rr1 -1)))
                              ctx)))
            (let [ctx (make_ctx a b cursor)
                  marks []]
              (append marks (block.collect ctx))
              (append marks (tables.collect ctx))
              ;; block.collect and tables.collect run first (above) and are
              ;; what populate ctx.owned, so it is already complete here:
              ;; drop every inline.collect mark whose row is owned from the
              ;; col a block recipe claimed on, before it ever reaches
              ;; `marks`.
              (each [_ m (ipairs (inline.collect ctx))]
                (let [owned_col (. ctx.owned m.row)]
                  (when (not (and owned_col (>= m.col owned_col)))
                    (table.insert marks m))))
              (append marks (mermaid.collect ctx))
              (vim.api.nvim_buf_clear_namespace buf (state.ns) a (+ b 1))
              (each [_ m (ipairs marks)]
                (when (and (>= m.row a) (<= m.row b)
                           (not (and st.cfg.anti_conceal m.shifting
                                     (= m.row cursor))))
                  (pcall vim.api.nvim_buf_set_extmark buf (state.ns) m.row
                         m.col m.opts)))
              (set stats.renders (+ stats.renders 1))
              (log.record_render (/ (- (vim.uv.hrtime) t0) 1000000))
              (when (has_rendered_listener?)
                (vim.api.nvim_exec_autocmds :User
                                            {:pattern :MadaRendered
                                             :data {: buf :rows [a b]}})))))))))

M
