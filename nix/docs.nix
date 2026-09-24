{ lib
, runCommand
, writeShellApplication
, coreutils
, findutils
, static-web-server
, watchexec
, pname
, ohimark
}:

let
  # The Markdown this site renders. Listed explicitly rather than handing
  # `ohimark` the whole project: this fileset decides what reaches the build
  # sandbox, so a broader one would copy build outputs into the store and
  # rebuild the site on unrelated source changes. New top-level Markdown has
  # to be added here to appear in `packages.docs`; the `docs` and `watchdocs`
  # apps read the working tree directly and need no such list.
  docsRoot = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../README.md
      ../docs
    ];
  };

  # The sealed site: this project's Markdown, rendered by `ohimark` with
  # `README.md` as the home page.
  docs = runCommand "${pname}-docs" { } ''
    ${lib.getExe ohimark} --out $out ${docsRoot}
  '';

  # The wrappers below serve the *working tree* rather than the sealed `docs`
  # derivation above, so an edit is visible without a Nix rebuild. Both take
  # the port to listen on as an optional positional argument, and agree on
  # what to render through the environment:
  #
  #   OHIMARK_DOCS_REPO   working tree to render (default: `$PWD`)
  #   OHIMARK_DOCS_STATE  cache directory holding the served site
  #
  # The working tree defaults to `$PWD` rather than a VCS toplevel because the
  # checkout may be Pijul or untracked, where there is no git repository to
  # ask; `ohimark` honors `.gitignore` and `.ignore` either way, so build
  # outputs stay out of the site.
  #
  # `OHIMARK_DOCS_STATE` defaults to a stable path, reused across runs rather
  # than created fresh each time, because neither wrapper has a reliable place
  # to clean one up: `serve` execs into the server and never regains control,
  # `watch`'s trap only reaps the server it backgrounded, and a trap would not
  # fire on `SIGKILL` or a crash in any case. Reuse is safe because `build`
  # replaces the served directory's contents on every render, so nothing stale
  # survives. Overriding the variable is what lets two servers on different
  # ports run without sharing one directory.

  # `PORT` handling, shared so both wrappers present the same command line:
  # `NAME [PORT]`, defaulting to 8080. Validated here rather than left to
  # static-web-server so that `watchdocs`, which only passes the port on to
  # the server it backgrounds, still rejects a bad one up front.
  portArg = name: ''
    if [ "$#" -gt 1 ]; then
      echo "usage: ${name} [PORT]" >&2
      exit 2
    fi
    port="''${1-8080}"
    case "$port" in
      "" | *[!0-9]*)
        echo "${name}: PORT must be a number, got '$port'" >&2
        exit 2
        ;;
    esac
  '';

  # One render of the working tree into `$OHIMARK_DOCS_STATE/site`.
  build = writeShellApplication {
    name = "${pname}-docs-build";
    runtimeInputs = [ coreutils findutils ];
    text = ''
      repo="''${OHIMARK_DOCS_REPO:-$PWD}"
      state="''${OHIMARK_DOCS_STATE:?must be set by ${pname}-docs}"

      # `--out` has to be empty or absent, so each render goes to a fresh
      # staging directory and then replaces the served directory's
      # *contents*: static-web-server resolves its root once at startup, so
      # that directory has to keep its identity across rebuilds.
      mkdir -p "$state/site"
      rm -rf "$state/next"
      ${lib.getExe ohimark} --out "$state/next" --root README.md "$repo"
      find "$state/site" -mindepth 1 -delete
      cp -R "$state/next/." "$state/site/"
      rm -rf "$state/next"

      echo "${pname}: rendered $repo into $state/site" >&2
    '';
  };

  # `nix run path:.#docs [-- PORT]`: render the working tree once, then serve it.
  serve = writeShellApplication {
    name = "${pname}-docs";
    runtimeInputs = [ build static-web-server ];
    text = ''
      ${portArg "${pname}-docs"}
      OHIMARK_DOCS_REPO="''${OHIMARK_DOCS_REPO:-$PWD}"
      OHIMARK_DOCS_STATE="''${OHIMARK_DOCS_STATE:-''${XDG_CACHE_HOME:-$HOME/.cache}/${pname}/docs}"
      export OHIMARK_DOCS_REPO OHIMARK_DOCS_STATE

      ${pname}-docs-build

      echo "${pname}: serving http://127.0.0.1:$port" >&2
      # Cache headers are on by default, which lets a browser hold a stale page
      # or stylesheet across a rebuild — exactly what `watchdocs` exists to
      # avoid, and misleading even for a one-shot `docs` run after an edit.
      exec static-web-server --host 127.0.0.1 --port "$port" \
        --cache-control-headers false \
        --root "$OHIMARK_DOCS_STATE/site"
    '';
  };

  # `nix run path:.#watchdocs [-- PORT]`: the server above, plus a re-render
  # on every change.
  watch = writeShellApplication {
    name = "${pname}-watchdocs";
    runtimeInputs = [ build serve watchexec ];
    text = ''
      ${portArg "${pname}-watchdocs"}
      OHIMARK_DOCS_REPO="''${OHIMARK_DOCS_REPO:-$PWD}"
      OHIMARK_DOCS_STATE="''${OHIMARK_DOCS_STATE:-''${XDG_CACHE_HOME:-$HOME/.cache}/${pname}/docs}"
      export OHIMARK_DOCS_REPO OHIMARK_DOCS_STATE

      # The watcher depends on the server: start it in the background (it
      # performs the first render), then re-render on change. `--postpone`
      # suppresses watchexec's own run at startup, which that first render
      # already covered; its default ignores honor `.gitignore`/`.ignore`,
      # and the cache directory lives outside the tree, so neither feeds the
      # watcher its own output.
      ${pname}-docs "$port" &
      server=$!
      trap 'kill "$server" 2>/dev/null || true' EXIT INT TERM

      watchexec \
        --watch "$OHIMARK_DOCS_REPO" \
        --debounce 200ms \
        --postpone \
        --on-busy-update restart \
        -- ${pname}-docs-build
    '';
  };
in
{
  inherit docs serve watch;
}
