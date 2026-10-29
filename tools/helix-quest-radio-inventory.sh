#!/usr/bin/env bash
set -euo pipefail

fail() {
    echo "Helix Quest radio inventory: $*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required host command: $1"
}

for cmd in adb awk date grep tr; do
    need "$cmd"
done

ADB_COUNT=$(adb devices | awk 'NR>1 && $2 == "device" {n++} END {print n+0}')
[[ "$ADB_COUNT" -eq 1 ]] || fail "expected exactly one connected ADB device, found $ADB_COUNT"
ADB_SERIAL=$(adb devices | awk 'NR>1 && $2 == "device" {print $1; exit}')
[[ -n "$ADB_SERIAL" ]] || fail "could not determine ADB serial"
[[ "$ADB_SERIAL" != *:* ]] || fail "wireless ADB is connected; use USB for this inventory"

ROOT_ID=$(adb shell su -c id 2>/dev/null | tr -d '\r' || true)
[[ "$ROOT_ID" == *"uid=0"* ]] || fail "Quest root shell is not active"

QUEST_ROUTE=$(adb shell "su -c 'ip route show default 2>/dev/null | head -n1'" | tr -d '\r')
QUEST_IF=$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$QUEST_ROUTE")
[[ -n "$QUEST_IF" ]] || QUEST_IF=wlan0

STAMP=$(date +%Y%m%d-%H%M%S)
OUT=${HELIX_RADIO_INVENTORY_OUT:-"$HOME/helix-quest-radio-inventory-$STAMP.txt"}

{
    echo "helix_quest_radio_inventory_v1"
    echo "captured_utc=$(date -u +%FT%TZ)"
    echo "adb_serial=$ADB_SERIAL"
    echo "quest_if=$QUEST_IF"
    echo

    echo "===== kernel ====="
    adb shell "su -c 'uname -a; cat /proc/version 2>/dev/null || true'" 2>&1 | tr -d '\r'
    echo

    echo "===== android build ====="
    adb shell "su -c 'getprop ro.product.model; getprop ro.build.fingerprint; getprop ro.build.version.release; getprop ro.build.version.sdk'" 2>&1 | tr -d '\r'
    echo

    echo "===== wifi-related properties ====="
    adb shell "su -c \"getprop | grep -Ei 'wifi|wlan|cnss|qcom|qualcomm|firmware' || true\"" 2>&1 | tr -d '\r'
    echo

    echo "===== interface identity ====="
    adb shell "su -c 'ip -details link show dev $QUEST_IF 2>/dev/null || ip link show dev $QUEST_IF; ip -s link show dev $QUEST_IF'" 2>&1 | tr -d '\r'
    adb shell "su -c 'readlink -f /sys/class/net/$QUEST_IF/device/driver 2>/dev/null || true; readlink -f /sys/class/net/$QUEST_IF/device/driver/module 2>/dev/null || true; cat /sys/class/net/$QUEST_IF/device/uevent 2>/dev/null || true'" 2>&1 | tr -d '\r'
    echo

    echo "===== sysfs interface counters ====="
    adb shell "su -c 'for f in /sys/class/net/$QUEST_IF/statistics/*; do [ -r \"\$f\" ] || continue; printf \"%s=\" \"\${f##*/}\"; cat \"\$f\"; done'" 2>&1 | tr -d '\r'
    echo

    echo "===== ethtool identity ====="
    adb shell "su -c 'if command -v ethtool >/dev/null 2>&1; then ethtool -i $QUEST_IF 2>&1; else echo unavailable; fi'" 2>&1 | tr -d '\r'
    echo

    echo "===== ethtool statistics ====="
    adb shell "su -c 'if command -v ethtool >/dev/null 2>&1; then ethtool -S $QUEST_IF 2>&1; else echo unavailable; fi'" 2>&1 | tr -d '\r'
    echo

    echo "===== iw interface/link/station ====="
    adb shell "su -c 'if command -v iw >/dev/null 2>&1; then iw dev $QUEST_IF info 2>&1; echo ---link---; iw dev $QUEST_IF link 2>&1; echo ---station---; iw dev $QUEST_IF station dump 2>&1; else echo unavailable; fi'" 2>&1 | tr -d '\r'
    echo

    echo "===== wifi service status ====="
    adb shell "su -c 'cmd wifi status 2>/dev/null || true'" 2>&1 | tr -d '\r'
    echo

    echo "===== tracefs/debugfs mounts ====="
    adb shell "su -c 'mount | grep -E \"debugfs|tracefs\" || true; ls -ld /sys/kernel/debug /sys/kernel/tracing 2>/dev/null || true'" 2>&1 | tr -d '\r'
    echo

    echo "===== relevant tracepoints ====="
    adb shell "su -c 'for p in /sys/kernel/tracing/available_events /sys/kernel/debug/tracing/available_events; do if [ -r \"\$p\" ]; then echo source=\$p; grep -Ei \"(^|:)(cfg80211|mac80211|wifi|wlan|ath|qca|cnss|qrtr|net):|rx|drop|firmware|fw|reorder\" \"\$p\" 2>/dev/null | head -n 800; break; fi; done'" 2>&1 | tr -d '\r'
    echo

    echo "===== candidate debugfs/sysfs radio telemetry files ====="
    adb shell "su -c 'for root in /sys/kernel/debug /sys/kernel/tracing /sys/class/net/$QUEST_IF/device; do [ -d \"\$root\" ] || continue; find \"\$root\" -maxdepth 5 -type f 2>/dev/null | grep -Ei \"wifi|wlan|ath|qca|cnss|rx|drop|err|reorder|firmware|fw|ring|stat|debug\" | head -n 1200; done'" 2>&1 | tr -d '\r'
    echo

    echo "===== recent kernel wifi/firmware messages ====="
    adb shell "su -c 'dmesg 2>/dev/null | grep -Ei \"wifi|wlan|ath|qca|cnss|firmware|fw|rx.*(drop|error|stall|ring)|reorder|timeout|reset\" | tail -n 1000 || true'" 2>&1 | tr -d '\r'
} >"$OUT"

[[ -s "$OUT" ]] || fail "inventory output is empty"

echo "Quest radio capability inventory complete."
echo "Interface: $QUEST_IF"
echo "Saved: $OUT"
echo
echo "Decision-relevant capability summary:"
grep -E -i 'driver|module|ethtool|unavailable|tracepoint|cfg80211|mac80211|ath|qca|cnss|firmware|reorder|drop|error|ring|reset|timeout' "$OUT" | head -n 120 || true
