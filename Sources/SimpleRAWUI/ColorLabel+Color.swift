import Catalog
import SwiftUI

extension ColorLabel {
    var color: Color {
        switch self {
        case .red: Theme.labelRed
        case .yellow: Theme.labelYellow
        case .green: Theme.labelGreen
        case .blue: Theme.labelBlue
        case .purple: Theme.labelPurple
        }
    }

    var title: String { rawValue.capitalized }

}
