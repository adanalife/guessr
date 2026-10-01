// swift-tools-version:6.2
import PackageDescription

// The app's half that needs no app: the public game API, the Twitch login, and
// the chat log's SwiftUI leaves. Foundation only outside one file guarded on
// SwiftUI, so it builds and tests anywhere Swift runs, Xcode or not. Its
// user-facing strings read from the package's own string catalog, so an app
// that links it gets them in every language the catalog carries.
let package = Package(
    name: "GuessrKit",
    defaultLocalization: "en",
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
