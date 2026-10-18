pragma ComponentBehavior: Bound
import QtQuick
import Swiftify

// a title: the same face as all the other text, only larger and bold, as
// spotify sets its headings.
StyledText {
    /// display, headline or title: the page's name, a hero's, a section's
    property string level: "title"

    font.pixelSize: level === "display" ? Appearance.fontSize.display
                  : level === "headline" ? Appearance.fontSize.headline : Appearance.fontSize.title
    font.weight: Font.Bold
    font.letterSpacing: level === "display" ? -0.4 : 0
}
