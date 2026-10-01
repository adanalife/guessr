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

    /// What a warning says when the mod typed nothing: Twitch insists on a
    /// reason, and the viewer has to read one to chat again.
    public var defaultWarning: String { String(localized: "Please keep to the chat rules", bundle: .module) }

    /// A chat line's context menu: Translate for a line with words to read,
    /// then the moderation verbs a nil closure leaves out. `ban` takes the
    /// seconds, 0 for good, and the reason the mod typed, nil for none: a
    /// length from the submenu is one tap with no reason, the submenu's last
    /// item and the ban itself ask in an alert, where the reason is optional.
    /// The ban always asks first, the one verb that doesn't undo itself.
    /// `warn` takes the reason, asked for in an alert. Delete comes first: it
    /// answers what was said rather than who said it. tvOS has no context
    /// menus, so there it draws the line bare.
    public struct ChatLineMenu: ViewModifier {
        var translatable: String?
        var name: String
        var delete: (() -> Void)?
        var ban: ((Int, String?) -> Void)?
        var reply: (() -> Void)?
        var warn: ((String) -> Void)?
        /// Whether the system translation sheet is up for this line.
        @State private var translating = false
        @State private var banning = false
        @State private var timingOut = false
        @State private var warning = false
        @State private var reason = ""

        /// `translatable` is the text the Translate item offers, nil for none;
        /// `name` is who the ban confirmation names; `reply`, when given,
        /// heads the menu.
        public init(
            translatable: String?, name: String, delete: (() -> Void)?, ban: ((Int, String?) -> Void)?,
            reply: (() -> Void)? = nil, warn: ((String) -> Void)? = nil
        ) {
            self.translatable = translatable
            self.name = name
            self.delete = delete
            self.ban = ban
            self.reply = reply
            self.warn = warn
        }

        /// The typed reason, nil when the field was left blank.
        private var why: String? { reason.isEmpty ? nil : reason }

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
                            Button(String(localized: "Reply", bundle: .module), systemImage: "arrowshape.turn.up.left", action: reply)
                        }
                        #if canImport(Translation)
                            if translatable != nil {
                                Button(String(localized: "Translate", bundle: .module), systemImage: "translate") { translating = true }
                            }
                        #endif
                        if let delete {
                            Button(String(localized: "Delete message", bundle: .module), systemImage: "trash", role: .destructive, action: delete)
                        }
                        if warn != nil {
                            Button(String(localized: "Warn", bundle: .module), systemImage: "exclamationmark.bubble") { warning = true }
                        }
                        if let ban {
                            Menu(String(localized: "Time out", bundle: .module), systemImage: "clock.badge.xmark") {
                                ForEach(timeouts, id: \.self) { seconds in
                                    Button(timeoutLength(seconds)) { ban(seconds, nil) }
                                }
                                Divider()
                                Button(String(localized: "With a reason…", bundle: .module), systemImage: "text.bubble") {
                                    reason = ""
                                    timingOut = true
                                }
                            }
                            Button(String(localized: "Ban", bundle: .module), systemImage: "nosign", role: .destructive) {
                                reason = ""
                                banning = true
                            }
                        }
                    }
                    .alert(String(localized: "Ban \(name) from the channel?", bundle: .module), isPresented: $banning) {
                        TextField(String(localized: "Reason (optional)", bundle: .module), text: $reason)
                        Button(String(localized: "Ban", bundle: .module), role: .destructive) { ban?(0, why) }
                        Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
                    } message: {
                        Text("Other mods see the reason, and so do they.", bundle: .module)
                    }
                    .alert(String(localized: "Time out \(name)", bundle: .module), isPresented: $timingOut) {
                        TextField(String(localized: "Reason (optional)", bundle: .module), text: $reason)
                        ForEach(timeouts, id: \.self) { seconds in
                            Button(timeoutLength(seconds)) { ban?(seconds, why) }
                        }
                        Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
                    }
                    .alert(String(localized: "Warn \(name)", bundle: .module), isPresented: $warning) {
                        TextField(String(localized: "Reason", bundle: .module), text: $reason)
                        Button(String(localized: "Warn", bundle: .module)) { warn?(reason.isEmpty ? defaultWarning : reason) }
                        Button(String(localized: "Cancel", bundle: .module), role: .cancel) {}
                    } message: {
                        Text("They can't chat again until they've read it.", bundle: .module)
                    }
                    #if canImport(Translation)
                        .translationPresentation(isPresented: $translating, text: translatable ?? "")
                    #endif
            #endif
        }
    }

    /// A chatter's card, from a tap on their line: avatar, how long they have
    /// been on Twitch, and what they have said in this session. `recent` is
    /// their lines' text from the log, oldest first — the ring, not an API, so
    /// it is only what this device saw. `load` reads the profile; until it
    /// answers, or if it fails, the card shows the name it was opened with.
    public struct UserCard: View {
        var displayName: String
        var login: String
        var recent: [String]
        var load: () async -> TwitchUser?
        @State private var user: TwitchUser?
        @State private var avatar: Image?

        public init(displayName: String, login: String, recent: [String], load: @escaping () async -> TwitchUser?) {
            self.displayName = displayName
            self.login = login
            self.recent = recent
            self.load = load
        }

        public var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    (avatar ?? Image(systemName: "person.crop.circle.fill"))
                        .resizable()
                        .scaledToFill()
                        .foregroundStyle(.secondary)
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user?.displayName ?? displayName).font(.headline)
                        if let user {
                            Text("On Twitch since \(user.createdAt.formatted(.dateTime.month(.wide).year()))", bundle: .module)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let url = URL(string: "https://www.twitch.tv/\(login)") {
                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                            .accessibilityLabel(String(localized: "Open \(displayName) on Twitch", bundle: .module))
                    }
                }
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recent messages", bundle: .module).font(.caption.bold()).foregroundStyle(.secondary)
                        // ponytail: the last five; a scrolling list if a
                        // chatty viewer's card needs the whole session.
                        ForEach(Array(recent.suffix(5).enumerated()), id: \.offset) { _, text in
                            Text(text).font(.subheadline).lineLimit(3)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .task {
                user = await load()
                if let url = user?.profileImage { avatar = await remoteImage(url, scale: 1) }
            }
        }
    }
#endif
