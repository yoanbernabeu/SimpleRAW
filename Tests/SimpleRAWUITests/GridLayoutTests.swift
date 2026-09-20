import Testing
@testable import SimpleRAWUI

@Suite struct GridLayoutTests {
    @Test func aRowHoldsAsManyCellsAsFit() {
        // 28 of padding, then cells of 180 separated by 10.
        #expect(GridLayout.columns(width: 28 + 180, cellWidth: 180) == 1)
        #expect(GridLayout.columns(width: 28 + 180 * 3 + 20, cellWidth: 180) == 3)
        #expect(GridLayout.columns(width: 28 + 180 * 3 + 19, cellWidth: 180) == 2)
        #expect(GridLayout.columns(width: 1144, cellWidth: 180) == 5)
    }

    @Test func thereIsAlwaysOneColumn() {
        #expect(GridLayout.columns(width: 0, cellWidth: 180) == 1)
        #expect(GridLayout.columns(width: 100, cellWidth: 340) == 1)
    }
}
