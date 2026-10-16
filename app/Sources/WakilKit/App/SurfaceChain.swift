import Foundation

/// The order an api pane's surface edits reach the store in (2c-iv Amendment 9a;
/// extracted from `WindowModel` in PR 5 of the split): each piece of work starts
/// only after everything enqueued before it has finished.
@MainActor
final class SurfaceChain {
    private var tail: Task<Void, Never>?
    private static var focusGenerations = 0

    @discardableResult
    func enqueue<T: Sendable>(_ work: @escaping @MainActor () async -> T) -> Task<T, Never> {
        let previous = tail
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await work()
        }
        tail = Task { _ = await task.value }
        return task
    }

    /// Returns once everything enqueued so far has run.
    func settled() async { await tail?.value }

    static func nextFocusGeneration() -> Int {
        focusGenerations += 1
        return focusGenerations
    }
}
