import CleanerCore
import SwiftUI

/// A progress ring with a label in its centre.
struct Ring<Label: View>: View {
  let fraction: Double
  let color: Color
  let lineWidth: CGFloat
  @ViewBuilder let label: Label

  var body: some View {
    ZStack {
      Circle().stroke(.quaternary, lineWidth: lineWidth)
      Circle()
        .trim(from: 0, to: fraction)
        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .rotationEffect(.degrees(-90))
      label
    }
    .animation(.smooth, value: fraction)
  }
}

/// One stat as a ring on a glass card, shared by the menu bar window and the full view.
struct GaugeTile: View {
  let title: String
  var detail: String?
  let fraction: Double
  let color: Color
  var size: CGFloat = 46
  var lineWidth: CGFloat = 5
  var font: Font = .caption2.weight(.semibold)

  var body: some View {
    VStack(spacing: 6) {
      Ring(fraction: fraction, color: color, lineWidth: lineWidth) {
        Text(Format.percent(fraction)).font(font)
      }
      .frame(width: size, height: size)
      Text(title).font(.caption2).foregroundStyle(.secondary)
      if let detail { Text(detail).font(.caption.weight(.medium)).lineLimit(1) }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 10)
    .glassEffect(.regular, in: .rect(cornerRadius: 16))
    .accessibilityElement(children: .combine)
  }
}

func pressureColor(_ fraction: Double) -> Color {
  fraction < 0.6 ? .green : fraction < 0.85 ? .orange : .red
}

func batteryColor(_ fraction: Double) -> Color {
  fraction > 0.2 ? .green : .red
}
