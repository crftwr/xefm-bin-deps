<#
.SYNOPSIS
    Build libarchive for Windows as a single self-contained archive.dll, for XeFM.

.DESCRIPTION
    XeFM reads .7z, .rar, .iso, .cab, .cpio and .rpm through libarchive, reached
    from Python by the pure-ctypes `libarchive-c` binding. That binding carries no
    binary of its own, and Windows -- unlike macOS and most Linux distributions --
    has no system libarchive for it to find. This script produces the one that
    XeFM's Windows builds bundle.

    The output is ONE DLL: zlib, bzip2, liblzma and libzstd are built static and
    linked in, so there are no compression libraries to ship alongside it. The
    MSVC runtime is deliberately NOT static -- see the note above $CommonArgs,
    where the filename-encoding reason for that is spelled out.

    What is deliberately in and out:

      ENABLE_CNG           ON   Hashes and AES through Windows' own bcrypt, which
                                is the whole reason OpenSSL is not needed. Note
                                what it does NOT buy: as of 3.8.9 zip is the only
                                format libarchive decrypts -- the 7z and RAR5
                                readers reject an encrypted entry unconditionally,
                                with no crypto #ifdef anywhere near them. So this
                                is here to drop a dependency, not to add a format.
      ENABLE_WIN32_XMLLITE ON   xar's XML through the OS, so libxml2/expat are
                                not needed either.
      zlib bzip2 liblzma        Required. XeFM's capability probe reads the codec
                                list out of archive_version_details() and drops a
                                format whose codec is missing -- no liblzma means
                                no .7z, no zlib means no .cab, neither means no
                                .rpm. Building without one does not fail loudly;
                                it just ships fewer formats.
      libzstd                   Not needed for .tar.zst (Python 3.14's tarfile
                                handles that), but a zstd-compressed 7z entry or
                                a zstd-payload .rpm is a codec *inside* a
                                container, which the probe cannot see. Without
                                libzstd, libarchive answers those by spawning
                                zstd.exe, which does not exist on Windows.
      OpenSSL libxml2 expat     OFF -- superseded by the two Win32 options above.
      lz4 lzo libb2 pcre        OFF -- no format XeFM offers needs them.
      iconv                     OFF -- libarchive uses the Win32 codepage APIs.
      tar cpio cat unzip tests  OFF -- this build is the library, nothing else.

    Upstream versions and their hashes are NOT in this file: they live in
    ..\sources.json, which every platform's build reads. See ADDING_A_PLATFORM.md
    for what is shared between platforms and what each one has to answer itself.

.PARAMETER Arch
    Target architecture. x64 is what XeFM's Windows bundle ships.

.PARAMETER Clean
    Discard build trees and the staging prefix first. Downloads are kept (they
    are checksum-verified, so re-fetching them proves nothing).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File windows\build-libarchive.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Arch = 'x64',
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- layout -------------------------------------------------------------------

$RepoRoot  = Split-Path -Parent $PSScriptRoot
$WinRoot   = Join-Path $RepoRoot 'windows'
$CacheDir  = Join-Path $RepoRoot '.cache'
$DlDir     = Join-Path $CacheDir 'src'
$BuildRoot = Join-Path $WinRoot  "build\$Arch"
$Prefix    = Join-Path $BuildRoot 'deps'      # static deps install here
$StageDir  = Join-Path $BuildRoot 'stage'     # what gets zipped

# --- pinned upstream sources --------------------------------------------------
#
# Read from sources.json at the repo root rather than written out here, because
# every platform's build has to agree on them: this repository exists so a CVE in
# zlib, bzip2, liblzma or libzstd is answered without an XeFM release, and a copy
# of these versions per build script is how "bumped zlib for Windows only" would
# happen. That file carries the rationale for each pin, including why xz must
# never be pinned below 5.6.2.
#
# Property access below is case-insensitive on the objects ConvertFrom-Json
# returns, so the JSON's lowercase keys read as .Name / .Url / .Sha256 here.

$SourcesFile = Join-Path $RepoRoot 'sources.json'
if (-not (Test-Path $SourcesFile)) {
    throw "sources.json not found at $SourcesFile; it is the pinned source manifest for every platform."
}
$Sources = (Get-Content -Raw -Path $SourcesFile | ConvertFrom-Json).sources
if (-not $Sources) { throw "sources.json has no 'sources' array." }

function Get-Source([string]$name) {
    $s = $Sources | Where-Object { $_.name -eq $name }
    if (-not $s) { throw "No pinned source named '$name' in sources.json" }
    return $s
}

# Every source in the file is built; these are the ones this script names
# directly, and a manifest missing one would otherwise fail much later with a
# confusing CMake error.
foreach ($required in 'zlib', 'bzip2', 'xz', 'zstd', 'libarchive') {
    Get-Source $required | Out-Null
}

$LibarchiveVersion = (Get-Source 'libarchive').Version
$PackageName = "libarchive-$LibarchiveVersion-windows-$Arch"

function Write-Step([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Info([string]$msg) { Write-Host "    $msg" -ForegroundColor DarkGray }

if ($Clean -and (Test-Path $BuildRoot)) {
    Write-Step "Cleaning $BuildRoot"
    Remove-Item -Recurse -Force $BuildRoot
}

New-Item -ItemType Directory -Force -Path $DlDir, $BuildRoot, $Prefix | Out-Null

# --- toolchain ----------------------------------------------------------------

function Import-VsEnvironment([string]$targetArch) {
    # VsDevCmd exports the compiler environment into a cmd session; the only way
    # to get it into this one is to run it and read back `set`.
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) {
        throw "vswhere.exe not found. Install Visual Studio Build Tools with the C++ workload."
    }
    $vsPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if (-not $vsPath) {
        throw "No Visual Studio install with the C++ toolset (VC.Tools.x86.x64) was found."
    }
    $devCmd = Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat'
    if (-not (Test-Path $devCmd)) { throw "VsDevCmd.bat not found under $vsPath" }

    # Cross-compiling from an ARM64 host is a first-class MSVC configuration and
    # is markedly faster than running the x64 toolset under emulation, which is
    # what a plain -host_arch=amd64 would do on a Windows-on-ARM machine.
    $native = $env:PROCESSOR_ARCHITEW6432
    if (-not $native) { $native = $env:PROCESSOR_ARCHITECTURE }
    $hostArch = if ($native -eq 'ARM64') { 'arm64' } else { 'amd64' }
    $tgtArch  = if ($targetArch -eq 'x64') { 'amd64' } else { 'arm64' }

    Write-Info "Visual Studio: $vsPath"
    Write-Info "Toolset: host=$hostArch target=$tgtArch"

    $output = cmd /c "`"$devCmd`" -arch=$tgtArch -host_arch=$hostArch -no_logo && set"
    if ($LASTEXITCODE -ne 0) { throw "VsDevCmd.bat failed for -arch=$tgtArch -host_arch=$hostArch" }
    foreach ($line in $output) {
        if ($line -match '^([^=]+)=(.*)$') {
            Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2] -ErrorAction SilentlyContinue
        }
    }
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        # The usual cause is that the toolset for this *target* is not installed:
        # VsDevCmd reports success and simply leaves the compiler off PATH.
        # The x64 target is Microsoft.VisualStudio.Component.VC.Tools.x86.x64;
        # an arm64 target additionally needs ...VC.Tools.ARM64.
        throw ("cl.exe is not on PATH after importing the VS environment for " +
               "-arch=$tgtArch -host_arch=$hostArch. The toolset for the $targetArch " +
               "target is most likely not installed -- add it in the Visual Studio Installer.")
    }
}

Write-Step "Locating the build toolchain"
Import-VsEnvironment $Arch

foreach ($tool in 'cmake', 'ninja') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool is not on PATH. The simplest way to get both: pip install cmake ninja"
    }
    Write-Info "$tool $((& $tool --version | Select-Object -First 1))"
}

# --- fetch --------------------------------------------------------------------

function Get-Tarball($source) {
    $file = Join-Path $DlDir (Split-Path -Leaf ([uri]$source.Url).AbsolutePath)
    if (Test-Path $file) {
        $have = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLower()
        if ($have -eq $source.Sha256) { Write-Info "$($source.Name) $($source.Version): cached"; return $file }
        Write-Info "$($source.Name): cached copy has the wrong hash, re-downloading"
        Remove-Item -Force $file
    }
    Write-Info "$($source.Name) $($source.Version): downloading"
    # Invoke-WebRequest's progress bar costs more time than the download on a
    # fast link, and is noise in a log.
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest -Uri $source.Url -OutFile $file -UseBasicParsing }
    finally { $ProgressPreference = $oldProgress }

    $have = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLower()
    if ($have -ne $source.Sha256) {
        Remove-Item -Force $file
        throw "$($source.Name) $($source.Version): SHA-256 mismatch`n  expected $($source.Sha256)`n  got      $have"
    }
    return $file
}

function Expand-Tarball($source) {
    # bsdtar, shipped in Windows since 1803, reads .tar.gz and .tar.xz both.
    $dir = Join-Path $DlDir "$($source.Name)-$($source.Version)"
    if (Test-Path $dir) { return $dir }
    $file = Get-Tarball $source
    Write-Info "$($source.Name): extracting"
    & "$env:SystemRoot\System32\tar.exe" -xf $file -C $DlDir
    if ($LASTEXITCODE -ne 0) { throw "Failed to extract $file" }
    if (-not (Test-Path $dir)) { throw "$file did not extract to the expected $dir" }
    return $dir
}

Write-Step "Fetching pinned sources"
$SrcDirs = @{}
foreach ($s in $Sources) {
    Get-Tarball $s | Out-Null
    $SrcDirs[$s.Name] = Expand-Tarball $s
}

# --- building -----------------------------------------------------------------

# Every dependency and libarchive itself gets the same three: a Release build,
# the shared MSVC runtime, and Ninja. CMP0091 is what makes
# CMAKE_MSVC_RUNTIME_LIBRARY authoritative rather than the old flag-rewriting.
#
# The runtime is shared (/MD) rather than static (/MT), and that is a deliberate
# reversal worth recording, because /MT looks strictly better: it would make
# archive.dll depend on nothing outside Windows itself.
#
# libarchive decides how to convert a filename between wide and narrow forms by
# calling setlocale(LC_CTYPE, NULL) in its own C runtime and reading the code
# page out of the answer (get_current_codepage() in archive_string.c). Under /MT
# that runtime is private to this DLL, permanently at the process ANSI code page,
# and unreachable from the host: nothing the application does can change it. On a
# machine whose ACP is, say, 1252, archive_entry_pathname() then returns NULL for
# any name the ACP cannot spell -- and the cpio writer reports "Pathname
# required" while the iso9660 writer mistakes the NULL for the virtual root and
# drops the file without a word.
#
# Under /MD the runtime is the process's, so a single setlocale(LC_CTYPE, .UTF8)
# on the application's side fixes every one of those conversions. XeFM does
# exactly that before it loads this library. For a file manager expected to hold
# CJK filenames, that is worth more than dropping a dependency on vcruntime140,
# which the bundle already ships because CPython needs it.
$CommonArgs = @(
    '-G', 'Ninja'
    '-DCMAKE_BUILD_TYPE=Release'
    '-DCMAKE_POLICY_DEFAULT_CMP0091=NEW'
    '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL'
    "-DCMAKE_INSTALL_PREFIX=$Prefix"
    "-DCMAKE_PREFIX_PATH=$Prefix"
)

function Invoke-CMakeBuild([string]$name, [string]$sourceDir, [string[]]$extraArgs) {
    $bld = Join-Path $BuildRoot $name
    Write-Step "Building $name"
    & cmake -S $sourceDir -B $bld @CommonArgs @extraArgs
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed for $name" }
    & cmake --build $bld --target install
    if ($LASTEXITCODE -ne 0) { throw "cmake build failed for $name" }
}

# zlib. Its CMake gates the two library kinds on its own options rather than
# BUILD_SHARED_LIBS, and names the static one z.lib -- which CMake's FindZLIB
# does look for, but libarchive's other consumers may not, so it is normalized
# below alongside the rest.
Invoke-CMakeBuild 'zlib' $SrcDirs['zlib'] @(
    '-DZLIB_BUILD_SHARED=OFF'
    '-DZLIB_BUILD_STATIC=ON'
    '-DZLIB_BUILD_TESTING=OFF'
    '-DZLIB_INSTALL=ON'
)

# bzip2, through the CMakeLists in this repo -- upstream ships none.
Invoke-CMakeBuild 'bzip2' (Join-Path $WinRoot 'cmake\bzip2') @(
    "-DBZIP2_SOURCE_DIR=$($SrcDirs['bzip2'])"
)

# liblzma. The tools are the bulk of the xz tree and none of them is wanted:
# this build is the library that libarchive links.
Invoke-CMakeBuild 'xz' $SrcDirs['xz'] @(
    '-DBUILD_SHARED_LIBS=OFF'
    '-DXZ_NLS=OFF'
    '-DXZ_DOC=OFF'
    '-DXZ_TOOL_XZ=OFF'
    '-DXZ_TOOL_XZDEC=OFF'
    '-DXZ_TOOL_LZMADEC=OFF'
    '-DXZ_TOOL_LZMAINFO=OFF'
    '-DXZ_TOOL_SCRIPTS=OFF'
)

# libzstd. Legacy format support decodes zstd streams from before the format was
# frozen in 2016; nothing XeFM opens contains one.
Invoke-CMakeBuild 'zstd' (Join-Path $SrcDirs['zstd'] 'build\cmake') @(
    '-DZSTD_BUILD_SHARED=OFF'
    '-DZSTD_BUILD_STATIC=ON'
    '-DZSTD_BUILD_PROGRAMS=OFF'
    '-DZSTD_BUILD_TESTS=OFF'
    '-DZSTD_BUILD_CONTRIB=OFF'
    '-DZSTD_LEGACY_SUPPORT=OFF'
)

# CMake's bundled find modules and libarchive's own hand-rolled zstd lookup each
# search a handful of conventional names, and the four projects above agree with
# none of them consistently -- zlib 1.3.2 installs zs.lib, zstd installs
# zstd_static.lib. Rather than teach libarchive about each, give every static
# library every name a finder might ask for. Which file is the real one is
# discovered rather than assumed, so an upstream renaming it again is a no-op
# here instead of a silently missing codec.
Write-Step "Normalizing static library names"
$LibDir = Join-Path $Prefix 'lib'
$Aliases = @(
    @{ Built = @('zs.lib', 'z.lib', 'zlibstatic.lib')
       Names = @('z.lib', 'zlib.lib', 'zlibstatic.lib') }
    @{ Built = @('zstd_static.lib', 'zstd.lib')
       Names = @('zstd.lib', 'libzstd.lib', 'zstd_static.lib') }
    @{ Built = @('lzma.lib', 'liblzma.lib')
       Names = @('lzma.lib', 'liblzma.lib') }
    @{ Built = @('bz2.lib', 'libbz2.lib')
       Names = @('bz2.lib', 'bzip2.lib', 'libbz2.lib') }
)
foreach ($group in $Aliases) {
    $src = $group.Built | ForEach-Object { Join-Path $LibDir $_ } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $src) {
        throw ("None of {0} was installed into {1}; the dependency build did not " +
               "produce the static library libarchive needs." -f
               ($group.Built -join ', '), $LibDir)
    }
    foreach ($alias in $group.Names) {
        $dst = Join-Path $LibDir $alias
        if ($dst -ne $src) { Copy-Item -Force $src $dst }
    }
    Write-Info "$(Split-Path -Leaf $src) -> $($group.Names -join ', ')"
}

# libarchive itself. See the header comment for why each of these is set.
Invoke-CMakeBuild 'libarchive' $SrcDirs['libarchive'] @(
    '-DBUILD_SHARED_LIBS=ON'
    '-DENABLE_CNG=ON'
    '-DENABLE_WIN32_XMLLITE=ON'
    '-DENABLE_ZLIB=ON'
    '-DENABLE_BZip2=ON'
    '-DENABLE_LZMA=ON'
    '-DENABLE_ZSTD=ON'
    '-DENABLE_OPENSSL=OFF'
    '-DENABLE_LIBXML2=OFF'
    '-DENABLE_EXPAT=OFF'
    '-DENABLE_LZ4=OFF'
    '-DENABLE_LZO=OFF'
    '-DENABLE_LIBB2=OFF'
    '-DENABLE_MBEDTLS=OFF'
    '-DENABLE_NETTLE=OFF'
    '-DENABLE_PCREPOSIX=OFF'
    '-DENABLE_PCRE2POSIX=OFF'
    '-DENABLE_ICONV=OFF'
    '-DENABLE_TAR=OFF'
    '-DENABLE_CPIO=OFF'
    '-DENABLE_CAT=OFF'
    '-DENABLE_UNZIP=OFF'
    '-DENABLE_TEST=OFF'
    '-DENABLE_INSTALL=ON'
)

# --- verify -------------------------------------------------------------------
#
# The capability probe on XeFM's side turns a missing codec into a silently
# absent format rather than an error, so a wrong build here would not announce
# itself later. Check the two things that would be wrong -- the codec list and
# the DLL's imports -- while the build is still in front of us.

$Dll = Join-Path $Prefix 'bin\archive.dll'
if (-not (Test-Path $Dll)) { throw "archive.dll was not produced at $Dll" }

Write-Step "Verifying the built library"

# zlib, liblzma and bz2lib are what XeFM's registry keys off; libzstd is the one
# that cannot be probed from XeFM's side at all (see the header), so it has to be
# established here or nowhere.
$RequiredCodecs = @('zlib', 'liblzma', 'bz2lib', 'libzstd')

# archive_version_details() assembles its string at run time -- " zlib/" and the
# rest are separate literals concatenated onto the version -- so the honest check
# is to load the DLL and call it. That needs a process of the target
# architecture, which this one is not when cross-compiling (an x64 DLL cannot
# load into the arm64 PowerShell on a Windows-on-ARM box). Try the call, and fall
# back to looking for those literals in .rdata, which settles the same question
# from either host.
$details = $null
$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) {
    $probe = @'
import ctypes, sys
lib = ctypes.CDLL(sys.argv[1])
lib.archive_version_details.restype = ctypes.c_char_p
sys.stdout.write(lib.archive_version_details().decode())
'@
    $out = $probe | & $python.Source - $Dll 2>$null
    if ($LASTEXITCODE -eq 0 -and $out) { $details = "$out".Trim() }
}

if ($details) {
    Write-Info "archive_version_details(): $details"
    $missing = $RequiredCodecs | Where-Object { $details -notmatch [regex]::Escape("$_/") }
} else {
    Write-Info "cross-built for $Arch; checking the codec literals in the binary instead"
    $bytes = [System.IO.File]::ReadAllBytes($Dll)
    $text  = [System.Text.Encoding]::ASCII.GetString($bytes)
    $missing = $RequiredCodecs | Where-Object { $text -notmatch [regex]::Escape(" $_/") }
}
if ($missing) {
    throw ("The build is missing codecs XeFM needs: {0}. Check that the matching " +
           "dependency configured and installed above." -f ($missing -join ', '))
}
Write-Info "all required codecs present: $($RequiredCodecs -join ', ')"

# The compression libraries are static, so the only things here should be
# Windows' own DLLs plus the C runtime. Anything else means a dependency escaped
# and would have to be shipped alongside.
$dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
if ($dumpbin) {
    $imports = & dumpbin.exe /DEPENDENTS $Dll |
        Select-String -Pattern '^\s{4}(\S+\.dll)$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value }
    Write-Info "imports: $($imports -join ' ')"
    $unexpected = $imports | Where-Object { $_ -match '^(zlib|libzstd|zstd|liblzma|lzma|bz2|libbz2|libcrypto|libxml2)' }
    if ($unexpected) {
        throw "archive.dll dynamically imports what should have been static: $($unexpected -join ', ')"
    }
    # /MD is chosen on purpose (see CommonArgs); its absence would mean the
    # runtime went static again and took the filename conversions with it.
    if (-not ($imports -match '^(vcruntime|api-ms-win-crt|ucrtbase)')) {
        Write-Warning "No C runtime import: this looks like a static-CRT build, which breaks non-ASCII filenames in the cpio and iso writers."
    }
    if ($imports -match '^bcrypt\.dll$') {
        Write-Info "bcrypt.dll present -- CNG took effect, so OpenSSL is genuinely not needed"
    } else {
        Write-Warning ("bcrypt.dll is NOT imported: ENABLE_CNG did not take effect, and with " +
                       "ENABLE_OPENSSL=OFF this build has no digest implementation at all.")
    }
}

# --- stage --------------------------------------------------------------------

Write-Step "Staging $PackageName"
if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
$PkgDir = Join-Path $StageDir $PackageName
New-Item -ItemType Directory -Force -Path (Join-Path $PkgDir 'bin'), (Join-Path $PkgDir 'licenses') | Out-Null

Copy-Item -Force $Dll (Join-Path $PkgDir 'bin\archive.dll')

# The license text of everything statically linked into that DLL travels with
# it, because a consumer bundling the DLL has to redistribute these too.
$LicenseFiles = @{
    'libarchive' = @('COPYING')
    'zlib'       = @('LICENSE')
    'bzip2'      = @('LICENSE')
    'xz'         = @('COPYING', 'COPYING.0BSD')
    'zstd'       = @('LICENSE', 'COPYING')
}
foreach ($name in $LicenseFiles.Keys) {
    foreach ($f in $LicenseFiles[$name]) {
        $p = Join-Path $SrcDirs[$name] $f
        if (Test-Path $p) {
            Copy-Item -Force $p (Join-Path $PkgDir "licenses\$name-$f.txt")
        }
    }
}

$manifest = @()
$manifest += "libarchive for Windows $Arch, built for XeFM"
$manifest += ""
if ($details) { $manifest += "archive_version_details(): $details"; $manifest += "" }
$manifest += "Statically linked, from these pinned upstream releases:"
foreach ($s in $Sources) {
    $manifest += ("  {0,-12} {1,-8} sha256 {2}" -f $s.Name, $s.Version, $s.Sha256)
}
$manifest += ""
$manifest += "Built with CNG (Windows bcrypt) for hashes and AES, and XmlLite for xar,"
$manifest += "so there is no OpenSSL and no libxml2 dependency. The MSVC runtime is"
$manifest += "linked statically as well: bin\archive.dll needs nothing but the OS."
$manifest += ""
$manifest += "License text for every component is under licenses\."
$manifest -join "`r`n" | Set-Content -Path (Join-Path $PkgDir 'MANIFEST.txt') -Encoding utf8

$Zip = Join-Path $BuildRoot "$PackageName.zip"
if (Test-Path $Zip) { Remove-Item -Force $Zip }
# Not Compress-Archive: under Windows PowerShell it writes entry names with
# backslashes, which the ZIP spec does not allow and some extractors take
# literally, as one file with slashes in its name. Entries are added by hand so
# the separator is right in a published asset.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipFile = [System.IO.Compression.ZipFile]::Open($Zip, 'Create')
try {
    foreach ($f in Get-ChildItem -Recurse -File $PkgDir | Sort-Object FullName) {
        $rel = $f.FullName.Substring($StageDir.Length + 1).Replace('\', '/')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zipFile, $f.FullName, $rel, 'Optimal') | Out-Null
    }
} finally { $zipFile.Dispose() }
$zipHash = (Get-FileHash -Algorithm SHA256 $Zip).Hash.ToLower()
"$zipHash *$PackageName.zip" | Set-Content -Path (Join-Path $BuildRoot "$PackageName.zip.sha256") -Encoding ascii

Write-Step "Done"
Write-Host "  $Zip"
Write-Host "  sha256 $zipHash"
Write-Host ""
Write-Host "  Try it:  `$env:LIBARCHIVE = '$(Join-Path $PkgDir 'bin\archive.dll')'" -ForegroundColor DarkGray
