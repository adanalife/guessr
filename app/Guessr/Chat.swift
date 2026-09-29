import GuessrKit
import SwiftUI

/// The channel's Twitch chat: the sign-in until there is a login, then the log
/// and the composer.
struct ChatTab: View {
    @Environment(Account.self) private var account

    var body: some View {
        NavigationStack {
            Group {
                if let session = account.session {
                    ChatLog(
                        lines: account.chat?.lines ?? [],
                        mayModerate: account.isMod && session.canModerate)
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
            .paper()
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
    /// The last timeout or ban this mod made, offered back as an undo — a
    /// long-press menu on a phone is easy to mis-tap.
    @State private var banned: Banned?
    /// Whether the composer holds the keyboard. The log sits behind the
    /// keyboard while it does, so there has to be a way to give it back.
    @FocusState private var composing: Bool
    /// The channel's emotes and Twitch's, for the picker; empty until read.
    @State private var emotes: [ChatEmote] = []
    @State private var pickingEmote = false

    var body: some View {
        VStack(spacing: 0) {
            log
            if let banned { undoBar(banned) }
            if let status = error ?? connectionStatus {
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

    /// A socket error means nothing to a player, and the chat retries on its
    /// own, so while it is down the log says only that it is on its way.
    private var connectionStatus: String? {
        guard let chat = account.chat else { return nil }
        return chat.isConnected ? chat.lastError : "Connecting to chat…"
    }

    private func loadArt() async {
        guard let chat = account.chat else { return }
        await BadgeArt.shared.load { try await chat.badgeArt() }
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
                ChatLineView(line: line, mayModerate: mayModerate, error: $error, banned: $banned)
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

    private func undoBar(_ ban: Banned) -> some View {
        HStack {
            Text(ban.summary)
            Spacer()
            Button("Undo") { unban(ban) }
            Button("Dismiss", systemImage: "xmark") { banned = nil }
                .labelStyle(.iconOnly)
        }
        .font(.caption)
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private func unban(_ ban: Banned) {
        guard let chat = account.chat else { return }
        banned = nil
        Task {
            await account.refreshIfNeeded()
            do {
                try await chat.unban(userId: ban.userId)
                error = nil
            } catch {
                self.error = error.localizedDescription
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
    @Binding var banned: Banned?
    /// Emote art that has arrived, by the id Twitch named it with.
    @State private var emotes: [String: Image] = [:]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                // A sub, gift, raid or announcement: Twitch's sentence about
                // it, then anything the chatter said as an ordinary line.
                if let kind = line.kind, let notice = line.notice {
                    Label(notice, systemImage: kindSymbol(kind))
                        .font(.caption.italic())
                        .foregroundStyle(.secondary)
                }
                if line.kind == nil || !line.text.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        ForEach(line.badgeTags) { BadgeMark(tag: $0) }
                        Text("\(username): \(words)")
                            .font(.subheadline)
                    }
                }
            }
            .task(id: line.id) { await loadEmotes() }
            Spacer(minLength: 4)
            Text(shortAge(line.timestamp))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .modifier(
            ChatLineMenu(
                translatable: line.text.isEmpty ? nil : line.text,
                name: line.displayName,
                delete: mayModerate ? { moderate { try await $0.delete(messageId: line.id) } } : nil,
                ban: mayModerate
                    ? { seconds in
                        moderate {
                            try await $0.ban(userId: line.userId, seconds: seconds)
                            banned = Banned(userId: line.userId, name: line.displayName, seconds: seconds)
                        }
                    } : nil))
    }

    /// Runs a moderation verb on a fresh token. Twitch checks the mod's
    /// standing again, and says so when it refuses.
    private func moderate(_ verb: @escaping (TwitchChat) async throws -> Void) {
        guard let chat = account.chat else { return }
        Task {
            await account.refreshIfNeeded()
            do {
                try await verb(chat)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// The sender's name in their Twitch color, or the palette's for one who
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

/// A timeout or ban, as the undo bar names it.
struct Banned {
    var userId: String
    var name: String
    /// 0 for a ban.
    var seconds: Int

    var summary: String {
        guard seconds > 0 else { return "Banned \(name)" }
        return "Timed out \(name) for \(timeoutLength(seconds))"
    }
}

/// The glyph for a notice's `notice_type`; a shared-chat variant reads as its
/// plain kind.
private func kindSymbol(_ kind: String) -> String {
    switch kind.replacingOccurrences(of: "shared_chat_", with: "") {
    case "sub", "resub", "prime_paid_upgrade": "star.fill"
    case "sub_gift", "community_sub_gift", "gift_paid_upgrade", "pay_it_forward": "gift.fill"
    case "raid", "unraid": "person.2.fill"
    case "announcement": "megaphone.fill"
    default: "sparkles"
    }
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
                ChatLine(
                    id: "5", userId: "13", login: "kate", displayName: "Kate", text: "a year of van", color: "#00FF7F",
                    badges: ["subscriber": "12"], timestamp: now.addingTimeInterval(-3), kind: "resub",
                    notice: "Kate subscribed at Tier 1. They've subscribed for 12 months!"),
                ChatLine(
                    id: "6", userId: "14", login: "vanfan", displayName: "vanfan", text: "", fragments: [],
                    timestamp: now.addingTimeInterval(-1), kind: "raid", notice: "5 raiders from vanfan have joined!"),
            ],
            mayModerate: true
        )
        .navigationTitle("Chat")
    }
    .environment(Account(store: MemorySessionStore()))
}
