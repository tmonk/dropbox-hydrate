import Foundation

/// Cooperative cancellation. Signal delivery runs on a dispatch queue, never
/// inside a POSIX signal handler (where locks and Swift allocation are unsafe).
public final class Cancellation {
	public static let shared = Cancellation()
	private let lock = NSLock()
	private var reason: String?
	private var observers: [UUID: () -> Void] = [:]
	private static let installLock = NSLock()
	private static var sources: [DispatchSourceSignal] = []

	public init() {}

	public var isCancelled: Bool {
		lock.lock(); defer { lock.unlock() }
		return reason != nil
	}

	public var cause: String {
		lock.lock(); defer { lock.unlock() }
		return reason ?? "cancelled"
	}

	public func cancel(_ cause: String) {
		lock.lock()
		guard reason == nil else { lock.unlock(); return }
		reason = cause
		let callbacks = Array(observers.values)
		lock.unlock()
		for callback in callbacks { callback() }
	}

	/// Registration also observes cancellation that happened just before it.
	func observe(_ callback: @escaping () -> Void) -> UUID {
		let id = UUID()
		lock.lock()
		observers[id] = callback
		let cancelled = reason != nil
		lock.unlock()
		if cancelled { callback() }
		return id
	}

	func removeObserver(_ id: UUID) {
		lock.lock(); observers[id] = nil; lock.unlock()
	}

	public static func installSignalHandlers() {
		installLock.lock(); defer { installLock.unlock() }
		guard sources.isEmpty else { return }
		let queue = DispatchQueue(label: "com.dbhydrate.signals", qos: .userInitiated)
		for (number, name) in [(SIGINT, "SIGINT"), (SIGTERM, "SIGTERM")] {
			signal(number, SIG_IGN)
			let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
			source.setEventHandler { shared.cancel(name) }
			sources.append(source)
			source.resume()
		}
	}
}
