#!/usr/bin/env bash
# Drive Android UI (native screens AND Flutter semantics) by label, via uiautomator.
# Usage: SERIAL=emulator-5554; source scripts/android_ui.sh; ui_tap "Scan a page"; ui_wait "Crop" 30
# See CLAUDE.md, "Android emulator".
adb() { "$HOME/Library/Android/sdk/platform-tools/adb" -s "${SERIAL:-emulator-5554}" "$@"; }
# ui_dump: one line per labelled node: label<TAB>cx cy
ui_dump() {
  adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
  adb shell cat /sdcard/ui.xml | python3 -c '
import sys,re,html
for m in re.finditer(r"<node [^>]*>", sys.stdin.read()):
    n=m.group(0); g=lambda k:(re.search(k+r"=\"([^\"]*)\"",n) or [None,""])[1]
    lab=html.unescape(g(" text") or g("content-desc")).replace("\n"," / ")
    b=list(map(int,re.findall(r"\d+",g("bounds"))))
    if lab and len(b)==4 and b[2]>b[0]: print(f"{lab}\t{(b[0]+b[2])//2} {(b[1]+b[3])//2}")
'
}
# ui_tap LABEL_REGEX: tap first node whose label matches; fails if none
ui_tap() {
  local xy; xy=$(ui_dump | grep -E -m1 "^($1)	" | cut -f2)
  [ -n "$xy" ] || { echo "ui_tap: no '$1'" >&2; return 1; }
  adb shell input tap $xy
}
# ui_wait LABEL_REGEX [timeout_s]: wait until a label appears
ui_wait() {
  local t=${2:-30} s=$(date +%s)
  until ui_dump | grep -qE "^($1)	"; do
    [ $(( $(date +%s)-s )) -ge $t ] && { echo "ui_wait: timeout '$1'" >&2; return 1; }
    sleep 2
  done
}
