import Foundation

/// Messages that arrived before anyone asked for them, and the one waiter.
actor Inbox<Element: Sendable> {
    private var queue: [Element] = []
    private var waiter: (id: UUID, continuation: CheckedContinuation<Element?, Never>)?
    private var closed = false

    func push(_ element: Element) {
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: element)
        } else {
            queue.append(element)
        }
    }

    func finish() {
        closed = true
        waiter?.continuation.resume(returning: nil)
        waiter = nil
    }

    func next(timeout: TimeInterval) async -> Element? {
        if !queue.isEmpty { return queue.removeFirst() }
        if closed { return nil }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiter = (id, continuation)
            Task {
                try? await Task.sleep(for: .milliseconds(Int(timeout * 1000)))
                self.expire(id)
            }
        }
    }

    private func expire(_ id: UUID) {
        guard let waiter, waiter.id == id else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: nil)
    }
}
