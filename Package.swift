// swift-tools-version:6.2
import PackageDescription

// GuessrKit, reachable by this repo's git URL. SwiftPM only reads a manifest at
// the repository root, so another app (tempomat) depending on
// `https://github.com/adanalife/guessr` lands here; the sources stay under
// app/GuessrKit, whose own manifest is what the app and CI build against.
// A target added there goes here too.
let package = Package(
    name: "Guessr",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "GuessrKit", targets: ["GuessrKit"])],
    targets: [
        .target(name: "GuessrKit", path: "app/GuessrKit/Sources/GuessrKit"),
        .testTarget(
            name: "GuessrKitTests",
            dependencies: ["GuessrKit"],
            path: "app/GuessrKit/Tests/GuessrKitTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
