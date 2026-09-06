# Adding a platform

Today this repository builds libarchive for **Windows only**, because Windows is
the only platform XeFM supports that has no system libarchive for `libarchive-c`
to find. macOS and most Linux distributions do, so nothing needs shipping there
yet.

"Yet" is the reason this file exists. When a second platform arrives, most of the
work is genuinely per-platform and should stay that way — but a few things must
*not* diverge, and it is much cheaper to say which now than to discover it during
a CVE response.

---

## The one thing that must stay shared

**[`sources.json`](sources.json) is the single source of truth for every
platform.** It pins libarchive and the four compression libraries linked into it,
by version and SHA-256.

This is not tidiness. The whole reason this repository is separate from XeFM is
so that a CVE in zlib, bzip2, liblzma or libzstd can be answered by rebuilding
here, without cutting an XeFM release. If each platform's build script carried
its own copy of those versions, the predictable failure would be bumping zlib for
Windows and quietly shipping the old one everywhere else — which is exactly the
outcome the separation was meant to prevent.

So: **a platform build reads `sources.json`. It does not restate a version.**

`windows/build-libarchive.ps1` reads it with `ConvertFrom-Json`; a shell script
would use `jq`. Both are a few lines. Keep the JSON lowercase-keyed and give
every entry every key (`null` where it does not apply) so a consumer can read a
field without checking for its existence first — PowerShell's `Set-StrictMode`
throws on a missing property, and `jq` is happier too.

### Bumping a pinned version

The hashes in `sources.json` were not taken on trust. Each was recorded from a
download whose OpenPGP signature was checked against the project's published
signing key, and `signature_url` / `signing_key` / `signer` record which. Repeat
that when bumping — the hash is only as good as the download it came from:

```bash
curl -LO <url>
curl -LO <signature_url>
gpg --recv-keys <signing_key>          # from keys.openpgp.org or keyserver.ubuntu.com
gpg --verify <signature file> <tarball>   # must say "Good signature from" <signer>
sha256sum <tarball>                    # this is the value that goes in the file
```

zlib and bzip2 publish no signature; their entries say so and explain what is
being relied on instead.

**xz is the one to be careful with.** 5.6.0 and 5.6.1 shipped the CVE-2024-3094
backdoor. A *downgrade* is the change least likely to be questioned in a diff, so
the entry's `note` says never to pin below 5.6.2. Leave that note in place.

## What should move when the second platform lands

`windows/cmake/bzip2/CMakeLists.txt` — bzip2 has no upstream CMake build on any
platform, so this is needed everywhere. It is under `windows/` only because
`windows/` is currently the sole consumer; move it to a top-level `cmake/` at the
point a second build script wants it, not before.

Nothing else is worth lifting up front. Resist writing a "generic" build driver:
the parts below are genuinely different per platform, and an abstraction over
them written before the second platform exists would be guesswork.

## What each platform answers for itself

| | Shared | Per-platform |
|---|---|---|
| Pinned versions and hashes | `sources.json` | — |
| bzip2 CMakeLists | (move to `cmake/` when needed) | — |
| Toolchain discovery | — | `VsDevCmd.bat` / Xcode / gcc |
| libarchive CMake options | — | `ENABLE_CNG` and `ENABLE_WIN32_XMLLITE` are Windows-only |
| Static library naming | — | MSVC's `.lib` names need normalizing; `.a` does not |
| Dependency check | — | `dumpbin /DEPENDENTS` / `otool -L` / `ldd` |
| Output filename | — | `archive.dll` / `libarchive.dylib` / `libarchive.so` |
| Runtime linkage | — | see "the C runtime trap" below |

## The contract a platform build must satisfy

Whatever language it is written in, a build here has to produce the same shape,
because XeFM's build steps and its users both depend on it.

1. **One library with the compression codecs linked in statically.** zlib,
   bzip2, liblzma and libzstd inside; nothing to place alongside.
2. **These codecs present, verified before packaging.** XeFM's capability probe
   answers a missing codec by not offering the format, so a wrong build ships as
   a working file manager with `.7z` quietly absent. Load the library, call
   `archive_version_details()`, and fail the build if `zlib`, `liblzma`,
   `bz2lib` or `libzstd` is missing. Do not skip this because it looks
   redundant — it is the only place the mistake is loud.
3. **This layout**, zipped:
   ```
   libarchive-<version>-<platform>-<arch>/
   ├── bin/<the library>
   ├── licenses/          one file per statically linked component
   └── MANIFEST.txt       versions and hashes actually used
   ```
4. **A `.sha256` sidecar** published beside the zip. XeFM pins by it.
5. **Forward slashes in zip entry names.** The ZIP spec requires it and some
   extractors take a backslash literally, as one file with slashes in its name.
   Windows PowerShell's `Compress-Archive` gets this wrong; see how
   `build-libarchive.ps1` writes entries by hand.

### Naming

Assets are `libarchive-<version>-<platform>-<arch>.zip` — already
platform-qualified, so new ones simply appear beside the existing
`libarchive-3.8.9-windows-x64.zip`.

Release tags are `libarchive-<version>-<build revision>`, deliberately with no
platform in them: **one release holds every platform's asset for that build**.
The revision exists so a rebuild at an unchanged libarchive version — a zlib CVE,
say — gets its own tag rather than mutating a published one.

XeFM pins tag *and* SHA-256 per platform, so platforms may be added to a later
tag without disturbing one already shipping.

## The C runtime trap

Worth reading before choosing linkage on any platform, because it cost a rebuild
and a deleted release on Windows.

libarchive converts an entry's pathname between its wide and narrow forms using a
code page it obtains by calling `setlocale(LC_CTYPE, NULL)` **in its own C
runtime** (`get_current_codepage()` in `archive_string.c`). Link that runtime
statically and it belongs to the library alone, fixed at whatever the process
started with, unreachable from the application. On Windows that meant CJK
filenames became NULL pathnames — and the ISO 9660 writer reads a NULL pathname
as its root directory and drops the file *without an error*.

So Windows links the shared MSVC runtime on purpose, and XeFM calls
`setlocale(LC_CTYPE, ".UTF8")` before loading the library. Any platform that
considers static linkage for self-containment reasons should check the same
thing: the application must be able to reach the locale the library reads.

## Per-platform notes

### macOS

The system `/usr/lib/libarchive.dylib` (3.7.4) is what XeFM uses today and is
adequate for `.7z`. The real argument for shipping one is **libzstd**: the system
build has none, so a zstd-compressed member makes libarchive reach for an
external `zstd` binary.

What a macOS build has to answer that Windows did not:

- **Universal binary** — `-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"`, and every
  static dependency built the same way, or the link fails per-slice.
- **Deployment target** — set `CMAKE_OSX_DEPLOYMENT_TARGET` to match the macOS
  app bundle's, or the dylib will refuse to load on older systems.
- **Install name** — set it to `@rpath/libarchive.dylib`; the default is an
  absolute build path that will not exist on a user's machine.
- **Signing and notarization** — a dylib inside a notarized `.app` must be
  signed with the app's identity. This is the step most likely to be discovered
  late, so plan it with the bundle work rather than here.
- **Crypto and XML** — no CNG and no XmlLite. CommonCrypto replaces the first;
  for the second, either accept no xar support or take on libxml2, which is a
  dependency this repository has so far avoided.

### Linux

Lower priority: distributions ship a libarchive, and XeFM on Linux is the
terminal build installed from PyPI. A binary here would be for users on
distributions too old to have a usable one — which makes the glibc floor the
entire problem.

- **Build against the oldest glibc you intend to support**, in a `manylinux`
  container. A library built on a current distribution will not load on an older
  one, and this is not fixable after the fact.
- **`RPATH=$ORIGIN`** so the loader looks beside the library.
- **Two assets**, `linux-x64` and `linux-arm64`.
- CNG and XmlLite are Windows-only here too; the same xar question as macOS.

## XeFM's side is already ready

No XeFM change is needed to consume a new platform's asset. `_BUNDLED_NAMES` in
`xefm/archive_libarchive.py` already looks for `archive.dll`,
`libarchive.dylib` and `libarchive.so`, in that order, inside `xefm/_bin/`.

What each platform's *bundle build* needs is its own download-and-verify step,
the counterpart of Step 4b in `windows_app/build.ps1` — pinned by tag and
SHA-256, placing the library at `app/xefm/_bin/`, checking the codec list, and
feeding the asset's `licenses/` to the third-party notices generator.
