# mada

`mada` (short for MArkDown Artist) renders Markdown buffers in place: styled
in Normal mode, raw in Insert mode, Mermaid fences as diagrams.

Pre-release, not yet functional. Design: [docs/requirements.md](docs/requirements.md),
[docs/architecture.md](docs/architecture.md). Implementation follows the
milestones in architecture §16.

## What it does

- Rendered in Normal mode; raw Markdown in Insert, Replace and Select mode.
- Cursor row always shown raw, even while rendered (anti-conceal).
- Mermaid fences render as text diagrams via [termaid](https://github.com/fasouto/termaid), asynchronously, in place of the source.
- Minimal, [glamour](https://github.com/charmbracelet/glamour)-inspired look: no reflow, no margins, no word wrap — rows still map 1:1 to file lines.
- Never modifies the buffer: text, undo history, `modified` and `changedtick` are untouched.

```mermaid
stateDiagram-v2
    Rendered --> Raw: Insert / Replace / Select
    Raw --> Rendered: leave Insert / Replace / Select
    Raw --> Raw: Ctrl-O
```

## Requirements

| Component | Needs |
|---|---|
| Neovim | ≥ 0.11 (bundled `markdown`/`markdown_inline` parsers; no nvim-treesitter) |
| Mermaid | [termaid](https://github.com/fasouto/termaid) on `$PATH` — `pip install termaid`, or `mermaid.cmd = {"uvx", "termaid"}` |
| Build | Nix, or Fennel, to compile `src/` to Lua |

Stays off when render-markdown.nvim or markview.nvim is also loaded (FR-M9).

## Install

### Nix flake

```nix
{
  inputs.mada.url = "path:/path/to/mada"; # or a git url
  # ...
  programs.neovim.plugins = [ inputs.mada.packages.${pkgs.system}.default ];
}
```

### NixVim

```nix
{
  imports = [ inputs.mada.nixvimModules.default ];
  programs.mada = {
    enable = true;
    settings.ascii = true;
  };
}
```

### Without Nix

Compile the Fennel sources to `lua/`:

```sh
for file in $(find src -name '*.fnl' -type f); do
  dest="lua/${file#src/}"
  dest="${dest%.fnl}.lua"
  mkdir -p "$(dirname "$dest")"
  fennel --compile "$file" > "$dest"
done
```

Put the repo on Neovim's runtimepath. Copy `help/` to `doc/` and run
`:helptags` on it. Without the Nix build, `require("mada").version()`
reports `"dev"`.

## Configuration

Zero-config: `mada` attaches on `FileType markdown` without a `setup()`
call. To change any key, call `setup()` with a subset of the defaults
below (deep-merged; safe to call again — the last call wins):

```lua
require("mada").setup({
  enabled = true,
  filetypes = { "markdown" },
  max_file_lines = 20000,
  raw_modes = { "i", "R", "s", "S", "\19" },  -- first char of mode(1); "\19" is CTRL-S
  anti_conceal = true,
  ascii = false,                              -- ASCII glyphs, and termaid --ascii
  treesitter = { highlight = "auto" },        -- "auto" | true | false
  viewport_margin = 20,
  headings = { conceal_markers = false },
  bullets = { "•", "◦", "▪" },
  checkbox = { todo = "[ ]", done = "[✓]" },
  quote = "│",
  rule = "─",
  image_icon = "▣ ",
  code = { hide_fences = true, show_language = true },
  links = { conceal = true, show_url = false },
  tables = {
    style = "unicode",                        -- "unicode" | "off"
    border = { v = "│", h = "─", cross = "┼", left = "├", right = "┤" },
  },
  mermaid = {
    placement = "replace",                    -- "replace" | "off"
    cmd = { "termaid" },                      -- string or list
    args = {},
    width_bucket = 10,
    timeout_ms = 5000,
    pending_text = "rendering diagram…",
  },
  debug = false,
})
```

Glyphs, highlight groups and their defaults: requirements §7.

## Docs

- [docs/requirements.md](docs/requirements.md) — what it does and why.
- [docs/architecture.md](docs/architecture.md) — how it's built.
- [docs/contribution.md](docs/contribution.md) — dev shell, build, checks.

