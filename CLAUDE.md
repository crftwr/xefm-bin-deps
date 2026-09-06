# xefm-bin-deps — Claude Code Instructions

This repository builds the **binary dependencies [XeFM](https://github.com/crftwr/xefm)
cannot get from the system**. Today that is exactly one thing: libarchive for
Windows, shipped as a single `archive.dll` with zlib, bzip2, liblzma and libzstd
linked into it.

It is a separate repository from XeFM on purpose. That DLL statically links four
compression libraries with their own vulnerability cycles; keeping them here means
a CVE in any of them is answered by rebuilding and re-releasing **this**
repository, on its own schedule, instead of forcing an XeFM release. Every rule
below follows from that.

The output is consumed by `windows_app/build.ps1` Step 4b in the XeFM repo, which
downloads a release asset pinned by tag and SHA-256. Nothing here is published to
a package index.

---

## Invariants

Break any of these and the repository stops doing its job. Do not "improve" past
one without saying so explicitly.

1. **`sources.json` is the single source of truth for pinned versions.** No build
   script restates a version or a hash. When a second platform is added it reads
   the same file. This is the whole point: a copy per script is how "bumped zlib
   for Windows, still shipping the old one on macOS" happens.
2. **Pin by version AND SHA-256. Never `latest`.** XeFM's Store submissions have
   to be reproducible, and the point of a pin is that it does not move when
   nobody is looking. Every build must refuse to continue on a hash mismatch.
3. **Never pin xz below 5.6.2.** 5.6.0 and 5.6.1 shipped the CVE-2024-3094
   backdoor. A downgrade is the change least likely to be questioned in a diff,
   so the `note` in `sources.json` says this too. Leave it there.
4. **The codec self-check stays.** Before packaging, load the built library, call
   `archive_version_details()`, and fail if `zlib`, `liblzma`, `bz2lib` or
   `libzstd` is missing. It looks redundant and is not: XeFM's capability probe
   answers a missing codec by *not offering the format*, so a wrong build ships
   as a working file manager with `.7z` quietly absent. This is the only place
   that mistake is loud.
5. **The C runtime stays dynamically linked.** See "The C runtime trap".
6. **Every statically linked component's license travels in the asset**, under
   `licenses/`. XeFM's bundle reads them into its `THIRD_PARTY_NOTICES.txt`.

---

## Repository layout

| What | Where |
|------|-------|
| Pinned upstream versions + hashes | `sources.json` (root) |
| Windows build | `windows/build-libarchive.ps1` |
| CMake for deps with no upstream CMake | `windows/cmake/<name>/CMakeLists.txt` |
| Build trees, downloads, staged assets | `.cache/`, `windows/build/` (both gitignored) |
| End-user instructions | `README.md` |

`windows/cmake/bzip2/CMakeLists.txt` will be needed by **every** platform (bzip2
has no upstream CMake build anywhere). Move it to a top-level `cmake/` when a
second build script wants it — **not before**. Same for anything else: do not
hoist code into a shared location speculatively.

---

## Terminal session rules

- Use `--no-pager` for any git command that may page: `diff`, `log`, `show`,
  `branch`, `tag`, `blame`, `grep`.
- **This machine is Windows on ARM.** `platform.machine()` reports `ARM64` while
  most shells report `PROCESSOR_ARCHITECTURE=AMD64`, so the host is easy to
  misread. The build cross-compiles ARM64 host → x64 target automatically.
- **A cross-built x64 DLL cannot load into an ARM64 process.** Verify it with an
  x64 Python (XeFM's `.venv`), not from PowerShell, which may be ARM64.
- Do not launch XeFM to test a build (it is a TUI/GUI and blocks). Load the DLL
  with `ctypes` instead. Note that a *running* XeFM can hold a built zip open and
  block the next build's staging step — identify the holder via the Restart
  Manager API rather than killing processes blindly, and never kill a process
  without checking what it is.

---

## Building

Requires Visual Studio Build Tools with the C++ workload, plus CMake and Ninja —
the easiest source of the latter two is `pip install cmake ninja` (neither ships
with Build Tools, and no admin is needed).

```powershell
powershell -ExecutionPolicy Bypass -File windows\build-libarchive.ps1
```

Output lands in `windows\build\x64\` as the zip and its `.sha256`. `-Clean`
discards build trees but keeps downloads, which are hash-verified anyway.

`-Arch arm64` exists but is **untested**: it needs the `VC.Tools.ARM64` component
that this machine does not have, and XeFM ships no ARM64 Windows bundle to
consume it. The script reports a missing target toolset clearly rather than
failing obscurely.

### libarchive build options, and why

| Option | |
|---|---|
| `ENABLE_CNG=ON` | Hashes via Windows' own bcrypt. This is what lets `ENABLE_OPENSSL=OFF` cost nothing. |
| `ENABLE_WIN32_XMLLITE=ON` | xar's XML via the OS, so no libxml2 and no expat. |
| zlib, bzip2, liblzma | Required — invariant 4 explains what silently disappears without each. |
| libzstd | Required, though `.tar.zst` goes through Python's tarfile. A zstd-compressed 7z entry or zstd-payload rpm is a codec *inside* a container, which XeFM's probe cannot see, and libarchive answers a codec it lacks by spawning `zstd.exe` — absent on Windows. |
| lz4, lzo, libb2, PCRE, iconv, tar/cpio/cat/unzip, tests | OFF. No format XeFM offers needs them. |

**CNG does not enable encrypted archives.** As of libarchive 3.8.9, zip is the
only format libarchive decrypts — the 7z and RAR5 readers reject an encrypted
entry unconditionally, with no crypto `#ifdef` near them. The option name invites
the opposite assumption; do not act on it.

---

## Bumping a pinned version

The hashes in `sources.json` were not taken on trust. Each came from a download
whose OpenPGP signature was checked against the project's published signing key —
`signature_url`, `signing_key` and `signer` record which. **Repeat that**; a hash
is only as good as the download it came from.

```bash
curl -LO <url>
curl -LO <signature_url>
gpg --recv-keys <signing_key>            # keys.openpgp.org, or keyserver.ubuntu.com
gpg --verify <sig> <tarball>             # must say "Good signature from" <signer>
sha256sum <tarball>                      # this is the value that goes in the file
```

zlib and bzip2 publish no signature; their `note` fields say what is relied on
instead. Then rebuild every platform and cut one release.

---

## Releasing

- **Tag**: `libarchive-<version>-<build revision>` — deliberately with no
  platform in it, so **one release holds every platform's asset**. The revision
  exists so a rebuild at an unchanged libarchive version (a zlib CVE, say) gets
  its own tag instead of mutating a published one.
- **Assets**: `libarchive-<version>-<platform>-<arch>.zip` plus a `.sha256`
  sidecar. XeFM pins tag *and* hash per platform, so a platform can be added to a
  later tag without disturbing one already shipping.
- **Never mutate a published asset.** If a build is wrong, cut the next revision.
  Deleting a release is only appropriate for one published minutes ago that
  nothing can have consumed.
- After releasing, update `$LibarchiveTag` **and** `$LibarchiveSha256` together in
  XeFM's `windows_app/build.ps1`. Changing one alone fails the hash check, so
  this cannot break silently — but it will break the build.
- Release notes should say what the codec line is, since that is what determines
  which formats XeFM offers.

---

## The C runtime trap

Read this before changing linkage on any platform. It cost a rebuild and a
deleted release.

libarchive converts an entry's pathname between wide and narrow forms using a
code page it obtains by calling `setlocale(LC_CTYPE, NULL)` **in its own C
runtime** (`get_current_codepage()` in `archive_string.c`). Link that runtime
statically and it belongs to the library alone, fixed at the process ANSI code
page, unreachable from the application.

On a machine whose ACP is 1252, that makes `archive_entry_pathname()` return NULL
for any CJK name — and the iso9660 writer reads a NULL pathname as its root
directory and **drops the file with no error at all**.

So `/MD` is deliberate, and XeFM calls `setlocale(LC_CTYPE, ".UTF8")` before
loading the library. The cost is an import of `vcruntime140.dll`, which XeFM's
bundle already ships for CPython. Any platform tempted by static linkage for
self-containment must check the same thing: **the application has to be able to
reach the locale the library reads.**

---

## Adding a platform

Only Windows is built today, because it is the only platform XeFM supports with
no system libarchive. The strongest case for a second is **macOS**, whose system
libarchive (3.7.4) has no libzstd — so a zstd-compressed member makes it reach for
an external `zstd` binary.

### Shared vs per-platform

| | Shared | Per-platform |
|---|---|---|
| Pinned versions and hashes | `sources.json` | — |
| bzip2 CMakeLists | (move to `cmake/` when needed) | — |
| Toolchain discovery | — | `VsDevCmd.bat` / Xcode / gcc |
| libarchive options | — | `ENABLE_CNG`, `ENABLE_WIN32_XMLLITE` are Windows-only |
| Static library naming | — | MSVC `.lib` names need normalizing; `.a` does not |
| Dependency check | — | `dumpbin /DEPENDENTS` / `otool -L` / `ldd` |
| Output filename | — | `archive.dll` / `libarchive.dylib` / `libarchive.so` |

**Do not write a generic build driver.** The per-platform column is genuinely
different, and an abstraction over it written before a second case exists is
guesswork. Write `macos/build-libarchive.sh` separately; share only the manifest
and the bzip2 CMakeLists.

### The asset contract

Whatever language a build is written in, it must produce this shape:

```
libarchive-<version>-<platform>-<arch>/
├── bin/<the library>
├── licenses/          one file per statically linked component
└── MANIFEST.txt       versions and hashes actually used
```

Plus: the codec self-check (invariant 4), a `.sha256` sidecar, and **forward
slashes in zip entry names** — the ZIP spec requires it and some extractors treat
a backslash literally, as one file with slashes in its name. Windows PowerShell's
`Compress-Archive` gets this wrong; `build-libarchive.ps1` writes entries by hand
to avoid it.

### macOS notes

- **Universal binary** — `-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"`, and every
  static dependency built the same way or the link fails per-slice.
- **`CMAKE_OSX_DEPLOYMENT_TARGET`** must match the macOS app bundle's, or the
  dylib will not load on older systems.
- **Install name** — set `@rpath/libarchive.dylib`; the default is an absolute
  build path that will not exist on a user's machine.
- **Signing and notarization** — a dylib inside a notarized `.app` must be signed
  with the app's identity. Most likely to be discovered late; plan it with the
  bundle work, not here.
- **No CNG, no XmlLite** — CommonCrypto replaces the first; for the second,
  either accept no xar support or take on libxml2, a dependency this repository
  has so far avoided.

### Linux notes

Lower priority: distributions ship a libarchive, and XeFM on Linux is the
terminal build from PyPI. A binary here would serve users on distributions too
old to have a usable one — which makes the glibc floor the entire problem.

- **Build against the oldest glibc you intend to support**, in a `manylinux`
  container. This is not fixable after the fact.
- **`RPATH=$ORIGIN`** so the loader looks beside the library.
- Two assets: `linux-x64` and `linux-arm64`.

### XeFM's side is already ready

No XeFM change is needed to consume a new platform's asset. `_BUNDLED_NAMES` in
`xefm/archive_libarchive.py` already looks for `archive.dll`,
`libarchive.dylib` and `libarchive.so`, in that order, inside `xefm/_bin/`.

What each platform's *bundle build* needs is its own download-and-verify step —
the counterpart of Step 4b in XeFM's `windows_app/build.ps1`: pinned by tag and
SHA-256, placing the library at `app/xefm/_bin/`, checking the codec list, and
feeding the asset's `licenses/` to the notices generator.
