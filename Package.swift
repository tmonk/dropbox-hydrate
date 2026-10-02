// swift-tools-version:5.9
import PackageDescription

let package = Package(
	name: "dbhydrate",
	platforms: [.macOS(.v13)],
	products: [
		.executable(name: "dbhydrate", targets: ["dbhydrate"]),
		.library(name: "DBHydrateCore", targets: ["DBHydrateCore"]),
	],
	targets: [
		.target(name: "DBHydrateCore"),
		.executableTarget(name: "dbhydrate", dependencies: ["DBHydrateCore"]),
	]
)
