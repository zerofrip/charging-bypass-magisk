#!/system/bin/sh
MODDIR="${MODDIR:-${0%/*}}"

# Re-enable charging before uninstall
for node in \
  /sys/class/power_supply/battery/charging_enabled \
  /sys/class/power_supply/battery/battery_charging_enabled \
; do
  [ -w "$node" ] && echo 1 > "$node" 2>/dev/null
done
for node in \
  /sys/class/power_supply/battery/input_suspend \
  /sys/class/power_supply/usb/input_suspend \
; do
  [ -w "$node" ] && echo 0 > "$node" 2>/dev/null
done

# Kill daemon
[ -f "$MODDIR/daemon.pid" ] && kill "$(cat "$MODDIR/daemon.pid")" 2>/dev/null

# Cleanup
rm -f /data/local/tmp/charging_bypass.log
rm -f /sdcard/charging_bypass.log
