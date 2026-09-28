;; mada.hl - highlight groups (requirements §7.2, architecture §10).

(local M {})

;; group -> {:target base-group} or {:target base-group :extra {attrs}}.
;; Plain groups link outright; groups with :extra copy the target's resolved
;; attributes and add the extra attribute, still `default = true`.
(local groups {:MadaH1 {:target "@markup.heading.1" :extra {:bold true}}
               :MadaH1Line {:target :ColorColumn}
               :MadaH2 {:target "@markup.heading.2"}
               :MadaH3 {:target "@markup.heading.3"}
               :MadaH4 {:target "@markup.heading.4"}
               :MadaH5 {:target "@markup.heading.5"}
               :MadaH6 {:target "@markup.heading.6"}
               :MadaHeadingMarker {:target "@markup.heading"}
               :MadaEmph {:target "@markup.italic"}
               :MadaStrong {:target "@markup.strong"}
               :MadaStrike {:target "@markup.strikethrough"}
               :MadaCode {:target "@markup.raw"}
               :MadaCodeBlock {:target :ColorColumn}
               :MadaCodeLang {:target :Comment}
               :MadaLink {:target "@markup.link.label"
                          :extra {:underline true}}
               :MadaUrl {:target "@markup.link.url"}
               :MadaImage {:target "@markup.link"}
               :MadaBullet {:target "@markup.list"}
               :MadaTaskTodo {:target "@markup.list.unchecked"}
               :MadaTaskDone {:target "@markup.list.checked"}
               :MadaTaskDoneText {:target :Comment}
               :MadaQuote {:target "@markup.quote"}
               :MadaQuoteText {:target "@markup.quote"}
               :MadaRule {:target "@punctuation.special"}
               :MadaTableHead {:target "@markup.heading" :extra {:bold true}}
               :MadaTableBorder {:target "@punctuation.special"}
               :MadaComment {:target :Comment}
               :MadaDiagramLine {:target :NonText}
               :MadaDiagramText {:target :Normal}
               :MadaDiagramPending {:target :Comment :extra {:italic true}}
               :MadaDiagramError {:target :DiagnosticError}})

(fn M.define []
  "(Re)define every group, linked to its target or copying the target's
resolved attributes plus an extra attribute. Called on setup and
ColorScheme."
  (each [name spec (pairs groups)]
    (if spec.extra
        (let [resolved (vim.api.nvim_get_hl 0 {:name spec.target :link false})]
          (vim.api.nvim_set_hl 0 name
                               (vim.tbl_extend :force resolved spec.extra
                                               {:default true})))
        (vim.api.nvim_set_hl 0 name {:link spec.target :default true}))))

M
