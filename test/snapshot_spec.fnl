;; test.snapshot_spec - AT-18: golden snapshot fixtures, one per element
;; class in UR-3. Generic over test/fixtures/*.md so later milestones add
;; fixtures and snapshots without editing this spec.

(local h (require :helpers))
(local mada (require :mada))

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

(fn render_fixture [name]
  "Open test/fixtures/<name>.md under a fixed, deterministic setup: 80
columns, a window tall enough to cover every row (viewport_margin defaults
to 20 on top), anti_conceal off, Mermaid backend off. Returns buf."
  (mada.setup {:anti_conceal false :mermaid {:placement :off}})
  (set vim.o.columns 80)
  (let [path (.. :test/fixtures/ name :.md)
        nlines (length (vim.fn.readfile path))]
    (set vim.o.lines (math.max 60 (+ nlines 10))))
  (h.open (.. name :.md)))

(fn normalize [marks]
  "Strip opts.ns_id: it names the namespace by creation order within this
process, not part of the mark's meaning, and could vary (NFR-Q1)."
  (icollect [_ m (ipairs marks)]
    (let [opts (vim.deepcopy m.opts)]
      (tset opts :ns_id nil)
      {:row m.row :col m.col : opts})))

(fn make_test [name]
  "Open the fixture (attaches via the real FileType autocommand), force a
full-range render (`mada.render` bypasses clean-tracking, so every row gets
marks regardless of the actual window height: this headless harness's
`vim.o.lines` does not resize the window, see test.ascii_spec's
`open_fixture` comment for the same workaround), and compare its marks
against test/snapshots/<name>.lua."
  (fn []
    (let [buf (render_fixture name)]
      (mada.render buf)
      (h.snapshot name (normalize (h.marks buf))))))

;; ---- FR-R7/FR-R8: task checkbox takes the bullet's place -----------------

(fn scratch-md [lines]
  (let [buf (vim.api.nvim_create_buf true false)]
    (vim.api.nvim_buf_set_lines buf 0 -1 false lines)
    (vim.api.nvim_win_set_buf 0 buf)
    (set vim.bo.filetype :markdown)
    buf))

(fn check [cond msg]
  (when (not cond) (error msg 0)))

(fn mark-at [marks row col]
  "First mark at [row, col), or nil."
  (var found nil)
  (each [_ m (ipairs marks)]
    (when (and (not found) (= m.row row) (= m.col col)) (set found m)))
  found)

(fn has-mada-bullet? [marks row]
  "True if `row` carries a MadaBullet mark, whether a plain highlight
(ordered markers, `block.fnl`'s `ordered`) or a virt_text overlay (plain
bullets, `block.fnl`'s `bullet`)."
  (var found false)
  (each [_ m (ipairs marks)]
    (when (= m.row row)
      (when (= m.opts.hl_group :MadaBullet) (set found true))
      (when m.opts.virt_text
        (each [_ vt (ipairs m.opts.virt_text)]
          (when (= (. vt 2) :MadaBullet) (set found true))))))
  found)

(fn test-task-bullet-hidden-ordered-bullet-kept []
  "A task item's checkbox takes the bullet's place: `- [ ] x` conceals the
whole dash marker (bullet + its trailing space) instead of overlaying a
bullet glyph over it, so no MadaBullet mark remains on that row; an ordered
marker on a task item (`1. [ ] x`) is unaffected and keeps its MadaBullet
highlight."
  (mada.setup {:anti_conceal false})
  (set vim.o.columns 80)
  (let [buf (scratch-md ["- [ ] x" "1. [ ] x"])]
    (mada.render buf)
    (let [marks (h.marks buf)
          bullet-conceal (mark-at marks 0 0)]
      (check (not= bullet-conceal nil)
             "row 0 (- [ ] x): expected a mark at col 0")
      (h.eq "" bullet-conceal.opts.conceal
            "row 0: the dash marker should conceal (empty replacement), not overlay a bullet glyph")
      (h.eq 2 bullet-conceal.opts.end_col
            "row 0: the concealed marker should cover [0, 2), the whole bullet + its trailing space")
      (check (not (has-mada-bullet? marks 0))
             "row 0: no MadaBullet mark should remain once the checkbox takes the bullet's place")
      (check (has-mada-bullet? marks 1)
             "row 1 (1. [ ] x): the ordered marker should keep its MadaBullet highlight"))))

(fn test-h1-marker-setting-and-no-background []
  (mada.setup {:anti_conceal false :headings {:conceal_markers true}})
  (let [buf (scratch-md ["# One" "## Two" "" :Setext "======"])]
    (mada.render buf)
    (let [marks (h.marks buf)
          h1-marker (mark-at marks 0 0)
          h2-marker (mark-at marks 1 0)]
      (check (and h1-marker h2-marker)
             "ATX H1 and H2 should both have marker marks")
      (h.eq "" h1-marker.opts.conceal "H1 marker should follow conceal_markers")
      (h.eq "" h2-marker.opts.conceal "H2 marker should follow conceal_markers")
      (each [_ m (ipairs marks)]
        (check (not= m.opts.line_hl_group :MadaH1Line)
               "ATX and setext H1 should not add a row background")))))

(local fixture_tests (icollect [_ name (ipairs (fixture_names))]
                       [name (make_test name)]))

(table.insert fixture_tests
              ["task bullet (FR-R7/FR-R8): `- [ ] x` conceals [0,2) with no MadaBullet mark; `1. [ ] x` keeps MadaBullet"
               test-task-bullet-hidden-ordered-bullet-kept])

(table.insert fixture_tests
              ["H1 follows conceal_markers and has no row background"
               test-h1-marker-setting-and-no-background])

fixture_tests
