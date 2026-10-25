#!/usr/bin/env bash
# Regenerates the tiny image fixtures read by tests/test_static_image_meta.nim.
# They are real encoder output, so the header readers are checked against
# files written by an independent implementation (libvips and the codecs it
# links), not against bytes written by hand the way the reader expects.
#
# Usage, from the repository root:
#   nix develop .#content-tools --command bash tests/fixtures/images/generate.sh
set -euo pipefail

vips="${ISONIM_VIPS:?enter nix develop .#content-tools}"
out="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
run() { env -i VIPS_CONCURRENCY=1 "$vips" "$@"; }

# A 7x5 RGB image of seeded noise, and a 7x10 strip read as two 7x5 frames.
noise() { # width height output
  for band in 1 2 3; do
    run gaussnoise "$work/n$band.v" "$1" "$2" --mean 128 --sigma 60 --seed "$band"
  done
  run bandjoin "$work/n1.v $work/n2.v $work/n3.v" "$work/joined.v"
  run cast "$work/joined.v" "$3" uchar
}
noise 7 5 "$work/rgb.v"
noise 7 10 "$work/strip.v"

run copy "$work/rgb.v" "$out/tiny.png[keep=none]"
run copy "$work/rgb.v" "$out/tiny.jpg[keep=none]"
run copy "$work/rgb.v" "$out/tiny.gif[keep=none]"
run copy "$work/rgb.v" "$out/tiny-lossy.webp[keep=none]"
run copy "$work/rgb.v" "$out/tiny-lossless.webp[lossless,keep=none]"
run copy "$work/rgb.v" "$out/tiny.avif[keep=none]"
run copy "$work/strip.v" "$out/tiny-animated.webp[page-height=5,keep=none]"
# The GIF saver takes the frame height from the image, not an option: load
# the animated WebP with all its pages and save that.
run copy "$out/tiny-animated.webp[n=-1]" "$out/tiny-animated.gif[keep=none]"
