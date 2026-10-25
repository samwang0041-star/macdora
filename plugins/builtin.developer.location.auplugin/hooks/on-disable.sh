#!/system/bin/sh
am startservice -a STOP -n local.androiduse.plugin.gnss/.GnssKeepWarmService >/dev/null 2>&1 || true
am stopservice -n local.androiduse.plugin.gnss/.GnssKeepWarmService >/dev/null 2>&1 || true
cmd deviceidle whitelist -local.androiduse.plugin.gnss >/dev/null 2>&1 || true
pm uninstall local.androiduse.plugin.gnss >/dev/null 2>&1 || true
rm -f /data/local/tmp/au-gnss-keepwarm.apk >/dev/null 2>&1 || true
STATE_FILE="/data/local/tmp/au-location-plugin-state.sh"
if [ -f "$STATE_FILE" ]; then
  /system/bin/sh "$STATE_FILE" >/dev/null 2>&1 || true
  rm -f "$STATE_FILE" >/dev/null 2>&1 || true
fi
echo AU_PLUGIN_HOOK_OK
