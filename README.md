# NewPutty

NewPutty is a modified version of [PuTTY](https://www.chiark.greenend.org.uk/~sgtatham/putty/),
the free SSH and Telnet client by Simon Tatham and contributors. It is
based on the **PuTTY 0.84** release. It adds:

* **SSHFP host key checks.** Host keys are checked against SSHFP
  records published in DNS ([RFC 4255](https://www.rfc-editor.org/rfc/rfc4255),
  [RFC 6594](https://www.rfc-editor.org/rfc/rfc6594)).
* **JSON configuration files instead of the Windows registry.**
  Nothing is written to the registry.
* **The same settings files on every platform.** Windows, macOS and
  Linux all read and write the same JSON files.
* **A native macOS app.** `PuTTY.app` is a Cocoa application that
  needs nothing beyond macOS itself.

Apart from these changes, the code is kept as close to upstream as
possible, so that new PuTTY releases can be merged in easily.

> NewPutty is not an official PuTTY release, and it isn't supported by
> the PuTTY developers. Please don't send bug reports about NewPutty
> to them; open an issue in this repository instead.

## Upstream PuTTY

* Website: <https://www.chiark.greenend.org.uk/~sgtatham/putty/>
* Git repository: <https://git.tartarus.org/simon/putty.git>
  (browse it at <https://git.tartarus.org/?p=simon/putty.git>)
* The base for this fork is the 0.84 release source tarball, imported
  in commit `97e4f49` ("Import upstream PuTTY 0.84 release tarball").
  Run `git diff 97e4f49` to see every change made since.

Upstream's own source README is kept, unchanged, as [`README`](README).

## Licence

PuTTY is copyright 1997-2026 Simon Tatham, with portions copyright to
the other people listed in [`LICENCE`](LICENCE). It is distributed
under the MIT licence. The full text and all of upstream's copyright
notices are in [`LICENCE`](LICENCE), unchanged from the 0.84 release.
The changes in NewPutty are released under the same licence.

If you redistribute this source code, or programs built from it, you
must include that copyright and permission notice:

* PuTTY, PuTTYgen and Pageant show it under *About > Licence*. It's
  compiled in from `LICENCE`.
* The command-line tools (`plink`, `pscp`, `psftp` and so on) don't
  show it, so ship `LICENCE` alongside them, as upstream does. The
  binaries that CI builds include `LICENCE`.

Some source files carry their own copy of the same MIT notice, for
example `charset/macenc.c` (copyright Ben Harris). Keep those notices
as they are.

`LICENCE` keeps upstream's file name and exact contents so that
upstream releases merge cleanly. Don't rename or reformat it.

## How NewPutty differs from PuTTY 0.84

[`FORK.md`](FORK.md) has the full details. In summary:

| Area | Upstream PuTTY 0.84 | NewPutty |
|---|---|---|
| Settings storage, Windows | Registry, under `HKCU\Software\SimonTatham\PuTTY` | JSON files in `%USERPROFILE%\.putty`. The registry is only read, and only to import old settings. |
| Settings storage, Unix | Text files in `~/.putty` or `~/.config/putty` | JSON files in `~/.putty` |
| Settings location | Different on each platform, with several overrides (`PUTTYSESSIONS`, etc.) | `$PUTTYDIR` if set, otherwise `~/.putty`, on every platform |
| Host key checks | Local cache only | Local cache, plus SSHFP records in DNS |
| macOS | GTK build (needs Homebrew/XQuartz) | Native Cocoa `PuTTY.app` that needs only macOS. The GTK build is still available. |
| Importing old settings | — | **Import** button on the Session panel reads a `.reg` export of upstream's registry settings, on any platform |
| CI | — | GitHub Actions builds and tests on Linux, macOS and Windows (MinGW and MSVC) |

### SSHFP

In *Connection > SSH > Host keys*, the **DNS SSHFP Settings** button
opens a box with three choices:

* **Never look up SSHFP records.**
* **Report the result, but always ask me** (the default). The
  result is shown when PuTTY asks you to confirm a new host key.
* **Trust a DNSSEC-validated match.** A new key that matches a
  DNSSEC-validated SSHFP record is accepted without asking.

The **Require valid SSHFP** checkbox in the same box (off by default)
refuses any connection whose host key doesn't match an SSHFP record.
On Windows, SSHFP checks are advisory only for now: matches are shown,
but they never skip the prompt. Every lookup is recorded in the Event
Log.

### Settings files

```
~/.putty/                  (%USERPROFILE%\.putty on Windows; $PUTTYDIR overrides)
  sessions/<name>.json     one file per saved session
  hostcas/<name>.json      one file per trusted host CA
  hostkeys.json            SSH host key cache
  randomseed               random seed (binary)
  jumplist.json            Windows jump list (recent sessions)
```

Setting names and values are the same as upstream's, so you can copy
settings over or write them by hand. [`FORK.md`](FORK.md) describes the
file format.

## Folder layout

| Path | Contents |
|---|---|
| `*.c`, `*.h` (top level) | Code shared by all the programs: settings (`settings.c`, `config.c`), storage interface (`storage.h`, `jsonstore.c`), registry import (`regimport.c`), PSCP/PSFTP, Pageant core, logging, etc. |
| `ssh/` | SSH protocol implementation, including the SSHFP check (`ssh/sshfp.c`) |
| `crypto/` | Ciphers, MACs, hashes, key exchange and public-key algorithms |
| `keygen/` | Key and prime generation for PuTTYgen |
| `terminal/` | Terminal emulator |
| `proxy/` | Proxy support (HTTP, SOCKS, Telnet, local command) |
| `otherbackends/` | Non-SSH connection types: Telnet, rlogin, raw, SUPDUP, serial test |
| `utils/` | Small general-purpose routines, including the JSON parser (`utils/json.c`) |
| `charset/` | Character set conversion library |
| `unicode/` | Unicode data tables and the scripts that generate them |
| `stubs/` | Do-nothing stand-ins for features a particular program doesn't need |
| `windows/` | Windows front end: GUI, Windows networking, file storage (`windows/storage.c`), DNS lookups (`windows/dns.c`), installer |
| `unix/` | Unix front end: GTK GUI, `pterm`, Unix networking, file storage (`unix/storage.c`), DNS lookups (`unix/dns.c`). On macOS, the command-line tools are built from here too. |
| `macos/` | **NewPutty only.** Native Cocoa front end that builds `PuTTY.app` |
| `cmake/` | CMake helper modules, platform settings and cross-compilation toolchains (`cmake/toolchain-mingw.cmake`) |
| `doc/` | Manual and man pages, in Halibut (`.but`) format |
| `icons/` | Scripts that draw the program icons |
| `test/` | Unit tests (`test_jsonstore.c`, `test_sshfp.c`, `test_regimport.c`, …), the cryptography test suite, and the SSHFP end-to-end test (`sshfp-e2e.sh`) |
| `scripts/` | **NewPutty only.** CI helpers: registry-write check, macOS dependency check and smoke test, binary collection |
| `contrib/` | Unsupported extra tools from upstream |
| `.github/workflows/` | **NewPutty only.** GitHub Actions build and test pipeline |
| `LICENCE` | Licence and copyright notices (from upstream, unchanged) |
| `README` | Upstream's source README (unchanged) |
| `FORK.md` | Full description of NewPutty's changes, status and next steps |

## Building

PuTTY is built with [CMake](https://cmake.org/) (version 3.7 or newer)
and a C99 compiler. In each case below, the programs end up in the
`build` directory.

### Linux and other Unix systems

Install a compiler, CMake and the GTK 3 development files. For
example, on Debian or Ubuntu:

```sh
sudo apt-get install build-essential cmake libgtk-3-dev
```

Then:

```sh
cmake -S . -B build
cmake --build build -j"$(nproc)"
sudo cmake --install build      # optional
```

This builds `putty`, `pterm`, `puttygen`, `pageant`, `plink`, `pscp`,
`psftp` and `psocks`. Without GTK, only the command-line tools are
built.

### macOS

You need Xcode or the Xcode Command Line Tools
(`xcode-select --install`), and CMake (for example
`brew install cmake`, or the installer from cmake.org). Nothing else is
needed.

```sh
cmake -S . -B build -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0
cmake --build build -j"$(sysctl -n hw.ncpu)"
open build/PuTTY.app
```

The command-line tools are built next to `PuTTY.app` in `build/`.
macOS 12 is the oldest version supported. To build with GTK instead of
Cocoa, add `-DPUTTY_MACOS_COCOA=OFF` (this needs GTK 3 from Homebrew).

To work in the Xcode IDE, generate an Xcode project:

```sh
cmake -G Xcode -S . -B build-xcode
open build-xcode/putty.xcodeproj
```

To build it from the command line instead:

```sh
xcodebuild -project build-xcode/putty.xcodeproj -scheme putty -configuration Release build
```

The app is then at `build-xcode/Release/PuTTY.app`. If `xcode-select -p`
points at the Command Line Tools rather than Xcode, run the build with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` set.

Locally built and CI-built copies of `PuTTY.app` are signed ad hoc, not
notarised. To open a downloaded copy, Control-click it in the Finder and
choose Open, or run:

```sh
xattr -dr com.apple.quarantine PuTTY.app
```

### Windows

With Visual Studio (2019 or later, with the C++ workload), run this
from a Developer Command Prompt:

```bat
cmake -S . -B build
cmake --build build --config Release
```

The programs are put in `build\Release`.

To cross-compile from Linux with MinGW-w64:

```sh
sudo apt-get install cmake gcc-mingw-w64-x86-64
cmake -S . -B build -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-mingw.cmake
cmake --build build -j"$(nproc)"
```

### Documentation

The manual and man pages are built from `doc/*.but` if
[Halibut](https://www.chiark.greenend.org.uk/~sgtatham/halibut/) is
installed. Without it, the build skips them.

## Testing

```sh
build/test_jsonstore /tmp/empty-dir      # JSON parser and settings storage
build/test_regimport /tmp/empty-dir2     # .reg file import
build/test_sshfp                         # SSHFP record parsing and key matching
sudo test/sshfp-e2e.sh build             # real sshd plus fake DNS (Linux)
scripts/check-no-registry-writes.sh build   # Windows builds: no registry writes
scripts/check-macos-deps.sh build           # macOS: only system libraries linked
```

Every push is built and tested by [GitHub Actions](.github/workflows/build.yml)
on Linux, macOS and Windows. Each run publishes the binaries, with
`LICENCE` and `FORK.md`, as downloadable artifacts.

## Contributing

Keep changes to upstream files small and self-contained, and put new
functionality in new files where possible, so that future PuTTY
releases can be merged in. Add any new upstream file you change to the
list in [`FORK.md`](FORK.md).
