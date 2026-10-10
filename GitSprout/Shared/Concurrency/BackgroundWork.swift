import Foundation

nonisolated enum BackgroundWork {
    static func run<T: Sendable>(_ body: @Sendable @escaping () -> T) async -> T {
        await Task.detached(priority: .userInitiated) {
            body()
        }.value
    }
}
