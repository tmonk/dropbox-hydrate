import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Live progress for a recall run.
///
/// Degrades in three steps so it is never wrong or ugly:
///
///   * TTY + colour capable -> a single redrawn line with a bar, throughput and
///     ETA;
///   * TTY without colour -> the same line, plain;
///   * not a TTY (a pipe, a log, CI) -> occasional plain lines, no escape
///     sequences at all, so redirected output stays greppable.
public final class ProgressReporter {

	public enum Style: String { case auto, bar, plain, silent }

	private let style: Style
	private let useColor: Bool
	private let width: Int
	private let stream: FileHandle
	private let lock = NSLock()

	private var total = 0
	private var done = 0
	private var bytes: Int64 = 0
	private var failures = 0
	private let started = Date()
	private var lastRender = Date.distantPast
	private var lastPlain = Date.distantPast
	private var live = false

	public init(style: Style = .auto, stream: FileHandle = .standardOutput) {
		self.stream = stream
		let tty = isatty(stream.fileDescriptor) == 1
		let dumb = ProcessInfo.processInfo.environment["TERM"] == "dumb"
		let noColor = ProcessInfo.processInfo.environment["NO_COLOR"] != nil

		switch style {
		case .auto:
			self.style = tty && !dumb ? .bar : (tty ? .plain : .plain)
		case .bar:
			self.style = .bar
		case .plain:
			self.style = .plain
		case .silent:
			self.style = .silent
		}
		self.useColor = !noColor && isatty(stream.fileDescriptor) == 1 && dumb == false
		self.width = ProgressReporter.terminalWidth()
	}

	// MARK: - Terminal helpers

	private static func terminalWidth() -> Int {
		var ws = winsize()
		if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 {
			return max(40, min(Int(ws.ws_col), 100))
		}
		return 72
	}

	private func write(_ s: String) {
		stream.write(Data(s.utf8))
	}

	private var supportsRedraw: Bool { style == .bar && isatty(stream.fileDescriptor) == 1 }

	// MARK: - Formatting

	private static func bytes(_ n: Int64) -> String {
		let units = ["B", "KB", "MB", "GB", "TB"]
		var value = Double(n)
		var unit = 0
		while value >= 1024, unit < units.count - 1 {
			value /= 1024
			unit += 1
		}
		return unit == 0 ? "\(n) B" : String(format: "%.1f %@", value, units[unit])
	}

	private static func duration(_ seconds: TimeInterval) -> String {
		let s = Int(seconds.rounded())
		if s < 60 { return "\(s)s" }
		if s < 3600 { return "\(s / 60)m \(s % 60)s" }
		return "\(s / 3600)h \((s % 3600) / 60)m"
	}

	private func paint(_ text: String, _ code: String) -> String {
		useColor ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
	}

	// MARK: - Lifecycle

	public func begin(totalFiles: Int) {
		lock.lock(); defer { lock.unlock() }
		guard style != .silent else { return }
		total = totalFiles
		if totalFiles == 0 {
			write("\(paint("nothing to recall", "2"))\n")
			return
		}
		if supportsRedraw {
			live = true
			render(force: true)
		} else {
			write("recalling \(totalFiles) placeholder(s) from Dropbox...\n")
		}
	}

	public func completed(path: URL, bytes landed: Int64, ok: Bool) {
		guard style != .silent else { return }
		lock.lock(); defer { lock.unlock() }
		done += 1
		if ok { bytes += max(0, landed) }
		if !ok { failures += 1 }
		guard style != .silent else { return }

		if supportsRedraw {
			render(force: false)
		} else {
			// Rate-limit plain output so a piped log stays readable.
			let now = Date()
			if now.timeIntervalSince(lastPlain) > 2 {
				lastPlain = now
				let elapsed = now.timeIntervalSince(started)
				let rate = elapsed > 0 ? Double(done) / elapsed : 0
				let eta = rate > 0 ? Double(max(0, total - done)) / rate : 0
				write("  [\(done)/\(total)] \(bytesRate(landed: landed))"
					+ " \(ProgressReporter.duration(elapsed)) elapsed, ~\(ProgressReporter.duration(eta)) left\n")
			}
		}
	}

	private func bytesRate(landed: Int64) -> String {
		let elapsed = Date().timeIntervalSince(started)
		guard elapsed > 0 else { return ProgressReporter.bytes(bytes) }
		return "\(ProgressReporter.bytes(Int64(Double(bytes) / elapsed)))/s"
	}

	/// Erase the live line so the caller can print its own summary cleanly.
	public func finish() {
		lock.lock(); defer { lock.unlock() }
		guard live else { return }
		live = false
		var erase = String(repeating: " ", count: width)
		erase.append("\r")
		write(erase)
	}

	// MARK: - Rendering

	private func render(force: Bool) {
		guard style == .bar else { return }
		let now = Date()
		// ~12 fps is smooth to the eye and cheap; force on completions that are
		// rare, throttle the rest.
		if !force && now.timeIntervalSince(lastRender) < 0.08 { return }
		lastRender = now

		let elapsed = now.timeIntervalSince(started)
		let fraction = total > 0 ? min(1.0, Double(done) / Double(total)) : 0
		let rate = elapsed > 0 ? Double(done) / elapsed : 0
		// A retry pass can push completions past the file count; never show a
		// negative or absurd remaining time.
		let remainingFiles = total > 0 ? max(0, total - done) : 0
		let eta = (rate > 0 && remainingFiles > 0) ? Double(remainingFiles) / rate : 0

		// `done` can exceed `total` when the engine runs a retry pass, so the
		// displayed counter is clamped -- a bar reading "52/40" is worse than one
		// that simply stops at the end.
		let shown = total > 0 ? min(done, total) : done
		let counters = "\(shown)/\(total)"
		let rateText = String(format: "%.1f/s", rate)
		let etaText = eta > 0 ? "ETA " + ProgressReporter.duration(eta) : ""
		let bytesText = bytesRate(landed: 0)
		let suffix = " \(counters)  \(rateText)  \(bytesText)  \(etaText) "
		let suffixWidth = suffix.count + 2

		let barWidth = max(10, min(40, width - suffixWidth))
		let filled = Int((Double(barWidth) * fraction).rounded())
		let bar = String(repeating: "█", count: filled)
			+ String(repeating: "░", count: barWidth - filled)

		// Colour only the bar: green when clean, red once anything has failed.
		let tint = failures > 0 ? "31" : "32"
		var line = paint(bar, tint) + suffix
		if line.count < width { line += String(repeating: " ", count: width - line.count) }
		write("\r" + line)
	}
}
