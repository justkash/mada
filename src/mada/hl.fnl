;; mada.hl - highlight groups (requirements §7.2, architecture §10).

(local M {})
(var previous-table-border nil)

;; group -> {:target base-group} or {:target base-group :extra {attrs}}.
;; Plain groups link outright; groups with :extra copy the target's resolved
;; attributes and add the extra attribute, still `default = true`.
(local groups {:MadaH1 {:target "@markup.heading.1" :extra {:bold true}}
               :MadaH2 {:target "@markup.heading.2" :extra {:bold true}}
               :MadaH3 {:target "@markup.heading.3" :extra {:bold true}}
               :MadaH4 {:target "@markup.heading.4" :extra {:bold true}}
               :MadaH5 {:target "@markup.heading.5" :extra {:bold true}}
               :MadaH6 {:target "@markup.heading.6" :extra {:bold true}}
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
               :MadaComment {:target :Comment}
               :MadaDiagramLine {:target :NonText}
               :MadaDiagramText {:target :Normal}
               :MadaDiagramPending {:target :Comment :extra {:italic true}}
               :MadaDiagramError {:target :DiagnosticError}})

(fn table-border-color []
  "Keep table rules just lighter than the editor background."
  (let [normal (vim.api.nvim_get_hl 0 {:name :Normal :link false})
        bg (or normal.bg (if (= vim.o.background :light) 16777215 0))
        r (math.floor (/ bg 65536))
        g (% (math.floor (/ bg 256)) 256)
        b (% bg 256)]
    (+ (* (math.min 255 (+ r 12)) 65536) (* (math.min 255 (+ g 12)) 256)
       (math.min 255 (+ b 12)))))

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
        (vim.api.nvim_set_hl 0 name {:link spec.target :default true})))
  (let [current (vim.api.nvim_get_hl 0 {:name :MadaTableBorder})
        color (table-border-color)]
    (if (and previous-table-border
             (vim.deep_equal current {:fg previous-table-border}))
        ;; Refresh our own derived color even when ColorScheme did not clear it.
        (vim.api.nvim_set_hl 0 :MadaTableBorder {:fg color})
        (vim.api.nvim_set_hl 0 :MadaTableBorder {:fg color :default true}))
    (set previous-table-border color)))

M
