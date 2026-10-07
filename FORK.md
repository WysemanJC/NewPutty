# PuTTY fork: JSON config, SSHFP, portability

This tree is PuTTY 0.84 with three changes:

1. **SSHFP host key checks** (RFC 4255, RFC 6594): host keys are checked
   against fingerprints published in DNS.
2. **JSON configuration files instead of the Windows registry.** Nothing
   is written to the registry.
3. **One storage format on every platform**, so Windows, macOS and Linux
   read and write the same files.

Everything else is meant to stay as close to upstream as possible, so
that new upstream releases can be merged with little conflict.

## Licence

PuTTY is distributed under the MIT licence; the full text, with
upstream's copyright notices, is in [`LICENCE`](LICENCE), unchanged
from the 0.84 release. The changes in this fork are released under the
same licence. Anyone redistributing this tree or binaries built from it
must keep that notice. PuTTY, PuTTYgen and Pageant show it under
*About > Licence* (compiled in from `LICENCE`); the command-line tools
don't, so ship `LICENCE` alongside the binaries, as upstream does.

`LICENCE` keeps upstream's file name and contents so that upstream
releases merge cleanly; don't rename it or reformat it.

## Status

| Area | State |
|---|---|
| JSON storage, Unix | Done; unit tests pass (also under ASan/UBSan) |
| JSON storage, Windows | Done; cross-compiles with MinGW; not yet run on Windows |
| No registry writes | Done; no `.exe` imports a registry write API (checked by script) |
| SSHFP, Unix | Done; unit tests and an end-to-end test against a real sshd pass |
| SSHFP, Windows | Done, advisory only (see below); not yet run on Windows |
| macOS | Should build via the GTK port; CI job added but not yet run |
| Import of existing settings | Not started |

## Configuration directory

* `$PUTTYDIR` if set, otherwise `~/.putty` (`%USERPROFILE%\.putty` on
  Windows).
* Upstream's Unix-only overrides (`PUTTYSESSIONS`, `PUTTYSSHHOSTKEYS`,
  `PUTTYRANDOMSEED`, `PUTTYSSHHOSTCAS`) and the XDG `~/.config/putty`
  lookup are gone, so the location rule is the same everywhere.

Layout:

```
~/.putty/
  sessions/<name>.json     one file per saved session
  hostcas/<name>.json      one file per trusted host CA
  hostkeys.json            SSH host key cache
  randomseed               random seed (binary)
  jumplist.json            Windows jump list (recent sessions)
```

Session file example:

```json
{
  "format": "putty-session",
  "version": 1,
  "name": "My Server",
  "settings": {
    "HostName": "example.org",
    "PortNumber": 22,
    "VerifyHostKeyDNS": 2
  }
}
```

Setting keys and values are exactly upstream's, so the settings code
(`settings.c`) is untouched. Strings are JSON strings, integers are
JSON numbers. Missing keys take PuTTY's defaults, so a hand-written
file only needs the settings it cares about.

File names encode the session name: lower-case letters, digits and
`-_.@+` are kept; everything else becomes `%XX`, including upper case
(so names differing only in case can't collide on Windows or macOS).
Windows device names such as `CON` are escaped too. "Default Settings"
is `%44efault%20%53ettings.json`.

All writes go to a temporary file which is flushed and then renamed
over the target, so a crash can't leave a half-written file. On Unix
the files are created mode 0600. A corrupt `hostkeys.json` is treated
as "no keys known" (so you are prompted) and is never overwritten.

## SSHFP

Setting: *Connection > SSH > Host keys > DNS SSHFP Settings > Check
unknown host keys against DNS*, saved as `VerifyHostKeyDNS`. It
follows OpenSSH's option of the same name. The button opens a small
modal box (like *Configure host CAs*, but editing the session being
configured), because the Host keys panel has no room left at 640x480.

| Value | Behaviour |
|---|---|
| 0, never | No lookup |
| 1, ask (default) | Look up; say in the host key prompt whether the key matches |
| 2, yes | As "ask", and an uncached key matching a DNSSEC-validated record is accepted without a prompt (and not stored) |

A second setting in the same box, *Require valid SSHFP* (saved as
`RequireSSHFP`, off by default), makes a match compulsory: SSHFP is
looked up on **every** connection, cached keys included, and the
connection is refused (no "accept anyway" prompt) unless the key
matches a record. It fails closed: no records, a mismatch, a failed
lookup, or no lookup (proxy resolving names, key type or certificate
SSHFP can't describe) all refuse. The match need not be
DNSSEC-validated (Windows can't tell). Manually configured host keys
and CA-accepted certificates are not affected, as they're decided
before the cache and DNS are consulted.

Decisions made where the request didn't say:

* **Default is "ask".** "Yes" trusts the resolver's AD bit, which
  anyone who can forge the DNS answer can also forge on macOS, the BSDs
  and glibc before 2.31 (which pass AD through unless told not to).
  So by default a DNS match is advice in the prompt, never a reason to
  skip it. (OpenSSH's own default is "no".)
* **The lookup never blocks.** It runs on a short-lived helper thread
  (the only thing that thread does), and the host key check carries on
  from the event loop when it finishes, as it would after a dialog box.
  This follows PuTTY's rule that almost nothing may block.
* **No lookup when a proxy resolves host names** (the same test as
  `name_lookup` uses), so the local resolver doesn't learn the
  destination.
* **Lookups happen only when the key isn't already cached**, so known
  hosts cost no extra DNS query and leak nothing.
* **A key that contradicts the cache always gets the full warning**,
  even with a validated DNS match. OpenSSH would accept it silently;
  we show the DNS result as extra evidence instead.
* A published fingerprint that doesn't match adds a "DNS FINGERPRINT
  MISMATCH" warning to the prompt.
* Certificates and IP-literal hosts are not looked up.
* "Validated" means the resolver set the AD bit **and** the OS is
  configured to trust it (glibc strips AD unless `options trust-ad` is
  in `/etc/resolv.conf`). We never decide that ourselves.
* **Windows is advisory only for now**: `DnsQuery` doesn't expose a
  trustworthy validation flag, so matches are shown but never skip the
  prompt.

Every lookup result goes to the Event Log.

## Files changed from upstream

New: `json.h`, `utils/json.c`, `jsonstore.h`, `jsonstore.c`,
`sshfp.h`, `ssh/sshfp.c`, `unix/dns.c`, `windows/dns.c`,
`test/test_jsonstore.c`, `test/test_sshfp.c`, `test/sshfp-e2e.sh`,
`test/fake_dns.py`, `scripts/check-no-registry-writes.sh`,
`.github/workflows/build.yml`.

Rewritten: `unix/storage.c`, `windows/storage.c` (now only filesystem
primitives and platform-specific setting types).

Small edits: `conf.h`, `conf-enums.h`, `putty.h` (new setting),
`config.c` (new radio buttons), `ssh.h`, `ssh/common.c`,
`ssh/kex2-client.c`, `ssh/login1.c` (SSHFP in host key verification),
`windows/utils/registry.c` and `windows/platform.h` (read-only registry
helpers), `windows/pageant.c` (sessions menu via storage API),
`windows/putty.c` (`-cleanup` text), `doc/config.but`, CMake files.

## Testing

```
cmake -S . -B build && cmake --build build
build/test_jsonstore /tmp/empty-dir      # JSON parser and storage
build/test_sshfp                         # DNS parsing and key matching
sudo test/sshfp-e2e.sh build             # real sshd + fake DNS (Linux)
scripts/check-no-registry-writes.sh <dir with .exe files>
```

The end-to-end test covers: validated match accepted without a prompt;
unvalidated match prompts; validated mismatch warns; no records; and
SSHFP turned off in a hand-written JSON Default Settings file.

## Next steps

1. **Import existing settings.** A read-only `-import-registry` on
   Windows (sessions, host keys, CAs from
   `HKCU\Software\SimonTatham\PuTTY`), and an importer for upstream's
   Unix text files in `~/.putty`. Without this, switching users lose
   their sessions and host keys.
2. **Run on real Windows**: the binaries are only cross-compiled so
   far. Check with Process Monitor that nothing writes the registry,
   including Windows itself on our behalf (the common file dialogs keep
   a recent-files list; `OFN_DONTADDTORECENT` should stop that).
3. **Windows text encoding.** The Windows GUI passes some strings in
   the ANSI code page. They round-trip, but non-ASCII ones aren't valid
   UTF-8 JSON. Convert at the storage boundary.
4. **Windows DNSSEC**: use `DnsQueryRaw` (Windows 11) to read the AD
   bit, or trust only a resolver on localhost.
5. **Command-line switch** for SSHFP mode in plink/pscp/psftp
   (e.g. `-sshfp off|ask|yes`).
6. **Concurrent writes to `hostkeys.json`.** Two PuTTYs storing keys at
   the same moment can lose one update (upstream Unix has the same
   race). Add a lock file.
7. **macOS**: confirm the CI GTK build; package as an app bundle
   (upstream has `unix/osxlaunch.c`). A native Cocoa interface is a
   separate, much larger project.
8. **Docs**: replace remaining registry references in `doc/` and the
   man pages.
9. **Upstream tracking**: import the official git history (the build
   environment couldn't reach git.tartarus.org; this tree came from the
   0.84 release tarball) so later releases merge cleanly.
