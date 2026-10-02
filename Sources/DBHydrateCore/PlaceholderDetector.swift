import Foundation

public enum PlaceholderDetector {
	public static let attributeName = "com.dropbox.placeholder"
	private static let attributeBytes = Array(attributeName.utf8)

	/// Attribute errors are not evidence of local content. In particular, EACCES
	/// and ENOENT must never be interpreted as a successful recall.
	public static func hasPlaceholderAttribute(_ url: URL) -> Bool {
		attributeStatus(url).present
	}

	static func attributeStatus(_ url: URL) -> (present: Bool, error: Int32?) {
		attributeStatus(path: url.path)
	}

	static func attributeStatus(path: String) -> (present: Bool, error: Int32?) {
		let result = path.withCString { getxattr($0, attributeName, nil, 0, 0, XATTR_NOFOLLOW) }
		if result >= 0 { return (true, nil) }
		let code = errno
		return (false, code == ENOATTR || code == ENOTSUP ? nil : code)
	}

	/// APFS exposes ordinary custom attribute names in listxattr. Listing names
	/// avoids the expensive missing-name query on mostly local trees. Confirm a
	/// match with getxattr so permission errors and races remain visible. A large
	/// or unsupported list takes the exact query instead of losing a candidate.
	static func listedAttributeStatus(path: String) -> (present: Bool, error: Int32?) {
		withUnsafeTemporaryAllocation(of: CChar.self, capacity: 512) { names in
			let count = path.withCString { listxattr($0, names.baseAddress, names.count, XATTR_NOFOLLOW) }
			if count < 0 {
				let code = errno
				if code == ERANGE || code == ENOTSUP { return attributeStatus(path: path) }
				return (false, code)
			}
			guard count <= names.count else { return attributeStatus(path: path) }
			var start = 0
			for end in 0..<count where names[end] == 0 {
				if end - start == attributeBytes.count {
					let match = attributeBytes.withUnsafeBytes {
						memcmp(names.baseAddress!.advanced(by: start), $0.baseAddress!, attributeBytes.count) == 0
					}
					if match { return attributeStatus(path: path) }
				}
				start = end + 1
			}
			// A truncated/malformed list cannot establish absence.
			return start == count ? (false, nil) : attributeStatus(path: path)
		}
	}

	static func fileStat(_ url: URL) -> stat? {
		var st = stat()
		guard lstat(url.path, &st) == 0 else { return nil }
		return st
	}

	public static func size(of url: URL) -> Int? {
		guard let st = fileStat(url), st.st_mode & S_IFMT == S_IFREG else { return nil }
		return Int(st.st_size)
	}

	public static func isPlaceholder(_ url: URL) -> Bool {
		guard let st = fileStat(url), st.st_mode & S_IFMT == S_IFREG else { return false }
		return hasPlaceholderAttribute(url)
	}

	enum FileState {
		case local(Int), placeholder(Int), failed(String)
		var size: Int {
			switch self { case .local(let n), .placeholder(let n): return n; case .failed: return 0 }
		}
		var recalled: Bool { if case .local = self { return true }; return false }
	}

	static func state(of url: URL) -> FileState {
		guard let st = fileStat(url) else { return .failed(String(cString: strerror(errno))) }
		guard st.st_mode & S_IFMT == S_IFREG else { return .failed("not a regular file; symlinks are refused") }
		let attribute = attributeStatus(url)
		if let code = attribute.error { return .failed(String(cString: strerror(code))) }
		return attribute.present ? .placeholder(Int(st.st_size)) : .local(Int(st.st_size))
	}

	/// Empty files can also be recalled: absence of the attribute, rather than a
	/// positive byte count, determines completion. Symlinks are never followed.
	public static func isRecalled(_ url: URL) -> Bool {
		state(of: url).recalled
	}

	public struct ScanResult {
		public var entries = 0
		public var placeholders: [URL] = []
		public var errors: [(url: URL, message: String)] = []
		public var cancelled = false
	}

	/// Native directory batches avoid a URL allocation for every local entry.
	/// Attribute lookups use at most eight workers and a bounded batch, rather
	/// than allocating one task per file. Errors and cancellation remain visible.
	public static func scan(root: URL, cancellation: Cancellation = .shared) -> ScanResult {
		scan(root: root, cancellation: cancellation, preferBulk: nil)
	}

	static func scan(root: URL, cancellation: Cancellation, preferBulk: Bool?) -> ScanResult {
		var result = ScanResult()
		guard let st = fileStat(root) else {
			result.errors.append((root, String(cString: strerror(errno))))
			return result
		}
		let kind = st.st_mode & S_IFMT
		guard kind == S_IFREG || kind == S_IFDIR else {
			result.errors.append((root, "not a regular file or directory; symlinks are refused"))
			return result
		}
		func examine(_ lookup: ScanLookup, into partial: inout ScanResult) {
			let path = lookup.path
			let state = lookup.listAttributes ? listedAttributeStatus(path: path) : attributeStatus(path: path)
			if let code = state.error {
				partial.errors.append((URL(fileURLWithPath: path), String(cString: strerror(code))))
			} else if state.present {
				let url = URL(fileURLWithPath: path, isDirectory: false)
				guard let item = fileStat(url), item.st_mode & S_IFMT == S_IFREG else {
					partial.errors.append((url, "placeholder is not a regular file, or disappeared"))
					return
				}
				partial.placeholders.append(url)
			}
		}
		if cancellation.isCancelled { result.cancelled = true; return result }
		if kind == S_IFREG {
			result.entries = 1; examine(ScanLookup(path: root.path, listAttributes: false), into: &result); return result
		}
		let fd = root.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
		guard fd >= 0 else {
			result.errors.append((root, String(cString: strerror(errno)))); return result
		}
		let directory = OwnedDescriptor(fd)
		guard let opened = try? descriptorStat(fd), sameFile(st, opened) else {
			result.errors.append((root, "directory changed before scan")); return result
		}
		let checks = ScanLookupPool(cancellation: cancellation, examine: examine)
		func walk(_ directory: OwnedDescriptor, path: String) {
			var filesystem = statfs()
			let nameCapacity = MemoryLayout.size(ofValue: filesystem.f_fstypename)
			let listAttributes = fstatfs(directory.fd, &filesystem) == 0 && withUnsafePointer(to: &filesystem.f_fstypename) {
				$0.withMemoryRebound(to: CChar.self, capacity: nameCapacity) {
					String(cString: $0) == "apfs"
				}
			}
			// APFS supplies readdir types; reading full per-entry metadata costs
			// more than the fast name checks. Other filesystems can benefit from
			// bulk metadata and its explicit no-attributes hint. Tests force both.
			let reader = DirectoryBatchReader(directory, preferBulk: preferBulk ?? !listAttributes)
			do {
				while !cancellation.isCancelled {
					let entries = try reader.next()
					if entries.isEmpty { break }
					var children: [String] = [], lookups: [ScanLookup] = []
					for entry in entries {
						if cancellation.isCancelled { break }
						result.entries += 1
						let fullPath = path == "/" ? path + entry.name : path + "/" + entry.name
						if let code = entry.error {
							result.errors.append((URL(fileURLWithPath: fullPath), String(cString: strerror(code))))
							continue
						}
						var type = entry.type
						if type == nil {
							var info = stat()
							guard entry.name.withCString({ fstatat(directory.fd, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0 else {
								result.errors.append((URL(fileURLWithPath: fullPath), String(cString: strerror(errno))))
								continue
							}
							type = info.st_mode & S_IFMT == S_IFDIR ? VDIR.rawValue : VNON.rawValue
						}
						if type == VDIR.rawValue { children.append(entry.name) }
						if !entry.noAttributes || type != VREG.rawValue {
							lookups.append(ScanLookup(path: fullPath, listAttributes: listAttributes && type == VREG.rawValue))
						}
					}
					checks.submit(lookups)
					for name in children {
						if cancellation.isCancelled { break }
						let childPath = path == "/" ? path + name : path + "/" + name
						let child = name.withCString {
							openat(directory.fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
						}
						guard child >= 0 else {
							result.errors.append((URL(fileURLWithPath: childPath), String(cString: strerror(errno))))
							continue
						}
						walk(OwnedDescriptor(child), path: childPath)
					}
				}
			} catch { result.errors.append((URL(fileURLWithPath: path, isDirectory: true), error.localizedDescription)) }
		}
		walk(directory, path: root.path)
		let checked = checks.finish()
		result.placeholders += checked.placeholders; result.errors += checked.errors
		result.cancelled = cancellation.isCancelled
		return result
	}

	public static func placeholders(under root: URL) -> [URL] { scan(root: root).placeholders }
}

struct ScanLookup {
	let path: String
	let listAttributes: Bool
}

/// A fixed pool consumes 128-path chunks while the caller enumerates ahead.
/// Backpressure bounds queued chunks to 16; neither tasks nor threads grow with
/// the file count. Cancellation is checked between lookups and releases waiters.
final class ScanLookupPool {
	private let cancellation: Cancellation
	private let examine: (ScanLookup, inout PlaceholderDetector.ScanResult) -> Void
	private let condition = NSCondition()
	private let group = DispatchGroup()
	private var queue: [[ScanLookup]] = []
	private var closed = false
	private var started = false
	private var result = PlaceholderDetector.ScanResult()
	private var observation: UUID?

	init(cancellation: Cancellation,
	     examine: @escaping (ScanLookup, inout PlaceholderDetector.ScanResult) -> Void) {
		self.cancellation = cancellation; self.examine = examine
		observation = cancellation.observe { [weak self] in
			guard let self else { return }
			self.condition.lock(); self.condition.broadcast(); self.condition.unlock()
		}
	}

	deinit { if let observation { cancellation.removeObserver(observation) } }

	func submit(_ paths: [ScanLookup]) {
		if paths.isEmpty || cancellation.isCancelled { return }
		if !started {
			started = true
			for _ in 0..<8 {
				group.enter()
				DispatchQueue.global(qos: .userInitiated).async { self.consume(); self.group.leave() }
			}
		}
		for start in stride(from: 0, to: paths.count, by: 128) {
			condition.lock()
			while queue.count >= 16 && !cancellation.isCancelled { condition.wait() }
			if cancellation.isCancelled { condition.unlock(); break }
			queue.append(Array(paths[start..<min(paths.count, start + 128)]))
			condition.broadcast(); condition.unlock()
		}
	}

	private func consume() {
		while true {
			condition.lock()
			while queue.isEmpty && !closed && !cancellation.isCancelled { condition.wait() }
			if cancellation.isCancelled || (queue.isEmpty && closed) { condition.unlock(); return }
			let paths = queue.removeFirst()
			condition.broadcast(); condition.unlock()
			var partial = PlaceholderDetector.ScanResult()
			for path in paths {
				if cancellation.isCancelled { break }
				examine(path, &partial)
			}
			condition.lock()
			result.placeholders += partial.placeholders; result.errors += partial.errors
			condition.unlock()
		}
	}

	func finish() -> PlaceholderDetector.ScanResult {
		condition.lock(); closed = true; condition.broadcast(); condition.unlock()
		group.wait()
		return result
	}
}
