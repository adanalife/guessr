import GuessrKit
import SwiftUI
import Translation

/// The channel's Twitch chat: the sign-in until there is a login, then the log
/// and the composer.
struct ChatTab: View {
    @Environment(Account.self) private var account

    var body: some View {
        NavigationStack {
            Group {
                if let session = account.session {
                    VStack(spacing: 0) {
                        // The mod's second login, asked for the moment Twitch
                        // names them a mod — Chat is where it's needed.
                        if let code = account.modCode {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Log in again to moderate chat").font(.subheadline.bold())
                                DeviceCodeRows(code: code)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(.thinMaterial)
                        }
                        ChatLog(
                            lines: account.chat?.lines ?? [],
                            mayModerate: account.moderates && session.canModerate)
                    }
                    .task(id: session.userID) { await account.openChat() }
                } else {
                    Form {
                        Section {
                            Text("Chat is for signed-in Twitch viewers: sign in to read and talk in \(account.channel).")
                            TwitchSignIn()
                        }
                    }
                }
            }
            .navigationTitle("Chat")
        }
    }
}

/// The log and the composer. Lines come in as a value so a preview can draw
/// them without a live chat; sending and moderating go through the account's.
struct ChatLog: View {
    @Environment(Account.self) private var account
    var lines: [ChatLine]
    var mayModerate: Bool
    @State private var text = ""
    /// Whether the log tracks the newest line. Only a gesture turns it off —
    /// content growing under a reader who hasn't moved keeps them following.
    @State private var following = true
    @State private var hasNew = false
    /// The last send or moderation Twitch refused, until the next one.
    @State private var error: String?
    /// Whether the composer holds the keyboard. The log sits behind the
    /// keyboard while it does, so there has to be a way to give it back.
    @FocusState private var composing: Bool
    /// The channel's emotes and Twitch's, for the picker; empty until read.
    @State private var emotes: [ChatEmote] = []
    @State private var pickingEmote = false

    var body: some View {
        VStack(spacing: 0) {
            log
            if let status = error ?? account.chat?.lastError {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            if let stub = mentionInProgress(text) { mentions(matching: stub) }
            composer
            if pickingEmote { emotePicker }
        }
        .toolbar {
            // A short log has nothing to drag, so the drag-to-dismiss needs a
            // button beside it.
            ToolbarItem(placement: .keyboard) {
                Button("Done") { composing = false }
            }
        }
        // Keyed on the chat, which arrives after the first appearance.
        .task(id: account.chat.map(ObjectIdentifier.init)) { await loadArt() }
    }

    private func loadArt() async {
        guard let chat = account.chat else { return }
        await BadgeArt.shared.load(from: chat)
        if emotes.isEmpty { emotes = (try? await chat.emotes()) ?? [] }
    }

    /// Who has spoken, newest first, once each.
    private var chatters: [ChatLine] {
        var seen: Set<String> = []
        return lines.reversed().filter { seen.insert($0.login).inserted }
    }

    /// The chatters whose name starts with what has been typed after the `@`;
    /// a tap finishes the word.
    private func mentions(matching stub: String) -> some View {
        let needle = stub.lowercased()
        let hits = chatters.filter {
            $0.login.hasPrefix(needle) || $0.displayName.lowercased().hasPrefix(needle)
        }.prefix(8)
        return ScrollView(.horizontal) {
            HStack {
                ForEach(hits) { line in
                    Button("@\(line.displayName)") { text = completingLastWord(text, with: "@\(line.displayName)") }
                        .buttonStyle(.bordered)
                        .font(.caption)
                }
            }
            .padding(.horizontal)
        }
        .scrollIndicators(.hidden)
    }

    /// The emotes as a grid of their art; a tap types the name.
    private var emotePicker: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 36))], spacing: 8) {
                ForEach(emotes) { emote in
                    Button {
                        let head = text.isEmpty || text.hasSuffix(" ") ? text : text + " "
                        text = head + emote.name + " "
                    } label: {
                        AsyncImage(url: emoteURL(emote.id)) { $0.resizable().scaledToFit() } placeholder: {
                            Text(emote.name).font(.caption2).lineLimit(1).minimumScaleFactor(0.5)
                        }
                        .frame(width: 32, height: 32)
                    }
                    .accessibilityLabel(emote.name)
                }
            }
            .padding()
        }
        .frame(height: 180)
        .background(.thinMaterial)
    }

    private var log: some View {
        ScrollViewReader { proxy in
            List(lines) { line in
                ChatLineView(line: line, mayModerate: mayModerate, error: $error)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onScrollPhaseChange { _, phase, context in
                guard phase == .interacting || phase == .idle else { return }
                following = atBottom(context.geometry)
                if following { hasNew = false }
            }
            // The newest id rather than the count: a full ring stays the same
            // length as lines arrive.
            .onChange(of: lines.last?.id) {
                if following { scroll(proxy) } else { hasNew = true }
            }
            .safeAreaInset(edge: .bottom) {
                // An inset rather than an overlay, so the pill never sits on
                // top of the newest line it is announcing.
                if hasNew {
                    Button {
                        scroll(proxy)
                        following = true
                        hasNew = false
                    } label: {
                        Label("new", systemImage: "arrow.down")
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 4)
                }
            }
        }
    }

    private func atBottom(_ geo: ScrollGeometry) -> Bool {
        geo.contentOffset.y + geo.containerSize.height
            >= geo.contentSize.height + geo.contentInsets.bottom - 40
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let last = lines.last?.id else { return }
        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
    }

    private var composer: some View {
        HStack {
            Button { pickingEmote.toggle() } label: { Image(systemName: pickingEmote ? "keyboard" : "face.smiling") }
                .accessibilityLabel(pickingEmote ? "Hide emotes" : "Emotes")
                .disabled(emotes.isEmpty)
            TextField("Say something as \(account.session?.login ?? "you")", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($composing)
                .onSubmit(send)
            Button(action: send) { Image(systemName: "paperplane.fill") }
                .accessibilityLabel("Send")
                .disabled(account.chat == nil || text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
    }

    private func send() {
        let msg = text.trimmingCharacters(in: .whitespaces)
        guard !msg.isEmpty, let chat = account.chat else { return }
        text = ""
        pickingEmote = false
        Task {
            await account.refreshIfNeeded()
            do {
                try await chat.send(msg)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct ChatLineView: View {
    @Environment(Account.self) private var account
    var line: ChatLine
    var mayModerate: Bool
    @Binding var error: String?
    /// Whether the system translation sheet is up for this line.
    @State private var translating = false
    /// Whether the ban confirmation is up — the one moderation verb that
    /// doesn't undo itself.
    @State private var banning = false
    /// Emote art that has arrived, by the id Twitch named it with.
    @State private var emotes: [String: Image] = [:]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                ForEach(line.badgeTags) { BadgeMark(tag: $0) }
                Text("\(username): \(words)")
                    .font(.subheadline)
            }
            .task(id: line.id) { await loadEmotes() }
            Spacer(minLength: 4)
            Text(shortAge(line.timestamp))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        // Viewers chat in several languages. The system sheet translates on
        // device, picking the source language itself, and asks to download a
        // language pack the first time it meets one.
        // ponytail: the sheet is the ceiling — a TranslationSession rendering
        // every line inline is the upgrade if reading one at a time palls.
        .contextMenu {
            if !line.text.isEmpty { Button("Translate", systemImage: "translate") { translating = true } }
            if mayModerate { moderation }
        }
        .confirmationDialog(
            "Ban \(line.displayName) from the channel?", isPresented: $banning, titleVisibility: .visible
        ) {
            Button("Ban", role: .destructive) { moderate { try await $0.ban(userId: line.userId, seconds: 0) } }
        }
        .translationPresentation(isPresented: $translating, text: line.text)
    }

    /// Delete first: it answers what was said rather than who said it.
    @ViewBuilder private var moderation: some View {
        Button("Delete message", systemImage: "trash", role: .destructive) {
            moderate { try await $0.delete(messageId: line.id) }
        }
        Button("Time out 10 minutes", systemImage: "clock.badge.xmark") {
            moderate { try await $0.ban(userId: line.userId, seconds: 600) }
        }
        Button("Ban", systemImage: "nosign", role: .destructive) { banning = true }
    }

    /// Runs a moderation verb on a fresh token. Twitch checks the mod's
    /// standing again, and says so when it refuses.
    private func moderate(_ verb: @escaping (TwitchChat) async throws -> Void) {
        guard let chat = account.chat else { return }
        Task {
            await account.refreshIfNeeded()
            do {
                try await verb(chat)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// The sender's name in their Twitch colour, or the palette's for one who
    /// never picked. A bot reads muted.
    private var username: Text {
        Text(line.displayName).bold().foregroundStyle(line.colorHex.map(hexColor) ?? .secondary)
    }

    /// The words, with any emote whose art has arrived drawn in place of its
    /// name. Until then — and if the fetch fails — the name shows, which is
    /// what the chatter typed.
    private var words: Text {
        line.fragments.reduce(Text("")) { text, fragment in
            if case .emote(let id, _) = fragment, let art = emotes[id] { return Text("\(text)\(art)") }
            return Text("\(text)\(fragment.text)")
        }
    }

    private func loadEmotes() async {
        for case .emote(let id, _) in line.fragments where emotes[id] == nil {
            if let art = await emoteImage(id) { emotes[id] = art }
        }
    }
}

/// Twitch's emote art for an id. The 2.0 asset drawn at 2x lands at about a
/// line of text, and the dark variant suits the chat log.
private func emoteURL(_ id: String) -> URL? {
    URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/\(id)/default/dark/2.0")
}

// ponytail: URLSession's cache is the only cache.
private func emoteImage(_ id: String) async -> Image? {
    guard let url = emoteURL(id) else { return nil }
    return await remoteImage(url, scale: 2)
}

/// Art off the network at a known scale — the log's emotes and its badges are
/// both CDN assets drawn inline at about a line of text.
func remoteImage(_ url: URL, scale: CGFloat) async -> Image? {
    guard let (data, _) = try? await URLSession.shared.data(from: url),
        let art = UIImage(data: data, scale: scale)
    else { return nil }
    return Image(uiImage: art)
}

/// A badge as its own art when Twitch publishes some for it, and as a text
/// chip while the art is arriving or when there is none.
private struct BadgeMark: View {
    var tag: BadgeTag

    var body: some View {
        if let icon = BadgeArt.shared.icon(tag) {
            icon.accessibilityLabel(tag.label)
        } else {
            Chip(tag.label, badgeColor(tag.label))
        }
    }
}

/// Badge chips borrow the roles' usual colours; a badge this app has no opinion
/// about gets the neutral chip.
private func badgeColor(_ chip: String) -> Color {
    if chip == "mod" { return .green }
    if chip.hasPrefix("sub") { return .purple }
    return .secondary
}

/// A word in a colour.
private struct Chip: View {
    var text: String
    var color: Color
    init(_ text: String, _ color: Color) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }
}

/// A `#rrggbb` string as a `Color`.
private func hexColor(_ hex: String) -> Color {
    let v = UInt64(hex.dropFirst(), radix: 16) ?? 0
    return Color(
        .sRGB,
        red: Double((v >> 16) & 0xff) / 255,
        green: Double((v >> 8) & 0xff) / 255,
        blue: Double(v & 0xff) / 255
    )
}

/// How long ago, in its coarsest unit — `12s`, `45m`, `2h`, `3d`.
// ponytail: drawn when the line is, so it ages only as new lines redraw the
// log; a TimelineView if a quiet chat's ages need to tick.
private func shortAge(_ then: Date, now: Date = .now) -> String {
    let s = max(Int(now.timeIntervalSince(then)), 0)
    switch s {
    case ..<60: return "\(s)s"
    case ..<3600: return "\(s / 60)m"
    case ..<86400: return "\(s / 3600)h"
    default: return "\(s / 86400)d"
    }
}

#Preview {
    let now = Date.now
    NavigationStack {
        ChatLog(
            lines: [
                ChatLine(
                    id: "1", userId: "10", login: "mathgaming", displayName: "mathgaming", text: "morning from the van",
                    badges: ["moderator": "1", "subscriber": "3012"], timestamp: now.addingTimeInterval(-300)),
                ChatLine(
                    id: "2", userId: "11", login: "roadwatcher", displayName: "RoadWatcher", text: "where is this?",
                    color: "#1E90FF", timestamp: now.addingTimeInterval(-95)),
                ChatLine(
                    id: "3", userId: "12", login: "nightbot", displayName: "Nightbot",
                    text: "Guess today's rounds at guessr.dana.lol", color: "#8A2BE2",
                    badges: ["moderator": "1"], timestamp: now.addingTimeInterval(-40)),
                ChatLine(
                    id: "4", userId: "11", login: "roadwatcher", displayName: "RoadWatcher", text: "looks like Utah Kappa",
                    color: "#1E90FF",
                    fragments: [.text("looks like Utah "), .emote(id: "25", text: "Kappa")],
                    timestamp: now.addingTimeInterval(-5)),
            ],
            mayModerate: true
        )
        .navigationTitle("Chat")
    }
    .environment(Account(store: MemorySessionStore()))
}
