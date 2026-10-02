import DBHydrateCore
import Foundation

typealias Reporter = DBHydrateCore.ProgressReporter
func stderr(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
func fail(_ message: String) -> Never { stderr("dbhydrate: " + message); exit(2) }
func fileURL(_ path: String) -> URL {
	URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}
func usage() -> String {
	"""
	dbhydrate (beta)

	usage: dbhydrate [hydrate] [options] <path>...
	       dbhydrate evict --sandbox <dir> [--dry-run | --yes] [options] <path>...
	       dbhydrate evict --sandbox <dir> --undo <manifest> [--dry-run]

	hydrate options:
	  -c, --concurrency N   active files (1...64, default 8)
	  -t, --ceiling SEC     total wait per file across retries (default 60)
	      --stall-grace SEC stop after no observed recall progress (default 30)
	      --max-passes N    bounded retry passes (1...100, default 3)
	      --max-reissues N  extra event-triggered requests per file (0...100, default 3)
	  -n, --dry-run         scan and report; request nothing
	      --stats <path>    create a new JSON report (implies --quiet)
	      --allow-outside-dropbox
	                        allow paths outside the configured Dropbox root
	  -x, --explain         explain the recall mechanism

	evict options:
	      --sandbox <dir>   required boundary, including for undo
	      --manifest <path> create a new metadata journal outside the sandbox
	      --undo <manifest> recall and verify journal entries; no content backups
	  -n, --dry-run         preview eviction (default) or undo
	  -y, --yes             remove local bytes; attrs do not prove upload completion
	                        undo depends on Dropbox still having the exact bytes

	common options:
	  -q, --quiet           summary only; diagnostics still go to stderr
	  -v, --verbose         per-file output
	      --progress MODE   auto (default), bar, plain or silent
	      --no-progress     silence progress
	      --                end options; remaining arguments are paths
	  -h, --help            show this message

	exit status: 0 success, 1 incomplete/refused, 2 usage/output error, 130 interrupted
	time options must be finite, positive, and at most 86400 seconds.
	"""
}

Cancellation.installSignalHandlers()
enum Mode { case hydrate, evict }
var mode = Mode.hydrate
var argv = Array(CommandLine.arguments.dropFirst())
if let first = argv.first, first == "hydrate" || first == "evict" {
	mode = first == "evict" ? .evict : .hydrate; argv.removeFirst()
}
var paths: [String] = [], concurrency = 8, maxPasses = 3, maxReissues = 3
var ceiling = 60.0, stallGrace = 30.0
var progressStyle = "auto", noProgress = false, quiet = false, verbose = false
var dryRun = false, confirmed = false, explain = false, allowOutside = false
var statsPath: String?, sandboxArg: String?, manifestArg: String?, undoPath: String?
var i = 0
while i < argv.count {
	let arg = argv[i]
	func nextValue() -> String {
		i += 1; guard i < argv.count else { fail("\(arg) requires a value") }; return argv[i]
	}
	func number(_ value: String) -> Double {
		guard let value = Double(value), value.isFinite, value > 0, value <= 86400 else {
			fail("\(arg) must be a finite positive number at most 86400")
		}
		return value
	}
	func integer(_ value: String, range: ClosedRange<Int>) -> Int {
		guard let value = Int(value), range.contains(value) else {
			fail("\(arg) must be an integer in \(range.lowerBound)...\(range.upperBound)")
		}
		return value
	}
	switch arg {
	case "-h", "--help": print(usage()); exit(0)
	case "--": paths += argv.dropFirst(i + 1); i = argv.count; continue
	case "-c", "--concurrency": concurrency = integer(nextValue(), range: 1...64)
	case "-t", "--ceiling": ceiling = number(nextValue())
	case "--stall-grace": stallGrace = number(nextValue())
	case "--max-passes": maxPasses = integer(nextValue(), range: 1...100)
	case "--max-reissues": maxReissues = integer(nextValue(), range: 0...100)
	case "--stats": statsPath = nextValue(); quiet = true
	case "--progress":
		progressStyle = nextValue()
		guard Reporter.Style(rawValue: progressStyle) != nil else { fail("invalid progress mode") }
	case "--no-progress": noProgress = true
	case "-q", "--quiet": quiet = true
	case "-v", "--verbose": verbose = true
	case "-n", "--dry-run": dryRun = true
	case "-y", "--yes": confirmed = true
	case "-x", "--explain": explain = true
	case "--sandbox": sandboxArg = nextValue()
	case "--manifest": manifestArg = nextValue()
	case "--undo": undoPath = nextValue()
	case "--backup-dir": fail("content backups are not supported; undo recalls from Dropbox using metadata only")
	case "--allow-outside-dropbox": allowOutside = true
	default:
		if arg.hasPrefix("-") { fail("unknown option \(arg); use -- before paths starting with '-'") }
		paths.append(arg)
	}
	i += 1
}
if explain {
	print("""
	Detect regular legacy Dropbox files carrying com.dropbox.placeholder.
	Publish read intent with NSFileCoordinator.coordinate(readingItemAt:options:).
	Wait on FSEvents, armed before requests; recheck pending files on dropped events.
	A fixed worker pool bounds active files; a separate finite pool bounds native claims.
	The ceiling is shared across retry passes. Cancellation wakes waiting workers.
	The hydrate operation does not modify content or launch applications. Dropbox
	performs the download. Issued native claims can outlive a timeout or cancellation.
	""")
	exit(0)
}
if mode == .hydrate && (sandboxArg != nil || manifestArg != nil || undoPath != nil || confirmed) {
	fail("eviction options require the evict subcommand")
}
if mode == .evict && statsPath != nil { fail("--stats is a hydrate option") }
if paths.isEmpty && !(mode == .evict && undoPath != nil) { print(usage()); exit(2) }
if undoPath != nil && (!paths.isEmpty || manifestArg != nil || confirmed) {
	fail("--undo takes its targets from the manifest; do not combine it with paths, --manifest or --yes")
}
let roots = paths.map(fileURL)
let engine = RecallEngine(ceiling: ceiling, concurrency: concurrency, maxPasses: maxPasses,
                          maxReissues: maxReissues, stallGrace: stallGrace,
                          allowOutsideDropbox: allowOutside,
                          log: { if verbose && !quiet { stderr($0) } })

if mode == .evict {
	guard let sandboxArg else { fail("evict requires --sandbox <dir>") }
	let sandbox = fileURL(sandboxArg)
	let evictor = Evictor(sandboxRoot: sandbox,
	                     dryRun: dryRun || (!confirmed && undoPath == nil), confirmed: confirmed)
	if let undoPath {
		do {
			let manifest = try UndoManifest.read(from: fileURL(undoPath))
			let report = evictor.undo(manifest: manifest, engine: engine)
			if dryRun { print("would recall \(report.wouldRecall.count) file(s) from the journal") }
			else { print("verified \(report.restored.count)  still-placeholder \(report.needRecall.count)  failed \(report.failures.count)") }
			for (path, reason) in report.failures.prefix(20) { stderr("failed: \(path): \(reason)") }
			if let diagnosis = report.diagnosis { stderr("DIAGNOSIS: " + diagnosis) }
			if !report.needRecall.isEmpty {
				stderr("Remaining placeholders were not recalled. Keep the metadata journal, inspect diagnostics and retry --undo later.")
			}
			if let cancelled = report.cancelled { stderr(cancelled); exit(130) }
			if Cancellation.shared.isCancelled { stderr("cancelled by \(Cancellation.shared.cause)"); exit(130) }
			exit(report.ok ? 0 : 1)
		} catch { fail("cannot read undo manifest: \(error)") }
	}
	// Gate before walking; fail on traversal errors before starting eviction.
	let allowed = roots.filter { Evictor.isWithin(sandbox: sandbox, path: $0) }
	let outside = roots.filter { !Evictor.isWithin(sandbox: sandbox, path: $0) }
	for root in outside { stderr("refused: \(root.path) is outside the sandbox") }
	if allowed.isEmpty { exit(1) }
	let expansion = Evictor.expandChecked(allowed)
	if !expansion.errors.isEmpty {
		for error in expansion.errors.prefix(20) { stderr("error: " + error) }
		exit(Cancellation.shared.isCancelled ? 130 : 1)
	}
	if Cancellation.shared.isCancelled { stderr("cancelled during scan"); exit(130) }
	do {
		let destination: URL
		if let manifestArg { destination = fileURL(manifestArg) }
		else if evictor.dryRun { destination = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("unused.jsonl") }
		else {
			let directory = URL(fileURLWithPath: NSHomeDirectory())
				.appendingPathComponent("Library/Application Support/dbhydrate/evictions")
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
			                                        attributes: [.posixPermissions: 0o700])
			destination = directory.appendingPathComponent("\(UUID().uuidString).jsonl")
		}
		let report = try evictor.evict(paths: expansion.paths, manifestURL: destination)
		if let path = report.manifestPath { print("undo journal: \(path) (metadata only)") }
		let verb = evictor.dryRun ? "would evict" : "evicted"
		print("\(verb) \(report.wouldEvict + report.evicted) file(s), \(report.bytes) bytes; skipped \(report.skipped), refused \(report.refusals.count + outside.count)")
		if verbose && !quiet {
			for outcome in report.outcomes.prefix(20) { print("  \(outcome.status)  \(outcome.bytes) bytes  \(outcome.path.path)  \(outcome.note)") }
		}
		for refusal in report.refusals.prefix(20) { stderr("refused: " + refusal) }
		if let cancelled = report.cancelled {
			stderr("\(cancelled): evicted \(report.evicted), left \(report.untouched.count) unprocessed. Keep the metadata journal.")
			exit(130)
		}
		exit(report.ok && outside.isEmpty ? 0 : 1)
	} catch { fail("\(error)") }
}

// Reserve new statistics output before making recall requests.
let statsOutput: NewStatisticsFile?
do { statsOutput = try statsPath.map { try NewStatisticsFile(url: fileURL($0)) } }
catch { fail("could not create stats output: \(error)") }
let reporter = Reporter(style: (noProgress || quiet) ? .silent : Reporter.Style(rawValue: progressStyle)!)
engine.collectStats = statsPath != nil
engine.onPlan = { reporter.begin(totalFiles: $0) }
engine.onFileResult = { url, size, ok in
	if verbose && !quiet { stderr("[\(ok ? "ok" : "INCOMPLETE")] \(size) bytes  \(url.path)") }
	reporter.completed(path: url, bytes: Int64(size), ok: ok)
}
let report = dryRun ? engine.plan(roots: roots).report : engine.hydrate(roots: roots)
reporter.finish()
if let statsOutput {
	do {
		struct Statistics: Encodable {
			let scanned: Int, placeholders: Int, hydrated: Int, alreadyLocal: Int
			let timedOut: [String], errors: [String], refusals: [String]
			let elapsed: Double, concurrency: Int, ceiling: Double, maxPasses: Int, maxReissues: Int
			let diagnosis: String?
			let stats: RunStats
		}
		let payload = Statistics(scanned: report.scanned, placeholders: report.placeholders,
		                         hydrated: report.hydrated, alreadyLocal: report.alreadyLocal,
		                         timedOut: report.timedOut.map(\.path),
		                         errors: report.errors.map { "\($0.url.path): \($0.message)" },
		                         refusals: report.refusals, elapsed: report.elapsed,
		                         concurrency: concurrency, ceiling: ceiling, maxPasses: maxPasses,
		                         maxReissues: maxReissues, diagnosis: report.diagnosis,
		                         stats: report.stats)
		let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		try statsOutput.write(encoder.encode(payload))
	} catch { fail("could not write stats: \(error)") }
}
if dryRun { print("would recall \(report.placeholders) placeholder file(s)") }
else { print(report.summary) }
for (url, message) in report.errors.prefix(20) { stderr("error: \(url.path): \(message)") }
for refusal in report.refusals.prefix(20) { stderr("refused: " + refusal) }
if let diagnosis = report.diagnosis { stderr("DIAGNOSIS: " + diagnosis) }
if Cancellation.shared.isCancelled { exit(130) }
exit(report.ok ? 0 : 1)
