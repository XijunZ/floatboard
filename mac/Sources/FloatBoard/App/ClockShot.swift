import SwiftUI

/// Snapshot pictures of the clock face (hours and minutes, light and dark), for checking its look.
@MainActor enum ClockShot {
    static func run(dir: String) {
        for (mode, active) in [("hours", 0), ("minutes", 1)] {
            for dark in [false, true] {
                var m = SegmentModel.time(Date()); m.values = [14, 25]; m.active = active
                let v = ClockFace(model: .constant(m)).padding(10)
                    .background(dark ? Color(white: 0.16) : Color(white: 0.97))
                    .environment(\.colorScheme, dark ? .dark : .light)
                let r = ImageRenderer(content: v); r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("clock-\(mode)-\(dark ? "dark" : "light").png")) // try?-ok: snapshot tool
                }
            }
        }
    }
}
