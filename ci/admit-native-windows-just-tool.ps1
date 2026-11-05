# Materialize the existing `uses: "just >=1"` requirement for the original cross-checks.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'This fixture role is Windows-only' }
$arch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToUpperInvariant()
if ($arch -cne $env:RUNNER_ARCH) { throw 'Runner and native OS architecture differ' }
$pins = @{
  X64 = @{ target='x86_64-pc-windows-msvc'; archiveSHA='9c5463e2d0974e31bee71346aa5cbf19167de1585a4abc1bae7b3b04604ea9c0'; archiveBytes=2292448; imageSHA='146c26ccfe1e40fadb59183cf8bc17d46c0cdf1bd1e43e52cca686cef0c44627'; imageBytes=5922304; machine=34404 }
  ARM64 = @{ target='aarch64-pc-windows-msvc'; archiveSHA='a72808bc8f8028c25aaae87cf26405d2bd85d2769a779380b344c69607216971'; archiveBytes=2098112; imageSHA='4f54ce81fc2c99094be22bf3a0e28aff106ab7d92ff286f3979bee54e3b03f48'; imageBytes=5016064; machine=43620 }
}
if (-not $pins.ContainsKey($arch)) { throw 'Only native Windows x64 and ARM64 are declared' }
$pin = $pins[$arch]
$version = '1.59.0'
$url = 'https://github.com/casey/just/releases/download/'+$version+'/just-'+$version+'-'+$pin.target+'.zip'
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class AcpJustFileIdentity {
  [StructLayout(LayoutKind.Sequential)] public struct Info {
    public uint Attributes;
    public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
    public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
  }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info info);
}
'@
$holds = [Collections.Generic.List[IDisposable]]::new()
$receipt = [ordered]@{ scope='Pinned native Windows Just fixture admission; original cross-checks remain mandatory'; workflowSHA=$env:GITHUB_SHA; architecture=$arch; version=$version; URL=$url; admitted=$false; PATHChanged=$false; directories=@(); images=@(); precision='Held identity/hash/native-machine and version probe at admission only; no subsequent execution-time identity or Windows test acceptance from this record' }
function Identity($Handle) {
  $info = [AcpJustFileIdentity+Info]::new()
  if (-not [AcpJustFileIdentity]::GetFileInformationByHandle($Handle,[ref]$info)) { throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
  if (($info.Attributes -band 1024) -ne 0) { throw 'Reparse points are not fixture objects' }
  return [ordered]@{ volume=$info.Volume; indexHigh=$info.IndexHigh; indexLow=$info.IndexLow; attributes=$info.Attributes; sizeHigh=$info.SizeHigh; sizeLow=$info.SizeLow }
}
function Hold-Directory([string]$Path) {
  $handle = [AcpJustFileIdentity]::CreateFileW($Path,2147483648,1,[IntPtr]::Zero,3,35651584,[IntPtr]::Zero)
  if ($handle.IsInvalid) { $handle.Dispose(); throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
  $holds.Add($handle); $id = Identity $handle
  if (($id.attributes -band 16) -eq 0) { throw 'Expected a held fixture directory' }
  $receipt.directories += @{path=$Path; identity=$id}
  return $handle
}
function Hash-Held([IO.FileStream]$Stream) {
  $position = $Stream.Position
  try { $Stream.Position=0; return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Stream)).ToLowerInvariant() }
  finally { $Stream.Position=$position }
}
try {
  if (-not $env:RUNNER_TEMP -or -not [IO.Path]::IsPathFullyQualified($env:RUNNER_TEMP)) { throw 'Absolute runner-owned temporary parent is required' }
  $root = Join-Path $env:RUNNER_TEMP ('acp-just-'+[Guid]::NewGuid().ToString('N'))
  [void](New-Item -ItemType Directory -Path $root)
  $rootHold = Hold-Directory $root
  $bin = Join-Path $root 'bin'; [void](New-Item -ItemType Directory -Path $bin)
  $binHold = Hold-Directory $bin
  $archive = Join-Path $root 'just.zip'
  Invoke-WebRequest -Uri $url -OutFile $archive -TimeoutSec 60
  $archiveHold = [IO.File]::Open($archive,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  $holds.Add($archiveHold); $archiveID = Identity $archiveHold.SafeFileHandle
  if (($archiveID.attributes -band 16) -ne 0 -or $archiveHold.Length -ne $pin.archiveBytes -or (Hash-Held $archiveHold) -cne $pin.archiveSHA) { throw 'Official Just archive bytes do not match the declared pin' }
  $zip = [IO.Compression.ZipArchive]::new($archiveHold,[IO.Compression.ZipArchiveMode]::Read,$true)
  try {
    $entries = @($zip.Entries | Where-Object { $_.FullName -ceq 'just.exe' })
    if ($entries.Count -ne 1 -or $entries[0].Length -ne $pin.imageBytes) { throw 'Exactly one pinned Just image is required' }
    $image = Join-Path $bin 'just.exe'
    $entryStream = $entries[0].Open()
    $imageOutput = [IO.File]::Open($image,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $entryStream.CopyTo($imageOutput); $imageOutput.Flush($true) }
    finally { $imageOutput.Dispose(); $entryStream.Dispose() }
  } finally { $zip.Dispose() }
  $imageHold = [IO.File]::Open($image,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  $holds.Add($imageHold); $imageID = Identity $imageHold.SafeFileHandle
  if (($imageID.attributes -band 16) -ne 0 -or $imageHold.Length -ne $pin.imageBytes -or (Hash-Held $imageHold) -cne $pin.imageSHA) { throw 'Held Just image bytes do not match the declared pin' }
  $reader = [IO.BinaryReader]::new($imageHold,[Text.Encoding]::UTF8,$true)
  try {
    if ($reader.ReadUInt16() -ne 23117) { throw 'Just image lacks an MZ header' }
    $imageHold.Position=60; $offset=$reader.ReadUInt32()
    if ($offset -gt $imageHold.Length-6) { throw 'Invalid Just PE offset' }
    $imageHold.Position=$offset
    if ($reader.ReadUInt32() -ne 17744 -or $reader.ReadUInt16() -ne $pin.machine) { throw 'Just must have the runner native PE machine' }
  } finally { $reader.Dispose(); $imageHold.Position=0 }
  $reportedVersion = @(& $image --version)
  if ($LASTEXITCODE -ne 0 -or ($reportedVersion -join "`n").Trim() -cne ('just '+$version)) { throw 'Pinned native Just version probe failed' }
  if ((Identity $imageHold.SafeFileHandle | ConvertTo-Json -Compress) -cne ($imageID | ConvertTo-Json -Compress)) { throw 'Held Just image identity drift' }
  foreach ($row in $receipt.directories) {
    $item=Get-Item -LiteralPath $row.path -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Fixture directory path drift' }
  }
  $receipt.images += @{path=$image; identity=$imageID; SHA256=$pin.imageSHA; bytes=$pin.imageBytes; machine=$pin.machine; actualVersion=($reportedVersion -join "`n").Trim()}
  $receipt.archive=@{path=$archive; identity=$archiveID; SHA256=$pin.archiveSHA; bytes=$pin.archiveBytes}
  if (-not $env:GITHUB_PATH -or -not (Test-Path -LiteralPath $env:GITHUB_PATH -PathType Leaf)) { throw 'Runner PATH publication channel is required' }
  [IO.File]::AppendAllText($env:GITHUB_PATH,$bin+"`n",[Text.UTF8Encoding]::new($false))
  $receipt.PATHChanged=$true; $receipt.admitted=$true
} finally {
  $receipt | ConvertTo-Json -Depth 12
  for ($i=$holds.Count-1; $i -ge 0; $i--) { $holds[$i].Dispose() }
}
