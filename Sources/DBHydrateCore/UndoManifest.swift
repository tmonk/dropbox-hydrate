import CryptoKit
import Foundation

/// Metadata only. No local content copy is made; undo must obtain the content
/// from Dropbox and verify it against this record.
public struct UndoEntry: Codable, Sendable {
	public var path: String
	public var size: Int
	public var sha256: String
	public var dropboxAttributes: Data?
	public init(path: String, size: Int, sha256: String, dropboxAttributes: Data? = nil) {
		self.path = path; self.size = size; self.sha256 = sha256
		self.dropboxAttributes = dropboxAttributes
	}
}

public struct UndoManifest: Codable, Sendable {
	static let maximumBytes = 256 * 1024 * 1024
	public var version = 2
	public var created = Date()
	public var sandbox: String
	public var entries: [UndoEntry] = []
	public init(sandbox: String) { self.sandbox = sandbox }

	/// Version 1 JSON remains readable, but its former local-copy fields are
	/// ignored. Version 2 is an append-only JSON-lines journal. A torn last line
	/// was never acknowledged as durable, and therefore could not authorize an
	/// eviction; all complete preceding entries remain recoverable.
	public static func read(from url: URL) throws -> UndoManifest {
		let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
		guard fd >= 0 else { throw posixError("open manifest") }
		let file = OwnedDescriptor(fd)
		let st = try descriptorStat(file.fd)
		guard st.st_mode & S_IFMT == S_IFREG, st.st_size <= Self.maximumBytes else {
			throw Evictor.EvictError.journal("manifest must be a regular file under 256 MiB")
		}
		let handle = FileHandle(fileDescriptor: file.fd, closeOnDealloc: false)
		let data = try handle.readToEnd() ?? Data()
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		if let old = try? decoder.decode(UndoManifest.self, from: data) { return old }
		var lines = data.split(separator: 10, omittingEmptySubsequences: false)
		if data.last != 10 { lines.removeLast() } // incomplete tail, never acted on
		guard let first = lines.first, !first.isEmpty else {
			throw Evictor.EvictError.journal("missing journal header")
		}
		var manifest = try decoder.decode(UndoManifest.self, from: Data(first))
		guard manifest.version == 2, manifest.entries.isEmpty else {
			throw Evictor.EvictError.journal("unsupported journal header")
		}
		for line in lines.dropFirst() where !line.isEmpty {
			manifest.entries.append(try decoder.decode(UndoEntry.self, from: Data(line)))
		}
		return manifest
	}
}

final class UndoJournal {
	let output: ExclusiveOutput
	private let maximumBytes: Int
	private let encoder = JSONEncoder()
	private(set) var count = 0
	var url: URL { output.url }

	init(url: URL, sandbox: URL, maximumBytes: Int = UndoManifest.maximumBytes) throws {
		self.maximumBytes = min(maximumBytes, UndoManifest.maximumBytes)
		output = try ExclusiveOutput(url)
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.sortedKeys]
		try output.append(encoder.encode(UndoManifest(sandbox: sandbox.path)) + Data([10]))
	}
	func record(_ entry: UndoEntry) throws {
		let data = try encoder.encode(entry) + Data([10])
		guard try descriptorStat(output.file.fd).st_size + Int64(data.count) <= maximumBytes else {
			throw Evictor.EvictError.journal("size limit reached; start a new journal for remaining files")
		}
		try output.append(data)
		count += 1
	}
}

public struct UndoReport {
	public var restored: [(path: String, verified: Bool)] = []
	public var needRecall: [String] = []
	public var failures: [(path: String, reason: String)] = []
	public var wouldRecall: [String] = []
	public var cancelled: String?
	public var diagnosis: String?
	public var ok: Bool { failures.isEmpty && needRecall.isEmpty && cancelled == nil }
}

/// Hash a pinned descriptor with bounded memory. A read error is an error, never
/// the digest of a silently truncated prefix. pread leaves the file offset alone.
func digest(fd: Int32, cancellation: Cancellation? = nil) throws -> (sha256: String, size: Int) {
	var hasher = SHA256(), offset: off_t = 0
	var buffer = [UInt8](repeating: 0, count: 1 << 20)
	while true {
		if cancellation?.isCancelled == true { throw Evictor.EvictError.changed("cancelled before eviction") }
		let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, offset) }
		if count < 0 && errno == EINTR { continue }
		guard count >= 0 else { throw posixError("read for sha256") }
		if count == 0 { break }
		hasher.update(data: Data(buffer.prefix(count)))
		offset += off_t(count)
	}
	return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), Int(offset))
}

public func sha256(ofFileAt path: String) -> String? {
	let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
	guard fd >= 0 else { return nil }
	let file = OwnedDescriptor(fd)
	guard let st = try? descriptorStat(file.fd), st.st_mode & S_IFMT == S_IFREG else { return nil }
	return try? digest(fd: file.fd).sha256
}
