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
