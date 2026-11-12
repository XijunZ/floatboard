import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import FloatBoardConnectors
import FloatBoardCore
import SwiftUI

/// "Pair a phone…": asks the engine for a one-time pairing address and shows it as a QR code to scan.
struct PairPhoneSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let info: ConnectorInfo
    @State private var code: (url: URL, expires: Date)?
    @State private var qr: NSImage?
    @State private var error: String?
    @State private var loading = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair a phone").font(.system(size: 15, weight: .semibold))
            Text("Open the camera on your phone and scan this code, then follow the steps on the phone.")
                .font(.system(size: 12))
            Text("The code works once and for 10 minutes.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.white)
                    if let qr {
                        Image(nsImage: qr).interpolation(.none).resizable().scaledToFit().padding(14)
                            .accessibilityLabel("QR code for pairing a phone")
                    } else if loading {
                        ProgressView().colorScheme(.light)
                    } else {
                        Image(systemName: "qrcode").font(.system(size: 60)).foregroundStyle(.gray.opacity(0.4))
                    }
                }
                .frame(width: 260, height: 260)
                Spacer()
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let code {
                HStack(alignment: .firstTextBaseline) {
                    Text(code.url.absoluteString).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code.url.absoluteString, forType: .string)
                        copied = true
                    }
                }
                Text(code.expires > Date() ? "Works until \(ConnectorHealth.time(code.expires))." : "This code has expired. Make a new one.")
                    .font(.system(size: 11)).foregroundStyle(code.expires > Date() ? Color.secondary : Color.orange)
            }
            Text("Phones you've paired are listed on the setup page, where you can remove one.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button("New code") { Task { await load() } }.disabled(loading)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .task { await load() }
    }

    private func load() async {
        loading = true; error = nil; copied = false
        defer { loading = false }
        guard let client = ConnectorAccounts.client(for: info, store: store) else {
            error = "This connection has no address or key. Reconnect it first."
            return
        }
        do {
            let c = try await client.pairPhone()
            code = c
            qr = Self.qrImage(c.url.absoluteString)
            if qr == nil { error = "Couldn't draw the QR code. Copy the address below and open it on the phone instead." }
        } catch {
            code = nil; qr = nil
            let why = (error as? ConnectorError)?.description ?? error.localizedDescription
            self.error = "Couldn't get a pairing code. \(why)"
            if (error as? ConnectorError) != .noPhoneApp {
                store.activity("connector:\(info.id)", .warning, "Could not get a phone pairing code", detail: why)
            }
        }
    }

    /// A crisp QR code: each module scaled to whole pixels (the view also draws it without smoothing).
    static func qrImage(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let scale = max(1, (600 / out.extent.width).rounded(.down))
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
