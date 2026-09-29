// The chat log's SwiftUI leaves: badge art and chips, emote art, the colors a
// line is drawn in, and a line's context menu. Each takes primitives rather
// than a chat line, so an app with a line type of its own draws with them too.
// Guarded so the rest of the package still builds where SwiftUI doesn't exist.
#if canImport(SwiftUI)
    import SwiftUI

    // The module resolves on tvOS and offers no presentation there, so the
    // import alone is not the capability check it is elsewhere.
    #if canImport(Translation) && !os(tvOS)
        import Translation
    #endif

    /// The chat badge icons, fetched once per launch and cached by the art's URL.
    ///
    /// One object for the whole app rather than per line: every line carries the
    /// same handful of badges, so a per-view cache would fetch the moderator icon
    /// once for each moderator who speaks.
    @MainActor @Observable public final class BadgeArt {
        public static let shared = BadgeArt()

        private var sets: BadgeSets = [:]
        private var images: [URL: Image] = [:]
        private var asked: Set<URL> = []
        private var loaded = false

        /// Reads the badge table from `source`, once. A failure leaves it
        /// unloaded, so the next visit to the chat log tries again — the text
        /// chips show meanwhile.
        public func load(from source: () async throws -> BadgeSets) async {
            guard !loaded, let sets = try? await source() else { return }
            loaded = true
            self.sets = sets
        }

        /// The icon for a badge, or nil while it is still arriving — or for a
        /// badge the platform publishes no art for, which is what the chip is
        /// still for.
        public func icon(_ tag: BadgeTag) -> Image? {
            guard let url = sets.url(for: tag) else { return nil }
            if let art = images[url] { return art }
            guard !asked.contains(url) else { return nil }
            asked.insert(url)
            Task { images[url] = await remoteImage(url, scale: 2) }
            return nil
        }
    }

    /// A badge as its own art when there is some for it, and as a text chip
    /// while the art is arriving or when there is none.
    public struct BadgeMark: View {
        public var tag: BadgeTag
        public init(tag: BadgeTag) { self.tag = tag }

        public var body: some View {
            if let icon = BadgeArt.shared.icon(tag) {
                icon.accessibilityLabel(tag.label)
            } else {
                ColorChip(tag.label, badgeColor(tag.label))
            }
        }
    }

    /// A word in a color: a chat badge, a status marker, a platform's initials.
    public struct ColorChip: View {
        public var text: String
        public var color: Color
        public init(_ text: String, _ color: Color) {
            self.text = text
            self.color = color
        }
        public var body: some View {
            Text(text)
                .font(.caption2.bold())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(color.opacity(0.2), in: Capsule())
                .foregroundStyle(color)
        }
    }

    /// Badge chips borrow the roles' usual colors; a badge the app has no
    /// opinion about gets the neutral chip.
    public func badgeColor(_ chip: String) -> Color {
        if chip == "mod" { return .green }
        if chip.hasPrefix("sub") { return .purple }
        return .secondary
    }

    /// A `#rrggbb` string as a `Color`.
    public func hexColor(_ hex: String) -> Color {
        let v = UInt64(hex.dropFirst(), radix: 16) ?? 0
        return Color(
            .sRGB,
            red: Double((v >> 16) & 0xff) / 255,
            green: Double((v >> 8) & 0xff) / 255,
            blue: Double(v & 0xff) / 255
        )
    }

    /// Twitch's emote art for an id. The 2.0 asset drawn at 2x lands at about a
    /// line of text, and the dark variant suits the chat log.
    public func emoteURL(_ id: String) -> URL? {
        URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/\(id)/default/dark/2.0")
    }

    // ponytail: URLSession's cache is the only cache.
    public func emoteImage(_ id: String) async -> Image? {
        guard let url = emoteURL(id) else { return nil }
        return await remoteImage(url, scale: 2)
    }

    /// Art off the network at a known scale — the chat log's emotes and its
    /// badges are both CDN assets drawn inline at about a line of text.
    public func remoteImage(_ url: URL, scale: CGFloat) async -> Image? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        #if os(macOS)
            guard let art = NSImage(data: data) else { return nil }
            art.size = NSSize(width: art.size.width / scale, height: art.size.height / scale)
            return Image(nsImage: art)
        #else
            guard let art = UIImage(data: data, scale: scale) else { return nil }
            return Image(uiImage: art)
        #endif
    }

    /// The timeout lengths the menu offers, Chatterino's short list.
    private let timeouts = [60, 600, 3600, 86400]

    /// A timeout's length as a mod reads it: `10 minutes`, `1 hour`.
    public func timeoutLength(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }

    /// A chat line's context menu: Translate for a line with words to read,
    /// then the moderation verbs a nil closure leaves out. `ban` takes the
    /// seconds, 0 for good; the ban asks first, the one verb that doesn't undo
    /// itself. Delete comes first: it answers what was said rather than who
    /// said it. tvOS has no context menus, so there it draws the line bare.
    public struct ChatLineMenu: ViewModifier {
        var translatable: String?
        var name: String
        var delete: (() -> Void)?
        var ban: ((Int) -> Void)?
        var reply: (() -> Void)?
        /// Whether the system translation sheet is up for this line.
        @State private var translating = false
        @State private var banning = false

        /// `translatable` is the text the Translate item offers, nil for none;
        /// `name` is who the ban confirmation names; `reply`, when given,
        /// heads the menu.
        public init(
            translatable: String?, name: String, delete: (() -> Void)?, ban: ((Int) -> Void)?,
            reply: (() -> Void)? = nil
        ) {
            self.translatable = translatable
            self.name = name
            self.delete = delete
            self.ban = ban
            self.reply = reply
        }

        public func body(content: Content) -> some View {
            #if os(tvOS)
                content
            #else
                // Viewers chat in several languages. The system sheet translates
                // on device, picking the source language itself, and asks to
                // download a language pack the first time it meets one.
                // ponytail: the sheet is the ceiling — a TranslationSession
                // rendering every line inline is the upgrade if reading one at a
                // time palls.
                content
                    .contextMenu {
                        if let reply {
                            Button("Reply", systemImage: "arrowshape.turn.up.left", action: reply)
                        }
                        #if canImport(Translation)
                            if translatable != nil {
                                Button("Translate", systemImage: "translate") { translating = true }
                            }
                        #endif
                        if let delete {
                            Button("Delete message", systemImage: "trash", role: .destructive, action: delete)
                        }
                        if let ban {
                            Menu("Time out", systemImage: "clock.badge.xmark") {
                                ForEach(timeouts, id: \.self) { seconds in
                                    Button(timeoutLength(seconds)) { ban(seconds) }
                                }
                            }
                            Button("Ban", systemImage: "nosign", role: .destructive) { banning = true }
                        }
                    }
                    .confirmationDialog(
                        "Ban \(name) from the channel?", isPresented: $banning, titleVisibility: .visible
                    ) {
                        Button("Ban", role: .destructive) { ban?(0) }
                    }
                    #if canImport(Translation)
                        .translationPresentation(isPresented: $translating, text: translatable ?? "")
                    #endif
            #endif
        }
    }
#endif
