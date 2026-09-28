# Requirements

Status: draft for implementation. Requirement IDs are stable; reference them in commits and tests. Revised 2026-09-24: user requirements added (§2); requirements aligned to them, then simplified to match `architecture.md` (retired IDs are listed at the end of their section).

The user requirements in §2 are the acceptance bar. Every functional and non-functional requirement serves at least one of them, and each group below names the ones it serves.

## 1. Purpose

mada is a Neovim plugin that renders Markdown in place while the user is not editing, and steps out of the way while they are. Rendering is purely visual (extmarks); the buffer, its undo history and its `modified` flag are never touched. Mermaid fenced blocks are rendered to text diagrams by an external tool, [termaid](https://github.com/fasouto/termaid), and shown in place of their source.

## 2. User requirements

Stated from the user's side. Each one has acceptance criteria and lists the requirements and scenarios that realise it.

### UR-1 Rendered on open

> When I open a Markdown buffer with the plugin enabled, I see a minimal but pretty rendering of the file.

- The first screen is drawn already rendered; a raw frame is never shown first. Mermaid diagrams that are not drawn yet arrive shortly after (UR-3).
- It works with no configuration beyond installing the plugin.
- **Minimal:** styling uses colour, weight and glyph substitution only. No margins, padding rows, boxes or reflow are added. Delimiters that carry no meaning once styled are hidden: emphasis markers, backticks, link brackets and destinations, heading markers when `headings.conceal_markers` is enabled, code fences. Structural markers become glyphs: bullets, checkboxes, quote bars, rules, table separators. Pipe tables are the exception: they are laid out in virtual text (FR-R13).
- **Pretty:** it looks native in the active colourscheme, light or dark. Highlight groups link to a `@markup.*` or built-in group, except `MadaTableBorder`, whose foreground is slightly lighter than `Normal`'s background; explicit user overrides win, so no colour setup is needed.
- [glamour](https://github.com/charmbracelet/glamour)'s dark style is the reference for how each element looks (§7.1). mada departs from it only where glamour changes the layout, because that would break UR-4.

Realised by FR-M1, FR-M5, FR-M10, FR-T2, FR-T6, FR-R1–FR-R21, FR-C3, FR-C6, §7; AT-1, AT-15, AT-18, AT-19, AT-21, AT-22.

### UR-2 Raw while editing

> When I enter Insert mode, I edit the raw text like a regular text file. When I leave it, the rendering comes back.

- In Insert, Replace and Select mode every character is shown where it is stored. The plugin adds no conceal, overlays, virtual text, hidden rows or diagrams.
- Entering Insert mode does not shift the text on the cursor row. That row is already shown raw in Normal mode (anti-conceal), so what I see is what I edit.
- Brief trips out of Insert mode (`<C-o>` commands, including `<C-o>:`) do not flash the rendering back.
- The plugin runs no code while I type: no mappings, no Insert-mode autocommands, no buffer-change callbacks.
- Accepted deviation: if the plugin started tree-sitter highlighting (FR-M10, off by default), its syntax colours stay visible in Insert mode.

Realised by FR-M3, FR-M4, FR-M11, FR-M12, FR-AC1–FR-AC5, FR-D15; NFR-P2, NFR-P6; AT-2, AT-3, AT-4, AT-9, AT-20, AT-23, AT-25.

### UR-3 Complete Markdown coverage

> All basic Markdown syntax renders correctly, and so do task lists, code blocks and Mermaid diagrams.

- Basic syntax (CommonMark): ATX and setext headings; paragraphs and line breaks; emphasis and strong emphasis; block quotes, nested included; ordered and unordered lists, nested included; code spans; indented and fenced code blocks; thematic breaks; inline and reference links; autolinks; images; backslash escapes; entity references; HTML comments. Other raw HTML is shown as source.
- Advanced syntax, required: task lists; fenced code blocks with a language label, and syntax colours when a tree-sitter highlighter is active (FR-M10; none by default, since the plugin stops one on attach — opt in with `"auto"` or `true`); Mermaid diagrams drawn as text in place of their source.
- Advanced syntax, also covered: pipe tables, strikethrough, front matter.
- **Correctly** means CommonMark/GFM semantics as parsed by the bundled tree-sitter grammars. Only real syntax is styled (a `*` inside a code span is not emphasis), and anything that cannot be parsed stays raw rather than being mis-styled.
- A Mermaid diagram appears on its own once the backend has produced it, and producing it never blocks editing.

Realised by FR-R1–FR-R21, FR-D1, FR-D3, FR-D6–FR-D8, FR-D10–FR-D17; NFR-Q2; AT-7, AT-9–AT-11, AT-13, AT-18, AT-28.

### UR-4 Interaction unchanged

> Everything I do in the buffer behaves as it would without the plugin.

- Buffer-line motions, counts, text objects, operators, search, marks, jumps and `:{n}` act on the same buffer positions as without the plugin. Absolute and relative line numbers match the file.
- The plugin defines no key mappings. The only options it changes are the window-local `conceallevel` and `concealcursor`, which it restores in raw mode and on disable.
- Diagnostics, signs, completion and other plugins' marks show and behave as before.
- Accepted deviations: screen-row commands (`gj`, `gk`, `H`, `M`, `L`, scroll counts) count screen rows, and those differ where fence rows are hidden or a Mermaid diagram replaces its source. When the plugin starts the tree-sitter highlighter (FR-M10, off by default), the buffer options `vim.treesitter.start` sets (regex `syntax` off) apply until the plugin stops it.

Realised by FR-M9, FR-M11, FR-M12, FR-AC1–FR-AC5; NFR-I1, NFR-I2, NFR-Q4; AT-4, AT-5, AT-20, AT-25, AT-26, AT-29.

### UR-5 No perceptible cost

> Rendering is fast enough that using the buffer feels no different from Neovim without the plugin.

- Opening, moving, scrolling, switching modes, editing and typing show no added delay or hitch. Every plugin callback fits the budgets in §5.1; only tree-sitter's parse on open and after an edit (NFR-P8, NFR-P10) may exceed one 60 Hz frame.
- In rendered mode, rows are never shown raw or stale: after a scroll, jump or Normal-mode edit they are rendered before they are drawn.
- Mermaid rendering is asynchronous. A slow or broken backend never delays editing, and a diagram already on screen stays in place while its new version is produced.

Realised by FR-M2, FR-T1–FR-T6, FR-AC2, FR-D6, FR-D12, FR-D17; NFR-P0–NFR-P10, NFR-Q4; AT-5, AT-6, AT-12, AT-13, AT-16, AT-17, AT-24.

### UR-6 Non-destructive

> The plugin never changes my file.

- Buffer text, undo history, `modified` and `changedtick` are exactly what they would be without the plugin.
- Disabling the plugin for a buffer restores every window option it changed.

Realised by FR-M6, FR-M7, FR-T5, FR-A1; AT-1, AT-14, AT-26.

## 3. Definitions

| Term | Meaning |
|---|---|
| **Rendered mode** | Marks are present in the buffer's namespace. |
| **Raw mode** | Namespace is empty; window options restored. |
| **Mark** | One `nvim_buf_set_extmark` call (highlight range, conceal, overlay/inline virtual text, `virt_lines`, `line_hl_group`, `conceal_lines`). |
| **Shifting mark** | A mark that changes the mapping between buffer columns and screen columns on its row: conceal, overlay virtual text, inline virtual text, `conceal_lines`. |
| **Non-shifting mark** | Highlight ranges and `line_hl_group`; `virt_lines` (they occupy their own screen rows). Table overflow lines are non-shifting; the cursor row blanks their cells (FR-R13). |
| **Anti-conceal** | Removal of shifting marks from the cursor row so the row is displayed exactly as stored. |
| **Mermaid block** | A `fenced_code_block` whose language is `mermaid` (FR-D1). "Block" in §4.5 means a Mermaid block. |
| **Backend** | An adapter that turns Mermaid source into lines of text via an external process. |
| **Viewport range** | `[line("w0") - viewport_margin, line("w$") + viewport_margin]` clamped to the buffer, for the window that triggered the render. |
| **Width bucket** | Usable text width of the window rounded down to a multiple of `mermaid.width_bucket`. |
| **Block key** | `source .. "\0" .. width_bucket .. "\0" .. ascii` for a Mermaid block. A diagram is current when it was produced for the block's current key. |
| **Reference document** | `test/fixtures/reference.md`: 2,026 lines covering every element class in UR-3, including tables, 3 fenced code blocks and 1 Mermaid block whose diagram is already drawn, shown in an 80-row window. The budgets in §5.1 are measured against it. |

## 4. Functional requirements

### 4.1 Lifecycle and modes (FR-M)

Serves UR-1, UR-2, UR-4, UR-6.

- **FR-M1** The plugin attaches to buffers whose filetype is in `filetypes` (default `{"markdown"}`) when `enabled = true`, via `FileType`. Attachment is idempotent.
- **FR-M2** Buffers with more than `max_file_lines` lines are not attached; `:Mada enable` on such a buffer notifies and does nothing.
- **FR-M3** Display state is derived from the current mode: if the first character of `vim.fn.mode(1)` is in `raw_modes`, the buffer is in raw mode; otherwise rendered mode. Transitions are driven by `ModeChanged`. Defaults: raw in Insert, Replace and Select (`s`, `S` and blockwise `CTRL-S`); rendered in Normal, Visual, Operator-pending, Command-line and Terminal-normal. Two exceptions keep brief trips out of Insert mode raw (UR-2): Insert-pending Normal mode (`mode(1)` starts with `ni`, entered with `<C-o>`) is raw, and Command-line and Operator-pending mode keep the display state that was in effect when they were entered. Raw mode applies to the current buffer only: other attached buffers visible in other windows stay rendered, and a buffer that stops being current while raw returns to rendered mode.
- **FR-M4** Entering raw mode clears the namespace in one call and restores the window's `conceallevel` and `concealcursor` to the values saved when rendered mode was entered.
- **FR-M5** Entering rendered mode sets `conceallevel=2` on the current window (saving prior values once per window) and renders the viewport range synchronously (FR-T3). `concealcursor` is set to `""` when `anti_conceal = true` (the cursor row then reveals every conceal, including those set by Neovim's tree-sitter highlighter, which are not the plugin's to remove) and to `nvc` when `anti_conceal = false`.
- **FR-M10** Tree-sitter highlighting. `treesitter.highlight = false` (default, OQ-4): on attach, and once more via `vim.schedule` (Neovim's runtime `ftplugin/markdown.lua` can start a highlighter after the plugin's `FileType` handler runs), stop any tree-sitter highlighter active on the buffer — whoever started it, including that runtime ftplugin — remembering that the plugin stopped it (so it can restart one later) and forcing the buffer's `syntax` option to `""`, because stopping a highlighter re-fires the `syntaxset` `FileType` autocommand and, with `:syntax on`, would otherwise re-enable regex `syntax/markdown.vim`. `"auto"`: on attach and on that same rescheduled check, keep or start one (`vim.treesitter.start(buf, "markdown")`) while the buffer has at most `treesitter.auto_max_lines` lines (default 5000); over the line limit, stop one exactly as `false` does. `true`: ensure one runs, starting it if none is active, uncapped. The plugin's own marks never depend on the highlighter being active or on the contents of the runtime `highlights.scm` queries; code blocks keep their `MadaCodeBlock` band and language label either way (FR-R10), but syntax colours inside them appear only while a highlighter is active — losing them is the accepted cost of the `false` default. A highlighter left running (`true`, or `"auto"` under the limit) keeps running in raw mode: its per-keystroke cost counts against NFR-P6, and the buffer options `vim.treesitter.start` sets (regex `syntax` off) are an accepted deviation from UR-4 until the plugin stops it.
- **FR-M6** The plugin never writes to the buffer, never changes `modified`, and never changes `changedtick`. Test by asserting `changedtick` before and after a full render and mode round-trip.
- **FR-M7** `:Mada disable` clears marks, restores window options for every window showing the buffer, undoes the FR-M10 highlighter action (stops a highlighter the plugin started, or restarts one it had stopped, restoring `syntax` implicitly), and detaches autocommands for that buffer. `:Mada enable` reverses it. `toggle` alternates. Enabled state is buffer-local.
- **FR-M8** On `BufWipeout`/`BufUnload` all per-buffer state is released, including pending mermaid jobs (results are dropped on arrival).
- **FR-M9** If another in-buffer Markdown renderer is loaded (render-markdown.nvim or markview.nvim), the plugin stays disabled and reports the conflict in `:checkhealth` and once via `vim.notify` at WARN level.
- **FR-M11** Nothing else is touched. The plugin defines no key mappings and changes no option other than the window-local `conceallevel` and `concealcursor` (plus the FR-M10 side effect: starting or stopping a highlighter, and forcing the buffer's `syntax` option off while attached under `false`). It registers no `InsertCharPre`, `TextChangedI`, `TextChangedP` or `CursorMovedI` handlers and no `nvim_buf_attach` callbacks, so it runs no code per keystroke in raw mode.
- **FR-M12** The view stays put. The plugin never moves the cursor or scrolls a window. Switching between raw and rendered mode leaves the cursor's buffer position and the window's first visible buffer row (`topline`) unchanged, except where Neovim itself scrolls to keep the cursor visible.

### 4.2 Rendering triggers and scope (FR-T)

Serves UR-1, UR-5.

- **FR-T1** Rendering covers the viewport range only. Rows outside it carry no marks until they are scrolled into range.
- **FR-T2** Triggers: `BufWinEnter`, `WinScrolled`, `WinResized`, `TextChanged` (Normal-mode edits, undo/redo), `ModeChanged` into rendered mode, `BufReadPost` (`:e!`), and explicit `:Mada render`.
- **FR-T3** Renders run synchronously inside the triggering event, before Neovim's next redraw, so rendered mode never displays a raw or stale row. `WinScrolled`, `BufEnter`, `BufWinEnter` and `WinEnter` render only rows not yet rendered in that window (a full viewport-range render when none are, or the buffer changed); the other triggers render the whole viewport range. There is no debounce; one is added only if measurements show renders over budget (§9). A render requested while the buffer is in raw mode is dropped.
- **FR-T4** A render pass first clears the namespace in the range it is about to redraw, then sets marks. Rows outside the range keep their marks.
- **FR-T5** Marks are created with `invalidate = true` and `undo_restore = false` so that deleted-text marks vanish and undo does not resurrect stale marks.
- **FR-T6** First paint. On attach, the viewport range is rendered before the window first draws the buffer, so the raw file is never shown first. Diagram jobs for blocks in view start during that render and never delay it (NFR-P4).

### 4.3 Anti-conceal (FR-AC)

Serves UR-2, UR-4. Because the cursor row always shows its stored text, Normal-mode edits and entering Insert mode never shift the text under the cursor.

- **FR-AC1** When `anti_conceal = true` (default), the cursor row carries no shifting marks in rendered mode. Non-shifting marks stay.
- **FR-AC2** On `CursorMoved`, only the previous and the new cursor rows are re-rendered, from the existing parse tree without calling the parser; the new row is rendered without shifting marks. When the cursor enters or leaves a Mermaid block, that block's rows are re-rendered instead. No other rows are touched.
- **FR-AC3** When the cursor row is inside a mermaid block (opening fence through closing fence inclusive), the block shows its whole source without the diagram overlay; fence rows stay hidden except the cursor's own row (anti-conceal). The block height remains unchanged: blank padding `virt_lines` below the first content row keep it. Leaving the block restores the diagram overlay.
- **FR-AC4** With `anti_conceal = false`, the cursor row is rendered like any other row; `concealcursor=nvc` keeps conceals applied under the cursor.
- **FR-AC5** The plugin strips only marks it owns. Conceals contributed by the tree-sitter highlighter (`@conceal` captures in the runtime queries) are revealed on the cursor row through `concealcursor=""` (FR-M5); the two mechanisms together produce a fully raw cursor row. When both the highlighter and the plugin conceal the same delimiter, the effect is identical and no de-duplication is attempted.

### 4.4 Markdown elements (FR-R)

Serves UR-1, UR-3. The visual spec follows glamour's dark style, adapted to a buffer whose rows cannot move; §7.1 maps each element and lists the deviations. Highlight group names are in §7.2. "Hidden" means concealed with `conceal = ""` unless stated.

- **FR-R1 ATX headings.** H1–H6 markers are highlighted `MadaHeadingMarker`; text is highlighted with `MadaH1`…`MadaH6` in bold. With `headings.conceal_markers = true`, markers are hidden for all heading levels. Closing `#`s (`## x ##`) are hidden.
- **FR-R2 Setext headings.** Text row as H1/H2 per FR-R1; the underline row is overlaid with `rule` glyphs across the text width in `MadaHeadingMarker`.
- **FR-R3 Emphasis.** `*x*`/`_x_` delimiters hidden, text `MadaEmph`. `**x**`/`__x__` → `MadaStrong`. `~~x~~` → `MadaStrike`. Nested combinations apply all groups (extmark priority increases with nesting depth).
- **FR-R4 Code spans.** Backtick delimiters hidden; content `MadaCode`. Multi-backtick delimiters are handled by hiding the whole delimiter node.
- **FR-R5 Inline links.** `[text](url "title")`: `[` and `](…)` hidden when `links.conceal = true`; `text` highlighted `MadaLink` (underline). With `links.show_url = true`, the URL is appended as inline virtual text `MadaUrl` in the form ` (url)`. Reference-style links (`[text][ref]`, `[text][]`, `[ref]`) get `MadaLink` on the text and hide the bracket/label parts. Autolinks `<https://…>` hide the angle brackets and highlight `MadaUrl`. Bare URLs are left untouched.
- **FR-R6 Images.** `![alt](src)`: replaced visually by `image_icon .. alt` in `MadaImage`: the source span is hidden and the text inserted as inline virtual text.
- **FR-R7 Lists.** Unordered markers `-`, `*`, `+` are overlaid with `bullets[level]` (1-based nesting level, cycling) in `MadaBullet`; the original leading indentation is preserved. Ordered markers (`1.`, `1)`) are highlighted `MadaBullet` and otherwise untouched. Nesting level is the number of enclosing `list` nodes. Exception: a task item's unordered marker, with the spaces after it, is hidden instead of drawn as a bullet (FR-R8); ordered task markers keep their number.
- **FR-R8 Task items.** `[ ]` → overlay `checkbox.todo` in `MadaTaskTodo`; `[x]`/`[X]` → overlay `checkbox.done` in `MadaTaskDone`. For an unordered item the checkbox takes the hidden bullet's place, starting at the marker's column (FR-R7); an ordered marker (`1.`) keeps its number and the checkbox follows it. When the replacement is wider than 3 cells, the extra cells are inline virtual text; when narrower, the remaining source characters are hidden. Item text of done tasks is highlighted `MadaTaskDoneText`.
- **FR-R9 Block quotes.** Each `>` marker is overlaid with `quote` in `MadaQuote` (the space after `>` is kept). Nested quotes produce one glyph per marker. Quote body text is highlighted `MadaQuoteText`. GFM callouts (`> [!NOTE]`) render as ordinary quotes in v1.
- **FR-R10 Fenced code blocks.** With `code.hide_fences = true`, the opening and closing fence rows get `conceal_lines = ""`. Content rows get `line_hl_group = MadaCodeBlock`. With `code.show_language = true` and a non-empty info string, the language is shown as right-aligned virtual text `MadaCodeLang` on the first content row. Content characters are never concealed so tree-sitter injection highlighting shows through when a highlighter is active (FR-M10); when no parser is installed for the language, content rows keep the `MadaCodeBlock` background without syntax colours. Unterminated fences (no closing row) render as a block to end of buffer; the parser already reports them that way.
- **FR-R11 Indented code blocks.** `line_hl_group = MadaCodeBlock` on every row.
- **FR-R12 Thematic breaks.** The row is overlaid with `rule` repeated to the window text width in `MadaRule`. Only the source characters are overlaid; the remainder is inline virtual text so the rule spans the window.
- **FR-R13 Pipe tables.** `tables.style = "unicode"`: the table is laid out in virtual text (`tables.fnl`) with only the horizontal separator below the header and vertical separators between columns. There are no top/bottom outer borders, outer vertical borders, or horizontal rules between body rows; absent outer positions are spaces, preserving existing padding and layout widths. Cell content keeps its inline styling (FR-R3–FR-R6, FR-R18, FR-R19): the inline pass runs over the whole table and its marks are projected into styled virtual-text chunks. Cells are trimmed; header cells add `MadaTableHead`; separators use `MadaTableBorder`; missing cells are empty; cells beyond the header's count are ignored; `||` with nothing between is a parser error and degrades like any other (NFR-Q2). Alignment from the delimiter row: `:--` left, `:-:` centre, `--:` right, none is left. Widths: each column's natural width is its widest cell; table width is columns plus the two outer padding positions (spaces) per row plus interior separators. If that exceeds the window text width minus the table's indent, the widest columns shrink first to a common cap (columns already narrower than the cap keep their width) and cells word-wrap: split at single spaces (runs of spaces collapse at the break), breaking mid-word when a word is longer than its column; columns never shrink below 1 cell, so a table with more columns than the window can hold still overflows. Re-laid out on `WinResized` like any other render; with several windows on a buffer the layout follows the window rendered last (marks are per buffer). Virtual lines start with blanks for the table's indent, with `quote` under each `>` of an enclosing block quote.

  Each table row's laid-out grid lines are drawn as overlays at window column 0, one per screen row S of the row (1 with `nowrap`; its wrapped height with `wrap`, honouring `linebreak`, `showbreak`, `breakindent`; S = `nvim_win_text_height().all − .fill`). Lines beyond S go to one `virt_lines` mark below the row. Inline-pass marks on non-cursor rows are dropped (`ctx.owned`): a conceal would change wrapping and misplace the overlays.

  Cursor row (FR-AC1): overlays are dropped, so raw source shows in its own screen rows; the lines below keep their count with cells blanked (the header separator remains when applicable), so table height is unchanged. All table marks sit on the row (invariant 2); `CursorMoved` re-renders just the previous and new rows (no table-anchor re-render). `OptionSet` for `wrap`, `linebreak`, `showbreak`, `breakindent` re-renders the window.

  The delimiter row carries the header separator, with spaces at the two outer edges; it is shown even when there are no body rows. Header and body rows have no top/bottom border or between-row horizontal rules. Overflow lines remain below their source row as needed.

  Layout cache (changedtick, width, config) unchanged; S and anchor columns computed at emit time. Measured on Neovim 0.12 (one line each, in place): `<C-e>` 1–2 lines per step (`nowrap`: 1), `<C-y>` −1 (or long row height), `j`/`k` move by row heights; no blank rows inside grid at EOF.

  `tables.style = "off"`: unchanged — `|` and header highlighted only, no layout.
- **FR-R14 HTML comments** `<!-- … -->` are highlighted `MadaComment`. Other HTML blocks/tags are untouched.
- **FR-R15 Front matter** (`---`/`+++` metadata blocks) rows get `line_hl_group = MadaComment`.
- **FR-R16 Untouched constructs.** Footnotes, wiki-links and LaTeX are left as source (out of scope, §9).
- **FR-R17 Global ASCII mode.** With `ascii = true`, every default glyph is replaced by its ASCII fallback from §7.4; user-supplied glyphs are used as given. It also asks termaid for ASCII output (FR-D13); otherwise diagrams use termaid's Unicode output.
- **FR-R18 Backslash escapes.** The `\` of a backslash escape is hidden, so `\*` displays as `*`.
- **FR-R19 Entity and numeric character references** (`&amp;`, `&#169;`, `&#xA9;`) are concealed with the decoded character as the conceal replacement when it is a single character of display width 1; otherwise they are untouched.
- **FR-R20 Hard line breaks.** The trailing `\` of a backslash hard break is hidden. Trailing-space hard breaks are left as they are (already invisible).
- **FR-R21 Paragraphs and soft line breaks** are displayed as stored: no reflow, no joining of soft-wrapped lines, no blank lines added between blocks (NFR-I1).

### 4.5 Mermaid (FR-D)

Serves UR-3, UR-5.

- **FR-D1 Detection.** A Mermaid block is a `fenced_code_block` whose `info_string` first token (before whitespace or `{`) equals `mermaid`, case-insensitively. Both backtick and tilde fences count. Source is the rows strictly between the fence rows, with common leading indentation (the fence's indentation) removed.
- **FR-D3 Backend.** termaid, run as `mermaid.cmd` (default `{"termaid"}`; a list such as `{"uvx", "termaid"}` is allowed) plus `mermaid.args`. If the executable is missing, blocks render as ordinary code blocks (FR-R10) and one WARN notification is emitted per session.
- **FR-D6 Job execution.** When a block in the viewport range has no current diagram, no error for its current key and no running job, the plugin spawns termaid with `vim.system`: source on stdin, `text = true`, `timeout = mermaid.timeout_ms`. At most one job per block runs at a time. Diagrams are produced on demand: there is no shared cache and no pre-rendering of blocks outside the viewport range (§9).
- **FR-D7 Result application.** On completion, work is scheduled to the main loop. If the buffer is still valid and enabled, the result becomes the block's latest diagram (or error), and in rendered mode the block's rows are re-rendered. If the block's key changed while the job ran, that render starts the next job, and the result is shown as the last diagram meanwhile (FR-D17).
- **FR-D8 Placement `replace` (default).** The block's fence rows are hidden with `conceal_lines`, like an ordinary code fence (`code.hide_fences`) — Neovim's own tree-sitter highlighter, when running, would hide them anyway, so nothing may ever be anchored on a fence row. Diagram rows are drawn as overlays (`virt_text_win_col = 0`) over the CONTENT rows' screen rows. A diagram shorter than the content leaves blank overlay rows; diagram rows beyond the content rows attach as one `virt_lines` mark below the FIRST content row, so the diagram stays contiguous and the virtual lines always sit between two visible rows (a `virt_lines` mark directly above a hidden fence row makes Neovim's scroll-up snap back). With the cursor in the block, the diagram is dropped and the whole source shown (fence rows stay hidden except the cursor's own row, via anti-conceal); blank padding `virt_lines` below the first content row keep the block height. Without a diagram (pending/error), the block renders as an ordinary code block (fences hidden per `code.hide_fences`) plus the pending/error row as `virt_lines` below the LAST content row. The block's identity anchor mark sits on the opening fence row (FR-D17).
- **FR-D10 Placement `off`.** Blocks render as ordinary code blocks.
- **FR-D11 Errors.** Non-zero exit or timeout records an error for the job's key: the first stderr line, or `"timeout"`. A block with no diagram renders as a code block plus one `virt_lines` row `"[termaid] <message>"` in `MadaDiagramError`. A block that was showing a diagram keeps it, and the error row is added below it (FR-D17). An error is not retried for the same key until `:Mada render!`.
- **FR-D12 Pending state.** While a job runs for a block with no previous diagram in this buffer, the block renders as a code block plus one `virt_lines` row with `mermaid.pending_text` in `MadaDiagramPending`, unless `pending_text` is empty. A block that already shows a diagram keeps it instead (FR-D17).
- **FR-D13 Width.** termaid is asked for a maximum width equal to the width bucket, and for ASCII output when `ascii = true`. Output rows longer than the window are clipped by Neovim (virtual lines do not wrap); the plugin does not truncate.
- **FR-D14 Colourisation.** Diagram rows are split into chunks: characters in U+2500–U+259F, U+25A0–U+25FF, U+2190–U+21FF and the ASCII set `-|+<>^v` get `MadaDiagramLine`; all other characters get `MadaDiagramText`. Chunking happens once per result.
- **FR-D15 Insert mode.** Raw mode removes `conceal_lines` and `virt_lines` with the rest of the namespace; the source is fully visible and editable.
- **FR-D16 Multiple windows.** Marks are buffer-scoped. Width is taken from the window that triggered the render; other windows showing the same buffer may clip. Documented limitation for v1.
- **FR-D17 Keep the last diagram.** Each block keeps its latest diagram, identified by an anchor mark on its opening fence row so it survives edits elsewhere in the buffer and raw mode. When the block's key changes (source edited, width bucket crossed, `ascii` toggled), that diagram stays exactly as drawn until the new result is applied, so the block never switches to the pending state and back. Block state is dropped when the anchor's row is deleted or the buffer detaches.

Retired: FR-D2 (diagram kind detection), FR-D4 and FR-D5 (shared cache), FR-D9 (`below`/`above` placement), FR-D18 (pre-render on open).

### 4.6 Configuration (FR-C)

Serves UR-1 (works with defaults and themes itself) and lets users tune the UR-1 and UR-3 styling.

- **FR-C1** `setup(opts)` deep-merges `opts` into defaults and validates types; invalid values raise an error naming the key path.
- **FR-C2** `setup` may be called more than once; later calls replace the config and trigger a re-render of attached buffers.
- **FR-C3** Every glyph, group and threshold named in this document is configurable, and `README.md`'s defaults table lists every key with its default. Highlight groups are defined with `default = true` so colourschemes and users can override them.
- **FR-C5** `treesitter.highlight` accepts `"auto"`, `true`, `false` (FR-M10). Changing it via `setup` re-evaluates every attached buffer.
- **FR-C6 Zero configuration.** Without a `setup()` call, the plugin attaches with the defaults on the first matching `FileType`.

Retired: FR-C4 (buffer-local overrides).

### 4.7 Commands and API (FR-A)

Serves UR-1 and UR-6: rendering can be turned off and back on per buffer at any time.

- **FR-A1** `:Mada {enable|disable|toggle|render|clear}` with `!` on `render` meaning "re-run every diagram in the buffer, including failed ones". Completion for the subcommands.
- **FR-A2** Lua API: `setup(opts)`, `enable(buf?)`, `disable(buf?)`, `toggle(buf?)`, `render(buf?, opts?)` with `opts.force = true`, `clear(buf?)`, `is_enabled(buf?) → boolean`, `version() → string`. `buf` defaults to the current buffer.
- **FR-A3** `User` autocommand `MadaRendered` (data: `{buf, rows}`) after each render pass; `MadaDiagram` (data: `{buf, row, status}`, `row` being the opening fence row) after each mermaid result is applied.

### 4.8 Health (FR-H)

Serves UR-3 (the diagram backend works) and UR-5 (renders stay within budget).

`:checkhealth mada` reports: Neovim version ≥ 0.11 (error otherwise); `markdown` and `markdown_inline` parsers loadable (error); termaid executable found and a smoke render of `graph LR; A-->B` succeeds within 3 s (error); Python available when the backend is termaid (info); conflicting plugins loaded (warn); `conceallevel`/`concealcursor` overridden by user autocommands (warn); whether a tree-sitter highlighter is active for the current markdown buffer and who started it (info); render timings for the session's last 100 renders, p95 and max — this ring mixes non-edit renders (NFR-P1) with parse-bound edit renders, so it is labelled and checked against NFR-P10's looser budget, warning only when over it; current config summary (info).

## 5. Non-functional requirements

### 5.1 Performance (NFR-P)

Serves UR-5.

- **NFR-P0 Latency parity.** Budgets are per plugin callback, measured with `vim.uv.hrtime` on a 2020-class laptop against the reference document. p95 is over at least 200 samples; max is the worst sample. No plugin callback takes longer than 16 ms (one 60 Hz frame), except `:checkhealth`, an explicit `:Mada render!`, and the parse-bound events NFR-P8 and NFR-P10. A missed budget is a defect: measure, then optimise (`architecture.md` §13). P1, P7, P8 p95 raised to measured floors after pipe-table layout (2026-09-25).

| ID | Event | p95 | Max |
|---|---|---|---|
| NFR-P1 | Full viewport-range render, backend time excluded, with no pending edit: entering rendered mode, jump, page scroll, resize, `:Mada render` | 10 ms | 16 ms |
| NFR-P2 | Entering raw mode: one `nvim_buf_clear_namespace` plus two option sets | 1 ms | 2 ms |
| NFR-P3 | Cursor move (anti-conceal update); never calls the parser | 0.5 ms | 2 ms |
| NFR-P6 | Insert-mode keystroke: latency added over Neovim without the plugin, including a highlighter the plugin started (FR-M10) | 2 ms | 8 ms |
| NFR-P7 | One-line scroll (`<C-e>`, or `j` at the window edge): rendering the newly exposed rows | 1.5 ms | 4 ms |
| NFR-P8 | Opening the file: attach plus first render, including the initial tree-sitter parse and one-off query compilation | 50 ms | 60 ms |
| NFR-P9 | Neovim startup with no Markdown buffer: sourcing `plugin/mada.lua`, no plugin module loaded | 0.5 ms | — |
| NFR-P10 | Normal-mode edit, or leaving Insert, including tree-sitter's incremental reparse | 25 ms | 40 ms |

- **NFR-P4 Never block on the backend.** No synchronous `vim.system():wait()` outside `:checkhealth`.
- **NFR-P5 Memory.** Per-buffer state, including each block's latest diagram (FR-D17), is released on detach.

### 5.2 Non-interference (NFR-I)

Serves UR-4, UR-6.

- **NFR-I1 Row mapping.** The plugin never reorders, joins, splits or wraps rows. Every buffer row keeps its own screen row(s) and line number. Exceptions: rows hidden by `conceal_lines` (code fences with `code.hide_fences`, and Mermaid block fence rows likewise — a Mermaid block's content rows are never hidden), which reappear on the cursor row (FR-AC1) and in raw mode. Pipe tables add virtual lines when laid-out cell content exceeds a source row's screen rows; each table row keeps its own screen rows and line number.
- **NFR-I2 Coexistence.** The plugin sets and clears marks only in its own namespace. Its mark priorities stay below `vim.hl.priorities.diagnostics` (150), so diagnostics and other plugins' marks at default priority draw over its styling.

### 5.3 Compatibility (NFR-C)

Serves UR-1: the plugin works wherever it is installed.

- **NFR-C1 Compatibility.** Neovim ≥ 0.11.0, LuaJIT. No nvim-treesitter dependency; use `vim.treesitter` and bundled parsers. If nvim-treesitter is installed with newer parsers, the plugin must still work (query node names must match both bundled and current upstream grammars; see `architecture.md` §7).
- **NFR-C2 Portability.** Linux and macOS supported; Windows best-effort (`vim.fn.exepath` resolution, no shell quoting in argv).
- **NFR-C3 Distribution.** Users never need Fennel: the installed plugin contains only compiled Lua.

### 5.4 Quality (NFR-Q)

Serves UR-3, UR-4, UR-5.

- **NFR-Q1 Determinism.** Given the same buffer, window width and config, the set of marks is identical (golden-snapshot testable).
- **NFR-Q2 Robustness.** Parser errors (`ERROR` nodes) degrade to unrendered regions, never to Lua errors. Every extmark set is wrapped so an out-of-range row (buffer edited between parse and apply) is skipped, not raised.
- **NFR-Q3 Observability.** With `debug = true`, timings per render pass and backend job lifecycle are appended to `stdpath("log")/mada.log`.
- **NFR-Q4 Fail-safe.** An error in any plugin callback is caught. It disables the plugin for that buffer, returns the buffer to raw display, and sends one ERROR notification. It never interrupts editing and never repeats per keystroke.

## 6. Acceptance scenarios

| ID | UR | Scenario | Pass condition |
|---|---|---|---|
| AT-1 | UR-1, UR-6 | Open a markdown file, stay in Normal | Marks present in viewport; `changedtick` unchanged |
| AT-2 | UR-2 | Press `i` | Namespace empty; `conceallevel` restored |
| AT-3 | UR-2 | `<Esc>` | Marks present again as soon as `<Esc>` is processed, with no timer wait |
| AT-4 | UR-2, UR-4 | Move cursor onto a heading row | Row shows raw `#`; other rows unchanged |
| AT-5 | UR-4, UR-5 | Move cursor off | Row re-rendered without a parser call (assert via instrumented counter) |
| AT-6 | UR-5 | Scroll 500 rows one step at a time | After each step, every row in the viewport range carries its marks as soon as the step is processed, with no timer wait; rows never scrolled into range carry none |
| AT-7 | UR-3 | Mermaid flowchart with backend present | After job completes: fence rows concealed, `virt_lines` contain backend output, chunks coloured |
| AT-9 | UR-2, UR-3 | Cursor into the block | Source rows visible, diagram still shown |
| AT-10 | UR-3 | Backend missing | Block shown as code block; single WARN notify; health reports error |
| AT-11 | UR-3 | Backend exits 1 | Error virt_line shown; no retry until `render!` |
| AT-12 | UR-5 | Backend hangs | Timeout → error row after `timeout_ms`; no leaked process; editing never blocked |
| AT-13 | UR-3, UR-5 | Edit a rendered diagram in Insert, `<Esc>` | Previous diagram shown at once with no pending row; replaced when the new job completes |
| AT-14 | UR-6 | `:Mada disable` with two windows on the buffer | Both windows' options restored |
| AT-15 | UR-1 | `ascii = true` | No non-ASCII glyph in any mark except user-provided text |
| AT-16 | UR-5 | Undo a deletion in Normal mode | Marks for the restored text present as soon as `u` is processed, with no timer wait; no duplicate marks |
| AT-17 | UR-5 | File with 25,000 lines | Plugin not attached; notify on `:Mada enable` |
| AT-18 | UR-1, UR-3 | Golden snapshot fixtures, one per element class in UR-3 | `nvim_buf_get_extmarks(..., {details=true})` equals stored snapshot |
| AT-19 | UR-1 | `treesitter.highlight = "auto"`, no highlighter active | Highlighter started on attach; stopped on `:Mada disable`; snapshot of the plugin's namespace identical to AT-18 (highlighter marks live in another namespace) |
| AT-20 | UR-2, UR-4 | Highlighter already active (user started it), `"auto"` | Plugin does not restart or stop it; cursor row shows raw delimiters (`concealcursor=""` + strip) |
| AT-21 | UR-1 | `treesitter.highlight = false`, Neovim's runtime `ftplugin` starts a highlighter | Stopped on attach (re-checked via `vim.schedule`); buffer `syntax` forced to `""`; rendering unchanged except code-block injection colours; on `:Mada disable` the highlighter restarts and `syntax` is restored |
| AT-22 | UR-1 | `:edit` a Markdown file | Viewport marks exist as soon as `:edit` returns, before any timer fires |
| AT-23 | UR-2 | In Insert: `<C-o>zz`, `<C-o>:echo 1<CR>`, open and close the completion menu | Namespace stays empty throughout; render counter unchanged |
| AT-24 | UR-5 | Scripted session on the reference document, with and without the plugin: open, 200 × `j`, 20 × `<C-f>`, `G`, `gg`, 10 × (`dd`, `u`), `i` + 500 typed characters, `<Esc>` | Every budget in §5.1 met, including NFR-P10 on the `10 × (dd, u)` edits (the session's worst case) |
| AT-25 | UR-2, UR-4 | Cursor mid-window, below a hidden code fence; `i`, then `<Esc>` | Cursor buffer position and `topline` (`winsaveview()`) unchanged |
| AT-26 | UR-4, UR-6 | Attach, mode round-trip, then `:Mada disable` | Keymaps unchanged; options other than `conceallevel`/`concealcursor` (and the FR-M10 side effect) unchanged throughout; all restored after disable |
| AT-28 | UR-3 | Break a rendered diagram's syntax in Insert, `<Esc>` | Previous diagram stays; one error row added |
| AT-29 | UR-4 | Diagnostic on a styled span | The diagnostic's highlight is drawn over the plugin's styling |
| AT-30 | UR-1, UR-3 | Pipe table in a 50-column `wrap` window, including one at EOF | No blank rows inside the grid; `<C-e>`/`<C-y>` scroll through it line by line, never stuck; cursor row raw in place with table height unchanged; toggling `wrap`/`linebreak` re-lays it out |
| AT-31 | UR-1, UR-3 | `- [ ] a` and `1. [ ] a` | Unordered renders `[ ] a` starting at column 0 (bullet hidden); ordered keeps `1.` before the checkbox |
| AT-32 | UR-1, UR-3 | Pipe table wider than a 60-column `nowrap` window | Columns fit the window; long cells wrap into virtual lines under their row; separators align; widening the window re-lays it out; cursor row shows raw source, header separator stays |

Retired: AT-8 (cache hit), AT-27 (pre-render on open).

## 7. Visual specification

### 7.1 Style reference

glamour's dark style, mapped onto a buffer whose rows cannot move (NFR-I1):

| Element | glamour (dark) | mada | Why it differs |
|---|---|---|---|
| H1 | `#` removed; bold text on a coloured badge | Marker kept (hidden with `headings.conceal_markers`); bold heading colour | No padding cells are inserted |
| H2–H6 | `##` prefix kept; bold, coloured | Marker kept (hidden with `headings.conceal_markers`); bold heading colour | — |
| Emphasis, strong, strikethrough | Italic, bold, crossed out; delimiters removed | Same | — |
| Code span | Coloured, on a background, padded | `@markup.raw`; backticks hidden | No padding |
| Code block | Indented by a margin; syntax colours | Row background; fences hidden; language label; tree-sitter colours | No margin |
| Lists | `•` bullets; indent per level | Bullet glyph per nesting level; source indentation kept | Indentation comes from the source |
| Task items | `[✓]` / `[ ]` | Checkbox in place of the bullet | — |
| Block quote | `│` bar | `│` over each `>` | — |
| Thematic break | Short `--------` line | `─` across the window | — |
| Link | Text and URL, both styled | Text underlined; brackets and URL hidden (`links.show_url` shows the URL) | Less noise |
| Image | `Image: alt →` plus URL | `▣ alt` | Shorter |
| Table | Cells realigned, borders drawn | Aligned, word-wrapped to the window, header rule and column separators | — |
| Layout | Margins, blank lines between blocks, word wrap | None, except tables (FR-R13) | UR-4 |

### 7.2 Highlight groups and defaults

Most groups are defined with `default = true`; `MadaTableBorder` derives its foreground from the `Normal` background. Plugin-owned values refresh on setup and `ColorScheme`, while explicit colourscheme or user overrides win.

| Group | Default link / attrs | Used for |
|---|---|---|
| `MadaH1` | `@markup.heading.1`, bold | H1 text |
| `MadaH2`…`MadaH6` | `@markup.heading.2`…`.6`, bold | heading text |
| `MadaHeadingMarker` | `@markup.heading` | heading markers, setext underline |
| `MadaEmph` | `@markup.italic` | emphasis |
| `MadaStrong` | `@markup.strong` | strong |
| `MadaStrike` | `@markup.strikethrough` | strikethrough |
| `MadaCode` | `@markup.raw` | code spans |
| `MadaCodeBlock` | `ColorColumn` | fenced/indented block rows |
| `MadaCodeLang` | `Comment` | language label |
| `MadaLink` | `@markup.link.label`, underline | link text |
| `MadaUrl` | `@markup.link.url` | urls |
| `MadaImage` | `@markup.link` | image placeholder |
| `MadaBullet` | `@markup.list` | list markers |
| `MadaTaskTodo` | `@markup.list.unchecked` | `[ ]` |
| `MadaTaskDone` | `@markup.list.checked` | `[✓]` |
| `MadaTaskDoneText` | `Comment` | text of done tasks |
| `MadaQuote` | `@markup.quote` | `│` |
| `MadaQuoteText` | `@markup.quote` | quote body |
| `MadaRule` | `@punctuation.special` | thematic break |
| `MadaTableHead` | `@markup.heading`, bold | header cells |
| `MadaTableBorder` | foreground derived from `Normal` background, slightly lighter | table separators; a user highlight override is honored |
| `MadaComment` | `Comment` | HTML comments, front matter |
| `MadaDiagramLine` | `NonText` | box-drawing in diagrams |
| `MadaDiagramText` | `Normal` | labels in diagrams |
| `MadaDiagramPending` | `Comment`, italic | pending row |
| `MadaDiagramError` | `DiagnosticError` | error row |

### 7.3 Glyphs (Unicode default)

| Key | Default |
|---|---|
| `bullets` | `{"•", "◦", "▪"}` |
| `checkbox.todo` / `.done` | `[ ]` / `[✓]` |
| `quote` | `│` |
| `rule` | `─` |
| `image_icon` | `▣ ` |
| table vertical / horizontal / cross / left / right | `│` `─` `┼` `├` `┤` |
| table top-left / top-cross / top-right | `┌` `┬` `┐` |
| table bottom-left / bottom-cross / bottom-right | `└` `┴` `┘` |

### 7.4 ASCII fallbacks (`ascii = true`)

| Key | Fallback |
|---|---|
| `bullets` | `{"*", "-", "+"}` |
| `checkbox.done` | `[x]` |
| `quote` | `\|` |
| `rule` | `-` |
| `image_icon` | `[img] ` |
| table | `\|` vertical, `-` horizontal, `+` every junction and corner |

Diagram glyphs come from termaid: Unicode by default, ASCII (`--ascii`) when `ascii = true`.

## 8. Backend: termaid (v1)

- Invocation: `termaid --width <bucket> [--ascii] <extra args>` with source on stdin, plain text on stdout, no `--theme` (that emits ANSI).
- Language: Python 3, pure Python package, zero dependencies. `pip install termaid`, `pipx install termaid`, or `uvx termaid` (`mermaid.cmd` may be a list, e.g. `{"uvx", "termaid"}`).
- Coverage: flowchart, sequence, class, ER, state, block, gitGraph, gantt, architecture, pie (rendered as horizontal bars), treemap, mindmap, timeline, kanban, quadrant, XY chart, journey, packet.
- Startup cost: interpreter + import, tens of milliseconds per diagram; hidden by asynchrony and by keeping the last diagram (FR-D17). Whether that is fast enough is OQ-6.
- Known limits: approximate grid layout, Manhattan-only edge routing, wide diagrams compacted by `--width`; invalid syntax rarely fails outright, instead rendering partial or empty output, and empty output (after trimming) is what mada reports as the `"empty output"` error.
- Possible alternatives, each a new adapter if ever needed: `mermaid-text` (Rust, flowchart family, `--width`), `merman` (Rust, flowchart/class/ER/sequence/xychart), `mmdr` (Rust, SVG/PNG only — image placement, out of scope for v1).

## 9. Out of scope (v1)

Callouts; LaTeX; wiki-links; footnotes; per-window rendering (decoration provider); image backends; a persistent backend server process; layout changes such as reflow, margins or blank lines between blocks (NFR-I1); Mermaid `below`/`above` placement; per-buffer config overrides; Neovim 0.10 support; Windows CI.

Held back until measurements call for them (`architecture.md` §13): a shared diagram cache (in memory or on disk) and pre-rendering of off-screen diagrams (OQ-6); render debouncing; a job concurrency limit.

Deferred to v2 as an option, not a default: `inline = "treesitter"`, which skips the plugin's inline pass and leaves emphasis/code-span/link concealment to the runtime `highlights.scm`. Rejected as the v1 default because the result would depend on which query files are installed (NFR-Q1) and the highlighter is not active by default for markdown buffers.

## 10. Open questions (resolve during M0)

- **OQ-1** Does a row with `conceal_lines` still display its own `virt_lines`? If not, attach the diagram to the row before the opening fence with `virt_lines_above = false`, and if the fence is row 0, to the row after the closing fence with `virt_lines_above = true`.
  - **Resolved:** No: a `conceal_lines` row hides its own `virt_lines`; attach to a visible neighbour (architecture §8.2). **Revised (2026-09-26):** the attach-row approach broke scroll-up; the design was replaced with overlays over the block's own rows, nothing hidden (architecture §8.2). **Revised (2026-09-28):** that traded away fence hiding for a remaining scroll-up snap and cut-off diagrams; fence rows are hidden again (like code fences), and the diagram overlays only the content rows, with overflow as one `virt_lines` mark below the FIRST content row — always between two visible rows, never directly above a hidden one (architecture §8.2, §15).
- **OQ-2** Does `conceal_lines` honour `concealcursor`, and does `j`/`k` step onto concealed rows? Determines whether FR-AC3 needs extra cursor handling and how NFR-I1 is met.
  - **Resolved:** Yes: `concealcursor=""` reveals a `conceal_lines` row under the cursor, and `j`/`k` move by buffer line and land on it like any other row.
- **OQ-3** Exact node names of the bundled grammars at 0.11.x (`pipe_table_delimiter_cell`, `task_list_marker_*`, `inline` under headings). Confirm with `:InspectTree` and pin in the query files.
  - **Resolved:** All node names in architecture §7.2 match the grammars bundled with 0.12.5 exactly (checked by dumping parse trees for every construct); no renames, `query.fnl` uses them unchanged.
- **OQ-4** Does a plugin-started tree-sitter highlighter (FR-M10) meet NFR-P6 on the reference document and at `max_file_lines`? If not, `"auto"` gets a size limit above which it does not start the highlighter.
  - **Resolved:** No. On the 2,026-line reference document, starting the highlighter added +19 ms per Insert keystroke (the highlighter alone, without mada, +14 ms) — over NFR-P6 — so the default is `false`. `"auto"` keeps a size limit, `treesitter.auto_max_lines` (default 5000 lines), above which it does not start one.
  - **Revised (2026-09-28):** Neovim 0.12's `ftplugin/markdown.lua` starts a tree-sitter highlighter itself on every markdown buffer (`filetype plugin on`, Neovim's default); its markdown query hides fence rows with `conceal_lines`, which `conceallevel=2` activates, and made a full-page `<C-f>` redraw on `reference.md` 6–7× slower (Neovim alone 7.4 ms median, mada with the highlighter running 49.9 ms, mada after stopping it 6.7 ms). So `false` now stops that highlighter (and any other) on attach instead of merely not starting one.
- **OQ-5** Do `WinScrolled`, `TextChanged` and `CursorMoved` always fire before the redraw that shows their result, including for mouse scrolling, `smoothscroll`, and `:normal`/macro execution? FR-T3 relies on this. Where they do not, those cases need a decoration provider (`on_win`), which is currently out of scope.
  - **Resolved:** Yes for interactive input (RPC `nvim_input`: `j`, `<C-e>`, `<C-f>`, mouse wheel, `smoothscroll`, `:normal`); from `nvim_feedkeys` in a `-l` script the deferred events never fire (architecture §15).
  - **Resolved:** Yes, for real interactive input (verified via `nvim_input` over RPC to a `--listen`ed instance, reading `screenstring` from inside each autocommand callback without forcing a redraw first): for `j`, `<C-e>`, `<C-f>`, `nvim_input_mouse` wheel scroll, `<C-e>` with `smoothscroll`, and `:normal! 3j`, the screen content read inside `CursorMoved`/`WinScrolled`/`TextChanged` callbacks always still shows the pre-event content; the grid only updates to the new content after the callback returns. So the plugin's synchronous render inside these handlers lands before Neovim's redraw in every case tried. **Caveat found during M0:** this does not hold for `nvim_feedkeys(keys, "xt", false)` driven from a `-l` script (the harness `test/run.lua` uses) — in that mode `CursorMoved`, `WinScrolled` and `TextChanged` never fire at all (confirmed: counters stay 0 through `vim.wait`), because those are "deferred" autocommands checked only when Neovim's main loop reaches a safe/idle point, which a `-l` script never reaches until it exits. `ModeChanged` is not deferred and does fire synchronously via `feedkeys`. `test/helpers.fnl`'s `feed` compensates by explicitly firing the corresponding autocommand via `nvim_exec_autocmds` when its precondition changed (cursor row, `changedtick`, or window view) after feeding keys, so specs still exercise the plugin's real handlers; this is a test-harness affordance only, not a change to the plugin's own event wiring.
- **OQ-6** Is on-demand diagram rendering fast enough, measured from a block entering the view (or `<Esc>` after an edit) to its diagram being drawn? If not, add a shared cache first, then pre-rendering on open.
  - **Resolved:** Yes. Median 115 ms from scroll-in to diagram (max 174 ms), 93 ms after `<Esc>` (max 98 ms), measured with real termaid. No cache or pre-rendering needed.
