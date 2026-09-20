import Catalog
import Foundation
import RawEngine
import Testing
@testable import SimpleRAWUI

@Suite struct PhotoCaptionTests {
    private func photo(rating: Int = 0, flag: Flag = .none, label: ColorLabel? = nil, isEdited: Bool = false, iso: Int? = 400) -> Photo {
        Photo(
            id: 1,
            file: NewPhoto(
                relativePath: "Originals/R0001.DNG", fileName: "R0001.DNG", contentHash: "hash", captureDate: nil, camera: "RICOH GR III",
                lens: nil, iso: iso, exposureTime: 1.0 / 80, aperture: 7.1, focalLength: 18.3, width: 6000, height: 4000
            ),
            importDate: Date(timeIntervalSince1970: 0), rating: rating, flag: flag, colorLabel: label, adjustments: Adjustments(),
            isEdited: isEdited
        )
    }

    /// A thumbnail was a picture and nothing else to VoiceOver.
    @Test func aThumbnailSaysWhatItShows() {
        #expect(PhotoCaption.accessibilityLabel(for: photo()) == "R0001.DNG")
        #expect(PhotoCaption.accessibilityLabel(for: photo(rating: 1)) == "R0001.DNG, 1 star")
        #expect(
            PhotoCaption.accessibilityLabel(for: photo(rating: 3, flag: .picked, label: .red, isEdited: true))
                == "R0001.DNG, 3 stars, picked, red label, edited"
        )
        #expect(PhotoCaption.accessibilityLabel(for: photo(flag: .rejected)) == "R0001.DNG, rejected")
    }

    /// The bar under the grid is always there, so that selecting never makes the grid jump.
    @Test func theBarUnderTheGridAlwaysHasSomethingToSay() {
        #expect(PhotoCaption.summary(selected: [], shown: 312) == "312 photos")
        #expect(PhotoCaption.summary(selected: [], shown: 1) == "1 photo")
        #expect(PhotoCaption.summary(selected: [photo(), photo()], shown: 312) == "2 photos selected")
        #expect(PhotoCaption.summary(selected: [photo()], shown: 312).hasPrefix("R0001.DNG  ·  RICOH GR III  ·  ISO 400"))
        #expect(!PhotoCaption.summary(selected: [photo(iso: nil)], shown: 312).contains("ISO"))
    }
}
