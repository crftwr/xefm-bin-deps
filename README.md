# xefm-bin-deps

Binary dependencies for [XeFM](https://github.com/crftwr/xefm).

Right now that means one thing: **libarchive for Windows**, built as a single
self-contained `archive.dll`.

> **This repository exists to serve XeFM's builds.** The binaries are published
> because XeFM's Windows users need somewhere to get them, not as a general
> distribution. There is no support commitment, no stable ABI promise, and no
> schedule beyond "whenever XeFM or a CVE requires it". If you are looking for
> general-purpose Windows libarchive binaries, vcpkg and conda-forge are the
> maintained answers.

## Why this is a separate repository

XeFM reads `.7z`, `.rar`, `.iso`, `.cab`, `.cpio` and `.rpm` through libarchive.
macOS and most Linux distributions ship a system libarchive that is new enough;
Windows ships none, so XeFM's Windows builds have to carry one.

That DLL statically links zlib, bzip2, liblzma and libzstd — four compression
libraries with their own vulnerability cycles. Keeping them here rather than
vendored inside XeFM means a CVE in any of them is answered by rebuilding and
re-releasing **this** repository, on its own schedule, instead of forcing an XeFM
release.

## Getting the DLL

Download the asset for your platform from
[Releases](https://github.com/crftwr/xefm-bin-deps/releases) — it is named
`libarchive-<version>-windows-<arch>.zip` — and check it against the
`.sha256` published beside it.

The zip contains:

```
libarchive-<version>-windows-<arch>/
├── bin/archive.dll      the library, and the only file you need
├── licenses/            license text for everything linked into it
└── MANIFEST.txt         exact upstream versions and their checksums
```

### Using it with XeFM

XeFM's Windows desktop builds bundle this DLL already; nothing below applies to
them.

If you run XeFM from source or from PyPI on Windows, point the `LIBARCHIVE`
environment variable at the extracted DLL. `libarchive-c` loads the library when
it is first imported, so the variable has to be set **before** XeFM starts, not
from inside it:

```powershell
# PowerShell, for this session
$env:LIBARCHIVE = "C:\path\to\libarchive-3.8.9-windows-x64\bin\archive.dll"
python -m xefm

# ...or permanently, for your account
setx LIBARCHIVE "C:\path\to\libarchive-3.8.9-windows-x64\bin\archive.dll"
```

To confirm it took, look at XeFM's log for the line that starts `libarchive:` —
it names the library that answered, the codecs compiled into it, and the formats
they justified:

```
libarchive: libarchive 3.8.9 zlib/1.3.2 liblzma/5.8.3 bz2lib/1.0.8 libzstd/1.5.7 cng/2.0 libb2/bundled [C:\...\archive.dll]
    reading .7z .rar .iso .cab .cpio .rpm, writing .7z .iso .cpio
```

If a format you expected is missing from that line, the library that loaded was
built without the codec it needs. XeFM will not error — it will simply not offer
the format — so that line is the thing to read.

## What is in the build

One DLL, with the compression libraries linked in statically. Beyond
`bcrypt.dll`, `XmlLite.dll`, `KERNEL32.dll` and `ole32.dll` — all part of
Windows — it imports only the Microsoft C runtime (`vcruntime140.dll` and the
`api-ms-win-crt-*` stubs), which any Python installation already requires.

The C runtime is deliberately **not** linked statically, and the reason is
filenames rather than size. libarchive picks the code page for its wide/narrow
filename conversions by calling `setlocale(LC_CTYPE, NULL)` in its own C
runtime. Made static, that runtime is private to the DLL and stuck at the
process ANSI code page, where an application cannot reach it — so on a machine
whose ACP is 1252 a CJK filename becomes a NULL pathname, and the ISO 9660
writer drops such a file silently. Sharing the runtime lets the application
select a UTF-8 `LC_CTYPE` once and have every conversion follow.

| Component | Why |
|-----------|-----|
| zlib | `.cab` (MSZIP is deflate) and `.rpm` |
| bzip2 | bzip2-compressed entries |
| liblzma | `.7z` (essentially every real one is LZMA/LZMA2) and `.rpm` |
| libzstd | zstd-compressed `.7z` entries and zstd-payload `.rpm` |
| CNG (`bcrypt.dll`) | Digests, via the OS — this is what makes OpenSSL unnecessary |
| XmlLite (`ole32.dll`) | xar's XML, via the OS — likewise for libxml2 and expat |

OpenSSL, libxml2, expat, lz4, lzo, libb2, PCRE and iconv are all disabled, and no
command-line tools are built.

A note on encryption, because it is easy to assume otherwise: enabling CNG does
**not** make encrypted `.7z` or RAR5 archives readable. As of libarchive 3.8.9,
zip is the only format libarchive decrypts; the 7z and RAR5 readers refuse an
encrypted entry unconditionally, with no build option involved. CNG is here to
remove the OpenSSL dependency, not to add a format.

## Building it yourself

Requires Windows with Visual Studio Build Tools (the C++ workload), plus CMake
and Ninja — the easiest source of the latter two is `pip install cmake ninja`.

```powershell
powershell -ExecutionPolicy Bypass -File windows\build-libarchive.ps1
```

The result lands in `windows\build\x64\` as the zip and its `.sha256`.

Every upstream source is pinned by version **and** SHA-256 in
[`windows/build-libarchive.ps1`](windows/build-libarchive.ps1); the build refuses
to continue on a mismatch. Those hashes were taken from downloads whose OpenPGP
signatures were verified against each project's published signing key, and the
script's header records which. bzip2 has no upstream CMake build, so
[`windows/cmake/bzip2/CMakeLists.txt`](windows/cmake/bzip2/CMakeLists.txt) in
this repository supplies one; the upstream tarball itself is used unmodified.

The build also verifies itself before packaging — it checks that
`archive_version_details()` reports every codec XeFM needs, and that the DLL has
not picked up a dynamic import of something meant to be static. This matters
because the failure it guards against is quiet: XeFM's capability probe responds
to a missing codec by not offering the format, so a wrong build produces a
working XeFM with fewer formats rather than an error.

Cross-building for x64 from a Windows-on-ARM host is supported and is what the
script selects automatically; pass `-Arch arm64` for a native ARM64 build.

## License

The build scripts in this repository are MIT-licensed (see [LICENSE](LICENSE)).

The binaries they produce are **not** covered by that license. libarchive,
zlib, bzip2, liblzma and libzstd each carry their own terms — permissive in every
case, and the full text of each travels inside every release asset under
`licenses/`.
