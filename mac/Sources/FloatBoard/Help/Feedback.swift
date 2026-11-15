import AppKit
import FloatBoardCore
import SwiftUI

/// Help › Send Feedback… (docs/architecture.md, Edition 2, C10): you write what happened, see exactly what will be
/// sent, and it goes to the maintainer's feedback service (its address is set at build time, `FEEDBACK_URL`).
/// Diagnostics are off by default and never include task or message text. A copy is noted in Activity.
@MainActor
enum FeedbackWindow {
    private static var window: NSWindow?

    static func show(store: Store) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Send Feedback"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: FeedbackView { window?.close() }.environmentObject(store))
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct FeedbackView: View {
    @EnvironmentObject var store: Store
    let close: () -> Void
    @State private var text = ""
    @State private var diagnostics = false
    @State private var sending = false
    @State private var result: String?
    @State private var failed = false

    static var address: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "FloatBoardFeedbackURL") as? String,
              let u = URL(string: s.trimmingCharacters(in: .whitespaces)), u.scheme == "https" else { return nil }
        return u
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What happened, or what would make FloatBoard better?").font(.system(size: 13, weight: .semibold))
            TextEditor(text: $text)
                .font(.system(size: 12))
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
            Toggle("Include diagnostics (counts, settings versions and recent problems; never task or message text)", isOn: $diagnostics)
                .font(.system(size: 11))
            DisclosureGroup("Exactly what will be sent") {
                ScrollView {
                    Text(preview).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            .font(.system(size: 11))
            Text("It goes to FloatBoard's maintainer, privately: it is kept and filed as a private issue, never made public.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if let result {
                Text(result).font(.system(size: 11)).foregroundStyle(failed ? Color.orange : Color.green)
            }
            HStack {
                if Self.address == nil {
                    Text("Feedback isn't set up in this build.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { close() }
                Button(sending ? "Sending…" : "Send") { Task { await send() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending || Self.address == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 460)
    }

    private var payload: [String: Any] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        var p: [String: Any] = [
            "install_id": installID,
            "text": String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(5000)),
            "app_version": version,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        if diagnostics {
            p["diagnostics"] = Diagnostics.json(store: store, backups: Backups.forEnvironment(), appVersion: version)
        }
        return p
    }

    private var preview: String {
        do {
            let d = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            return String(decoding: d, as: UTF8.self)
        } catch { return "(can't show the preview: \(error))" }
    }

    /// A random id for this Mac's FloatBoard, so the service can limit how much one install sends. Never linked to a name.
    private var installID: String {
        do {
            if let id = try store.db.query("SELECT value FROM meta WHERE key='install_id'", []) { DB.text($0, 0) }.first { return id }
            let id = UUID().uuidString.lowercased()
            try store.db.run("INSERT OR REPLACE INTO meta(key,value) VALUES('install_id', ?)", [id])
            return id
        } catch {
            store.activity("feedback", .warning, "Could not keep this install's feedback id", detail: "\(error)")
            return "unknown"
        }
    }

    private func send() async {
        guard let url = Self.address else { return }
        sending = true; defer { sending = false }
        do {
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                let why = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String // try?-ok: only for the message
                throw NSError(domain: "feedback", code: code, userInfo: [NSLocalizedDescriptionKey: why ?? "the service answered \(code)"])
            }
            store.activity("feedback", .info, "Sent feedback", detail: String(text.prefix(200)))
            failed = false; result = "Sent. Thank you!"
            text = ""
        } catch {
            store.activity("feedback", .warning, "Could not send feedback", detail: "\(error.localizedDescription)")
            failed = true; result = "Couldn't send it: \(error.localizedDescription). Your text is still here; try again later."
        }
    }
}
