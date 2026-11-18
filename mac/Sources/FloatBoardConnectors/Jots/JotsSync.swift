import FloatBoardCore
import Foundation

/// One Jots step with an engine (design §4), run with the phone step: take in what waits (phone captures and changes,
/// meeting notes, phone Make task), ack it, send changed jots and the nudge's state, attach meeting notes that arrived
/// before their event, and ask Claude for tags on new untagged jots (one batched call). Problems go to Activity once.
public enum JotsSync {
    public struct Result: Equatable {
        public var taken = 0
        public var pushed = 0
        public var asked = 0
        public var error: String?
    }
    @MainActor static var lastNudge: [String: JotNudgeState] = [:]
    @MainActor static var reported: [String: String] = [:]
    /// Engines without the Jots routes (404), and ones without a Claude key for the tags job: skipped quietly until relaunch.
    @MainActor static var unsupported: Set<String> = []
    @MainActor static var noClaude: Set<String> = []
    /// The engine's limit for one jot's text (characters as JavaScript counts them: UTF-16 units).
    static let maxText = 100_000

    @MainActor @discardableResult
    public static func tick(connector id: String, store: Store, client: ConnectorClient, now: Date = Date()) async -> Result {
        var r = Result()
        guard store.isOn(.jots), !unsupported.contains(id) else { return r }
        let core = JotsSyncCore(store: store)
        var step = "take in the phone's jots"
        do {
            r.taken = try await PhoneInbox.take(fetch: client.waitingJots, apply: { waiting in
                let acks = core.apply(waiting, now: now)
                step = "confirm the phone's jots"
                return acks
            }, ack: client.ackJots)
            JotStore(store: store).attachPendingMeetingNotes(now: now)
            step = "send jots to the phone"
            core.useEngine(client.accountFingerprint, connector: id)   // another engine account: every recent jot goes again
            let all = core.toPush(connector: id, now: now)
            // A jot longer than the engine takes is left out of the phone's copy (noted once; never cut on this Mac), and
            // counted as sent so it doesn't hold up the others; an edit that makes it short enough sends it again.
            let tooLong = all.filter { $0.text.utf16.count > Self.maxText }
            if !tooLong.isEmpty {
                core.markPushed(tooLong, connector: id)
                for j in tooLong {
                    store.activity("jots", .warning, "J-\(j.id) is too long for the phone (over 100,000 characters); it stays on this Mac only",
                                   detail: "\(j.text.count) characters")
                }
            }
            let push = all.filter { $0.text.utf16.count <= Self.maxText }
            let nudge = JotNudge(store: store).state(now: now)
            if !push.isEmpty || lastNudge[id] != nudge {
                // In requests under the engine's size and count limits; the nudge goes with the first.
                var sent = 0
                for (i, batch) in ConnectorClient.jotBatches(push).enumerated() {
                    let accepted = Set(try await client.putJots(batch, nudge: i == 0 ? nudge : nil))
                    core.markPushed(batch.filter { accepted.contains($0.id) }, connector: id)
                    sent += accepted.count
                }
                if push.isEmpty { _ = try await client.putJots([], nudge: nudge) }
                lastNudge[id] = nudge
                r.pushed = sent
            }
            if !noClaude.contains(id) {
                let sg = JotSuggestions(store: store)
                let ask = sg.toAsk(limit: 20)
                if !ask.isEmpty {
                    step = "ask Claude for tags"
                    do {
                        let names = store.tags.map(\.name)
                        let got = try await client.suggestTags(ask.map { ($0.id, $0.text) }, tags: names)
                        sg.record(asked: ask.map(\.id), suggestions: got, now: now)
                        r.asked = ask.count
                    } catch ConnectorError.http(409, _) {
                        noClaude.insert(id)   // no Claude key on this engine (or Jots off there): tags are added by hand
                    }
                }
            }
            if reported.removeValue(forKey: id) != nil { store.activity("connector:\(id)", .info, "Jots are in sync with the phone again") }
        } catch ConnectorError.http(404, _) {
            unsupported.insert(id)
        } catch {
            let why = (error as? ConnectorError)?.description ?? "\(error)"
            r.error = why
            let message = "Could not \(step); will try again"
            if reported[id] != message + why {
                reported[id] = message + why
                store.activity("connector:\(id)", .warning, message, detail: why)
            }
        }
        return r
    }
}
