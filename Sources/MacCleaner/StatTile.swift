import SwiftUI

struct StatTile: View {
  let title: String
  let value: String
  let fraction: Double?

  init(title: String, value: String, fraction: Double?) {
    self.title = title
    self.value = value
    self.fraction = fraction
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption2).foregroundStyle(.secondary)
      Text(value).font(.callout.weight(.semibold))
      if let fraction {
        ProgressView(value: fraction).tint(fraction < 0.6 ? .green : .orange)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(8)
    .background(.quaternary, in: .rect(cornerRadius: 8))
    .accessibilityElement(children: .combine)
  }
}
