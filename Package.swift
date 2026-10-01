// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Spotlit",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "Spotlit", path: "Sources/Spotlit")]
)
