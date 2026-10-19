import SwiftUI

extension Text {
    /// A title handed around as a String (component parameters, model titles) shown through the
    /// translations. Literals at the call site are picked up by scripts/i18n.py; anything else is shown as is.
    init(key: String) {
        self.init(LocalizedStringKey(key))
    }
}

extension Label where Title == Text, Icon == Image {
    /// `Label` with a String title looked up in the translations (see `Text(key:)`).
    init(key: String, systemImage: String) {
        self.init(LocalizedStringKey(key), systemImage: systemImage)
    }
}
