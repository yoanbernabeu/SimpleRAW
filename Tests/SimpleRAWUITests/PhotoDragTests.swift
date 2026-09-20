import Testing
@testable import SimpleRAWUI

@Suite struct PhotoDragTests {
    @Test func photosTravelAsTextAndComeBack() {
        let text = PhotoDrag.text(for: [12, 7, 40])
        #expect(PhotoDrag.photoIDs(in: text) == [12, 7, 40])
    }

    /// Any text can be dropped on the sidebar: only ours names photos.
    @Test func otherTextIsNotADragOfPhotos() {
        #expect(PhotoDrag.photoIDs(in: "12,7,40") == nil)
        #expect(PhotoDrag.photoIDs(in: "simpleraw-photos:12,seven") == nil)
        #expect(PhotoDrag.photoIDs(in: "simpleraw-photos:") == nil)
    }
}
