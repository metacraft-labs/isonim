## TBAR-M5b: editor-vendor derivation.
##
## Produces ``$out/tiptap.umd.js`` + ``$out/xterm.umd.js`` +
## ``$out/MANIFEST.txt`` by running ``yarn install --offline`` against
## a content-addressed ``fetchYarnDeps`` mirror and then driving the
## bundling step with the ``esbuild.config.mjs`` script in this
## directory.
##
## Inputs:
##
##   * ``../package.json`` / ``../yarn.lock`` — the yarn-managed
##     dependency set (see the parent flake.nix devShell for the
##     yarn 1 toolchain).
##   * ``./entry-tiptap.mjs`` / ``./entry-xterm.mjs`` /
##     ``./esbuild.config.mjs`` — the per-library entry scripts and
##     the bundling driver.
##
## When ``yarn.lock`` changes the ``offlineCache`` hash below MUST be
## refreshed.  The dev-shell carries ``prefetch-yarn-deps``; run
## ``prefetch-yarn-deps yarn.lock`` and paste the resulting SRI / nix
## hash here.
##
## For the full bump-a-dependency workflow (and the recipe for adding
## a brand-new JS library), see ``../docs/upgrading-js-dependencies.md``.

{
  lib,
  stdenv,
  fetchYarnDeps,
  fixup-yarn-lock,
  yarn,
  nodejs,
  esbuild,
}:

let
  src = ../.;

  offlineCache = fetchYarnDeps {
    yarnLock = ../yarn.lock;
    hash = "sha256-A/Flacyk8h4I3YnaiUTNGujmf/YDLIzOJoI/DJ8PB3k=";
  };
in
stdenv.mkDerivation {
  pname = "isonim-editor-vendor";
  version = "0.1.0";

  inherit src;

  nativeBuildInputs = [
    yarn
    nodejs
    fixup-yarn-lock
    esbuild
  ];

  # Bypass network access during the build — yarn pulls everything
  # from the content-addressed offline cache populated by
  # ``fetchYarnDeps`` above.  This is the standard nixpkgs pattern for
  # yarn-managed Nix derivations.
  configurePhase = ''
    runHook preConfigure

    export HOME=$(mktemp -d)
    export YARN_ENABLE_TELEMETRY=0
    yarn config --offline set yarn-offline-mirror "${offlineCache}"
    fixup-yarn-lock yarn.lock
    yarn install \
      --offline \
      --frozen-lockfile \
      --ignore-engines \
      --ignore-platform \
      --ignore-scripts \
      --no-progress \
      --non-interactive

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    mkdir -p $out
    export OUT_DIR=$out
    export REPO_ROOT=$PWD
    node nix/esbuild.config.mjs

    runHook postBuild
  '';

  # The build phase writes the UMD bundles + MANIFEST.txt directly
  # into ``$out``; there's no separate install step.
  dontInstall = true;

  meta = with lib; {
    description = "IsoNim editor-vendor UMD bundles (TipTap + xterm)";
    license = licenses.mit;
    platforms = platforms.unix;
  };
}
