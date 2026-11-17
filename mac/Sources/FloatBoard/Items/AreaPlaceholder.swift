import SwiftUI

/// What an area's tab shows until the area is built.
struct AreaPlaceholder: View {
    let title: String
    let text: String
    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("Switch areas on or off in Settings › Areas.").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
