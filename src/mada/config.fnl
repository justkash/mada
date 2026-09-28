;; mada.config - defaults, deep merge, validation, glyph resolution.

(local M {})

(local defaults {:enabled true
                 :filetypes [:markdown]
                 :max_file_lines 20000
                 ; first char of mode(1); "\19" is CTRL-S
                 :raw_modes [:i :R :s :S "\019"]
                 :anti_conceal true
                 ; ASCII glyphs, and termaid --ascii
                 :ascii false
                 ; "auto" | true | false. Default false: mada stops any
                 ; tree-sitter highlighter active on the buffer - whoever
                 ; started it, including Neovim's own runtime
                 ; ftplugin/markdown.lua under `filetype plugin on` - and
                 ; restarts it on detach (measured on the 2,026-line
                 ; reference document: the highlighter's conceal_lines,
                 ; active through mada's own conceallevel=2, took a
                 ; full-page redraw from 6.5ms to 49.9ms, over the
                 ; NFR-P6/NFR-P7 budgets). Set "auto" or true to opt back
                 ; in. "auto" keeps/starts one only at or under
                 ; auto_max_lines lines (OQ-4 / architecture §13), stopping
                 ; (and restoring on detach) above it; `true` always ensures
                 ; one runs, starting it if none is active.
                 :treesitter {:highlight false :auto_max_lines 5000}
                 :viewport_margin 20
                 :headings {:conceal_markers false}
                 :bullets ["•" "◦" "▪"]
                 :checkbox {:todo "[ ]" :done "[✓]"}
                 :quote "│"
                 :rule "─"
                 :image_icon "▣ "
                 :code {:hide_fences true :show_language true}
                 :links {:conceal true :show_url false}
                 :tables {; "unicode" | "off"
                          :style :unicode
                          :border {:v "│"
                                   :h "─"
                                   :cross "┼"
                                   :left "├"
                                   :right "┤"
                                   :top_left "┌"
                                   :top_cross "┬"
                                   :top_right "┐"
                                   :bottom_left "└"
                                   :bottom_cross "┴"
                                   :bottom_right "┘"}}
                 :mermaid {; "replace" | "off"
                           :placement :replace
                           ; string or list
                           :cmd [:termaid]
                           :args []
                           :width_bucket 10
                           :timeout_ms 5000
                           :pending_text "rendering diagram…"}
                 :debug false})

;; requirements §7.4: ascii fallbacks for glyphs the user did not set. Not in
;; §7.4 itself, but the same rule applies (FR-R17: every default glyph gets
;; an ASCII fallback): mermaid.pending_text defaults to a string containing
;; "…", which would otherwise leak a non-ASCII byte into a MadaDiagramPending
;; virt_lines row under ascii = true (AT-15).
(local ascii_fallbacks
       {:bullets ["*" "-" "+"]
        [:checkbox :done] "[x]"
        :quote "|"
        :rule "-"
        :image_icon "[img] "
        [:tables :border :v] "|"
        [:tables :border :h] "-"
        [:tables :border :cross] "+"
        [:tables :border :left] "+"
        [:tables :border :right] "+"
        [:tables :border :top_left] "+"
        [:tables :border :top_cross] "+"
        [:tables :border :top_right] "+"
        [:tables :border :bottom_left] "+"
        [:tables :border :bottom_cross] "+"
        [:tables :border :bottom_right] "+"
        [:mermaid :pending_text] "rendering diagram..."})

;; flat schema: dotted key path -> "boolean" | "number" | "string" | "list" |
;; "cmd" (string or list of strings) | a list of accepted literal values.
(local schema {:enabled :boolean
               :filetypes :list
               :max_file_lines :number
               :raw_modes :list
               :anti_conceal :boolean
               :ascii :boolean
               :treesitter.highlight [true false :auto]
               :treesitter.auto_max_lines :number
               :viewport_margin :number
               :headings.conceal_markers :boolean
               :bullets :list
               :checkbox.todo :string
               :checkbox.done :string
               :quote :string
               :rule :string
               :image_icon :string
               :code.hide_fences :boolean
               :code.show_language :boolean
               :links.conceal :boolean
               :links.show_url :boolean
               :tables.style [:unicode :off]
               :tables.border.v :string
               :tables.border.h :string
               :tables.border.cross :string
               :tables.border.left :string
               :tables.border.right :string
               :tables.border.top_left :string
               :tables.border.top_cross :string
               :tables.border.top_right :string
               :tables.border.bottom_left :string
               :tables.border.bottom_cross :string
               :tables.border.bottom_right :string
               :mermaid.placement [:replace :off]
               :mermaid.cmd :cmd
               :mermaid.args :list
               :mermaid.width_bucket :number
               :mermaid.timeout_ms :number
               :mermaid.pending_text :string
               :debug :boolean})

;; the containers walked to reach every leaf above (dotted path, "" for the
;; root); anything else at these levels is an unknown key.
(local containers {"" true
                   :treesitter true
                   :headings true
                   :checkbox true
                   :code true
                   :links true
                   :tables true
                   :tables.border true
                   :mermaid true})

(fn is_list [t]
  (and (= (type t) :table) (vim.islist t)))

(fn deep_merge [base opts]
  "Merge `opts` over `base`. Tables are merged key-by-key; lists and scalars
in `opts` fully replace the base value (no index-wise array merging)."
  (if (not= (type opts) :table)
      opts
      (let [out (vim.deepcopy base)]
        (each [k v (pairs opts)]
          (let [bv (. out k)]
            (if (and (= (type v) :table) (= (type bv) :table) (not (is_list v)))
                (tset out k (deep_merge bv v))
                (tset out k (vim.deepcopy v)))))
        out)))

(fn path_str [path]
  (table.concat path "."))

(fn get_path [t path]
  (var cur t)
  (each [_ k (ipairs path)]
    (set cur (and (= (type cur) :table) (. cur k))))
  cur)

(fn has_path [t path]
  (var cur t)
  (var ok true)
  (each [_ k (ipairs path)]
    (if (and ok (= (type cur) :table) (not= (. cur k) nil))
        (set cur (. cur k))
        (set ok false)))
  ok)

(fn check_type [path spec v]
  (let [p (path_str path)]
    (if (= spec :boolean)
        (assert (= (type v) :boolean)
                (: "mada: %s must be a boolean" :format p))
        (= spec :number)
        (assert (= (type v) :number) (: "mada: %s must be a number" :format p))
        (= spec :string)
        (assert (= (type v) :string) (: "mada: %s must be a string" :format p))
        (= spec :list)
        (assert (or (is_list v) (and (= (type v) :table) (= (next v) nil)))
                (: "mada: %s must be a list" :format p))
        (= spec :cmd)
        (assert (or (= (type v) :string) (is_list v))
                (: "mada: %s must be a string or a list of strings" :format p))
        ;; enum: a list of accepted literal values
        (let [ok (accumulate [found false _ opt (ipairs spec)]
                   (or found (= opt v)))]
          (assert ok (: "mada: %s must be one of %s" :format p
                        (table.concat (icollect [_ o (ipairs spec)]
                                        (tostring o))
                                      ", ")))))))

(fn extend [path k]
  (let [out []]
    (each [_ p (ipairs path)] (table.insert out p))
    (table.insert out k)
    out))

(fn validate_at [cfg path]
  (each [k v (pairs (get_path cfg path))]
    (let [sub (extend path k)
          leaf (. schema (path_str sub))]
      (if leaf
          (check_type sub leaf v)
          (. containers (path_str sub))
          (validate_at cfg sub)
          (error (: "mada: unknown config key %s" :format (path_str sub)))))))

(fn M.validate [cfg]
  "Validate `cfg` against the flat schema; raises naming the key path."
  (validate_at cfg []))

(fn apply_ascii [cfg opts]
  "With ascii=true, replace glyphs the user did not set in `opts` with their
ASCII fallback (requirements §7.4)."
  (when cfg.ascii
    (each [path fallback (pairs ascii_fallbacks)]
      (let [p (if (= (type path) :string) [path] path)]
        (when (not (has_path opts p))
          (var cur cfg)
          (for [i 1 (- (length p) 1)]
            (set cur (. cur (. p i))))
          (tset cur (. p (length p)) (vim.deepcopy fallback))))))
  cfg)

(var options (vim.deepcopy defaults))

(fn M.setup [opts]
  "Merge `opts` over the defaults, resolve ascii glyphs, validate, and store
the result. Raises on an invalid key or value (FR-C1)."
  (let [merged (deep_merge (vim.deepcopy defaults) (or opts {}))]
    (apply_ascii merged (or opts {}))
    (M.validate merged)
    (set options merged))
  options)

(fn M.get []
  "Return the current merged configuration."
  options)

(fn M.defaults []
  "Return a fresh copy of the built-in defaults."
  (vim.deepcopy defaults))

M
