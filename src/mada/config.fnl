;; mada.config - defaults and option merging.

(local M {})

(local defaults {:enabled true
                 :filetypes [:markdown]
                 :max_file_lines 20000
                 ; first char of mode(1); "\19" is CTRL-S
                 :raw_modes [:i :R :s :S "\019"]
                 :anti_conceal true
                 ; ASCII glyphs, and termaid --ascii
                 :ascii false
                 ; "auto" | true | false
                 :treesitter {:highlight :auto}
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
                                   :right "┤"}}
                 :mermaid {; "replace" | "off"
                           :placement :replace
                           ; string or list
                           :cmd [:termaid]
                           :args []
                           :width_bucket 10
                           :timeout_ms 5000
                           :pending_text "rendering diagram…"}
                 :debug false})

(var options (vim.deepcopy defaults))

(fn M.setup [opts]
  "Merge `opts` over the defaults and store the result."
  (set options
       (vim.tbl_deep_extend :force (vim.deepcopy defaults) (or opts {})))
  options)

(fn M.get []
  "Return the merged configuration."
  options)

M
