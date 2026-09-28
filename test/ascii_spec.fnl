;; test.ascii_spec - AT-15, FR-R17: `ascii = true`. No default glyph leaks a
;; non-ASCII byte into virt_text/virt_lines/conceal; user-supplied glyphs are
;; kept as given; termaid is asked for ASCII output (--ascii).
;;
;; How "buffer-derived" is decided (task instruction): a mark's `conceal`
;; replacement is always skipped by this scan - the only source of a
;; non-empty conceal replacement anywhere in the plugin is decoded-entity
;; text (inline.fnl's handle_entity), which requirements FR-R19 and this
;; milestone's task both call buffer-derived and allowed regardless of byte
;; content. For virt_text/virt_lines/right_align chunks (overlay, inline,
;; right-aligned language label, image alt text, `show_url`'s appended URL),
;; a chunk containing a non-ASCII byte is allowed only when that exact text
;; is a substring of the fixture's own buffer lines (so it came from the
;; source: alt text, a URL, a quote/heading/code-lang token, etc.), never
;; from one of mada's own default glyphs. Mermaid fixtures are out of scope
;; for this scan (covered by the separate --ascii backend check below,
;; mirroring how snapshot/invariant specs exclude them too).

(local h (require :helpers))
(local mada (require :mada))
(local config (require :mada.config))

(local fake-cmd (.. (vim.fn.getcwd) :/test/bin/fake-termaid))

;; See test.mermaid_spec: force FR-C6's lazy `mada.setup({})` now, before any
;; test's own config.setup/mada.setup call, so it cannot clobber one later.
(mada.setup {})

(fn check [cond msg]
  (when (not cond) (error msg 0)))

(fn fixture_names []
  "Sorted basenames of test/fixtures/*.md, excluding reference.md and names
starting with mermaid (their glyphs come from the termaid backend, checked
separately below)."
  (let [files (vim.fn.readdir :test/fixtures)
        names []]
    (each [_ f (ipairs files)]
      (when (and (f:match "%.md$") (not= f :reference.md)
                 (not (f:match :^mermaid)))
        (table.insert names (pick-values 1 (f:gsub "%.md$" "")))))
    (table.sort names)
    names))

(fn open_fixture [name extra]
  "Open test/fixtures/<name>.md under a fixed setup and force a fresh
parsing render. `h.open` re-edits the same file-backed buffer if a fixture
of the same name was opened earlier in this process (e.g. by an earlier
test in this spec); since `mada.setup`'s own re-render only reaches windows
showing the buffer *at setup time* (architecture §9, FR-C2), a buffer that
was hidden then would otherwise keep marks built under the old config
because its viewport range is already `clean` and BufEnter's `refresh`
only renders the delta. `mada.render` bypasses that clean-tracking (it
always calls `render_view`), so every call here reflects the config this
call passed, not a stale one."
  (mada.setup (vim.tbl_deep_extend :force {:ascii true :anti_conceal false}
                                   (or extra {})))
  (set vim.o.columns 80)
  (let [path (.. :test/fixtures/ name :.md)
        nlines (length (vim.fn.readfile path))]
    (set vim.o.lines (math.max 60 (+ nlines 10))))
  (let [buf (h.open (.. name :.md))]
    (mada.render buf)
    buf))

(fn has-non-ascii? [s] (not= nil (s:find "[\128-\255]")))

(fn chunk_texts [opts]
  "Every virt_text/virt_lines chunk's text on one mark's opts."
  (let [out []]
    (when opts.virt_text
      (each [_ chunk (ipairs opts.virt_text)] (table.insert out (. chunk 1))))
    (when opts.virt_lines
      (each [_ line (ipairs opts.virt_lines)]
        (each [_ chunk (ipairs line)] (table.insert out (. chunk 1)))))
    out))

(fn buffer_text [buf]
  (table.concat (vim.api.nvim_buf_get_lines buf 0 -1 false) "\n"))

(fn contains? [s needle]
  (not= nil (s:find needle 1 true)))

(fn find_leak [buf marks]
  "The first mark+text carrying a non-ASCII byte that is not a substring of
the buffer's own text, or nil."
  (let [src (buffer_text buf)]
    (var leak nil)
    (each [_ m (ipairs marks)]
      (when (not leak)
        ;; opts.conceal: always buffer-derived (entity decode) or empty; see
        ;; the module docstring.
        (each [_ text (ipairs (chunk_texts m.opts))]
          (when (and (not leak) (has-non-ascii? text)
                     (not (contains? src text)))
            (set leak {: m : text})))))
    leak))

(fn test-no-default-glyph-leaks []
  (each [_ name (ipairs (fixture_names))]
    (let [buf (open_fixture name)
          leak (find_leak buf (h.marks buf))]
      (check (= leak nil) (: "ascii=true: fixture %s leaked a non-ASCII glyph: %s (row %d)"
                             :format name (if leak (vim.inspect leak.text) "")
                             (if leak
                                 leak.m.row
                                 -1))))))

(fn test-user-glyph-kept-as-given []
  "A user-supplied non-ASCII glyph is used as given even under ascii = true
(FR-R17): overriding `bullets` with a non-ASCII glyph must still show that
exact glyph, not the ASCII fallback."
  (let [buf (open_fixture :lists {:bullets ["→"]})
        marks (h.marks buf)]
    (var found false)
    (each [_ m (ipairs marks)]
      (each [_ text (ipairs (chunk_texts m.opts))]
        (when (= text "→") (set found true))))
    (check found
           "expected the user-supplied bullet glyph '→' to appear, not an ASCII fallback")))

;; ---- termaid receives --ascii (fake-termaid echoes its args) ----

(fn scratch-md [lines]
  (let [buf (vim.api.nvim_create_buf true false)]
    (vim.api.nvim_buf_set_lines buf 0 -1 false lines)
    (vim.api.nvim_win_set_buf 0 buf)
    (set vim.bo.filetype :markdown)
    buf))

(fn diagram-text [marks]
  "The diagram's displayed text, drawn as `virt_text_win_col = 0` overlays
over the block's own rows (mada.mermaid's draw-over-source design, OQ-1) plus
any overflow `virt_lines` below the closing fence."
  (let [parts []]
    (each [_ m (ipairs marks)]
      (when (and m.opts.virt_text (= m.opts.virt_text_pos :win_col))
        (each [_ chunk (ipairs m.opts.virt_text)]
          (table.insert parts (. chunk 1))))
      (when m.opts.virt_lines
        (each [_ line (ipairs m.opts.virt_lines)]
          (each [_ chunk (ipairs line)] (table.insert parts (. chunk 1))))))
    (if (> (length parts) 0) (table.concat parts "\n") nil)))

(fn test-termaid-receives-ascii-flag []
  (vim.fn.setenv :FAKE_OUT "")
  (vim.fn.setenv :FAKE_SLEEP "")
  (vim.fn.setenv :FAKE_ERR "")
  (vim.fn.setenv :FAKE_CODE "")
  (config.setup {:ascii true
                 :mermaid {:cmd [fake-cmd] :timeout_ms 2000 :width_bucket 10}})
  (let [buf (scratch-md ["# D" "" "```mermaid" "graph LR" "  A --> B" "```" ""])]
    (check (h.wait_diagram buf) "expected the diagram job to complete")
    (let [text (diagram-text (h.marks buf))]
      (check (not= text nil) "expected the diagram to be drawn")
      (check (contains? text :ascii=yes)
             "expected fake-termaid to report --ascii was passed")))
  (config.setup {}))

[["ascii=true: no default glyph leaks a non-ASCII byte"
  test-no-default-glyph-leaks]
 ["ascii=true: a user-supplied non-ASCII glyph is kept as given"
  test-user-glyph-kept-as-given]
 ["ascii=true: termaid is invoked with --ascii"
  test-termaid-receives-ascii-flag]]
