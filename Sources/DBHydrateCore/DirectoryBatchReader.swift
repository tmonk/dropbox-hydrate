import Foundation
import Darwin

/// Read names and types in bounded native batches. The descriptor pins the
/// directory; callers descend with openat(O_NOFOLLOW), never through a link.
/// Missing extended flags mean "unknown", never "no extended attributes".
final class DirectoryBatchReader {
	struct Entry {
		let name: String
		let type: UInt32?
		let noAttributes: Bool
		let error: Int32?
	}

	let directory: OwnedDescriptor
	private let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64 * 1024, alignment: 8)
	private var stream: UnsafeMutablePointer<DIR>?
	private var started = false
	private var finished = false
	private let preferBulk: Bool

	init(_ directory: OwnedDescriptor, preferBulk: Bool = true) {
		self.directory = directory; self.preferBulk = preferBulk
	}

	deinit {
		if let stream { closedir(stream) }
		buffer.deallocate()
	}

	func next() throws -> [Entry] {
		if finished { return [] }
		if !preferBulk || stream != nil { return try readDirectory() }
		var attributes = attrlist()
		attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
		attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME)
			| UInt32(ATTR_CMN_ERROR) | UInt32(ATTR_CMN_OBJTYPE)
		attributes.forkattr = UInt32(ATTR_CMNEXT_EXT_FLAGS)
		var count: Int32
		repeat {
			count = getattrlistbulk(directory.fd, &attributes, buffer, 64 * 1024,
			                       UInt64(FSOPT_ATTR_CMN_EXTENDED | FSOPT_PACK_INVAL_ATTRS))
		} while count < 0 && errno == EINTR
		if count < 0 {
			// An unsupported filesystem/OS can use readdir, but a failure after
			// traversal began must remain an error, not restart and double count.
			if !started && (errno == ENOTSUP || errno == EINVAL || errno == ENOSYS) {
				return try readDirectory()
			}
			throw posixError("read directory metadata")
		}
		started = true
		if count == 0 { finished = true; return [] }
		return try Self.decode(UnsafeRawBufferPointer(start: buffer, count: 64 * 1024), count: Int(count))
	}

	/// PACK_INVAL_ATTRS fixes the field offsets, even when a field is unavailable.
	/// Validate every record, reference and name before reading variable data.
	static func decode(_ bytes: UnsafeRawBufferPointer, count: Int) throws -> [Entry] {
		func invalid() -> NSError {
			NSError(domain: NSPOSIXErrorDomain, code: Int(EIO),
			        userInfo: [NSLocalizedDescriptionKey: "invalid directory metadata buffer"])
		}
		guard count >= 0, count <= bytes.count / 48 else { throw invalid() }
		var entries: [Entry] = []
		entries.reserveCapacity(count)
		var offset = 0
		for _ in 0..<count {
			guard offset <= bytes.count - 48, let base = bytes.baseAddress else { throw invalid() }
			let row = base.advanced(by: offset)
			let length = Int(row.loadUnaligned(as: UInt32.self))
			guard length >= 48, length <= bytes.count - offset else { throw invalid() }
			let returned = row.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
			guard returned.commonattr & UInt32(ATTR_CMN_NAME) != 0 else { throw invalid() }
			let code = row.loadUnaligned(fromByteOffset: 24, as: UInt32.self)
			let reference = row.loadUnaligned(fromByteOffset: 28, as: attrreference_t.self)
			let nameOffset = 28 + Int(reference.attr_dataoffset)
			let nameLength = Int(reference.attr_length)
			guard nameOffset >= 48, nameOffset < length, nameLength > 1,
			      nameLength <= length - nameOffset else { throw invalid() }
			let nameBytes = UnsafeRawBufferPointer(start: row.advanced(by: nameOffset), count: nameLength)
			guard nameBytes.last == 0, !nameBytes.dropLast().contains(0),
			      !nameBytes.contains(UInt8(ascii: "/")) else { throw invalid() }
			guard let name = String(validatingCString: row.advanced(by: nameOffset).assumingMemoryBound(to: CChar.self)),
			      name != ".", name != ".." else { throw invalid() }
			let type = returned.commonattr & UInt32(ATTR_CMN_OBJTYPE) != 0
				? row.loadUnaligned(fromByteOffset: 36, as: UInt32.self) : nil
			let flags = row.loadUnaligned(fromByteOffset: 40, as: UInt64.self)
			let knownFlags = returned.forkattr & UInt32(ATTR_CMNEXT_EXT_FLAGS) != 0
			let error = returned.commonattr & UInt32(ATTR_CMN_ERROR) != 0 && code != 0
				? Int32(bitPattern: code) : nil
			entries.append(Entry(name: name, type: type,
			                     noAttributes: knownFlags && flags & UInt64(EF_NO_XATTRS) != 0,
			                     error: error))
			offset += length
		}
		return entries
	}

	private func readDirectory() throws -> [Entry] {
		if stream == nil {
			// A separate open description starts at offset zero even after an
			// unsupported bulk call. Never mix bulk/readdir on one description.
			let fd = openat(directory.fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
			guard fd >= 0 else { throw posixError("open directory stream") }
			guard let opened = fdopendir(fd) else {
				let error = posixError("open directory stream"); close(fd); throw error
			}
			stream = opened
		}
		var entries: [Entry] = []
		while entries.count < 256 {
			errno = 0
			guard let item = readdir(stream) else {
				if errno != 0 { throw posixError("read directory") }
				finished = true; break
			}
			let name = withUnsafePointer(to: &item.pointee.d_name) {
				$0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) {
					String(validatingCString: $0)
				}
			}
			guard let name, !name.contains("/"), !name.isEmpty else {
				throw NSError(domain: NSPOSIXErrorDomain, code: Int(EILSEQ))
			}
			if name == "." || name == ".." { continue }
			var type: UInt32?
			switch Int32(item.pointee.d_type) {
			case DT_DIR: type = VDIR.rawValue
			case DT_REG: type = VREG.rawValue
			case DT_LNK: type = VLNK.rawValue
			case DT_UNKNOWN: type = nil
			default: type = VNON.rawValue
			}
			entries.append(Entry(name: name, type: type, noAttributes: false, error: nil))
		}
		return entries
	}
}
