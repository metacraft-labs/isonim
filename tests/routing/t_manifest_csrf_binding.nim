## test_csrf_exemption_bound_to_signature (isonim-auth.md §2.5;
## isonim-routing-server-functions.md, "Typed Route Manifest"): the route
## manifest refuses, at compile time, a signature-bound CSRF exemption
## (every one but `csp-report`) on an entry whose `auth` is not
## `aSignature`, so an exemption cannot admit a session's cross-site request
## without a token. The check runs on the entry's EVALUATED values, so the
## spelling does not matter.
##
## Each fixture is compiled (front end and code generation, nothing linked).
## Refused with the binding's message: `email-webhook` on `aSession`,
## `aPublic` and an `any` entry's default `aOptional`; through a named
## constant and as a constructed `CsrfPolicy` (the two bypasses of a
## spelling-based check); and `billing-webhook`, `rfc8058`, `saml-acs` and
## `oidc-backchannel` on `aSession`; and server functions: `{.server.}` with
## `email-webhook` on `aSession`, `{.action.}` with `rfc8058` through a
## constant and the default auth. Compiled (the negative control: the
## refusal is the binding's, not a broken fixture): every bound exemption
## with `aSignature` (manifest entries and a server function), and
## `csp-report` on `aPublic`. The runtime checks behind these are
## t_csrf_binding_runtime.nim. FALSIFYING MUTATION:
## with `signatureBoundExemptions` emptied every refused fixture compiles and
## this test fails.
##
## MOCKS: none.

import std/[os, osproc, strutils, unittest]

const repoRoot = currentSourcePath.parentDir.parentDir.parentDir

proc nimCompile(file: string): tuple[ok: bool, output: string] =
  let (output, code) = execCmdEx("nim c --compileOnly --hints:off --path:" & quoteShell(repoRoot / "src") &
    " --nimcache:" & quoteShell(getTempDir() / "isonim-csrf-binding-" & file) & " " &
    quoteShell(repoRoot / "tests/fixtures" / file))
  (code == 0, output)

suite "the signature-bound CSRF exemptions":
  test "test_csrf_exemption_bound_to_signature":
    for f in ["manifest_csrf_email_webhook_asession.nim", "manifest_csrf_email_webhook_apublic.nim",
              "manifest_csrf_email_webhook_any_session.nim", "manifest_csrf_email_webhook_const.nim",
              "manifest_csrf_email_webhook_constructed.nim", "manifest_csrf_bound_billing_webhook_session.nim",
              "manifest_csrf_bound_rfc8058_session.nim", "manifest_csrf_bound_saml_acs_session.nim",
              "manifest_csrf_bound_oidc_backchannel_session.nim",
              # Server functions: the `{.server.}` / `{.action.}` pragma checks the same.
              "server_csrf_email_webhook_session.nim", "server_csrf_bound_const_action.nim"]:
      let r = nimCompile(f)
      checkpoint f & ": " & r.output
      check not r.ok
      check "is valid only with auth = aSignature" in r.output
    for f in ["manifest_csrf_email_webhook_ok.nim", "manifest_csrf_bound_ok.nim", "server_csrf_bound_ok.nim"]:
      let ok = nimCompile(f)
      checkpoint f & ": " & ok.output
      check ok.ok
