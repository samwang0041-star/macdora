import Foundation

struct GuestDeviceIdentity: Equatable, Sendable {
    let brand: String
    let manufacturer: String
    let model: String
    let device: String
    let name: String
    let board: String
    let characteristics: String
    let density: String
    let fingerprint: String

    static let tablet = GuestDeviceIdentity(
        brand: "Samsung",
        manufacturer: "Samsung",
        model: "SM-F926U",
        device: "SM-F926U",
        name: "SM-F926U",
        board: "SM-F926U",
        characteristics: "tablet",
        density: "240",
        fingerprint: "Samsung/SM-F926U/SM-F926U:12/V417IR/eng.nioh.20241225.154630:user/release-keys"
    )

    static let phone = GuestDeviceIdentity(
        brand: "Android",
        manufacturer: "unknown",
        model: "Android SDK built for arm64",
        device: "emu64a",
        name: "sdk_phone64_arm64",
        board: "goldfish_arm64",
        characteristics: "default",
        density: "420",
        fingerprint: "Android/sdk_phone64_arm64/emu64a:17/CE2A.260420.051.A3/16571990:userdebug/test-keys"
    )

    static func forMode(tabletMode: Bool) -> GuestDeviceIdentity {
        tabletMode ? .tablet : .phone
    }
}

/// Product-owned guest defaults, reapplied on boot, app launch and device-mode changes.
/// Keep these in the application so a stock image and an upgraded environment behave alike.
enum RuntimeSoftwareDefaults {
    static let guestSetupScript = """
    # The local virtual display must render protected application windows.
    settings put secure disable_secure_windows 1 >/dev/null 2>&1 || exit 1
    [ "$(settings get secure disable_secure_windows)" = "1" ] || exit 1
    settings put global force_resizable_activities 1 >/dev/null 2>&1 || true
    settings put global enable_non_resizable_multi_window 1 >/dev/null 2>&1 || true
    wm set-multi-window-config --supportsNonResizable 1 --respectsActivityMinWidthHeight -1 >/dev/null 2>&1 || true
    settings put global low_power 0 >/dev/null 2>&1 || true
    settings put global window_animation_scale 0 >/dev/null 2>&1 || true
    settings put global transition_animation_scale 0 >/dev/null 2>&1 || true
    settings put global animator_duration_scale 0 >/dev/null 2>&1 || true
    cmd thermalservice override-status 0 >/dev/null 2>&1 || true
    cmd power set-mode 0 >/dev/null 2>&1 || true
    cmd power set-fixed-performance-mode-enabled true >/dev/null 2>&1 || true
    cmd deviceidle disable >/dev/null 2>&1 || true
    cmd netpolicy set restrict-background false >/dev/null 2>&1 || true
    settings put system min_refresh_rate 60.0 >/dev/null 2>&1 || true
    settings put system peak_refresh_rate 60.0 >/dev/null 2>&1 || true
    setprop debug.sf.latch_unsignaled 1 >/dev/null 2>&1 || true
    setprop debug.sf.auto_latch_unsignaled 1 >/dev/null 2>&1 || true
    setprop debug.sf.vsync_reactor_ignore_present_fences true >/dev/null 2>&1 || true
    """

    static let windowExtensionsPatchPrefixBase64 = "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"
    static let windowExtensionsPatchSuffixBase64 = "H4sIAAAAAAAC/wvwZmQSYRBhgIFr279e12hkYABhbgZ0kJyTWFycWqyXkloRgKZxvVlNYsdaFgYQ5kHRFNII12gE0cnKBhJnAsJiIM2hzwokAf94h5qJAAAA"

    /// Encodes a 96-byte Bionic `prop_info` payload (`uint32_t serial = len << 24` in little-endian
    /// followed by a 92-byte NUL-padded UTF-8 value) so shorter values cleanly overwrite longer ones.
    static func propertyRecordBase64(_ value: String) -> String {
        let utf8 = Array(value.utf8.prefix(91))
        var bytes = [UInt8](repeating: 0, count: 96)
        bytes[3] = UInt8(utf8.count)
        for (index, byte) in utf8.enumerated() {
            bytes[4 + index] = byte
        }
        return Data(bytes).base64EncodedString()
    }

    static func guestDeviceIdentityScript(tabletMode: Bool) -> String {
        let id = GuestDeviceIdentity.forMode(tabletMode: tabletMode)
        let charsB64 = propertyRecordBase64(id.characteristics)
        let densityB64 = propertyRecordBase64(id.density)
        let fingerprintB64 = propertyRecordBase64(id.fingerprint)
        let boardB64 = propertyRecordBase64(id.board)
        let brandB64 = propertyRecordBase64(id.brand)
        let manufacturerB64 = propertyRecordBase64(id.manufacturer)
        let modelB64 = propertyRecordBase64(id.model)
        let deviceB64 = propertyRecordBase64(id.device)
        let nameB64 = propertyRecordBase64(id.name)

        return """
        su 0 sh -c '
        set -e
        disable_slirp_ipv6() {
          ip6tables -w -C INPUT -p ipv6-icmp --icmpv6-type 134 -j DROP >/dev/null 2>&1 || \\
            ip6tables -w -I INPUT -p ipv6-icmp --icmpv6-type 134 -j DROP >/dev/null 2>&1 || true
          ip6tables -w -C OUTPUT -d 2000::/3 -j REJECT >/dev/null 2>&1 || \\
            ip6tables -w -I OUTPUT -d 2000::/3 -j REJECT >/dev/null 2>&1 || true
          for iface in all default wlan0 eth0; do
            if [ -w "/proc/sys/net/ipv6/conf/$iface/accept_ra" ]; then
              echo 0 > "/proc/sys/net/ipv6/conf/$iface/accept_ra" 2>/dev/null || true
            fi
            if [ -w "/proc/sys/net/ipv6/conf/$iface/disable_ipv6" ]; then
              echo 1 > "/proc/sys/net/ipv6/conf/$iface/disable_ipv6" 2>/dev/null || true
            fi
          done
        }
        disable_slirp_ipv6
        target_model="\(id.model)"
        target_brand="\(id.brand)"
        target_manufacturer="\(id.manufacturer)"
        target_device="\(id.device)"
        target_name="\(id.name)"
        target_board="\(id.board)"
        target_chars="\(id.characteristics)"
        target_density="\(id.density)"
        target_fingerprint="\(id.fingerprint)"
        cur_zygote_model="$(getprop sys.androiduse.zygote_model)"
        cur_zygote_pid="$(getprop sys.androiduse.zygote_pid)"
        live_zygote_pid="$(pidof zygote64 2>/dev/null || pidof zygote 2>/dev/null || true)"
        if [ -z "$cur_zygote_model" ]; then
          cur_zygote_model="\(GuestDeviceIdentity.phone.model)"
        elif [ -n "$cur_zygote_pid" ] && [ "$cur_zygote_pid" != "$live_zygote_pid" ]; then
          cur_zygote_model="stale"
        fi
        if [ -f /system_ext/framework/androidx.window.extensions.jar ] && [ "$(getprop sys.androiduse.winext_patch)" != "v2" ]; then
          cur_zygote_model="stale"
        fi
        if [ "$cur_zygote_model" != "$target_model" ]; then
          setprop sys.androiduse.zygote_model "pending" >/dev/null 2>&1 || exit 1
          setprop sys.androiduse.zygote_pid "" >/dev/null 2>&1 || true
        fi
        patch_prop() {
          f="$1"; k="$2"; b64="$3"
          key_len=${#k}
          matched=0
          for p in "/dev/__properties__/$f" "/dev/__properties__/appcompat_override/$f"; do
            [ -f "$p" ] || continue
            file_matched=0
            for off in $(grep -abo "$k" "$p" 2>/dev/null | cut -d: -f1); do
              [ "$off" -ge 96 ] || continue
              prev_hex=$(dd if="$p" bs=1 skip=$((off - 1)) count=1 2>/dev/null | od -An -tx1 | tr -d " \\n")
              next_hex=$(dd if="$p" bs=1 skip=$((off + key_len)) count=1 2>/dev/null | od -An -tx1 | tr -d " \\n")
              if [ "$prev_hex" = "00" ] && [ "$next_hex" = "00" ]; then
                pos=$((off - 96))
                echo "$b64" | base64 -d | dd of="$p" bs=1 seek="$pos" conv=notrunc 2>/dev/null || return 1
                file_matched=1
                matched=1
                break
              fi
            done
            [ "$file_matched" = "1" ] || return 1
          done
          [ "$matched" = "1" ] || return 1
        }
        if [ "$(getprop ro.product.model)" != "$target_model" ] || \\
           [ "$(getprop ro.product.brand)" != "$target_brand" ] || \\
           [ "$(getprop ro.product.manufacturer)" != "$target_manufacturer" ] || \\
           [ "$(getprop ro.build.characteristics)" != "$target_chars" ] || \\
           [ "$(getprop qemu.sf.lcd_density)" != "$target_density" ]; then
          patch_prop "u:object_r:build_prop:s0" "ro.build.characteristics" "\(charsB64)"
          patch_prop "u:object_r:qemu_sf_lcd_density_prop:s0" "qemu.sf.lcd_density" "\(densityB64)"
          patch_prop "u:object_r:fingerprint_prop:s0" "ro.build.fingerprint" "\(fingerprintB64)"
          patch_prop "u:object_r:build_vendor_prop:s0" "ro.product.board" "\(boardB64)"
          for ns in "" "system." "product." "system_ext."; do
            patch_prop "u:object_r:build_prop:s0" "ro.product.${ns}brand" "\(brandB64)"
            patch_prop "u:object_r:build_prop:s0" "ro.product.${ns}manufacturer" "\(manufacturerB64)"
            patch_prop "u:object_r:build_prop:s0" "ro.product.${ns}model" "\(modelB64)"
            patch_prop "u:object_r:build_prop:s0" "ro.product.${ns}device" "\(deviceB64)"
            patch_prop "u:object_r:build_prop:s0" "ro.product.${ns}name" "\(nameB64)"
          done
          for ns in "vendor." "vendor_dlkm."; do
            patch_prop "u:object_r:build_vendor_prop:s0" "ro.product.${ns}brand" "\(brandB64)"
            patch_prop "u:object_r:build_vendor_prop:s0" "ro.product.${ns}manufacturer" "\(manufacturerB64)"
            patch_prop "u:object_r:build_vendor_prop:s0" "ro.product.${ns}model" "\(modelB64)"
            patch_prop "u:object_r:build_vendor_prop:s0" "ro.product.${ns}device" "\(deviceB64)"
            patch_prop "u:object_r:build_vendor_prop:s0" "ro.product.${ns}name" "\(nameB64)"
          done
          for ns in "odm."; do
            patch_prop "u:object_r:build_odm_prop:s0" "ro.product.${ns}brand" "\(brandB64)"
            patch_prop "u:object_r:build_odm_prop:s0" "ro.product.${ns}manufacturer" "\(manufacturerB64)"
            patch_prop "u:object_r:build_odm_prop:s0" "ro.product.${ns}model" "\(modelB64)"
            patch_prop "u:object_r:build_odm_prop:s0" "ro.product.${ns}device" "\(deviceB64)"
            patch_prop "u:object_r:build_odm_prop:s0" "ro.product.${ns}name" "\(nameB64)"
          done
        fi
        for ns in "" "system." "product." "system_ext." "vendor." "vendor_dlkm." "odm."; do
          [ "$(getprop "ro.product.${ns}model")" = "$target_model" ] || exit 1
          [ "$(getprop "ro.product.${ns}brand")" = "$target_brand" ] || exit 1
          [ "$(getprop "ro.product.${ns}manufacturer")" = "$target_manufacturer" ] || exit 1
          [ "$(getprop "ro.product.${ns}device")" = "$target_device" ] || exit 1
          [ "$(getprop "ro.product.${ns}name")" = "$target_name" ] || exit 1
        done
        [ "$(getprop ro.product.board)" = "$target_board" ] || exit 1
        [ "$(getprop ro.build.characteristics)" = "$target_chars" ] || exit 1
        [ "$(getprop qemu.sf.lcd_density)" = "$target_density" ] || exit 1
        [ "$(getprop ro.build.fingerprint)" = "$target_fingerprint" ] || exit 1
        mm_model_cache="/data/data/com.tencent.mm/.auth_cache/7a03bac2-692f-3d17-a2cd-a1b0721ffd0e/0"
        if [ -f "$mm_model_cache" ] && ! grep -q "^${target_model}," "$mm_model_cache" 2>/dev/null; then
          am force-stop com.tencent.mm >/dev/null 2>&1 || true
          rm -rf /data/data/com.tencent.mm/.auth_cache/7a03bac2-692f-3d17-a2cd-a1b0721ffd0e \\
                 /data/data/com.tencent.mm/.auth_cache/8fa14cdd-754f-31cc-a554-c9e71929cce7 2>/dev/null || exit 1
        fi
        if [ "$cur_zygote_model" != "$target_model" ]; then
          am force-stop com.tencent.mm >/dev/null 2>&1 || true
          rm -rf /data/data/com.tencent.mm/.auth_cache/7a03bac2-692f-3d17-a2cd-a1b0721ffd0e \\
                 /data/data/com.tencent.mm/.auth_cache/8fa14cdd-754f-31cc-a554-c9e71929cce7 2>/dev/null || exit 1
          if [ -f /system_ext/framework/androidx.window.extensions.jar ] && [ "$(getprop sys.androiduse.winext_patch)" != "v2" ]; then
            for p in /system_ext/framework/androidx.window.extensions.jar \\
                     /system_ext/framework/oat/arm64/androidx.window.extensions.odex \\
                     /system_ext/framework/oat/arm64/androidx.window.extensions.vdex; do
              while umount -l "$p" 2>/dev/null; do :; done
            done
            echo "\(windowExtensionsPatchPrefixBase64)" | base64 -d | gzip -d > /data/local/tmp/winext_rebuilt.jar || exit 1
            unzip -p /system_ext/framework/androidx.window.extensions.jar classes.dex >> /data/local/tmp/winext_rebuilt.jar || exit 1
            echo "\(windowExtensionsPatchSuffixBase64)" | base64 -d | gzip -d >> /data/local/tmp/winext_rebuilt.jar || exit 1
            /apex/com.android.art/bin/dex2oat64 \\
              --dex-file=/data/local/tmp/winext_rebuilt.jar \\
              --dex-location=/system_ext/framework/androidx.window.extensions.jar \\
              --oat-file=/data/local/tmp/winext_rebuilt.odex \\
              --output-vdex=/data/local/tmp/winext_rebuilt.vdex \\
              --instruction-set=arm64 --compiler-filter=speed >/dev/null 2>&1 || exit 1
            chmod 644 /data/local/tmp/winext_rebuilt.jar /data/local/tmp/winext_rebuilt.odex /data/local/tmp/winext_rebuilt.vdex || exit 1
            chcon u:object_r:system_file:s0 /data/local/tmp/winext_rebuilt.jar /data/local/tmp/winext_rebuilt.odex /data/local/tmp/winext_rebuilt.vdex || exit 1
            mount -o bind,ro /data/local/tmp/winext_rebuilt.jar /system_ext/framework/androidx.window.extensions.jar || exit 1
            mount -o bind,ro /data/local/tmp/winext_rebuilt.odex /system_ext/framework/oat/arm64/androidx.window.extensions.odex || exit 1
            mount -o bind,ro /data/local/tmp/winext_rebuilt.vdex /system_ext/framework/oat/arm64/androidx.window.extensions.vdex || exit 1
            setprop sys.androiduse.winext_patch "v2" >/dev/null 2>&1 || exit 1
          fi
          setprop ctl.restart zygote >/dev/null 2>&1 || exit 1
          sleep 1
          i=0
          ready=0
          new_zygote_pid=""
          while [ $i -lt 80 ]; do
            new_zygote_pid="$(pidof zygote64 2>/dev/null || pidof zygote 2>/dev/null || true)"
            if [ -n "$new_zygote_pid" ] && [ "$new_zygote_pid" != "$live_zygote_pid" ] && \\
               dumpsys activity activities >/dev/null 2>&1 && \\
               dumpsys window displays >/dev/null 2>&1 && \\
               dumpsys input_method >/dev/null 2>&1 && \\
               settings get secure disable_secure_windows >/dev/null 2>&1 && \\
               [ -n "$(pidof com.android.systemui)" ] && \\
               dumpsys connectivity 2>/dev/null | grep -q "CONNECTED"; then
              ready=1
              break
            fi
            i=$((i + 1))
            sleep 0.25
          done
          [ "$ready" = "1" ] || exit 1
          setprop sys.androiduse.zygote_model "$target_model" >/dev/null 2>&1 || exit 1
          setprop sys.androiduse.zygote_pid "$new_zygote_pid" >/dev/null 2>&1 || exit 1
        else
          setprop sys.androiduse.zygote_model "$target_model" >/dev/null 2>&1 || true
          if [ -n "$live_zygote_pid" ]; then
            setprop sys.androiduse.zygote_pid "$live_zygote_pid" >/dev/null 2>&1 || true
          fi
        fi
        disable_slirp_ipv6
        chown shell:shell /data/local/tmp/android-use-scrcpy.jar 2>/dev/null || true
        ' || exit 1
        """
    }
}
