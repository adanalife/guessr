// The web game's page and text colors, shared by every app that draws in
// guessr's style. Built in code rather than an asset catalog: the package
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
        /// The web game's page color behind a screen, lists and forms included.
        public func paper() -> some View {
            scrollContentBackground(.hidden).background(Color.paper)
        }
    }
#endif
