## isonim/routing/match.nim
##
## URL pattern matching for the router.
## Parses route patterns like "/users/:id/posts" into segments
## and matches URL paths against them, extracting dynamic parameters.

import std/strutils

type
  Segment* = object
    value*: string
    isDynamic*: bool        ## true for :param segments

  RoutePattern* = object
    path*: string           ## e.g. "/users/:id/posts"
    segments*: seq[Segment]

  MatchResult* = object
    matched*: bool
    params*: seq[(string, string)]  ## (paramName, value) pairs

proc splitSegments(path: string): seq[string] =
  ## Split a path into non-empty segments.
  ## "/users/42/posts" -> @["users", "42", "posts"]
  ## "/" -> @[]
  for part in path.split('/'):
    if part.len > 0:
      result.add(part)

proc parsePattern*(path: string): RoutePattern =
  ## Parse "/users/:id/posts" into a RoutePattern with typed segments.
  result.path = path
  result.segments = @[]
  for part in splitSegments(path):
    if part.len > 0 and part[0] == ':':
      result.segments.add(Segment(value: part[1..^1], isDynamic: true))
    else:
      result.segments.add(Segment(value: part, isDynamic: false))

proc matchPath*(pattern: RoutePattern; path: string): MatchResult =
  ## Match a URL path against a pattern. Returns params if matched.
  let pathSegs = splitSegments(path)
  result.matched = false
  result.params = @[]

  if pathSegs.len != pattern.segments.len:
    return

  for i in 0 ..< pattern.segments.len:
    let seg = pattern.segments[i]
    let pathSeg = pathSegs[i]
    if seg.isDynamic:
      result.params.add((seg.value, pathSeg))
    else:
      if seg.value != pathSeg:
        result.params = @[]
        return

  result.matched = true
