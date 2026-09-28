{
  description = "Render Markdown in place in Neovim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    ohimark = {
      url = "github:AltaraInc/ohimark";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, ohimark, ... }:
  let
    lib = nixpkgs.lib;

    # Single-source the plugin name and version. `pname` is also the Lua module
    # name (`require("mada")`), the `src/` module directory, the `plugin/`
    # entry file, and the `help/` help file: rename all of them together.
    pname = "mada";
    version = "0.1.0";

    # Named after the plugin so the overlay does not claim a generic `docs`
    # attribute in the package set of anyone who applies it.
    docsName = "${pname}-docs";

    overlay = final: _prev: {
      ${pname} = final.callPackage ./nix/package.nix { inherit pname version; };
      ${docsName} = final.callPackage ./nix/docs.nix {
        inherit pname;
        ohimark = ohimark.packages.${final.stdenv.hostPlatform.system}.default;
      };
      termaid = final.callPackage ./nix/termaid.nix { };
    };

    # `require("fennel")` for `-u NONE -l` scripts (the devShell and
    # checks.test) that run before the plugin is built: point Lua's search
    # path at the fennel-for-Lua source rather than the compiler binary.
    # The trailing `;;` keeps the interpreter's own compiled-in defaults.
    fennelLuaPath = pkgs: "${pkgs.luajitPackages.fennel}/share/lua/5.1/?.lua;;";

    # Neovim wrapped with the plugin installed and configured: a runnable demo
    # and a smoke test that the compiled Lua really loads. termaid goes on its
    # PATH so Mermaid blocks in the demo actually render.
    mkNvim = pkgs: pkgs.neovim.override {
      configure = {
        packages.${pname}.start = [ pkgs.${pname} ];
        customLuaRC = "require('${pname}').setup()";
      };
      extraMakeWrapperArgs = "--suffix PATH : ${pkgs.termaid}/bin";
    };

    supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    forEachSupportedSystem = f: lib.genAttrs supportedSystems (system: f {
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ overlay ];
      };
    });
  in {
    overlays.default = overlay;

    packages = forEachSupportedSystem ({ pkgs }: {
      docs = pkgs.${docsName}.docs;
      default = pkgs.${pname};
      ${pname} = pkgs.${pname};
      nvim = mkNvim pkgs;
      termaid = pkgs.termaid;
    });

    apps = forEachSupportedSystem ({ pkgs }:
    let
      # A NixVim (or other) shell config can export VIMINIT to source its own
      # init; that leaks into `nix run` and makes the demo load the user's
      # personal config instead of the plugin's, if VIMINIT is left as-is.
      # unset it before exec'ing the wrapped nvim so the demo is always
      # self-contained.
      nvimNoViminit = toString (pkgs.writeShellScript "${pname}-nvim" ''
        unset VIMINIT
        exec ${mkNvim pkgs}/bin/nvim "$@"
      '');
      app = {
        type = "app";
        program = nvimNoViminit;
        meta.description = "Neovim with ${pname} installed and set up";
      };
    in {
      default = app;
      # Both take the port to listen on as an optional argument, defaulting
      # to 8080 (`nix run path:.#docs -- 9000`).
      docs = {
        type = "app";
        program = lib.getExe pkgs.${docsName}.serve;
        meta.description = "Render and serve ${pname} Markdown documentation";
      };
      watchdocs = {
        type = "app";
        program = lib.getExe pkgs.${docsName}.watch;
        meta.description = "Serve ${pname} Markdown documentation, re-rendering on change";
      };
      nvim = app;
      # AT-24: latency of a scripted session on the reference document, with
      # and without the plugin. Machine-specific, so not in `checks`.
      bench = {
        type = "app";
        program = toString (pkgs.writeShellScript "${pname}-bench" ''
          export MADA_RTP=${pkgs.${pname}}
          export PATH=${pkgs.neovim-unwrapped}/bin:$PATH
          exec nvim --headless -u NONE -l ${./bench/latency.lua} ${./test/fixtures/reference.md}
        '');
        meta.description = "Run the AT-24 latency benchmark against the reference document";
      };
    });

    checks = forEachSupportedSystem ({ pkgs }: {
      default = pkgs.${pname};
      docs = pkgs.${docsName}.docs;

      # `fnlfmt --check` prints "Not formatted: <file>" for a misformatted
      # file but always exits 0, so `-exec fnlfmt --check {} +` never fails
      # this check. Compare `fnlfmt`'s own output against the file instead:
      # any difference is a formatting defect.
      format = pkgs.runCommand "${pname}-format" {
        nativeBuildInputs = [ pkgs.fnlfmt ];
      } ''
        fail=0
        check() {
          while IFS= read -r -d "" f; do
            if ! fnlfmt "$f" | cmp -s - "$f"; then
              echo "Not formatted: $f"
              fail=1
            fi
          done < <(find "$1" -name '*.fnl' -type f -print0)
        }
        check ${./src}
        ${lib.optionalString (builtins.pathExists ./test) ''
          check ${./test}
        ''}
        if [ "$fail" -ne 0 ]; then
          exit 1
        fi
        touch $out
      '';

      lint = pkgs.runCommand "${pname}-lint" {
        nativeBuildInputs = [ pkgs.luajitPackages.luacheck ];
      } ''
        luacheck ${./plugin} --globals vim --no-color
        ${lib.optionalString (builtins.pathExists ./test/run.lua) ''
          luacheck ${./test/run.lua} --globals vim --no-color
        ''}
        ${lib.optionalString (builtins.pathExists ./bench/latency.lua) ''
          luacheck ${./bench/latency.lua} --globals vim --no-color
        ''}
        touch $out
      '';

      # Builds the plugin, then runs each test/*_spec.fnl in its own headless
      # nvim process (architecture.md §15). A no-op (touch $out) until the
      # other worker lands test/run.lua and the first spec.
      test = pkgs.runCommand "${pname}-test" {
        nativeBuildInputs = [ pkgs.neovim-unwrapped ];
      } ''
        # Copy the test/ fileset into a writable dir; cp -r preserves the
        # executable bit that test/bin/fake-termaid needs.
        cp -r ${lib.fileset.toSource { root = ./.; fileset = ./test; }} work
        chmod -R u+w work
        cd work

        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        export MADA_RTP=${pkgs.${pname}}
        export LUA_PATH="${fennelLuaPath pkgs}"

        export LC_ALL=C
        shopt -s nullglob
        specs=(test/*_spec.fnl)
        for spec in "''${specs[@]}"; do
          echo "=== $spec ==="
          nvim --headless -u NONE -l test/run.lua "$spec"
        done

        touch $out
      '';
    });

    # Import this module into a NixVim configuration to install and configure
    # the plugin declaratively. Each option maps to one `setup()` key.
    nixvimModules.default = { config, lib, pkgs, ... }:
    let
      cfg = config.programs.${pname};
    in {
      options.programs.${pname} = {
        enable = lib.mkEnableOption "the ${pname} Neovim plugin";

        settings = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
          description = "Options passed to require('mada').setup(); see README.";
        };
      };

      config = lib.mkIf cfg.enable {
        extraPlugins = [ self.packages.${pkgs.stdenv.hostPlatform.system}.default ];

        extraConfigLua = "require('${pname}').setup(${lib.generators.toLua { } cfg.settings})";
      };
    };

    devShells = forEachSupportedSystem ({ pkgs }: {
      default = pkgs.mkShell {
        packages = with pkgs; [
          fennel-ls
          fnlfmt
          luajitPackages.fennel
          luajitPackages.luacheck
          neovim
          termaid
        ];

        # So `nvim -u NONE -l ...` scripts (bench, ad-hoc testing) can
        # `require("fennel")` without the plugin being built first.
        LUA_PATH = fennelLuaPath pkgs;
      };
    });
  };
}
