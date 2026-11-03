# Macdora 系统助手 — guest 配置载荷（由宿主服务经 adb shell 执行，非 hook）
# 原生模式：不安装任何应用；只清理旧版引擎并把环境收拢为宿主直连的系统通道。
set -eu
umask 077

STATE_FILE="/data/local/tmp/macdora-assistant-state"
LEGACY_STATE="/data/local/tmp/mika-assistant-state"

fail() { echo "AU_PLUGIN_HOOK_FAIL $1"; exit 1; }
root_getprop() { su 0 getprop "$1" 2>/dev/null; }
root_setprop() { su 0 setprop "$1" "$2" >/dev/null 2>&1; }

# 1. 旧版插件（APK 引擎）遗留清理：恢复它写入的无障碍设置，卸载其应用。
if [ -f "$LEGACY_STATE" ]; then
  . "$LEGACY_STATE"
  if [ "${perapp_override:-0}" = "1" ]; then
    settings delete secure enabled_accessibility_services >/dev/null 2>&1 || true
  fi
  case "${a11y_enabled_services:-null}" in
    null|"") settings delete secure enabled_accessibility_services >/dev/null 2>&1 || true ;;
    *) settings put secure enabled_accessibility_services "$a11y_enabled_services" >/dev/null 2>&1 || true ;;
  esac
  case "${a11y_enabled:-null}" in
    null|"") settings delete secure accessibility_enabled >/dev/null 2>&1 || true ;;
    *) settings put secure accessibility_enabled "$a11y_enabled" >/dev/null 2>&1 || true ;;
  esac
  rm -f "$LEGACY_STATE"
fi
pkill -f "local.macdora.assistant:helper" 2>/dev/null || true
pm uninstall local.macdora.assistant >/dev/null 2>&1 || true
rm -rf /data/local/tmp/mika-assistant.apk /data/local/tmp/mika-assistant-version \
  /data/local/tmp/mika-services-rebuilt.jar /data/local/tmp/mika-services-rebuilt.odex \
  /data/local/tmp/mika-services-rebuilt.vdex
setprop sys.androiduse.mika_norm "" >/dev/null 2>&1 || true

# 2. 系统通道不需要无线调试：关闭开关与 mDNS 广播，保留宿主 adb 链路即可。
if [ -f "$STATE_FILE" ]; then
  su 0 chown shell:shell "$STATE_FILE" >/dev/null 2>&1 || fail "OWN_STATE"
fi
if [ ! -f "$STATE_FILE" ]; then
  adb_wifi_enabled="$(settings get global adb_wifi_enabled 2>/dev/null)" ||
    fail "READ_ADB_WIFI"
  adb_tls_server_enable="$(root_getprop persist.adb.tls_server.enable)" ||
    fail "READ_ADB_TLS"
  {
    printf "adb_wifi_enabled='%s'\n" "$adb_wifi_enabled"
    printf "adb_tls_server_enable='%s'\n" "$adb_tls_server_enable"
  } > "$STATE_FILE" || fail "WRITE_STATE"
  chmod 600 "$STATE_FILE" 2>/dev/null || fail "CHMOD_STATE"
fi
if ! grep -q '^adb_tls_server_enable=' "$STATE_FILE"; then
  printf "adb_tls_server_enable=''\n" >> "$STATE_FILE" || fail "MIGRATE_STATE"
fi
settings put global adb_wifi_enabled 0 >/dev/null 2>&1 || fail "DISABLE_ADB_WIFI"
[ "$(settings get global adb_wifi_enabled 2>/dev/null)" = "0" ] || fail "CONFIRM_ADB_WIFI"
root_setprop persist.adb.tls_server.enable 0 || fail "DISABLE_ADB_TLS"
[ "$(root_getprop persist.adb.tls_server.enable)" = "0" ] || fail "CONFIRM_ADB_TLS"

# 3. 原生模式标记（宿主服务据此确认环境已收拢）。
root_setprop sys.androiduse.assistant_mode native || fail "SET_ASSISTANT_MODE"
echo "ASSISTANT_PROVISION_OK"
