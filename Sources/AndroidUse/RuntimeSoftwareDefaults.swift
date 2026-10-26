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
    static let windowExtensionsPatchSuffixBase64 = "H4sIAAAAAAAC/wvwZmQSYRZhAIHDsVGxx0198zLSGRhAmJsBAZY0gsjknMTi4tRivZTUigAkjQwMihbrzWoSO9ayMIAwD4rGKelwjUYQnaxsIBkmICwG0h6irEASAAsJNFGJAAAA"

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
        if [ -f /system_ext/framework/androidx.window.extensions.jar ] && [ "$(getprop sys.androiduse.winext_patch)" != "v1" ]; then
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
          if [ -f /system_ext/framework/androidx.window.extensions.jar ] && [ "$(getprop sys.androiduse.winext_patch)" != "v1" ]; then
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
            setprop sys.androiduse.winext_patch "v1" >/dev/null 2>&1 || exit 1
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
