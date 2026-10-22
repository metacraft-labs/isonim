## isonim/static/csp -- Content-Security-Policy with per-page inline-script
## hashes (CSP Level 3, https://www.w3.org/TR/CSP3/).
##
## A strict CSP that forbids `'unsafe-inline'` must instead allow each
## inline `<script>` a page emits by the SHA-256 of its exact body
## (`'sha256-<base64>'`, https://www.w3.org/TR/CSP3/#grammardef-hash-source).
## Those bodies are known at build time, so this module hashes them and
## folds the hash sources into the `script-src` directive of a configured
## policy, emitting either a `<meta http-equiv="Content-Security-Policy">`
## tag for a static page's head or the same value for an HTTP header.
##
## Everything here is pure (a self-contained SHA-256 and `std/base64`, no
## platform imports), so hashing and policy assembly run identically under
## `nim c` and `nim js`. CSP is off by default (`defaultCspConfig`); a site
## opts in with its own `CspConfig`. Moved from isonim-docs
## (`src/core/csp.nim`, with the `CspDirective`/`CspConfig` types and their
## two constructors from `src/core/config.nim`), which now re-exports it.

import std/[base64, strutils]
import ../ssr/escape

type
  CspDirective* = object
    ## One directive: a name (`default-src`, `script-src`, ...) and its
    ## ordered source list. Plain data, so a site composes a policy without
    ## this module knowing any origin; per-page inline-script hashes are
    ## folded into `script-src` when the policy is emitted.
    name*: string
    sources*: seq[string]

  CspConfig* = object
    ## A site's policy. `enabled` is the master switch (off by default, so
    ## a site that configures nothing emits no policy); `directives` are the
    ## base directives. The per-page hash sources are added at emit time,
    ## never stored here.
    enabled*: bool
    directives*: seq[CspDirective]

proc defaultCspConfig*(): CspConfig =
  ## CSP disabled: no meta tag, no header value.
  CspConfig(enabled: false, directives: @[])

proc strictCspConfig*(): CspConfig =
  ## A ready-made strict starting point a site can adopt or extend: no
  ## `'unsafe-inline'` on scripts (inline scripts ride in via their per-page
  ## hashes), everything else same-origin. It names no host, only `'self'`.
  ## `object-src 'none'` and `base-uri 'self'` close the usual injection
  ## escape hatches.
  CspConfig(enabled: true, directives: @[
    CspDirective(name: "default-src", sources: @["'self'"]),
    CspDirective(name: "script-src", sources: @["'self'"]),
    CspDirective(name: "style-src", sources: @["'self'", "'unsafe-inline'"]),
    CspDirective(name: "img-src", sources: @["'self'", "data:"]),
    CspDirective(name: "connect-src", sources: @["'self'"]),
    CspDirective(name: "object-src", sources: @["'none'"]),
    CspDirective(name: "base-uri", sources: @["'self'"]),
  ])

# --- SHA-256 (pure, dual-target) -------------------------------------------
#
# A from-scratch FIPS-180-4 SHA-256 rather than a stdlib call: Nim's
# `std/checksums` ships only sha1/md5 (neither valid for a CSP hash-source,
# which spec-restricts to sha256/384/512), and pulling `nimcrypto` would add
# a dep the framework doesn't otherwise carry AND wouldn't compile on the JS
# target. All arithmetic is `uint32` with explicit 32-bit masking so the
# wraparound is identical on the C target and on `nim js` (where a `uint32`
# is a JS number); the test pins it to the standard NIST vectors on both.

const sha256K: array[64, uint32] = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
  0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
  0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
  0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
  0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

const mask32 = 0xFFFFFFFF'u32

proc rotr(x: uint32; n: int): uint32 {.inline.} =
  ## 32-bit right rotate. Both halves are masked so the JS target (where a
  ## left shift can widen past 32 bits) agrees with the C target.
  ((x shr uint32(n)) or (x shl uint32(32 - n))) and mask32

proc sha256Digest*(msg: string): string =
  ## The raw 32-byte SHA-256 digest of `msg`, as a `string` of bytes (each
  ## `char` one octet) -- the form `std/base64.encode` consumes. `msg` is
  ## treated as an opaque byte sequence (the caller passes an already-UTF-8
  ## script body), matching how a browser hashes the script text.
  var h = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
           0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]

  # Pre-processing: append 0x80, pad with 0x00 to 56 mod 64, then the
  # 64-bit big-endian bit length.
  var data = newSeq[uint8](msg.len)
  for i in 0 ..< msg.len:
    data[i] = uint8(ord(msg[i]) and 0xFF)
  let bitLen = uint64(msg.len) * 8'u64
  data.add(0x80'u8)
  while data.len mod 64 != 56:
    data.add(0x00'u8)
  for shift in countdown(56, 0, 8):
    data.add(uint8((bitLen shr uint64(shift)) and 0xFF'u64))

  var w: array[64, uint32]
  var blockStart = 0
  while blockStart < data.len:
    for t in 0 ..< 16:
      let o = blockStart + t * 4
      w[t] = ((uint32(data[o]) shl 24) or (uint32(data[o + 1]) shl 16) or
              (uint32(data[o + 2]) shl 8) or uint32(data[o + 3])) and mask32
    for t in 16 ..< 64:
      let s0 = rotr(w[t - 15], 7) xor rotr(w[t - 15], 18) xor (w[t - 15] shr 3'u32)
      let s1 = rotr(w[t - 2], 17) xor rotr(w[t - 2], 19) xor (w[t - 2] shr 10'u32)
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) and mask32

    var a = h[0]; var b = h[1]; var c = h[2]; var d = h[3]
    var e = h[4]; var f = h[5]; var g = h[6]; var hh = h[7]
    for t in 0 ..< 64:
      let S1 = rotr(e, 6) xor rotr(e, 11) xor rotr(e, 25)
      let ch = (e and f) xor ((not e) and g)
      let temp1 = (hh + S1 + ch + sha256K[t] + w[t]) and mask32
      let S0 = rotr(a, 2) xor rotr(a, 13) xor rotr(a, 22)
      let maj = (a and b) xor (a and c) xor (b and c)
      let temp2 = (S0 + maj) and mask32
      hh = g; g = f; f = e
      e = (d + temp1) and mask32
      d = c; c = b; b = a
      a = (temp1 + temp2) and mask32

    h[0] = (h[0] + a) and mask32
    h[1] = (h[1] + b) and mask32
    h[2] = (h[2] + c) and mask32
    h[3] = (h[3] + d) and mask32
    h[4] = (h[4] + e) and mask32
    h[5] = (h[5] + f) and mask32
    h[6] = (h[6] + g) and mask32
    h[7] = (h[7] + hh) and mask32
    blockStart += 64

  result = newString(32)
  for i in 0 ..< 8:
    result[i * 4 + 0] = char((h[i] shr 24) and 0xFF'u32)
    result[i * 4 + 1] = char((h[i] shr 16) and 0xFF'u32)
    result[i * 4 + 2] = char((h[i] shr 8) and 0xFF'u32)
    result[i * 4 + 3] = char(h[i] and 0xFF'u32)

proc sha256Base64*(msg: string): string =
  ## Standard base64 (with `+`/`/` and `=` padding, per the CSP grammar) of
  ## the SHA-256 digest of `msg`.
  base64.encode(sha256Digest(msg))

proc cspHashSource*(scriptBody: string): string =
  ## The `'sha256-<base64>'` CSP source expression for one inline script's
  ## exact body -- the token a browser matches against the text between a
  ## `<script>` element's tags.
  "'sha256-" & sha256Base64(scriptBody) & "'"

# --- policy assembly -------------------------------------------------------

const scriptSrcName = "script-src"

proc withScriptHashes(directives: seq[CspDirective];
    inlineScriptBodies: seq[string]): seq[CspDirective] =
  ## Returns `directives` with a `'sha256-...'` source appended to
  ## `script-src` for each inline script body (deduped -- two pages sharing
  ## a script share a hash). Creates a `script-src 'self'` directive if the
  ## consumer configured none, so an inline script is never left unhashed.
  var hashes: seq[string]
  for body in inlineScriptBodies:
    let h = cspHashSource(body)
    if h notin hashes: hashes.add h
  result = @[]
  var sawScriptSrc = false
  for d in directives:
    if d.name == scriptSrcName:
      sawScriptSrc = true
      var merged = d
      for h in hashes:
        if h notin merged.sources: merged.sources.add h
      result.add merged
    else:
      result.add d
  if not sawScriptSrc and hashes.len > 0:
    result.add CspDirective(name: scriptSrcName, sources: @["'self'"] & hashes)

proc serializeDirective(d: CspDirective): string =
  result = d.name
  for s in d.sources:
    result.add ' '
    result.add s

proc buildCspPolicy*(cfg: CspConfig; inlineScriptBodies: seq[string]): string =
  ## The policy string (the value of a `Content-Security-Policy` header or
  ## the `content` of its meta tag): the configured directives, with the
  ## per-page inline-script hashes folded into `script-src`, joined by
  ## `; `. Returns "" when CSP is disabled.
  if not cfg.enabled: return ""
  let dirs = withScriptHashes(cfg.directives, inlineScriptBodies)
  var parts: seq[string]
  for d in dirs:
    if d.name.len > 0: parts.add serializeDirective(d)
  parts.join("; ")

proc cspHeaderValue*(cfg: CspConfig; inlineScriptBodies: seq[string]): string =
  ## Alias for `buildCspPolicy` read as the HTTP `Content-Security-Policy`
  ## header value -- what a server (an nginx SSR module, a search endpoint)
  ## sets so the policy also governs the pre-meta bytes a header (unlike a
  ## meta tag) covers. Same string; named for the delivery channel.
  buildCspPolicy(cfg, inlineScriptBodies)

proc renderCspMetaHtml*(cfg: CspConfig; inlineScriptBodies: seq[string]): string =
  ## The `<meta http-equiv="Content-Security-Policy">` tag for the static
  ## head, or "" when CSP is disabled. Emit it before any inline script in
  ## `<head>` (right after `<meta charset>`), so every script that follows it
  ## is governed by the policy. The policy value is
  ## attribute-escaped defensively -- hashes/keywords never contain `"`, but
  ## a consumer-supplied host source is untrusted text.
  let policy = buildCspPolicy(cfg, inlineScriptBodies)
  if policy.len == 0: return ""
  "<meta http-equiv=\"Content-Security-Policy\" content=\"" &
    escapeAttr(policy) & "\" />"
