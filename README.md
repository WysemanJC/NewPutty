# NewPutty

NewPutty is a fork of [PuTTY](https://www.chiark.greenend.org.uk/~sgtatham/putty/),
the free SSH and Telnet client by Simon Tatham and the PuTTY team. It
is based on the **PuTTY 0.84** release and adds:

- **SSHFP host key checks.** Host keys are checked against SSHFP
  fingerprints published in DNS (RFC 4255 and RFC 6594), optionally
  trusting DNSSEC-validated answers.
- **JSON configuration files instead of the Windows registry.** Settings
  live in `~/.putty` as plain JSON on every platform, and nothing is
  ever written to the registry.
- **A native macOS app.** On macOS, PuTTY is a Cocoa application that
  needs nothing beyond macOS itself: no GTK, XQuartz or Homebrew.

Apart from those changes, the aim is to stay as close to upstream PuTTY
as possible, so that new upstream releases can be merged in easily.

## Upstream PuTTY

All of PuTTY's original work belongs to its authors. This fork is not
an official PuTTY release, and it isn't supported by the PuTTY team, so
please don't send them bug reports about it.

- Website: <https://www.chiark.greenend.org.uk/~sgtatham/putty/>
- Source repository: <https://git.tartarus.org/?p=simon/putty.git>
  (clone with `git clone https://git.tartarus.org/simon/putty.git`)
- Upstream's own source README: [`README`](README), kept unchanged

## Licence

PuTTY is copyright 1997-2026 Simon Tatham, with portions copyright to
the other contributors named in [`LICENCE`](LICENCE). It is distributed
under the MIT licence, and the full text is in [`LICENCE`](LICENCE),
unchanged from upstream. The changes in this fork are released under
the same licence.

If you redistribute this source code or binaries built from it, you
must include that copyright and permission notice. The GUI programs
show it under *About > Licence*, because it is compiled in from
`LICENCE`. The command-line tools don't show it, so ship `LICENCE`
alongside them. A few source files, such as `utils/tree234.c` and
`charset/macenc.c`, carry their own MIT-style notices in their headers.
Those notices must also be kept.

## How this fork differs from PuTTY 0.84

| Area | Upstream PuTTY 0.84 | NewPutty |
|---|---|---|
| Settings storage | Windows registry on Windows; text files in `~/.putty` (or XDG) on Unix | JSON files in `~/.putty` on every platform (or `$PUTTYDIR`) |
| Registry | Read and written | Never written. Old settings can be imported from a `.reg` export |
| Host key checking | Cache, manually configured keys and host CAs | All of that, plus SSHFP records from DNS |
| macOS | GTK build, needing GTK from Homebrew or MacPorts | Native Cocoa `PuTTY.app` that uses only system libraries |
| CI | Not included | GitHub Actions builds and tests Linux, macOS and Windows (MinGW and MSVC) |

The details follow.

### JSON configuration

All settings live in one directory: `$PUTTYDIR` if it is set, otherwise
`~/.putty` (`%USERPROFILE%\.putty` on Windows).

```
~/.putty/
  sessions/<name>.json     one file per saved session
  hostcas/<name>.json      one file per trusted host CA
  hostkeys.json            SSH host key cache
  randomseed               random seed
  jumplist.json            Windows jump list (recent sessions)
```

Setting names and values are exactly the same as upstream's, so the
files are easy to read and edit by hand. Writes are atomic, and files
are created mode 0600 on Unix. Upstream's Unix-only environment
variables (`PUTTYSESSIONS` and the like) and the XDG `~/.config/putty`
lookup are gone, so the rule is the same everywhere.

Existing PuTTY sessions, host keys and CAs can be imported from a
Windows registry export (a `.reg` file) with the **Import** button on
the Session panel. This works on any platform and never overwrites
existing settings.

### SSHFP

The setting is *Connection > SSH > Host keys > DNS SSHFP Settings*:

- **Never**: no DNS lookup.
- **Ask** (the default): look up SSHFP and say in the host key prompt
  whether the key matches.
- **Yes**: as Ask, but an unknown key matching a DNSSEC-validated
  record is accepted without a prompt.

A separate *Require valid SSHFP* option refuses any connection whose
key doesn't match a published record. Lookups run in the background,
are skipped when a proxy resolves host names, and are logged to the
Event Log. On Windows, matches are shown but never skip the prompt,
because Windows doesn't report DNSSEC validation reliably.

### Native macOS app

`macos/` holds a Cocoa front end that replaces the GTK one on macOS.
It's one process with any number of session windows, a normal Mac menu
bar and upstream's full configuration box. Option and/or Command can
act as Meta. It links only against libraries and frameworks that ship
with macOS, and CI checks this.

[`FORK.md`](FORK.md) has the full design notes, the decisions made
along the way, the list of files changed from upstream and the
remaining work.

## Folder layout

| Path | Contents |
|---|---|
| `ssh/` | The SSH protocol: transport, key exchange, user authentication, connection layer, SSHFP checks (`ssh/sshfp.c`) |
| `crypto/` | Ciphers, MACs, hashes, public-key algorithms, bignum arithmetic |
| `terminal/` | The terminal emulator, shared by every platform |
| `otherbackends/` | Telnet, rlogin, SUPDUP, raw and serial backends |
| `proxy/` | Proxy support (SOCKS, HTTP, Telnet, local command, SSH jump hosts) |
| `keygen/` | Key generation and prime finding for PuTTYgen |
| `utils/` | Small general-purpose helpers, including the JSON parser (`utils/json.c`) |
| `charset/`, `unicode/` | Character set conversion tables and Unicode data |
| `stubs/` | Do-nothing versions of subsystems, for programs that don't need them |
| `unix/` | Unix front ends: the GTK PuTTY and pterm, plus the command-line tools |
| `windows/` | Windows front ends and installer |
| `macos/` | **New.** The native Cocoa PuTTY.app and its icon generator |
| `cmake/` | CMake modules, including the MinGW cross-compile toolchain |
| `icons/` | Scripts that draw PuTTY's icons at every size |
| `doc/` | The manual and man pages, in Halibut format |
| `test/` | Unit tests, cryptographic test suites and the SSHFP end-to-end test |
| `scripts/` | **New.** Checks used by CI (no registry writes, macOS dependencies, smoke tests) and binary packaging |
| `contrib/` | Extra tools from upstream (log parsers, `kh2reg.py` and others) |
| `.github/workflows/` | **New.** CI for Linux, macOS and Windows |

Top-level files:
- **New in this fork:** `jsonstore.c` (the shared JSON storage),
  `regimport.c` (`.reg` import) and `FORK.md`.
- **Upstream:** the programs' own sources, such as `pscp.c`,
  `psftp.c`, `cmdgen.c` (PuTTYgen) and `pageant.c`, plus `settings.c`,
  `config.c`, `putty.h` and the other shared core files.

## Building

Every platform builds with [CMake](https://cmake.org/) 3.7 or later and
a C99 compiler. Python 3 is optional; it is used to draw the macOS app
icon. Build in a separate directory:

```
cmake -S . -B build
cmake --build build
```

### Linux and other Unix systems

You need a C compiler, CMake and, for the GUI programs, GTK 3. On
Debian or Ubuntu:

```
sudo apt-get install cmake libgtk-3-dev
cmake -S . -B build
cmake --build build -j"$(nproc)"
sudo cmake --install build        # optional
```

This builds `putty`, `pterm`, `puttytel`, `puttygen`, `plink`, `pscp`,
`psftp`, `pageant` and `psocks`. Without GTK, only the command-line
tools are built.

### macOS

You need the Xcode Command Line Tools (`xcode-select --install`) and
CMake (from <https://cmake.org/download/> or `brew install cmake`).
Nothing else is needed.

```
cmake -S . -B build
cmake --build build
open build/PuTTY.app
```

To work in Xcode instead:

```
cmake -G Xcode -B build-xcode
open build-xcode/putty.xcodeproj
```

Then choose the **putty** scheme and press Run.

Builds run on macOS 12 and later. To target another version, pass
`-DCMAKE_OSX_DEPLOYMENT_TARGET=<version>`. To build the old GTK
version instead, configure with `-DPUTTY_MACOS_COCOA=OFF`.

The app is signed ad hoc, not notarised, so a downloaded copy is
blocked by Gatekeeper at first. Control-click it and choose Open, or
run:

```
xattr -dr com.apple.quarantine /Applications/PuTTY.app
```

### Windows

With Visual Studio (2019 or later, with the C++ workload) or the Build
Tools, from a Developer Command Prompt:

```
cmake -S . -B build
cmake --build build --config Release
```

To cross-compile from Linux with MinGW-w64:

```
sudo apt-get install gcc-mingw-w64-x86-64
cmake -S . -B build -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-mingw.cmake
cmake --build build
```

### Tests

```
build/test_jsonstore "$(mktemp -d)"   # JSON parser and storage
build/test_sshfp                      # SSHFP parsing and matching
sudo test/sshfp-e2e.sh build          # real sshd with fake DNS (Linux)
scripts/check-no-registry-writes.sh build   # Windows builds
scripts/check-macos-deps.sh build           # macOS builds
```

## Prebuilt binaries

Every push runs the [build workflow](.github/workflows/build.yml).
Each run on the
[Actions page](https://github.com/WysemanJC/NewPutty/actions) has
binaries for Linux (x86-64), macOS (Apple silicon, as `PuTTY.app.zip`)
and Windows (x64, from MinGW and MSVC).

## Documentation

PuTTY's manual is in `doc/`, in
[Halibut](https://www.chiark.greenend.org.uk/~sgtatham/halibut/)
format. Upstream's online copy is at
<https://the.earth.li/~sgtatham/putty/latest/htmldoc/>. Some pages
still mention the registry; settings now live in `~/.putty` as
described above.
