# Contributing

Dev shell: `nix develop path:.` (fennel, fnlfmt, fennel-ls, luacheck, neovim).

| Task | Command |
|---|---|
| Build | `nix build path:.` |
| Demo (Neovim with mada set up) | `nix run path:.` |
| All checks | `nix flake check path:.` |
| Format | `fnlfmt --fix src/mada/*.fnl` |
| Docs, one-shot | `nix run path:.#docs [-- PORT]` (default 8080) |
| Docs, live reload | `nix run path:.#watchdocs [-- PORT]` (default 8080) |

## Build

`src/mada/**/*.fnl` compiles to `lua/mada/**/*.lua`. `help/mada.txt` is
installed under `doc/`. `version.lua` is generated from `version` in
`flake.nix`. `plugin/mada.lua` is hand-written and must not `require` any
compiled module at startup. `nvimRequireCheck` (`nix/package.nix`) loads
every compiled module standalone, so each must `require` without depending
on another module's `setup()` having run first.

## Conventions

Layout and Fennel-for-LuaJIT rules: architecture §2. Tests: architecture
§15. Reference requirement IDs (FR-*, NFR-*, AT-*) in commits and tests.

## Docs site

Rendered by ohimark, separate from the Vim help under `help/`. `README.md`
is the home page; navigation mirrors `docs/`. New top-level Markdown must
be added to the fileset in `nix/docs.nix` to appear in `packages.docs`.
The live `docs` and `watchdocs` commands discover Markdown in the working tree and
exclude `test/`. Those files are isolated fixtures: their snapshots and line-specific
specs rely on exact content and placement, and several exercise parser boundaries.
They are test inputs rather than standalone docs pages.
