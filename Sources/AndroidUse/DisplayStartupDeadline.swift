import Foundation

struct DisplayStartupDeadline {
    private let started: Double
    private var checked: Double
    private var visibleWait: Double = 0
    private var wasPresentable = false

    init(at time: Double) { started = time; checked = time }

    mutating func expired(at time: Double, decoded: Bool, targetVisible: Bool, presentable: Bool) -> Bool {
        let elapsed = max(0, time - checked)
        checked = time
        if !decoded || !targetVisible { return time - started >= 35 }
        if wasPresentable && presentable { visibleWait += elapsed }
        wasPresentable = presentable
        return visibleWait >= 35
    }
}
