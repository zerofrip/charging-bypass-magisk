#!/system/bin/sh
MODDIR="${MODDIR:-${0%/*}}"

# Create default config if missing
if [ ! -f "$MODDIR/config.conf" ]; then
  cat > "$MODDIR/config.conf" <<EOF
SCREEN_CONTROL=1
BATTERY_MONITOR=1
CHARGE_START=20
CHARGE_STOP=80
EOF
fi
