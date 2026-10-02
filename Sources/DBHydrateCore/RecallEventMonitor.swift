import CoreServices
import Foundation

/// A recursive FSEvents stream over a directory tree.
///
/// One stream serves the whole recall run: workers register interest in
/// individual files, and the callback wakes only the waiters whose file
/// actually changed. That keeps the cost at a single stream regardless of how
/// many files are being recalled.
public final class RecallEventMonitor {
	private let root: URL
	private let onChange: ([String]) -> Void
	private let onRescan: () -> Void
	private let queue = DispatchQueue(label: "com.dbhydrate.fsevents", qos: .userInitiated)
	private let callbackQueueKey = DispatchSpecificKey<UInt8>()
	private let lock = NSLock()
	private var stream: FSEventStreamRef?

	public init(root: URL, onRescan: @escaping () -> Void = {}, onChange: @escaping ([String]) -> Void) {
		self.root = root
		self.onChange = onChange
		self.onRescan = onRescan
		queue.setSpecific(key: callbackQueueKey, value: 1)
	}

	deinit { stop() }

	@discardableResult
	public func start() -> Bool {
		lock.lock()
		defer { lock.unlock() }
		guard stream == nil else { return true }

		var context = FSEventStreamContext(
			version: 0,
			info: Unmanaged.passUnretained(self).toOpaque(),
			retain: nil, release: nil, copyDescription: nil)

		// FileEvents -> per-file callbacks. NoDefer -> deliver the first event of
		// a burst immediately. A zero latency means we are woken by the kernel as
		// soon as Dropbox swaps the stub out, not on a coalescing interval.
		let flags = UInt32(kFSEventStreamCreateFlagFileEvents)
			| UInt32(kFSEventStreamCreateFlagNoDefer)
			| UInt32(kFSEventStreamCreateFlagUseCFTypes)
			| UInt32(kFSEventStreamCreateFlagWatchRoot)

		let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, _ in
			// `info` is optional, `paths` is not.
			guard count > 0, let info else { return }
			let monitor = Unmanaged<RecallEventMonitor>.fromOpaque(info).takeUnretainedValue()
			// With kFSEventStreamCreateFlagUseCFTypes the paths arrive as a CFArray.
			let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
			let lost = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
				| UInt32(kFSEventStreamEventFlagUserDropped)
				| UInt32(kFSEventStreamEventFlagKernelDropped)
				| UInt32(kFSEventStreamEventFlagRootChanged)
				| UInt32(kFSEventStreamEventFlagEventIdsWrapped)
			if (0..<count).contains(where: { eventFlags[$0] & lost != 0 }) {
				monitor.onRescan()
			} else {
				monitor.onChange(array.compactMap { $0 as? String })
			}
		}

		guard let s = FSEventStreamCreate(
			kCFAllocatorDefault,
			callback,
			&context,
			[root.path] as CFArray,
			FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
			0.0,
			flags)
		else { return false }

		FSEventStreamSetDispatchQueue(s, queue)
		guard FSEventStreamStart(s) else {
			FSEventStreamInvalidate(s)
			FSEventStreamRelease(s)
			return false
		}
		stream = s
		return true
	}

	public func stop() {
		lock.lock()
		guard let s = stream else { lock.unlock(); return }
		stream = nil
		FSEventStreamStop(s)
		FSEventStreamInvalidate(s)
		lock.unlock()
		if DispatchQueue.getSpecific(key: callbackQueueKey) == nil {
			queue.sync {} // drain callbacks before releasing the unretained context
		}
		FSEventStreamRelease(s)
	}
}

protocol RecallMonitoring {
	func start() -> Bool
	func stop()
}

extension RecallEventMonitor: RecallMonitoring {}
