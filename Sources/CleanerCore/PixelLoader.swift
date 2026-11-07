/// The "Drive" loader from beautifului.dev (MIT): a chevron wave moving right through a 3x3 grid.
/// The cycle is shorter than the sweep, so two fronts are always in flight.
public enum PixelLoader {
  private static let cycle = 0.65
  private static let dim = 0.15

  public static func opacity(cell: Int, at seconds: Double) -> Double {
    let row = cell / 3, column = cell % 3
    let local = seconds - Double(column + abs(row - 1)) * 0.09
    guard local >= 0 else { return dim }
    let phase = local.truncatingRemainder(dividingBy: cycle) / cycle
    switch phase {
    case ..<0.18: return dim + (1 - dim) * ease(phase / 0.18)
    case ..<0.42: return 1
    case ..<0.62: return 1 - (1 - dim) * ease((phase - 0.42) / 0.2)
    default: return dim
    }
  }

  private static func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }
}
