import Foundation

/// Foundation's standardizedFileURL can collapse /private/var back to /var.
/// FSEvents and descriptor paths use the kernel spelling, so use realpath and
/// preserve it. For new outputs, resolve the existing parent instead.
func canonicalURL(_ url: URL) -> URL {
	if let pointer = url.path.withCString({ realpath($0, nil) }) {
		defer { free(pointer) }
		return URL(fileURLWithPath: String(cString: pointer), isDirectory: url.hasDirectoryPath)
	}
	let normalized = url.standardizedFileURL
	if normalized.path == "/" { return normalized }
	return canonicalURL(normalized.deletingLastPathComponent()).appendingPathComponent(normalized.lastPathComponent)
}

func posixError(_ operation: String) -> NSError {
	NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
	        userInfo: [NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(errno)))"])
}

final class OwnedDescriptor {
	let fd: Int32
	init(_ fd: Int32) { self.fd = fd }
	deinit { close(fd) }
}

func descriptorStat(_ fd: Int32) throws -> stat {
	var info = stat()
	guard fstat(fd, &info) == 0 else { throw posixError("fstat") }
	return info
}

func sameFile(_ a: stat, _ b: stat) -> Bool {
	a.st_dev == b.st_dev && a.st_ino == b.st_ino
}

func sameContents(_ a: stat, _ b: stat) -> Bool {
	sameFile(a, b) && a.st_size == b.st_size
		&& a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
		&& a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
		&& a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
		&& a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
}

func isContained(_ path: String, in root: String) -> Bool {
	path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
}

/// The directory descriptor pins the sandbox. Each component below it is opened
/// with O_NOFOLLOW; a later symlink swap cannot redirect a destructive syscall.
final class SandboxDirectory {
	let rawRoot: URL
	let root: URL
	let descriptor: OwnedDescriptor

	init(_ url: URL) throws {
		rawRoot = url.standardizedFileURL
		root = canonicalURL(rawRoot)
		descriptor = try Self.openDirectory(root)
	}

	static func openDirectory(_ url: URL) throws -> OwnedDescriptor {
		var current = OwnedDescriptor(open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC))
		guard current.fd >= 0 else { throw posixError("open /") }
		for component in url.path.split(separator: "/") {
			let next = String(component).withCString {
				openat(current.fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
			}
			guard next >= 0 else { throw posixError("open directory \(url.path)") }
			current = OwnedDescriptor(next)
		}
		return current
	}

	func relativePath(_ url: URL) throws -> String {
		let path = url.standardizedFileURL.path
		let bases = [rawRoot.path, root.path]
		guard let base = bases.first(where: { path != $0 && isContained(path, in: $0) }) else {
			throw Evictor.EvictError.outsideSandbox(path)
		}
		return String(path.dropFirst(base == "/" ? 1 : base.count + 1))
	}

	func openParent(of url: URL) throws -> (OwnedDescriptor, String) {
		let relative = try relativePath(url)
		let components = relative.split(separator: "/").map(String.init)
		guard let name = components.last, !components.contains("..") else {
			throw Evictor.EvictError.notAFile(url.path)
		}
		let copy = dup(descriptor.fd)
		guard copy >= 0 else { throw posixError("dup sandbox") }
		var parent = OwnedDescriptor(copy)
		for component in components.dropLast() {
			let next = component.withCString {
				openat(parent.fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
			}
			guard next >= 0 else { throw posixError("open parent of \(url.path)") }
			parent = OwnedDescriptor(next)
		}
		return (parent, name)
	}

	func openFile(_ url: URL, writable: Bool) throws -> (OwnedDescriptor, OwnedDescriptor, String) {
		let (parent, name) = try openParent(of: url)
		let flags = (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
		let fd = name.withCString { openat(parent.fd, $0, flags) }
		guard fd >= 0 else { throw posixError("open \(url.path)") }
		let file = OwnedDescriptor(fd)
		let st = try descriptorStat(fd)
		guard st.st_mode & S_IFMT == S_IFREG else { throw Evictor.EvictError.notAFile(url.path) }
		return (file, parent, name)
	}

	func validate(_ file: OwnedDescriptor, parent: OwnedDescriptor, name: String) throws {
		let current = try descriptorStat(file.fd)
		var named = stat()
		guard name.withCString({ fstatat(parent.fd, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
		      sameFile(current, named), named.st_mode & S_IFMT == S_IFREG else {
			throw Evictor.EvictError.changed("path was replaced")
		}
		var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
		guard fcntl(file.fd, F_GETPATH, &buffer) == 0 else { throw posixError("F_GETPATH") }
		guard isContained(String(cString: buffer), in: root.path) else {
			throw Evictor.EvictError.changed("open file moved outside sandbox")
		}
	}
}

func getAttribute(fd: Int32, name: String) throws -> [UInt8]? {
	let count = fgetxattr(fd, name, nil, 0, 0, 0)
	if count < 0 {
		if errno == ENOATTR || errno == ENOTSUP { return nil }
		throw posixError("read \(name)")
	}
	guard count > 0 else { return [] }
	var bytes = [UInt8](repeating: 0, count: count)
	let got = bytes.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, count, 0, 0) }
	guard got == count else { throw posixError("read changed \(name)") }
	return bytes
}

func setAttribute(fd: Int32, name: String, bytes: [UInt8], options: Int32 = 0) throws {
	let result = bytes.withUnsafeBytes { fsetxattr(fd, name, $0.baseAddress, bytes.count, 0, options) }
	guard result == 0 else { throw posixError("write \(name)") }
}

func writeAll(_ data: Data, to fd: Int32) throws {
	try data.withUnsafeBytes { raw in
		var offset = 0
		while offset < raw.count {
			let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
			if count < 0 && errno == EINTR { continue }
			guard count > 0 else { throw posixError("write") }
			offset += count
		}
	}
}

/// New files only: statistics and journals must never overwrite a target or an
/// earlier run. Open and validate the output before starting the operation.
final class ExclusiveOutput {
	let url: URL
	let file: OwnedDescriptor
	private let parent: OwnedDescriptor
	private let name: String

	init(_ url: URL) throws {
		let parentURL = canonicalURL(url.deletingLastPathComponent())
		let openedParent = try SandboxDirectory.openDirectory(parentURL)
		parent = openedParent
		name = url.lastPathComponent
		self.url = parentURL.appendingPathComponent(url.lastPathComponent)
		let fd = url.lastPathComponent.withCString {
			openat(openedParent.fd, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
		}
		guard fd >= 0 else { throw posixError("create \(url.path)") }
		file = OwnedDescriptor(fd)
		guard fsync(parent.fd) == 0 else { throw posixError("sync output directory") }
	}

	func append(_ data: Data) throws {
		try validate()
		try writeAll(data, to: file.fd)
		guard fsync(file.fd) == 0 else { throw posixError("sync \(url.path)") }
		try validate()
	}

	func validate() throws {
		var named = stat()
		let st = try descriptorStat(file.fd)
		guard name.withCString({ fstatat(parent.fd, $0, &named, AT_SYMLINK_NOFOLLOW) }) == 0,
		      sameFile(st, named), st.st_nlink == 1 else {
			throw Evictor.EvictError.journal("output was removed, replaced or hard-linked")
		}
	}
}

/// CLI output uses the same no-clobber file creation as eviction journals.
public final class NewStatisticsFile {
	private let output: ExclusiveOutput
	public init(url: URL) throws { output = try ExclusiveOutput(url) }
	public func write(_ data: Data) throws { try output.append(data) }
}
