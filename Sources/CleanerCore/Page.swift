/// One page of a list. An index past either end lands on the nearest page, since the list can shrink.
public struct Page<Item> {
  public let items: [Item]
  public let index: Int
  public let count: Int

  public init(_ all: [Item], index: Int, size: Int) {
    count = max(1, (all.count + size - 1) / size)
    self.index = min(max(index, 0), count - 1)
    items = Array(all.dropFirst(self.index * size).prefix(size))
  }
}
