import CryptoKit
import Foundation

enum OfficeKeepAwakePhase: Equatable, Sendable {
    case off
    case waitingForRuntime
    case applying
    case active
    case failed
}

struct OfficeKeepAwakeStatus: Equatable, Sendable {
    var enabled: Bool
    var phase: OfficeKeepAwakePhase

    static let off = OfficeKeepAwakeStatus(enabled: false, phase: .off)

    var detail: String {
        switch phase {
        case .off: return "仅此环境；开启后耗电和在线活动可能增加"
        case .waitingForRuntime: return enabled ? "已保存，启动此环境后应用" : "启动此环境后恢复原设置"
        case .applying: return "正在应用，请稍候"
        case .active: return "已应用；后台运行可能增加耗电、内存与在线活动"
        case .failed: return enabled ? "未能确认设置生效，请重试" : "未能确认设置恢复，请重试"
        }
    }
}

/// An opt-in applies to one canonical runtime root, never to a global app
/// preference or a package name. It does not identify a particular employer.
struct OfficeKeepAwakePreferences {
    let defaults: UserDefaults
    let key: String

    init(rootURL: URL, defaults: UserDefaults) {
        self.defaults = defaults
        let path = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        key = "AndroidUse.OfficeKeepAwake." + digest
    }

    var enabled: Bool {
        get { defaults.bool(forKey: key + ".enabled") }
        nonmutating set { defaults.set(newValue, forKey: key + ".enabled") }
    }

    var original: OfficeFreezerSnapshot? {
        get {
            guard let data = defaults.data(forKey: key + ".original") else { return nil }
            return try? JSONDecoder().decode(OfficeFreezerSnapshot.self, from: data)
        }
        nonmutating set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: key + ".original")
            } else {
                defaults.removeObject(forKey: key + ".original")
            }
        }
    }

    var hasOriginal: Bool { defaults.object(forKey: key + ".original") != nil }
}

enum OfficeFreezerSetting: String, Codable, Sendable {
    case absent = "null"
    case enabled
    case disabled
    case deviceDefault = "device_default"
}

struct OfficeFreezerSnapshot: Codable, Equatable, Sendable {
    let setting: OfficeFreezerSetting
    let inUse: Bool

    init?(output: Data) {
        let lines = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard lines.count == 2,
              let setting = OfficeFreezerSetting(rawValue: lines[0]),
              lines[1] == "true" || lines[1] == "false" else { return nil }
        self.setting = setting
        inUse = lines[1] == "true"
    }

    init(setting: OfficeFreezerSetting, inUse: Bool) {
        self.setting = setting
        self.inUse = inUse
    }
}

/// All commands are transported through the owning RuntimeController's ADB.
/// They contain no application identities, account data, UI input or credentials.
enum OfficeKeepAwakeCommands {
    static func arguments(_ script: String) -> [String] {
        ["shell", "su 0 sh -c '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"]
    }

    private static let freezerState = """
    freezer_state() {
      snapshot=$(dumpsys activity cao | sed -n '/^[[:space:]]*use_freezer=/p; /^[[:space:]]*Apps frozen:/p')
      if printf '%s\\n' "$snapshot" | grep -q '^[[:space:]]*use_freezer=\\(true\\|false\\)[[:space:]]*$'; then
        printf '%s\\n' "$snapshot"
      else
        dumpsys activity -a | sed -n '/^[[:space:]]*use_freezer=/p; /^[[:space:]]*Apps frozen:/p'
      fi
    }
    """

    static let inspect = """
    # macdora-office-awake:inspect
    set -eu
    \(freezerState)
    value=$(settings get global cached_apps_freezer)
    state=$(freezer_state | sed -n 's/^[[:space:]]*use_freezer=\\([a-z]*\\)[[:space:]]*$/\\1/p')
    [ "$state" = true ] || [ "$state" = false ] || exit 1
    printf '%s\\n%s\\n' "$value" "$state"
    """

    static let apply = """
    # macdora-office-awake:apply
    set -eu
    \(freezerState)
    settings put global cached_apps_freezer disabled >/dev/null
    ready=false
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      if freezer_state | grep '^[[:space:]]*use_freezer=false[[:space:]]*$' >/dev/null; then
        ready=true
        break
      fi
      sleep 0.1
    done
    [ "$ready" = true ] || exit 1
    # The settings observer stops future freezes, but some Android versions
    # leave old frozen/pending records behind. Cancel those through AMS too.
    names=$(dumpsys activity -a processes | sed -n 's|.*ProcessRecord{[^ ]* [0-9][0-9]*:\\([^/ ]*\\)/[^}]*}.*|\\1|p' | sort -u)
    [ -n "$names" ] || exit 1
    count=0
    for name in $names; do
      case "$name" in *[!a-zA-Z0-9_.:]*|'') exit 1;; esac
      count=$((count + 1))
      [ "$count" -le 512 ] || exit 1
      am unfreeze "$name" >/dev/null 2>&1 || true
    done
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      state=$(freezer_state; dumpsys activity -a processes | sed -n '/isPendingFreeze=/p')
      if printf '%s\\n' "$state" | grep -q '^[[:space:]]*use_freezer=false[[:space:]]*$' &&
         printf '%s\\n' "$state" | grep -q '^[[:space:]]*Apps frozen: 0[[:space:]]*$' &&
         printf '%s\\n' "$state" | grep -q 'isPendingFreeze=' &&
         ! printf '%s\\n' "$state" | grep -q 'isPendingFreeze=true'; then
        printf 'MACDORA_OFFICE_AWAKE_APPLIED\\n'
        exit 0
      fi
      sleep 0.1
    done
    exit 1
    """

    static func restore(_ original: OfficeFreezerSnapshot) -> String {
        let command = original.setting == .absent
            ? "settings delete global cached_apps_freezer"
            : "settings put global cached_apps_freezer \(original.setting.rawValue)"
        return """
        # macdora-office-awake:restore
        set -eu
        \(freezerState)
        current=$(settings get global cached_apps_freezer)
        if [ "$current" != disabled ]; then
          printf 'MACDORA_OFFICE_AWAKE_EXTERNAL\\n'
          exit 0
        fi
        \(command) >/dev/null
        [ "$(settings get global cached_apps_freezer)" = \(original.setting.rawValue) ] || exit 1
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
          if freezer_state | grep '^[[:space:]]*use_freezer=\(original.inUse ? "true" : "false")[[:space:]]*$' >/dev/null; then
            printf 'MACDORA_OFFICE_AWAKE_RESTORED\\n'
            exit 0
          fi
          sleep 0.1
        done
        exit 1
        """
    }
}
