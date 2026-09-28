;; test.invariant_spec - architecture.md §1 invariant 2: render(buf, win, a,
;; b) replaces exactly the marks of rows a..b, so a full-range render equals
;; the union of single-row renders. Generic over test/fixtures/*.md so later
;; milestones add fixtures without editing this spec.

(local h (require :helpers))
(local mada (require :mada))
(local render (require :mada.render))
(local state (require :mada.state))

(fn fixture_names []
  "Sorted basenames of test/fixtures/*.md, excluding reference.md and names
starting with mermaid (mermaid fixtures get their own spec)."
  (let [files (vim.fn.readdir :test/fixtures)
        names []]
    (each [_ f (ipairs files)]
      (when (and (f:match "%.md$") (not= f :reference.md)
                 (not (f:match :^mermaid)))
        (table.insert names (pick-values 1 (f:gsub "%.md$" "")))))
    (table.sort names)
    names))

(fn open_fixture [name]
  "Open test/fixtures/<name>.md under a fixed, deterministic setup: 80
columns, a window tall enough to cover every row (viewport_margin defaults
to 20 on top), anti_conceal off. Returns buf."
  (mada.setup {:anti_conceal false})
  (set vim.o.columns 80)
  (let [path (.. :test/fixtures/ name :.md)
        nlines (length (vim.fn.readfile path))]
    (set vim.o.lines (math.max 60 (+ nlines 10))))
  (h.open (.. name :.md)))

(fn multiset_keys [marks]
  "Sorted vim.inspect strings, one per mark: turns an ordered mark list into
a canonical form comparable regardless of source order (a multiset)."
  (let [ks (icollect [_ m (ipairs marks)] (vim.inspect m))]
    (table.sort ks)
    ks))

(fn make_test [name]
  "Render the fixture's full range once, then again one row at a time from a
cleared namespace (same cursor, same config both times: anti_conceal is off,
so ctx.cursor is always -1), and compare the two mark sets as multisets."
  (fn []
    (let [buf (open_fixture name)
          win (vim.api.nvim_get_current_win)
          nlines (vim.api.nvim_buf_line_count buf)]
      (render.render buf win 0 (- nlines 1))
      (let [full (h.marks buf)]
        (vim.api.nvim_buf_clear_namespace buf (state.ns) 0 -1)
        (for [r 0 (- nlines 1)]
          (render.render buf win r r))
        (let [per_row (h.marks buf)]
          (h.eq (multiset_keys per_row) (multiset_keys full)
                (.. "invariant 2 mismatch: " name)))))))

(icollect [_ name (ipairs (fixture_names))]
  [name (make_test name)])
