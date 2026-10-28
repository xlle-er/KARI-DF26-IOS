import SwiftUI

struct KariOTAProgress: View {
    let value: Double?
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let value {
                let fraction: Double = min(1, max(0, value))
                let percentage = Int(fraction * 100)
                let progressText = "\(LM(label)) · \(percentage)%"
                ProgressView(value: fraction, total: 1).progressViewStyle(.linear)
                Text(progressText).font(.caption).monospacedDigit()
            } else {
                ProgressView()
                if !label.isEmpty { Text(LM(label)).font(.caption) }
            }
        }.accessibilityIdentifier("otaProgress")
    }
}
