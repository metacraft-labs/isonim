## Phase B — chronicles wiring helper.
##
## This module bundles the small amount of configuration the daemon and the
## CLI need to keep their structured-logging behaviour predictable:
##
##   * Map a user-friendly ``--log-level=trace|debug|info|warn|error`` flag
##     to a chronicles :type:`LogLevel`.
##   * Apply that level at process startup via :proc:`setLogLevel`.
##
## All log output flows to **stderr** by virtue of the compile-time switch
## ``-d:chronicles_sinks=textlines[stderr]`` (see ``tests/config.nims`` and
## the ``isonim-review-build`` Justfile target).  Keeping the wiring in one
## file means a Phase C / REV-M11 follow-up that wants JSON logs or a third
## sink only needs to revisit a single module.

import std/strutils

import chronicles

export chronicles

type
  InvalidLogLevelError* = object of CatchableError

const ValidLogLevelNames* = ["trace", "debug", "info", "warn", "error"]

proc parseLogLevel*(raw: string): LogLevel =
  ## Parse ``--log-level=<name>`` (case-insensitive).
  ##
  ## Raises :type:`InvalidLogLevelError` when the input is non-empty but
  ## unrecognised — the CLI uses that signal to print a usage hint and
  ## return exit code 2.  An empty input maps to :enum:`LogLevel.INFO`,
  ## the default level for production use.
  case raw.toLowerAscii
  of "": LogLevel.INFO
  of "trace": LogLevel.TRACE
  of "debug": LogLevel.DEBUG
  of "info": LogLevel.INFO
  of "notice": LogLevel.NOTICE
  of "warn", "warning": LogLevel.WARN
  of "error", "err": LogLevel.ERROR
  of "fatal": LogLevel.FATAL
  of "none", "off": LogLevel.NONE
  else:
    raise newException(InvalidLogLevelError,
      "invalid log level '" & raw & "'; expected one of " &
      ValidLogLevelNames.join(", "))

proc configureLogging*(raw: string = "") =
  ## Convenience: parse + apply a log level in one call.  The default
  ## (no argument) leaves the level at chronicles' compile-time floor
  ## (INFO when built with ``-d:release``).
  let level = parseLogLevel(raw)
  setLogLevel(level)
