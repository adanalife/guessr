// swift-tools-version:6.2
import PackageDescription

// The app's half that needs no app: the public game API, the Twitch login, and
// the chat log's SwiftUI leaves. Foundation only outside one file guarded on
// SwiftUI, so it builds and tests anywhere Swift runs, Xcode or not.
let package = Package(
    name: "GuessrKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "GuessrKit", targets: ["GuessrKit"])],
    targets: [
        .target(name: "GuessrKit"),
        .testTarget(
            name: "GuessrKitTests",
            dependencies: ["GuessrKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
