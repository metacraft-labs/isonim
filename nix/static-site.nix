# The hermetic static-site builder: `lib.<system>.buildStaticSite`.
#
# It compiles a site's exporter program (a Nim file that renders the site
# with `isonim/static`, typically ending in `exportSite`) against this
# flake's own copy of IsoNim, runs it inside the Nix build sandbox (no
# network, no sibling checkouts, no home directory), and installs the
# directory it wrote as the derivation's output.
#
# `SOURCE_DATE_EPOCH` (https://reproducible-builds.org/specs/source-date-epoch/)
# is set for the exporter. By default it is the source's `lastModified`, so
# a flake input or `self` needs nothing more; a plain path has none and must
# pass `sourceDateEpoch`. With the wall clock out of the picture and the
# library ordering everything it writes, `nix build --rebuild` reproduces
# the output byte for byte (checks.<system>.static-site-fixture).
#
# Arguments:
#   name             derivation name
#   src              the site's source tree (holds the exporter and its content)
#   exporter         path of the exporter's main module, relative to `src`
#   outputDir        the directory the exporter writes, relative to `src`,
#                    passed to it as its first argument (default "public")
#   exporterArgs     further arguments after `outputDir`
#   nimPaths         extra Nim search paths (store paths of other Nim libraries)
#   nimFlags         extra `nim c` flags (`-d:...`)
#   sourceDateEpoch  seconds since the epoch; defaults to `src.lastModified`
#   nativeBuildInputs  tools the exporter runs (passed in by path, e.g. resvg)
#   env              extra environment variables for the exporter
{
  lib,
  stdenv,
  nim,
  isonimSrc,
  nimEverywhereSrc,
}:

{
  name,
  src,
  exporter,
  outputDir ? "public",
  exporterArgs ? [ ],
  nimPaths ? [ ],
  nimFlags ? [ ],
  sourceDateEpoch ?
    if builtins.isAttrs src && src ? lastModified then
      src.lastModified
    else
      throw "buildStaticSite (${name}): src has no lastModified; pass sourceDateEpoch",
  nativeBuildInputs ? [ ],
  env ? { },
}:

stdenv.mkDerivation (
  env
  // {
    inherit name src;
    nativeBuildInputs = [ nim ] ++ nativeBuildInputs;

    SOURCE_DATE_EPOCH = toString sourceDateEpoch;

    dontConfigure = true;
    # The output is a static site, not binaries: nothing to strip or patch.
    dontFixup = true;

    buildPhase = ''
      runHook preBuild
      export HOME="$TMPDIR"
      nim c --hints:off -d:release \
        --nimcache:"$TMPDIR/nimcache" \
        --out:"$TMPDIR/static-site-exporter" \
        --path:${isonimSrc}/src \
        --path:${nimEverywhereSrc}/src \
        ${lib.concatMapStringsSep " " (p: "--path:${lib.escapeShellArg (toString p)}") nimPaths} \
        ${lib.escapeShellArgs nimFlags} \
        ${lib.escapeShellArg exporter}
      "$TMPDIR/static-site-exporter" ${lib.escapeShellArgs ([ outputDir ] ++ exporterArgs)}
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      if [ ! -d ${lib.escapeShellArg outputDir} ]; then
        echo "buildStaticSite: the exporter wrote no ${outputDir}/ directory" >&2
        exit 1
      fi
      mkdir -p "$out"
      cp -R ${lib.escapeShellArg outputDir}/. "$out"/
      runHook postInstall
    '';
  }
)
