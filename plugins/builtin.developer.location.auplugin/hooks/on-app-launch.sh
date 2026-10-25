#!/system/bin/sh
set -e
STATE_FILE="/data/local/tmp/au-location-plugin-state.sh"

# Save each application's original grants and modes once, before changing them.
prepare_location_app() {
  app_pkg="$1"
  case "$app_pkg" in
    ''|*[!A-Za-z0-9_.]*|.*|*..*|*.) return 1 ;;
  esac
  case "$app_pkg" in *.*) ;; *) return 1 ;; esac
  pm path "$app_pkg" >/dev/null 2>&1 || return 1
  if ! grep -Fqx "# saved-permissions $app_pkg" "$STATE_FILE"; then
    pkg_dump="$(dumpsys package "$app_pkg" 2>/dev/null || true)"
    for perm in ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION ACCESS_BACKGROUND_LOCATION; do
      perm_line="$(printf '%s\n' "$pkg_dump" | grep "android.permission.$perm: granted=" | head -n 1 || true)"
      case "$perm_line" in
        *granted=true*) action=grant ;;
        *) action=revoke ;;
      esac
      printf 'pm %s %s android.permission.%s >/dev/null 2>&1 || true\n' "$action" "$app_pkg" "$perm" >> "$STATE_FILE"
    done
    for op in FINE_LOCATION COARSE_LOCATION MONITOR_LOCATION MONITOR_HIGH_POWER_LOCATION MOCK_LOCATION; do
      mode="$(appops get "$app_pkg" "$op" 2>/dev/null | sed -n "s/.*$op: \([a-z_]*\).*/\1/p" | head -n 1 || true)"
      case "$mode" in
        allow|ignore|deny|default|foreground|errored) ;;
        *) mode=default ;;
      esac
      printf 'appops set %s %s %s >/dev/null 2>&1 || true\n' "$app_pkg" "$op" "$mode" >> "$STATE_FILE"
    done
    printf '# saved-permissions %s\n' "$app_pkg" >> "$STATE_FILE"
  fi
  for perm in ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION ACCESS_BACKGROUND_LOCATION; do
    pm grant "$app_pkg" "android.permission.$perm" >/dev/null 2>&1 || true
  done
  for op in FINE_LOCATION COARSE_LOCATION MONITOR_LOCATION MONITOR_HIGH_POWER_LOCATION; do
    appops set "$app_pkg" "$op" allow >/dev/null 2>&1 || true
  done
  appops set "$app_pkg" MOCK_LOCATION deny >/dev/null 2>&1 || true
}

if [ -f "$STATE_FILE" ] && [ -n "${ANDROID_USE_ACTIVE_PACKAGE:-}" ]; then
  if prepare_location_app "$ANDROID_USE_ACTIVE_PACKAGE"; then
    current="$(settings get global location_background_throttle_package_whitelist 2>/dev/null || true)"
    case "$current" in ''|null) current=local.androiduse.plugin.gnss ;; esac
    case ",$current," in
      *,"$ANDROID_USE_ACTIVE_PACKAGE",*) ;;
      *) settings put global location_background_throttle_package_whitelist "$current,$ANDROID_USE_ACTIVE_PACKAGE" >/dev/null 2>&1 || true ;;
    esac
  fi
fi
am startservice -n local.androiduse.plugin.gnss/.GnssKeepWarmService >/dev/null 2>&1 || true
echo AU_PLUGIN_HOOK_OK
