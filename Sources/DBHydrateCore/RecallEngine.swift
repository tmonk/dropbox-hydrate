import Foundation

/// How a single file's recall ended.
///
/// These are distinguished rather than lumped into "timed out", because they
/// have different causes and different remedies:
public enum RecallOutcome: String, Codable, Sendable {
	/// Landed, and quickly -- the normal case.
	case served
	/// Landed, but slower than `RecallEngine.slowThreshold`. Usually Dropbox's
	/// service rate, not anything local.
	case slow
	/// Never landed, with a native coordinated read still outstanding at the
	/// snapshot. This observation alone does not establish the cause.
	case wedged
	/// Never landed, but the cause could not be attributed (for example every
	/// request was skipped because no request slot was free).
	case failed
}

/// Per-file request counts, timing and completion state for JSON reports.
public struct FileRecord: Codable, Sendable {
	public var path: String
	/// Coordinated reads requested for this file across all passes.
	public var requests: Int
	/// How many of those requests actually returned from `coordinate()`.
	///
	/// `requests > claimsReturned` at end of run is the direct, observable
	/// signature of an outstanding call, not proof of where it is blocked.
	public var claimsReturned: Int
	public var requestsSkipped: Int
	/// Which pass finally completed the file (1 = first pass).
	public var passes: Int
	/// Seconds from the first request to completion.
	public var latency: TimeInterval?
	/// Seconds spent in passes that did *not* complete this file. This is the
	/// wasted wall clock: time the run spent waiting on requests that delivered
	/// nothing.
	public var blockedSeconds: TimeInterval
	public var bytes: Int
	public var outcome: RecallOutcome
}

public struct RunStats: Codable, Sendable {
	public var files = 0
	public var served = 0
	public var slow = 0
	public var wedged = 0
	public var failed = 0
	/// Share of files whose request never returned, 0...1.
	public var wedgeRate: Double = 0
	/// Total seconds spent waiting on requests that did not deliver.
	public var wastedSeconds: TimeInterval = 0
	public var elapsed: TimeInterval = 0
	public var records: [FileRecord] = []
}

/// Result of a recall run.
public struct HydrateReport {
	public var scanned = 0
	public var placeholders = 0
	public var alreadyLocal = 0
	public var hydrated = 0
	public var timedOut: [URL] = []
	public var errors: [(url: URL, message: String)] = []
	/// Paths refused before any work started (symlinks, non-regular files,
	/// anything outside the Dropbox root).
	public var refusals: [String] = []
	public var elapsed: TimeInterval = 0
	/// Observed idle progress or cooperative cancellation, without attributing
	/// an unobserved cause to Dropbox or to its account.
	public var diagnosis: String?
	/// Per-file detail, populated when `collectStats` is on.
	public var stats = RunStats()

	public var ok: Bool { timedOut.isEmpty && errors.isEmpty && refusals.isEmpty && diagnosis == nil }

	public var summary: String {
		"scanned \(scanned)  placeholders \(placeholders)  hydrated \(hydrated)  "
			+ "already-local \(alreadyLocal)  timed-out \(timedOut.count)  errors \(errors.count)  refused \(refusals.count)"
			+ String(format: "  (%.2fs)", elapsed)
	}
}

/// Recalls Dropbox Smart Sync placeholders without opening them.
///
/// Publishes read intent with NSFileCoordinator and uses FSEvents to recheck
/// files as Dropbox replaces their placeholders with local content.
public final class RecallEngine {
	public var ceiling: TimeInterval
	public var concurrency: Int
	public var maxPasses: Int
	public var maxReissues: Int
	public var stallGrace: TimeInterval
	public var collectStats = false
	public var slowThreshold: TimeInterval = 2
	public var allowOutsideDropbox: Bool
	public private(set) var diagnosis: String?
	/// Callbacks are serialized and each file is reported once, across retries.
	public var onProgress: ((URL, Int, Bool) -> Void)?
	public var onPlan: ((Int) -> Void)?
	public var onFileResult: ((URL, Int, Bool) -> Void)?

	private let cancellation: Cancellation
	private let log: (String) -> Void
	private let runLock = NSLock()
	private let callbackLock = NSLock()
	private let requestQueue = DispatchQueue(label: "com.dbhydrate.requests",
	                                        qos: .userInitiated, attributes: .concurrent)
	private let requestSlots: DispatchSemaphore
	// Injection points exercise the same scheduler without needing a live account.
	var requestAction: (URL) throws -> Void = RecallEngine.coordinate
	var monitorFactory: (URL, @escaping () -> Void, @escaping ([String]) -> Void) -> RecallMonitoring = {
		RecallEventMonitor(root: $0, onRescan: $1, onChange: $2)
	}

	public init(ceiling: TimeInterval = 60, concurrency: Int = 8,
	            maxPasses: Int = 3, maxReissues: Int = 3, stallGrace: TimeInterval = 30,
	            allowOutsideDropbox: Bool = false, cancellation: Cancellation = .shared,
	            log: @escaping (String) -> Void = { _ in }) {
		self.ceiling = ceiling
		self.concurrency = min(64, max(1, concurrency))
		self.maxPasses = min(100, max(1, maxPasses))
		self.maxReissues = min(100, max(0, maxReissues))
		self.stallGrace = stallGrace
		self.allowOutsideDropbox = allowOutsideDropbox
		self.cancellation = cancellation
		self.log = log
		requestSlots = DispatchSemaphore(value: min(64, max(1, concurrency)) * 2)
	}

	private static func coordinate(_ url: URL) throws {
		let coordinator = NSFileCoordinator(filePresenter: nil)
		var error: NSError?
		// Publishing the read intent is sufficient. No ordinary file read is
		// needed, and opening a stub only returns empty data anyway.
		coordinator.coordinate(readingItemAt: url, options: [], error: &error) { _ in }
		if let error { throw error }
	}

	/// A direct request shares the same finite request pool as hydration.
	@discardableResult
	public func requestRecall(_ url: URL) -> Bool {
		guard !cancellation.isCancelled, case .allow = gate(url),
		      requestSlots.wait(timeout: .now()) == .success else { return false }
		let action = requestAction, slots = requestSlots, token = cancellation
		requestQueue.async {
			defer { slots.signal() }
			guard !token.isCancelled else { return }
			try? action(url)
		}
		return true
	}

	public enum GateVerdict { case allow, refuse(String) }
	public static var dropboxRoot: URL = {
		let path = ProcessInfo.processInfo.environment["DBHYDRATE_DROPBOX_ROOT"]
			?? NSHomeDirectory() + "/Dropbox"
		return URL(fileURLWithPath: path).standardizedFileURL
	}()

	public func gate(_ url: URL) -> GateVerdict {
		Self.gate(url, allowOutside: allowOutsideDropbox)
	}

	public static func gate(_ url: URL, allowOutside: Bool = false) -> GateVerdict {
		if let st = PlaceholderDetector.fileStat(url) {
			let kind = st.st_mode & S_IFMT
			if kind == S_IFLNK { return .refuse("is a symlink; pass the resolved path") }
			if kind != S_IFDIR && kind != S_IFREG { return .refuse("not a regular file or directory") }
		}
		if !allowOutside {
			let root = canonicalURL(dropboxRoot).path
			let path = canonicalURL(url).path
			if !isContained(path, in: root) {
				return .refuse("is outside the Dropbox root (\(root)); pass --allow-outside-dropbox to allow this path")
			}
		}
		return .allow
	}

	public struct Plan {
		public var report: HydrateReport
		public var files: [URL]
		var watchDirectories: [URL]
	}

	/// A single implementation for live runs and dry runs, including file roots,
	/// traversal failures, path gates, overlap removal and cancellation.
	public func plan(roots: [URL]) -> Plan {
		let start = uptime()
		var report = HydrateReport(), allowed: [URL] = []
		for raw in roots {
			let root = raw.standardizedFileURL
			if case .refuse(let reason) = gate(root) {
				report.refusals.append("\(root.path): \(reason)")
			} else {
				allowed.append(canonicalURL(root))
			}
		}
		let uniqueRoots = Self.minimalRoots(allowed)
		var files: [URL] = [], watch: [URL] = []
		for root in uniqueRoots {
			if cancellation.isCancelled { break }
			let scan = PlaceholderDetector.scan(root: root, cancellation: cancellation)
			report.scanned += scan.entries
			report.errors += scan.errors
			files += scan.placeholders
			if let st = PlaceholderDetector.fileStat(root), st.st_mode & S_IFMT == S_IFREG {
				if scan.errors.isEmpty && scan.placeholders.isEmpty { report.alreadyLocal += 1 }
				watch.append(root.deletingLastPathComponent())
			} else {
				watch.append(root)
			}
		}
		report.placeholders = files.count
		report.elapsed = uptime() - start
		if cancellation.isCancelled { report.diagnosis = "cancelled by \(cancellation.cause) during scan" }
		return Plan(report: report, files: files, watchDirectories: Self.minimalRoots(watch))
	}

	static func minimalRoots(_ roots: [URL]) -> [URL] {
		let unique = Dictionary(roots.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
		return unique.values.filter { url in
			var parent = url.deletingLastPathComponent().path
			while parent != url.path {
				if unique[parent] != nil { return false }
				if parent == "/" { break }
				parent = (parent as NSString).deletingLastPathComponent
			}
			return true
		}.sorted { $0.path < $1.path }
	}

	private final class Task {
		let url: URL
		let signal = DispatchSemaphore(value: 0)
		let lock = NSLock()
		var requests = 0, returned = 0, skipped = 0, pass = 0, reissues = 0
		var first: Double?, completed: Double?, deadline: Double?
		var blocked: Double = 0
		var error: String?
		var reported = false
		var reissueEvent = false
		var lastSize = 0
		init(_ url: URL) { self.url = url }
	}

	private final class Run {
		let lock = NSLock()
		var pending: [String: Task] = [:]
		var lastProgress = uptime()
		var halted = false
		var finished = false
		var reason: String?
		var requests = 0, returned = 0

		func stop(_ reason: String) {
			lock.lock()
			if !halted { halted = true; self.reason = reason }
			let waiting = Array(pending.values)
			lock.unlock()
			for task in waiting { task.signal.signal() }
		}
		var stopped: Bool {
			lock.lock(); defer { lock.unlock() }; return halted || finished
		}
		func progress() { lock.lock(); lastProgress = uptime(); lock.unlock() }
		func wake(_ paths: [String]? = nil) {
			lock.lock(); let waiting = Array(pending.values); lock.unlock()
			let named = paths.map(Set.init)
			let dirs = paths.map { Set($0.map { ($0 as NSString).deletingLastPathComponent }) }
			for task in waiting {
				let path = task.url.path, parent = task.url.deletingLastPathComponent().path
				if let named, let dirs,
				   !named.contains(path) && !named.contains(parent) && !dirs.contains(parent) { continue }
				// A neighbor's event is useful for rechecking a coalesced restore,
				// but does not justify another native claim for this file.
				if let named, named.contains(path) || named.contains(parent) {
					task.lock.lock(); task.reissueEvent = true; task.lock.unlock()
				}
				task.signal.signal()
			}
		}
	}

	public func hydrate(roots: [URL]) -> HydrateReport {
		runLock.lock(); defer { runLock.unlock() }
		diagnosis = nil
		let start = uptime()
		guard ceiling.isFinite, ceiling > 0, ceiling <= 86400,
		      stallGrace.isFinite, stallGrace > 0, stallGrace <= 86400,
		      (1...64).contains(concurrency), (1...100).contains(maxPasses),
		      (0...100).contains(maxReissues), slowThreshold.isFinite, slowThreshold >= 0 else {
			var report = HydrateReport()
			report.errors.append((roots.first ?? Self.dropboxRoot, "invalid recall configuration"))
			return report
		}
		let plan = plan(roots: roots)
		var report = plan.report
		onPlan?(plan.files.count)
		guard !plan.files.isEmpty, report.diagnosis == nil else { return report }
		let run = Run(), tasks = plan.files.map(Task.init)
		let observer = cancellation.observe { [weak run] in
			run?.stop("cancelled by \(self.cancellation.cause)")
		}
		defer { cancellation.removeObserver(observer) }
		let monitors = plan.watchDirectories.map { dir in
			monitorFactory(dir, { [weak run] in run?.wake() }, { [weak run] in run?.wake($0) })
		}
		defer { for monitor in monitors { monitor.stop() } }
		for (index, monitor) in monitors.enumerated() {
			if !monitor.start() {
				report.errors.append((plan.watchDirectories[index], "could not start FSEvents monitor; no recalls requested"))
				report.timedOut = plan.files
				report.elapsed = uptime() - start
				return report
			}
		}
		run.progress() // monitor startup time is not time spent waiting for service
		let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
		let tick = min(1, max(0.01, stallGrace / 4)), grace = stallGrace
		timer.schedule(deadline: .now() + grace, repeating: tick)
		timer.setEventHandler { [weak run] in
			guard let run else { return }
			run.lock.lock()
			let idle = uptime() - run.lastProgress
			run.lock.unlock()
			if idle >= grace { run.stop(String(format: "no recall progress observed for %.2fs", idle)) }
		}
		timer.resume()
		defer { timer.cancel(); run.lock.lock(); run.finished = true; run.lock.unlock() }

		var pending = tasks
		for pass in 1...maxPasses {
			if run.stopped { break }
			runPass(pending, pass: pass, run: run)
			pending = pending.filter { task in
				task.lock.lock(); defer { task.lock.unlock() }
				return task.completed == nil && task.error == nil && (task.deadline ?? 0) > uptime()
			}
			if pending.isEmpty { break }
		}

		// Reconcile once against the filesystem, including late completions and
		// files never assigned a worker. Reports and stats share this snapshot.
		var done = 0, stats = RunStats()
		for task in tasks {
			let state = PlaceholderDetector.state(of: task.url)
			let landed = state.recalled, size = state.size
			task.lock.lock()
			if case .failed(let reason) = state { task.error = reason }
			if landed && task.completed == nil { task.completed = uptime() }
			let error = task.error, completed = task.completed
			let latency = completed.flatMap { end in task.first.map { max(0, end - $0) } }
			let outcome: RecallOutcome = landed
				? ((latency ?? 0) > slowThreshold ? .slow : .served)
				: (task.requests > task.returned ? .wedged : .failed)
			if collectStats {
				stats.records.append(FileRecord(path: task.url.path, requests: task.requests,
				                                claimsReturned: task.returned, requestsSkipped: task.skipped,
				                                passes: task.pass, latency: latency,
				                                blockedSeconds: task.blocked, bytes: size, outcome: outcome))
			}
			task.lock.unlock()
			if landed { report.hydrated += 1; done += 1 }
			else if let error { report.errors.append((task.url, error)) }
			else { report.timedOut.append(task.url) }
			notify(task, count: done, size: size, ok: landed)
		}
		report.elapsed = uptime() - start
		run.lock.lock()
		if let reason = run.reason,
		   report.hydrated < report.placeholders || reason.hasPrefix("cancelled by") {
			report.diagnosis = reason.hasPrefix("cancelled by") ? reason
				: "\(reason); \(run.requests) coordinated reads issued, \(run.returned) returned. "
					+ "No completion was observed for the remaining files; this does not establish why Dropbox did not deliver."
		}
		run.lock.unlock()
		diagnosis = report.diagnosis
		report.timedOut.sort { $0.path < $1.path }
		if collectStats {
			stats.files = tasks.count; stats.elapsed = report.elapsed
			for record in stats.records {
				switch record.outcome {
				case .served: stats.served += 1
				case .slow: stats.slow += 1
				case .wedged: stats.wedged += 1
				case .failed: stats.failed += 1
				}
				stats.wastedSeconds += record.blockedSeconds
			}
			stats.wedgeRate = tasks.isEmpty ? 0 : Double(stats.wedged) / Double(tasks.count)
			report.stats = stats
		}
		return report
	}

	/// Dispatch O(concurrency) workers, never O(files) semaphore-blocked tasks.
	private func runPass(_ tasks: [Task], pass: Int, run: Run) {
		let group = DispatchGroup(), cursorLock = NSLock()
		var cursor = 0, completed = 0
		for _ in 0..<min(concurrency, tasks.count) {
			group.enter()
			DispatchQueue.global(qos: .userInitiated).async {
				defer { group.leave() }
				while !run.stopped {
					cursorLock.lock()
					guard cursor < tasks.count else { cursorLock.unlock(); return }
					let task = tasks[cursor]; cursor += 1
					cursorLock.unlock()
					let ok = self.recall(task, pass: pass, run: run)
					if ok {
						cursorLock.lock(); completed += 1; let count = completed; cursorLock.unlock()
						self.notify(task, count: count, size: PlaceholderDetector.size(of: task.url) ?? 0, ok: true)
					}
				}
			}
		}
		group.wait()
	}

	private func notify(_ task: Task, count: Int, size: Int, ok: Bool) {
		task.lock.lock()
		guard !task.reported else { task.lock.unlock(); return }
		task.reported = true; task.lock.unlock()
		callbackLock.lock(); defer { callbackLock.unlock() }
		onProgress?(task.url, count, ok)
		onFileResult?(task.url, size, ok)
	}

	private func recall(_ task: Task, pass: Int, run: Run) -> Bool {
		let initial = PlaceholderDetector.state(of: task.url)
		if case .failed(let reason) = initial {
			task.lock.lock(); task.error = reason; task.lock.unlock(); return false
		}
		if initial.recalled {
			task.lock.lock(); task.completed = uptime(); task.lock.unlock()
			run.progress(); return true
		}
		if run.stopped { return false }
		let begin = uptime()
		task.lock.lock()
		task.pass = pass
		if task.deadline == nil { task.deadline = begin + ceiling }
		let totalDeadline = task.deadline!
		// Retry waits share one total per-file ceiling, rather than multiplying it.
		let end = min(totalDeadline, begin + max(0, totalDeadline - begin) / Double(maxPasses - pass + 1))
		task.lock.unlock()
		run.lock.lock(); run.pending[task.url.path] = task; run.lock.unlock()
		defer { run.lock.lock(); run.pending[task.url.path] = nil; run.lock.unlock() }
		if run.stopped { return false }
		if initial.size == 0 { issue(task, run: run) }

		var woke = false
		while true {
			let state = PlaceholderDetector.state(of: task.url)
			if case .failed(let reason) = state {
				task.lock.lock(); task.error = reason; task.lock.unlock(); break
			}
			if state.recalled {
				task.lock.lock(); task.completed = uptime(); task.lock.unlock()
				run.progress(); return true
			}
			task.lock.lock(); let failed = task.error != nil; task.lock.unlock()
			if run.stopped || failed { break }
			// Only event wakes may spend the extra-request budget. Observing an
			// incomplete file just after dispatch is not a reason to request again.
			if woke {
				let size = state.size
				task.lock.lock()
				let advanced = size > task.lastSize
				task.lastSize = max(size, task.lastSize)
				let retry = size == 0 && task.reissueEvent && task.reissues < maxReissues
				task.reissueEvent = false
				if retry { task.reissues += 1 }
				task.lock.unlock()
				if advanced { run.progress() }
				if retry { issue(task, run: run) }
			}
			let remaining = end - uptime()
			if remaining <= 0 || task.signal.wait(timeout: .now() + remaining) != .success { break }
			woke = true
		}
		let landed = PlaceholderDetector.isRecalled(task.url)
		task.lock.lock()
		if landed { task.completed = uptime() } else { task.blocked += uptime() - begin }
		task.lock.unlock()
		if landed { run.progress() }
		return landed
	}

	private func issue(_ task: Task, run: Run) {
		guard !run.stopped, !cancellation.isCancelled else { return }
		if case .refuse(let reason) = gate(task.url) {
			task.lock.lock(); task.error = reason; task.lock.unlock(); task.signal.signal(); return
		}
		guard requestSlots.wait(timeout: .now()) == .success else {
			task.lock.lock(); task.skipped += 1; task.lock.unlock(); return
		}
		let slots = requestSlots, action = requestAction, token = cancellation
		// Reserve before dispatch: parked native claims cannot cause unbounded
		// tasks or threads. Counters count actual attempts, never slot misses.
		requestQueue.async { [weak run] in
			defer { slots.signal() }
			guard let run, !run.stopped, !token.isCancelled else { return }
			task.lock.lock()
			task.requests += 1
			if task.first == nil { task.first = uptime() }
			task.lock.unlock()
			run.lock.lock(); run.requests += 1; run.lock.unlock()
			do { try action(task.url) }
			catch { task.lock.lock(); task.error = error.localizedDescription; task.lock.unlock(); task.signal.signal() }
			task.lock.lock(); task.returned += 1; task.lock.unlock()
			run.lock.lock(); run.returned += 1; run.lock.unlock()
		}
	}
}

/// Elapsed time and safety deadlines must not depend on wall-clock adjustments.
private func uptime() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
