#!/bin/bash
# This file is part of LanScreen.
# Copyright (C) 2026 Kendal Percimoney
#
# LanScreen is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# LanScreen is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program. If not, see <https://www.gnu.org/licenses/>.
#
# Whether the Windows client builds, and whether what it builds would load on
# Windows 7.
#
# A program that calls one function Windows 7 does not have does not start at
# all: the loader refuses it with "The procedure entry point ... could not be
# located", before a single line of it runs. Nothing on this Mac can run it, so
# this reads the import table instead. Every DLL it names has to be one
# Windows 7 ships, and none of the functions can be from the list of ones added
# in Windows 8 and later that toolchains and FFmpeg are known to reach for.
#
# The C runtime has to be msvcrt.dll. The Universal C Runtime is a DLL Windows
# 7 only has after a particular update, and without it the program does not
# start: "api-ms-win-crt-convert-l1-1-0.dll is missing from your computer",
# which is what the first build did on the iMac.
#
# --no-build [dir] audits what build/windows (or dir) already holds instead.
# Reads the import table with Homebrew's mingw-w64 objdump.
#
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${1:-}" = "--no-build" ]; then
    OUT="${2:-$ROOT/build/windows}"
else
    OUT="${TMPDIR:-/tmp}/lanscreen-windows-build"
    rm -rf "$OUT"
    OUT_DIR="$OUT" "$ROOT/Client/windows/build.sh" > "$OUT.log" 2>&1 || { cat "$OUT.log"; echo "RESULT: FAIL (build)"; exit 1; }
fi
EXE="$OUT/LanScreen-Windows/lanscreen.exe"

failures=0
check() { if [ "$2" = "0" ]; then echo "  ok   $1"; else echo "  FAIL $1"; failures=$((failures + 1)); fi; }

x86_64-w64-mingw32-objdump -p "$EXE" > "$OUT/headers.txt"
awk '/DLL Name:/{dll=$3; next} dll && NF==4 && $2=="<none>"{print dll, $4}' "$OUT/headers.txt" > "$OUT/imports.txt"

echo
echo "==> lanscreen.exe"
grep -q "file format pei-x86-64" "$OUT/headers.txt"; check "is 64-bit" $?
grep -qE "^Subsystem\s+0+2\s" "$OUT/headers.txt"; check "is a Windows program, not a console one" $?
# 6.1 is Windows 7; a toolchain default of 6.2 or higher is refused outright.
version=$(awk '/MajorSubsystemVersion/{maj=$2} /MinorSubsystemVersion/{min=$2} END{print maj "." min}' "$OUT/headers.txt")
awk -v v="$version" 'BEGIN{split(v,p,"."); exit !(p[1] < 6 || (p[1] == 6 && p[2] <= 1))}'
check "needs no newer Windows than 7 to load (it asks for $version; 7 is 6.1)" $?

# DLLs every Windows 7 has.
ALLOWED='^(KERNEL32|USER32|GDI32|WS2_32|IPHLPAPI|d3d9|dxva2|ole32|bcrypt|ADVAPI32|SHELL32|msvcrt)\.(dll|DLL)$'
strangers=$(awk '{print $1}' "$OUT/imports.txt" | sort -u | grep -vE "$ALLOWED")
# The status is taken first: the $(...) in the message would reset $? to 0.
[ -z "$strangers" ]; status=$?
check "names only DLLs Windows 7 has${strangers:+ -- not: $(echo $strangers)}" $status

# Added in Windows 8 or later. api-ms-win-core-* are the Windows 8 API sets.
NEWER='GetSystemTimePreciseAsFileTime|CreateFile2|CopyFile2|GetCurrentThreadStackLimits|SetThreadInformation|GetThreadInformation|GetOverlappedResultEx|WaitOnAddress|WakeByAddressSingle|WakeByAddressAll|InitializeSynchronizationBarrier|EnterSynchronizationBarrier|PrefetchVirtualMemory|SetThreadDescription|GetThreadDescription|CreateFileMappingFromApp|MapViewOfFileFromApp|VirtualAllocFromApp|LoadPackagedLibrary|GetPackageFullName|GetCurrentPackageId|SetDefaultDllDirectories|AddDllDirectory|RemoveDllDirectory|GetDpiForWindow|GetDpiForSystem|SetProcessDpiAwareness|SetProcessDpiAwarenessContext|GetSystemMetricsForDpi|EnableNonClientDpiScaling|CreateDXGIFactory2|MFCreateDXGIDeviceManager|RoInitialize|GetTickCount64Precise'
newer=$(awk '{print $2}' "$OUT/imports.txt" | grep -xE "$NEWER")
[ -z "$newer" ]; status=$?
check "calls nothing added after Windows 7${newer:+ -- calls: $(echo $newer)}" $status
api_sets=$(awk '{print $1}' "$OUT/imports.txt" | sort -u | grep -i '^api-ms-win-core')
[ -z "$api_sets" ]; check "uses none of Windows 8's API sets" $?
awk '{print $1}' "$OUT/imports.txt" | grep -qx "msvcrt.dll" \
    && ! awk '{print $1}' "$OUT/imports.txt" | grep -qi '^api-ms-win-crt\|^ucrtbase'
check "its C runtime is msvcrt.dll, which every Windows has, not the UCRT" $?
echo "  $(awk '{print $1}' "$OUT/imports.txt" | sort -u | wc -l | tr -d ' ') DLLs, $(wc -l < "$OUT/imports.txt" | tr -d ' ') functions"

echo
echo "==> the package"
for f in lanscreen.exe run.cmd README.txt; do
    [ -f "$OUT/LanScreen-Windows/$f" ]; check "has $f" $?
done
# A batch file with bare LF line endings misparses on Windows, quietly.
[ "$(grep -c $'\r$' "$OUT/LanScreen-Windows/run.cmd")" = "$(wc -l < "$OUT/LanScreen-Windows/run.cmd" | tr -d ' ')" ]
check "run.cmd has Windows line endings throughout" $?
unzip -l "$OUT/LanScreen-Windows.zip" | grep -q "LanScreen-Windows/lanscreen.exe"; check "the zip holds it" $?

echo
if [ $failures -eq 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL ($failures)"; exit 1; fi
