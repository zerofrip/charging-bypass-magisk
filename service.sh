#!/system/bin/sh
# Charging Bypass v2.0 - Smart charging control with battery monitoring
MODDIR="${MODDIR:-${0%/*}}"
CONFIG="$MODDIR/config.conf"
STATE_FILE="$MODDIR/state.conf"
NODE_FILE="$MODDIR/charging_node"
LOG="/data/local/tmp/charging_bypass.log"
PID_FILE="$MODDIR/daemon.pid"

# Defaults
SCREEN_CONTROL=1
BATTERY_MONITOR=1
CHARGE_START=20
CHARGE_STOP=80
CHARGE_NODE=""
NODE_INVERTED=0

log_msg() {
  echo "$(date '+%m-%d %H:%M:%S') $1" >> "$LOG"
  # Keep log under 500 lines
  if [ "$(wc -l < "$LOG" 2>/dev/null)" -gt 500 ]; then
    tail -n 300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
}

load_config() {
  [ -f "$CONFIG" ] && . "$CONFIG"
}

detect_charging_node() {
  # MTK platform charger power path (0=disable, 1=enable)
  # Preferred on MTK: battery/disable resets capacity to 50%
  local mtk_pp="/sys/devices/platform/charger/enable_power_path"
  if [ -f "$mtk_pp" ] && [ -w "$mtk_pp" ]; then
    CHARGE_NODE="$mtk_pp"
    NODE_INVERTED=0
    return 0
  fi
  # Qualcomm / common (0=disable, 1=enable)
  for node in \
    /sys/class/power_supply/battery/charging_enabled \
    /sys/class/power_supply/battery/battery_charging_enabled \
    /sys/class/power_supply/battery/charge_control_limit_max \
  ; do
    if [ -f "$node" ] && [ -w "$node" ]; then
      CHARGE_NODE="$node"
      NODE_INVERTED=0
      return 0
    fi
  done
  # input_suspend (inverted: 1=disable, 0=enable)
  for node in \
    /sys/class/power_supply/battery/input_suspend \
    /sys/class/power_supply/usb/input_suspend \
  ; do
    if [ -f "$node" ] && [ -w "$node" ]; then
      CHARGE_NODE="$node"
      NODE_INVERTED=1
      return 0
    fi
  done
  # battery/disable (inverted: 1=disable, 0=enable)
  # WARNING: on some MTK devices this resets capacity to 50%
  if [ -f "/sys/class/power_supply/battery/disable" ]; then
    if [ -w "/sys/class/power_supply/battery/disable" ]; then
      CHARGE_NODE="/sys/class/power_supply/battery/disable"
      NODE_INVERTED=1
      return 0
    fi
    # Last resort: try writing even if -w fails (sysfs quirk)
    if echo 0 > /sys/class/power_supply/battery/disable 2>/dev/null; then
      CHARGE_NODE="/sys/class/power_supply/battery/disable"
      NODE_INVERTED=1
      return 0
    fi
  fi
  return 1
}

disable_charging() {
  if [ "$NODE_INVERTED" = "1" ]; then
    echo 1 > "$CHARGE_NODE" 2>/dev/null
  else
    echo 0 > "$CHARGE_NODE" 2>/dev/null
  fi
}

enable_charging() {
  if [ "$NODE_INVERTED" = "1" ]; then
    echo 0 > "$CHARGE_NODE" 2>/dev/null
  else
    echo 1 > "$CHARGE_NODE" 2>/dev/null
  fi
}

get_battery() {
  cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo 50
}

get_charge_status() {
  cat /sys/class/power_supply/battery/status 2>/dev/null || echo Unknown
}

get_screen() {
  # Primary: dumpsys display
  local s
  s=$(dumpsys display 2>/dev/null | grep -oE 'mScreenState=(ON|OFF)' | head -1 | cut -d= -f2)
  if [ -n "$s" ]; then echo "$s"; return; fi
  # Fallback: dumpsys power
  s=$(dumpsys power 2>/dev/null | grep -oE 'mWakefulness=(Awake|Asleep|Dozing)' | head -1 | cut -d= -f2)
  case "$s" in
    Awake) echo ON ;;
    *) echo OFF ;;
  esac
}

write_state() {
  cat > "$STATE_FILE" <<EOF
BATTERY_LEVEL=$1
CHARGING_STATUS=$2
SCREEN_STATE=$3
BYPASS_ACTIVE=$4
LAST_UPDATE=$(date '+%H:%M:%S')
EOF
}

# Kill previous daemon if running
if [ -f "$PID_FILE" ]; then
  old_pid=$(cat "$PID_FILE" 2>/dev/null)
  [ -n "$old_pid" ] && kill "$old_pid" 2>/dev/null
fi
echo $$ > "$PID_FILE"

# Wait for boot
while [ "$(getprop sys.boot_completed)" != "1" ]; do
  sleep 5
done
sleep 10

log_msg "=== Service started (PID $$) ==="

# Create default config if missing
if [ ! -f "$CONFIG" ]; then
  cp "$MODDIR/config.conf.default" "$CONFIG" 2>/dev/null || \
  cat > "$CONFIG" <<EOF
SCREEN_CONTROL=1
BATTERY_MONITOR=1
CHARGE_START=20
CHARGE_STOP=80
EOF
fi

# Detect charging node
if ! detect_charging_node; then
  log_msg "ERROR: No writable charging node found"
  write_state "$(get_battery)" "$(get_charge_status)" "$(get_screen)" 0
  exit 1
fi
echo "$CHARGE_NODE" > "$NODE_FILE"
log_msg "Node: $CHARGE_NODE (inverted=$NODE_INVERTED)"

bypass_active=0
prev_action=""

# Main loop
while true; do
  load_config

  battery=$(get_battery)
  screen=$(get_screen)
  status=$(get_charge_status)
  action=""

  if [ "$BATTERY_MONITOR" = "1" ]; then
    if [ "$battery" -ge "$CHARGE_STOP" ]; then
      # Battery at/above stop threshold -> bypass (disable charging)
      disable_charging
      bypass_active=1
      action="bypass"
    elif [ "$battery" -le "$CHARGE_START" ]; then
      # Battery at/below start threshold -> force charge regardless of screen
      enable_charging
      bypass_active=0
      action="force_charge"
    else
      # Between thresholds
      bypass_active=0
      if [ "$SCREEN_CONTROL" = "1" ]; then
        if [ "$screen" = "ON" ]; then
          disable_charging
          action="screen_off"
        else
          enable_charging
          action="screen_on"
        fi
      else
        # No screen control, just enable charging in the middle zone
        enable_charging
        action="normal"
      fi
    fi
  elif [ "$SCREEN_CONTROL" = "1" ]; then
    # Only screen control
    if [ "$screen" = "ON" ]; then
      disable_charging
      action="screen_off"
    else
      enable_charging
      action="screen_on"
    fi
  fi

  # Log only on state change
  if [ "$action" != "$prev_action" ]; then
    log_msg "Batt=${battery}% Screen=${screen} Status=${status} Action=${action}"
    prev_action="$action"
  fi

  write_state "$battery" "$status" "$screen" "$bypass_active"
  sleep 5
done
