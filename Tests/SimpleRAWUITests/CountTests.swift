import Testing
@testable import SimpleRAWUI

@Suite struct CountTests {
    @Test func aCountAgreesWithItsNoun() {
        #expect(Count.photos(0) == "0 photos")
        #expect(Count.photos(1) == "1 photo")
        #expect(Count.photos(3) == "3 photos")
        #expect(Count.of(1, "star") == "1 star")
        #expect(Count.of(1, "criterion", plural: "criteria") == "1 criterion")
        #expect(Count.of(2, "criterion", plural: "criteria") == "2 criteria")
    }
}
