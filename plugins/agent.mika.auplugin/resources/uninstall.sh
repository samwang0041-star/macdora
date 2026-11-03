# Macdora 系统助手 — guest 清理载荷（由宿主服务经 adb shell 执行）
set -eu
umask 077

STATE_FILE="/data/local/tmp/macdora-assistant-state"

fail() { echo "AU_PLUGIN_HOOK_FAIL $1"; exit 1; }
root_getprop() { su 0 getprop "$1" 2>/dev/null; }
root_setprop() { su 0 setprop "$1" "$2" >/dev/null 2>&1; }

# 1. 停止插件自有的后台显示会话。
pkill -f "macdora-assistant-scrcpy.jar" 2>/dev/null || true
rm -f /data/local/tmp/macdora-assistant-scrcpy.jar

# 2. 恢复无线调试开关。
if [ -f "$STATE_FILE" ]; then
  su 0 chown shell:shell "$STATE_FILE" >/dev/null 2>&1 || fail "OWN_STATE"
  . "$STATE_FILE"
  case "${adb_wifi_enabled:-null}" in
    null|"") settings delete global adb_wifi_enabled >/dev/null 2>&1 || fail "RESTORE_ADB_WIFI" ;;
    *) settings put global adb_wifi_enabled "$adb_wifi_enabled" >/dev/null 2>&1 || fail "RESTORE_ADB_WIFI" ;;
  esac
  case "${adb_tls_server_enable:-}" in
    "") root_setprop persist.adb.tls_server.enable "" || fail "RESTORE_ADB_TLS" ;;
    *) root_setprop persist.adb.tls_server.enable "$adb_tls_server_enable" || fail "RESTORE_ADB_TLS" ;;
  esac
  [ "$(root_getprop persist.adb.tls_server.enable)" = "${adb_tls_server_enable:-}" ] ||
    fail "CONFIRM_RESTORED_ADB_TLS"
  rm -f "$STATE_FILE" || fail "REMOVE_STATE"
fi

root_setprop sys.androiduse.assistant_mode "" || fail "CLEAR_ASSISTANT_MODE"
echo "ASSISTANT_UNINSTALL_OK"
