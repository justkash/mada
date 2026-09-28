;; test.config_spec - FR-C1: deep merge, validation, ascii glyph resolution.

(local h (require :helpers))
(local config (require :mada.config))

(fn test_defaults []
  (let [cfg (config.setup {})]
    (h.eq true cfg.enabled)
    (h.eq [:markdown] cfg.filetypes)
    (h.eq "│" cfg.quote)))

(fn test_deep_merge_keeps_siblings []
  (let [cfg (config.setup {:code {:hide_fences false}})]
    (h.eq false cfg.code.hide_fences)
    (h.eq true cfg.code.show_language)))

(fn test_list_replaces_not_merges []
  (let [cfg (config.setup {:bullets [:x]})]
    (h.eq [:x] cfg.bullets)))

(fn test_unknown_key_names_path []
  (let [(ok err) (pcall config.setup {:mermaid {:bogus 1}})]
    (h.eq false ok)
    (h.eq true (not= nil (err:find :mermaid.bogus 1 true)))))

(fn test_wrong_type_names_path []
  (let [(ok err) (pcall config.setup {:max_file_lines :20000})]
    (h.eq false ok)
    (h.eq true (not= nil (err:find :max_file_lines 1 true)))))

(fn test_enum_rejects_invalid []
  (let [(ok _) (pcall config.setup {:mermaid {:placement :bogus}})]
    (h.eq false ok)))

(fn test_cmd_accepts_string_or_list []
  (let [cfg1 (config.setup {:mermaid {:cmd "uvx termaid"}})
        cfg2 (config.setup {:mermaid {:cmd [:uvx :termaid]}})]
    (h.eq "uvx termaid" cfg1.mermaid.cmd)
    (h.eq [:uvx :termaid] cfg2.mermaid.cmd)))

(fn test_ascii_resolves_unset_glyphs []
  (let [cfg (config.setup {:ascii true})]
    (h.eq ["*" "-" "+"] cfg.bullets)
    (h.eq "[x]" cfg.checkbox.done)
    (h.eq "[ ]" cfg.checkbox.todo)
    (h.eq "|" cfg.quote)
    (h.eq "-" cfg.rule)
    (h.eq "|" cfg.tables.border.v)))

(fn test_ascii_keeps_user_glyphs []
  (let [cfg (config.setup {:ascii true :quote ">"})]
    (h.eq ">" cfg.quote)
    (h.eq "-" cfg.rule)))

[[:defaults test_defaults]
 ["deep merge keeps siblings" test_deep_merge_keeps_siblings]
 ["list replaces, does not merge" test_list_replaces_not_merges]
 ["unknown key names the path" test_unknown_key_names_path]
 ["wrong type names the path" test_wrong_type_names_path]
 ["enum rejects invalid value" test_enum_rejects_invalid]
 ["mermaid.cmd accepts string or list" test_cmd_accepts_string_or_list]
 ["ascii resolves glyphs the user did not set"
  test_ascii_resolves_unset_glyphs]
 ["ascii keeps user-supplied glyphs" test_ascii_keeps_user_glyphs]]
