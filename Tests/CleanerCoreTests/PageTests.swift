import Testing
@testable import CleanerCore

struct PageTests {
  @Test func splitsIntoPages() {
    let first = Page(Array(1...13), index: 0, size: 5)
    #expect(first.items == [1, 2, 3, 4, 5])
    #expect(first.count == 3)
    #expect(Page(Array(1...13), index: 2, size: 5).items == [11, 12, 13])
  }

  @Test func exactFitHasNoEmptyLastPage() {
    #expect(Page(Array(1...10), index: 0, size: 5).count == 2)
  }

  @Test func noItemsIsOneEmptyPage() {
    let page = Page([Int](), index: 0, size: 5)
    #expect(page.items.isEmpty)
    #expect(page.count == 1)
    #expect(page.index == 0)
  }

  @Test func indexOutOfRangeIsClamped() {
    #expect(Page(Array(1...6), index: 9, size: 5).index == 1)
    #expect(Page(Array(1...6), index: 9, size: 5).items == [6])
    #expect(Page(Array(1...6), index: -1, size: 5).index == 0)
  }
}
