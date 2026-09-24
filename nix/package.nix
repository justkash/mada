{ lib
, luajitPackages
, pname
, stdenvNoCC
, version
, vimUtils
}:

let
  srcDir = ../src;
  srcPrefix = "${toString srcDir}/";

  # Every `src/**/*.fnl` compiles to one Lua module. `nvimRequireCheck` then
  # asserts that each of them loads inside Neovim at build time, so a typo in a
  # module never reaches a user's config.
  fennelFiles = lib.filter
    (file: lib.hasSuffix ".fnl" (toString file))
    (lib.filesystem.listFilesRecursive srcDir);

  moduleName = file:
  let
    relative = lib.removeSuffix ".fnl" (lib.removePrefix srcPrefix (toString file));
    parts = lib.splitString "/" relative;
  in lib.concatStringsSep "." (if lib.last parts == "init" then lib.init parts else parts);
in
vimUtils.toVimPlugin (stdenvNoCC.mkDerivation {
  inherit pname version;

  __structuredAttrs = true;

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      (lib.fileset.fileFilter (file: file.hasExt "fnl") ../src)
      (lib.fileset.fileFilter (file: file.hasExt "lua") ../plugin)
      (lib.fileset.maybeMissing ../help)
    ];
  };

  nativeBuildInputs = [ luajitPackages.fennel ];

  buildPhase = ''
    runHook preBuild

    export HOME="$TMPDIR"
    export XDG_CACHE_HOME="$TMPDIR/.cache"
    mkdir -p "$XDG_CACHE_HOME" lua

    for file in $(find src -name '*.fnl' -type f); do
      dest="lua/''${file#src/}"
      dest="''${dest%.fnl}.lua"
      mkdir -p "$(dirname "$dest")"
      echo "compiling $file -> $dest"
      fennel --compile "$file" > "$dest"
    done

    # The version lives in flake.nix; expose it to the plugin instead of
    # repeating it in the Fennel source.
    echo 'return "${version}"' > "lua/${pname}/version.lua"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -r lua "$out/lua"
    cp -r plugin "$out/plugin"
    if [ -d help ]; then
      cp -r help "$out/doc"
    fi

    runHook postInstall
  '';

  nvimRequireCheck = map moduleName fennelFiles;

  meta = {
    description = "Render Markdown in place in Neovim";
    license = lib.licenses.mit;
  };
})
