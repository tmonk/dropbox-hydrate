import Foundation

/// Removes local content using legacy Dropbox stubs. An attrs blob is not proof
/// that the current bytes have been uploaded. --yes acknowledges this risk;
/// metadata journaling cannot guarantee that Dropbox can restore them.
public struct Evictor {
	public let sandboxRoot: URL
	public let dryRun: Bool
	public let confirmed: Bool
	private let cancellation: Cancellation
	// Fault injection tests exercise rollback and path replacement deterministically.
	var beforeMutation: ((URL) throws -> Void)?
	var beforeTruncate: ((Int32) throws -> Void)?
	var journalByteLimit = UndoManifest.maximumBytes

	public init(sandboxRoot: URL, dryRun: Bool = true, confirmed: Bool = false,
	            cancellation: Cancellation = .shared) {
		self.sandboxRoot = sandboxRoot.standardizedFileURL
		self.dryRun = dryRun; self.confirmed = confirmed; self.cancellation = cancellation
	}
	static let placeholderHeader: [UInt8] = [0x03, 0, 0, 0, 0x66, 0x75, 0x1B, 0x2A, 0, 0, 0, 0]

	public struct Outcome {
		public let path: URL
		public let status: Status
		public let bytes: Int
		public let note: String
		public enum Status { case evicted, wouldEvict, skipped }
	}
	public struct Report {
		public var outcomes: [Outcome] = []
		public var evicted = 0, wouldEvict = 0, skipped = 0, bytes = 0
		public var refusals: [String] = []
		public var cancelled: String?
		public var untouched: [String] = []
		public var manifestPath: String?
		public var ok: Bool { refusals.isEmpty && cancelled == nil }
	}
	public enum EvictError: Error, CustomStringConvertible {
		case noSandbox, notConfirmed
		case outsideSandbox(String), notAFile(String), attributeFailed(String)
		case changed(String), journal(String)
		public var description: String {
			switch self {
			case .noSandbox: return "no sandbox root configured; pass --sandbox <dir>"
			case .notConfirmed: return "evict removes local bytes; pass --yes or use --dry-run"
			case .outsideSandbox(let path): return "\(path) is outside the sandbox; refusing"
			case .notAFile(let path): return "\(path) is not a regular file; symlinks are refused"
			case .attributeFailed(let path): return "could not attach placeholder attributes to \(path)"
			case .changed(let reason): return "file changed or cannot safely be evicted: \(reason)"
			case .journal(let reason): return "undo journal: \(reason)"
			}
		}
	}

	/// No content backups. Each metadata entry is appended and fsynced before
	/// attributes or bytes change. All mutation uses the same validated descriptor.
	public func evict(paths: [URL], manifestURL: URL? = nil) throws -> Report {
		let sandbox = try SandboxDirectory(sandboxRoot)
		if !dryRun && !confirmed { throw EvictError.notConfirmed }
		let journal: UndoJournal?
		if dryRun { journal = nil }
		else {
			guard let manifestURL else { throw EvictError.journal("a destination is required") }
			guard !Self.isWithin(sandbox: sandbox.root, path: manifestURL) else {
				throw EvictError.journal("keep the journal outside the eviction sandbox")
			}
			journal = try UndoJournal(url: manifestURL, sandbox: sandbox.root, maximumBytes: journalByteLimit)
		}
		var report = Report(), seen = Set<String>()
		report.manifestPath = journal?.url.path
		for (index, raw) in paths.enumerated() {
			if cancellation.isCancelled {
				report.cancelled = "cancelled by \(cancellation.cause)"
				report.untouched = paths[index...].map(\.path); break
			}
			let url = raw.standardizedFileURL
			if !seen.insert(url.path).inserted { continue }
			do {
				let (file, parent, name) = try sandbox.openFile(url, writable: !dryRun)
				let initial = try descriptorStat(file.fd)
				guard initial.st_nlink == 1 else { throw EvictError.changed("hard-linked file \(url.path)") }
				try sandbox.validate(file, parent: parent, name: name)
				guard let attrs = try getAttribute(fd: file.fd, name: "com.dropbox.attrs"), !attrs.isEmpty else {
					report.skipped += 1
					report.outcomes.append(.init(path: url, status: .skipped, bytes: 0, note: "no non-empty com.dropbox.attrs"))
					continue
				}
				if try getAttribute(fd: file.fd, name: PlaceholderDetector.attributeName) != nil {
					guard initial.st_size == 0 else { throw EvictError.changed("placeholder still carries local bytes") }
					report.skipped += 1
					report.outcomes.append(.init(path: url, status: .skipped, bytes: 0, note: "already a placeholder"))
					continue
				}
				if dryRun {
					report.wouldEvict += 1; report.bytes += Int(initial.st_size)
					report.outcomes.append(.init(path: url, status: .wouldEvict, bytes: Int(initial.st_size), note: ""))
					continue
				}
				guard flock(file.fd, LOCK_EX | LOCK_NB) == 0 else { throw posixError("lock \(url.path)") }
				let hash = try digest(fd: file.fd, cancellation: cancellation)
				guard hash.size == Int(initial.st_size), sameContents(initial, try descriptorStat(file.fd)),
				      try getAttribute(fd: file.fd, name: "com.dropbox.attrs") == attrs else {
					throw EvictError.changed("content or Dropbox metadata changed while hashing")
				}
				let entry = UndoEntry(path: sandbox.root.appendingPathComponent(try sandbox.relativePath(url)).path,
				                      size: hash.size, sha256: hash.sha256, dropboxAttributes: Data(attrs))
				do { try journal!.record(entry) }
				catch {
					// Never append after a failed write: it may have left a torn
					// record. Stop the batch while earlier entries remain recoverable.
					report.refusals.append("\(url.path): cannot persist undo metadata (\(error)); stopping")
					report.untouched = paths[index...].map(\.path)
					break
				}
				try beforeMutation?(url)
				if cancellation.isCancelled {
					report.cancelled = "cancelled by \(cancellation.cause)"
					report.untouched = paths[index...].map(\.path); break
				}
				try sandbox.validate(file, parent: parent, name: name)
				try journal!.output.validate()
				guard sameContents(initial, try descriptorStat(file.fd)),
				      (try descriptorStat(file.fd)).st_nlink == 1,
				      try getAttribute(fd: file.fd, name: "com.dropbox.attrs") == attrs else {
					throw EvictError.changed("file changed before truncation")
				}
				let marker = Self.placeholderHeader + attrs
				var attached = false, truncated = false
				do {
					try setAttribute(fd: file.fd, name: PlaceholderDetector.attributeName, bytes: marker, options: XATTR_CREATE)
					attached = true
					guard try getAttribute(fd: file.fd, name: PlaceholderDetector.attributeName) == marker else {
						throw EvictError.attributeFailed(url.path)
					}
					// Persist the marker before removing bytes. Cooperative signals
					// are checked between files; they do not split this sequence.
					guard fsync(file.fd) == 0 else { throw posixError("sync placeholder marker") }
					try beforeTruncate?(file.fd)
					try sandbox.validate(file, parent: parent, name: name)
					let current = try descriptorStat(file.fd)
					guard current.st_size == initial.st_size, current.st_nlink == 1,
					      current.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
					      current.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
					      try getAttribute(fd: file.fd, name: "com.dropbox.attrs") == attrs,
					      try getAttribute(fd: file.fd, name: PlaceholderDetector.attributeName) == marker else {
						throw EvictError.changed("content changed after attaching marker")
					}
					guard ftruncate(file.fd, 0) == 0 else { throw posixError("truncate \(url.path)") }
					truncated = true
					report.evicted += 1; report.bytes += hash.size
					report.outcomes.append(.init(path: url, status: .evicted, bytes: hash.size, note: ""))
					guard fsync(file.fd) == 0 else { throw posixError("sync eviction") }
				} catch {
					// If truncation did not happen, remove the marker we added.
					// Never claim the file was untouched when rollback failed.
					if attached && !truncated {
						let observed = try? descriptorStat(file.fd)
						if observed?.st_size != initial.st_size
							|| observed?.st_mtimespec.tv_sec != initial.st_mtimespec.tv_sec
							|| observed?.st_mtimespec.tv_nsec != initial.st_mtimespec.tv_nsec {
							// An I/O error need not prove that no bytes changed. Keep
							// the marker when rollback could expose a truncated local edit.
							report.refusals.append("\(url.path): bytes changed or cannot be checked; marker retained for inspection and recall using the journal")
						} else if (fremovexattr(file.fd, PlaceholderDetector.attributeName, 0) != 0 && errno != ENOATTR)
							|| fsync(file.fd) != 0 {
							report.refusals.append("\(url.path): marker rollback failed; inspect this file and its journal")
						}
					}
					throw error
				}
			} catch {
				report.refusals.append("\(url.path): \(error)")
			}
		}
		if cancellation.isCancelled && report.cancelled == nil {
			report.cancelled = "cancelled by \(cancellation.cause)"
		}
		return report
	}

	public static func isWithin(sandbox: URL, path: URL) -> Bool {
		isContained(canonicalURL(path).path, in: canonicalURL(sandbox).path)
	}

	public struct Expansion {
		public var paths: [URL] = []
		public var errors: [String] = []
	}
	/// Do not silently discard traversal failures or follow a directory symlink.
	public static func expandChecked(_ roots: [URL], cancellation: Cancellation = .shared) -> Expansion {
		var result = Expansion(), seen = Set<String>()
		for root in RecallEngine.minimalRoots(roots.map(\.standardizedFileURL)) {
			if cancellation.isCancelled { break }
			guard let st = PlaceholderDetector.fileStat(root) else {
				result.errors.append("\(root.path): \(String(cString: strerror(errno)))"); continue
			}
			if st.st_mode & S_IFMT != S_IFDIR {
				if seen.insert(root.path).inserted { result.paths.append(root) }; continue
			}
			guard let walker = FileManager.default.enumerator(
				at: root, includingPropertiesForKeys: [], options: [],
				errorHandler: { url, error in result.errors.append("\(url.path): \(error.localizedDescription)"); return true })
			else { result.errors.append("\(root.path): could not enumerate"); continue }
			for case let url as URL in walker {
				if cancellation.isCancelled { break }
				guard let info = PlaceholderDetector.fileStat(url) else {
					result.errors.append("\(url.path): could not inspect entry"); continue
				}
				if info.st_mode & S_IFMT != S_IFDIR, seen.insert(url.path).inserted { result.paths.append(url) }
			}
		}
		return result
	}
	public static func expand(_ roots: [URL]) -> [URL] { expandChecked(roots).paths }

	/// Undo is a recall plus size/hash verification. It never deletes or
	/// overwrites local content, and it never reads or creates a content backup.
	public func undo(manifest: UndoManifest, engine: RecallEngine? = nil) -> UndoReport {
		var report = UndoReport()
		guard manifest.version == 1 || manifest.version == 2,
		      canonicalURL(URL(fileURLWithPath: manifest.sandbox)).path == canonicalURL(sandboxRoot).path else {
			report.failures.append((manifest.sandbox, "unsupported manifest version or sandbox mismatch")); return report
		}
		let sandbox: SandboxDirectory
		do { sandbox = try SandboxDirectory(sandboxRoot) }
		catch { report.failures.append((sandboxRoot.path, "\(error)")); return report }
		var valid: [UndoEntry] = [], targets: [URL] = [], seen = Set<String>()
		for entry in manifest.entries {
			if cancellation.isCancelled { report.cancelled = "cancelled by \(cancellation.cause)"; break }
			let url = URL(fileURLWithPath: entry.path).standardizedFileURL
			do {
				guard entry.path.hasPrefix("/"), entry.size >= 0, entry.sha256.count == 64,
				      entry.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
				      seen.insert(url.path).inserted else { throw EvictError.journal("invalid or duplicate entry") }
				let (file, parent, name) = try sandbox.openFile(url, writable: false)
				try sandbox.validate(file, parent: parent, name: name)
				guard (try descriptorStat(file.fd)).st_nlink == 1 else {
					throw EvictError.changed("hard-linked undo target")
				}
				let marker = try getAttribute(fd: file.fd, name: PlaceholderDetector.attributeName)
				if marker != nil, let attrs = entry.dropboxAttributes {
					guard marker == Self.placeholderHeader + Array(attrs) else {
						throw EvictError.changed("placeholder metadata differs from the recorded file")
					}
				}
				valid.append(entry)
				if marker != nil { targets.append(canonicalURL(url)) }
			} catch { report.failures.append((entry.path, "\(error)")) }
		}
		if dryRun { report.wouldRecall = targets.map(\.path); return report }
		let recall = engine ?? RecallEngine(cancellation: cancellation)
		if !targets.isEmpty {
			let hydration = recall.hydrate(roots: targets)
			report.failures += hydration.errors.map { ($0.url.path, $0.message) }
			report.failures += hydration.refusals.map { (manifest.sandbox, $0) }
			report.diagnosis = hydration.diagnosis
			if let reason = hydration.diagnosis, reason.hasPrefix("cancelled by") {
				report.cancelled = reason
				return report
			}
		}
		for entry in valid {
			if cancellation.isCancelled { report.cancelled = "cancelled by \(cancellation.cause)"; break }
			let url = URL(fileURLWithPath: entry.path)
			do {
				let (file, parent, name) = try sandbox.openFile(url, writable: false)
				try sandbox.validate(file, parent: parent, name: name)
				if try getAttribute(fd: file.fd, name: PlaceholderDetector.attributeName) != nil {
					report.needRecall.append(entry.path); continue
				}
				let initial = try descriptorStat(file.fd)
				let hash = try digest(fd: file.fd, cancellation: cancellation)
				guard sameContents(initial, try descriptorStat(file.fd)), hash.size == entry.size, hash.sha256 == entry.sha256 else {
					throw EvictError.changed("recalled or local content differs from the journal; local bytes were preserved")
				}
				report.restored.append((entry.path, true))
			} catch { report.failures.append((entry.path, "\(error)")) }
		}
		return report
	}
}
