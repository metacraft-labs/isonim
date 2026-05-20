# Package
version       = "0.1.0"
author        = "Metacraft Labs"
description   = "Isomorphic reactive web framework for Nim, inspired by SolidJS"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 2.0.0"
requires "faststreams >= 0.3.0"
requires "nim_everywhere >= 0.1.0"
# Phase A: structured logging for ACP/agent integration. Chronicles is the
# Metacraft house logger; downstream phases will route ACP transport,
# agent dispatch, and design-review backend telemetry through it.
requires "chronicles >= 0.10.3"
