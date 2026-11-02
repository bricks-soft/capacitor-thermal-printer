import Foundation

final class EscPosQueue {
    let queue: DispatchQueue
    private let key = DispatchSpecificKey<Bool>()

    init(label: String) {
        queue = DispatchQueue(label: label)
        queue.setSpecific(key: key, value: true)
    }

    var isCurrent: Bool {
        DispatchQueue.getSpecific(key: key) == true
    }

    func sync<T>(_ block: () throws -> T) rethrows -> T {
        if isCurrent {
            return try block()
        }
        return try queue.sync(execute: block)
    }

    func async(after delay: TimeInterval = 0, _ block: @escaping () -> Void) {
        if delay <= 0 {
            queue.async(execute: block)
        } else {
            queue.asyncAfter(deadline: .now() + delay, execute: block)
        }
    }
}
