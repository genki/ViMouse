import Foundation

enum MouseModeScheduler {
    static func scheduleTimer(timeInterval: TimeInterval, target: Any, selector: Selector) -> Timer {
        let timer = Timer(timeInterval: timeInterval, target: target, selector: selector, userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .modalPanel)
        return timer
    }
}
