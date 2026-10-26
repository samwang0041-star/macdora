import AppKit

enum AppDockIconMode: String {
    case application = "app"
    case macdora

    static func parse(arguments: [String]) -> Self {
        if let value = arguments.first(where: { $0.hasPrefix("--dock-icon=") })?.split(separator: "=", maxSplits: 1).last {
            return Self(rawValue: String(value)) ?? .application
        }
        guard let index = arguments.firstIndex(of: "--dock-icon"), index + 1 < arguments.count else {
            return .application
        }
        return Self(rawValue: arguments[index + 1]) ?? .application
    }
}

@MainActor
final class AppDockPresentation {
    let mode: AppDockIconMode

    init(mode: AppDockIconMode) { self.mode = mode }

    func update(app: ContainerApp?) {
        let brandIcon = MacdoraBrand.appIconImage(size: 512)
        if mode == .application, let app, let icon = TFAppIconView.resolveAppIconImage(for: app) {
            NSApp.applicationIconImage = MacdoraBrand.dockAppIconImage(icon)
        } else {
            NSApp.applicationIconImage = brandIcon
        }
        NSApp.dockTile.badgeLabel = nil
    }
}
