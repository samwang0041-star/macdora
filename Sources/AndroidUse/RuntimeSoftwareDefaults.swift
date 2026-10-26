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
    setprop debug.sf.latch_unsignaled 1 >/dev/null 2>&1 || true
    setprop debug.sf.auto_latch_unsignaled 1 >/dev/null 2>&1 || true
    setprop debug.sf.vsync_reactor_ignore_present_fences true >/dev/null 2>&1 || true
    """

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
