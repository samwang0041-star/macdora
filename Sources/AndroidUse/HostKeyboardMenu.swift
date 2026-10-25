import AppKit
import Carbon

struct HostKeyboardSource: Equatable {
    let identifier: String
    let name: String
    let asciiCapable: Bool

    static func enabled() -> [HostKeyboardSource] {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return [] }
        var sources: [HostKeyboardSource] = []
        for index in 0..<CFArrayGetCount(list) {
            let source = Unmanaged<TISInputSource>.fromOpaque(CFArrayGetValueAtIndex(list, index)).takeUnretainedValue()
            func string(_ key: CFString) -> String? {
                guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
                return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
            }
            func flag(_ key: CFString) -> Bool {
                guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
                return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
            }
            guard string(kTISPropertyInputSourceCategory) == kTISCategoryKeyboardInputSource as String,
                  flag(kTISPropertyInputSourceIsEnabled), flag(kTISPropertyInputSourceIsSelectCapable),
                  let identifier = string(kTISPropertyInputSourceID), let name = string(kTISPropertyLocalizedName) else { continue }
            sources.append(HostKeyboardSource(identifier: identifier, name: name, asciiCapable: flag(kTISPropertyInputSourceIsASCIICapable)))
        }
        return sources
    }
}

@MainActor
final class HostKeyboardMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu(title: "输入法")
    private let choose: (String) -> Void
    private let available: () -> Bool
    init(available: @escaping () -> Bool, choose: @escaping (String) -> Void) {
        self.choose = choose; self.available = available; super.init()
        menu.delegate = self; menu.autoenablesItems = false; menuNeedsUpdate(menu)
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let selected = NSTextInputContext.current?.selectedKeyboardInputSource
        for source in HostKeyboardSource.enabled() {
            let item = menu.addItem(withTitle: source.name, action: #selector(selectSource(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = source.identifier
            item.isEnabled = available()
            item.state = source.identifier == selected ? .on : .off
        }
        if menu.items.isEmpty {
            let item = menu.addItem(withTitle: "没有可用的键盘输入法", action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
    }
    @objc private func selectSource(_ sender: NSMenuItem) {
        if let identifier = sender.representedObject as? String { choose(identifier) }
    }
}
