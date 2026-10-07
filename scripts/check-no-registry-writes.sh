#!/bin/sh
# Fail if any Windows executable imports a registry API that can
# create, modify or delete registry data. This fork keeps all of its
# configuration in JSON files and must never write to the registry.
#
# Usage: scripts/check-no-registry-writes.sh <dir containing .exe files>
#        (needs a MinGW objdump, or set OBJDUMP)

set -eu
OBJDUMP=${OBJDUMP:-x86_64-w64-mingw32-objdump}
WRITERS='Reg(Create|Set|Delete|Save|Replace|Restore|Load|UnLoad|Copy|Rename|Flush|OverridePredef|ConnectRegistry)[A-Za-z]*|SHReg(Set|Write|Delete|Create)[A-Za-z]*|SHSetValue[AW]?|SHDeleteKey[AW]?|SHDeleteValue[AW]?|WriteProfileString[AW]?|WritePrivateProfileString[AW]?'

status=0
found=0
for exe in "$1"/*.exe; do
    [ -e "$exe" ] || continue
    found=1
    hits=$("$OBJDUMP" -p "$exe" | grep -oE "\b($WRITERS)\b" | sort -u || true)
    if [ -n "$hits" ]; then
        echo "FAIL: $(basename "$exe") imports: $(echo $hits)"
        status=1
    else
        echo "ok:   $(basename "$exe")"
    fi
done
[ $found = 1 ] || { echo "no .exe files in $1"; exit 1; }
exit $status
