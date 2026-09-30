// The Twitch device-code login's rows, shared by every app that signs in with
// GuessrKit's `TwitchAuth`, so the login reads the same way in each.
#if canImport(SwiftUI) && !os(tvOS)
    import SwiftUI
    #if canImport(UIKit)
        import UIKit
    #else
        import AppKit
    #endif

    /// A device code waiting on the human. The first time a code is shown, its
    /// Twitch page opens by itself — the press that asked for the code was the
    /// press to go to Twitch — so what is left here is for the way back: the
    /// code to copy and a button back to the page.
    ///
    /// Nothing spins. The app is waiting on the human, not the other way round.
    public struct TwitchCodeRows: View {
        let code: DeviceCode
        /// The label color on the prominent button, to pair with the fill an
        /// app sets through `.tint`.
        let prominentLabel: Color
        @Environment(\.openURL) private var openURL
        @State private var copied = false

        /// The codes whose page has opened already. A code shows in more than
        /// one place and each appearance is a new view, so a view's own state
        /// would send the human back to Twitch every time they came back.
        private static var opened: Set<String> = []

        public init(code: DeviceCode, prominentLabel: Color = .white) {
            self.code = code
            self.prominentLabel = prominentLabel
        }

        public var body: some View {
            HStack(spacing: 12) {
                Text(code.userCode)
                    .font(.title2.monospaced().bold())
                    .textSelection(.enabled)
                Button {
                    copy(code.userCode)
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(copied)
            }
            if let url = URL(string: code.verificationUri) {
                Link(destination: url) { Label("Go to Twitch", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(prominentLabel)
                    .onAppear {
                        if Self.opened.insert(code.deviceCode).inserted { openURL(url) }
                    }
            }
        }

        private func copy(_ string: String) {
            #if canImport(UIKit)
                UIPasteboard.general.string = string
            #else
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(string, forType: .string)
            #endif
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
    }
#endif
