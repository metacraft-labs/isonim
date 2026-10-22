## A legitimate user module may share the standard library's basename.
import std/hashes
export hashes.Hash
type HashValue* = ref object
  content*: int
proc hash*(value: HashValue): Hash = Hash(value.content * 31)
