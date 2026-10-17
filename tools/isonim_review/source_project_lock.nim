## Process-owned project transaction boundary. Metadata never creates lock files
## or recovers a journal. POSIX directory flock follows workspace directory-lock
## prior art; the descriptor is close-on-exec so a compiler cannot retain ownership
## after its native parent dies. Windows uses directory file identity, not a path
## alias or PID, for a kernel mutex released on process exit.
import std/os
when defined(windows):
  import std/[winlean, widestrs]
  proc createMutexW(attributes: pointer; initialOwner: int32; name: WideCString): Handle
    {.stdcall, dynlib: "kernel32", importc: "CreateMutexW".}
  proc releaseMutex(handle: Handle): int32
    {.stdcall, dynlib: "kernel32", importc: "ReleaseMutex".}
else:
  import std/posix
  proc flock(fd, operation: cint): cint {.importc: "flock", header: "<sys/file.h>".}

type SourceProjectLock* = object
  when defined(windows):
    handle: Handle
  else:
    fd: cint

proc acquireSourceProjectLock*(root: string): SourceProjectLock =
  when defined(windows):
    let directory = createFileW(newWideCString(root), 0, 7, nil, 3, 0x02000000, 0)
    if directory == INVALID_HANDLE_VALUE: raiseOSError(osLastError())
    var identity: BY_HANDLE_FILE_INFORMATION
    let found = getFileInformationByHandle(directory, addr identity)
    discard closeHandle(directory)
    if found == 0: raiseOSError(osLastError())
    let name = "Global\\IsoNim-source-" & $identity.dwVolumeSerialNumber & "-" &
      $identity.nFileIndexHigh & "-" & $identity.nFileIndexLow
    result.handle = createMutexW(nil, 0, newWideCString(name))
    if result.handle == 0: raiseOSError(osLastError())
    let acquired = waitForSingleObject(result.handle, 0)
    if acquired notin [0'i32, 0x80'i32]:
      discard closeHandle(result.handle)
      raise newException(IOError, "Source project transaction is busy.")
  else:
    result.fd = posix.open(root.cstring, O_RDONLY)
    if result.fd < 0: raiseOSError(osLastError())
    if fcntl(result.fd, F_SETFD, FD_CLOEXEC) < 0:
      discard posix.close(result.fd)
      raiseOSError(osLastError())
    if flock(result.fd, 2.cint or 4.cint) != 0:
      discard posix.close(result.fd)
      raise newException(IOError, "Source project transaction is busy.")

proc release*(lock: SourceProjectLock) =
  when defined(windows):
    discard releaseMutex(lock.handle)
    discard closeHandle(lock.handle)
  else:
    discard posix.close(lock.fd)
