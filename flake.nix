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
    };

    # Neovim wrapped with the plugin installed and configured: a runnable demo
    # and a smoke test that the compiled Lua really loads.
    mkNvim = pkgs: pkgs.neovim.override {
      configure = {
        packages.${pname}.start = [ pkgs.${pname} ];
        customLuaRC = "require('${pname}').setup()";
      };
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
    });

    apps = forEachSupportedSystem ({ pkgs }:
    let
      app = {
        type = "app";
        program = "${mkNvim pkgs}/bin/nvim";
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
    });

    checks = forEachSupportedSystem ({ pkgs }: {
      default = pkgs.${pname};
      docs = pkgs.${docsName}.docs;

      format = pkgs.runCommand "${pname}-format" {
        nativeBuildInputs = [ pkgs.fnlfmt ];
      } ''
        find ${./src} -name '*.fnl' -type f -exec fnlfmt --check {} +
        touch $out
      '';

      lint = pkgs.runCommand "${pname}-lint" {
        nativeBuildInputs = [ pkgs.luajitPackages.luacheck ];
      } ''
        luacheck ${./plugin} --globals vim --no-color
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
        ];
      };
    });
  };
}
