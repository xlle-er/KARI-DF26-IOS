import SwiftUI

struct KariOTAProgress: View {
    let value: Double?
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let value {
                ProgressView(value: min(1, max(0, value)), total: 1).progressViewStyle(.linear)
                Text(LM(label) + " · " + String(Int(min(1, max(0, value)) * 100)) + "%").font(.caption).monospacedDigit()
            } else {
                ProgressView()
                if !label.isEmpty { Text(LM(label)).font(.caption) }
            }
        }.accessibilityIdentifier("otaProgress")
    }
}
