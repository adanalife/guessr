// The web game's colors, title face and play button, shared by every app that
// draws in guessr's style, so the apps read as one family. Built in code rather than an asset catalog: the package
// also builds where no catalog compiler runs.
#if canImport(SwiftUI)
    import SwiftUI
    #if canImport(UIKit)
        import UIKit
    #else
        import AppKit
    #endif

    extension Color {
        /// The page: off-white in light mode, near-black in dark.
        public static let paper = adaptive(light: 0xFFFFF8, dark: 0x1A1A1A)
        /// The text: near-black in light mode, warm off-white in dark.
        public static let ink = adaptive(light: 0x111111, dark: 0xE8E6D8)
        /// Links and selection: a deep sky blue in light mode, a pale one in
        /// dark. The guessr app also carries it as its `AccentColor` asset.
        public static let accent = adaptive(light: 0x0369A1, dark: 0x7DD3FC)

        private static func adaptive(light: UInt32, dark: UInt32) -> Color {
            func rgb(_ hex: UInt32) -> (Double, Double, Double) {
                (Double(hex >> 16 & 0xFF) / 255, Double(hex >> 8 & 0xFF) / 255, Double(hex & 0xFF) / 255)
            }
            let (l, d) = (rgb(light), rgb(dark))
            #if canImport(UIKit)
                return Color(
                    uiColor: UIColor { traits in
                        let c = traits.userInterfaceStyle == .dark ? d : l
                        return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
                    })
            #else
                return Color(
                    nsColor: NSColor(name: nil) { appearance in
                        let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l
                        return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
                    })
            #endif
        }
    }

    extension View {
        /// The web game's play button: an ink fill under a paper label, the
        /// highest-contrast thing on screen in either theme. The accent is a text
        /// color, too light in dark mode to carry a white label.
        public func inkButton() -> some View { buttonStyle(InkButtonStyle()) }

        /// The web game's page color behind a screen, lists and forms included.
        public func paper() -> some View {
            #if os(tvOS)
                background(Color.paper)
            #else
                scrollContentBackground(.hidden).background(Color.paper)
            #endif
        }
    }

    /// An ink capsule under a paper label. Disabled, it is the same capsule at
    /// half strength rather than the system's grey, which vanishes on paper in
    /// light mode and on footage in either.
    private struct InkButtonStyle: ButtonStyle {
        @Environment(\.isEnabled) private var isEnabled

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.paper)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.ink.opacity(isEnabled ? 1 : 0.45), in: Capsule())
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }

    #if os(iOS)
        extension UINavigationBar {
            /// Sets every navigation title in the web's serif (ET Book there, New
            /// York here). SwiftUI has no modifier for a title's font, so it goes
            /// on the bar's appearance proxy, built from the text style so Dynamic
            /// Type still scales it. Call once, before the first bar is drawn.
            @MainActor public static func useSerifTitles() {
                let bar = appearance()
                bar.largeTitleTextAttributes = [.font: UIFont.serif(.largeTitle)]
                bar.titleTextAttributes = [.font: UIFont.serif(.headline)]
            }
        }

        extension UIFont {
            /// The text style's system font in New York, bold.
            fileprivate static func serif(_ style: TextStyle) -> UIFont {
                let base = preferredFont(forTextStyle: style).fontDescriptor
                let serif = base.withDesign(.serif)?.withSymbolicTraits(.traitBold) ?? base
                return UIFont(descriptor: serif, size: 0)
            }
        }
    #endif
#endif
