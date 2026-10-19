pragma ComponentBehavior: Bound
import QtQuick
import Swiftify

// a group of settings as spotify's settings page has them: a plain bold
// heading, then its rows, no card and no icon.
Column {
    id: root

    property string title
    default property alias content: rows.data

    width: parent ? parent.width : 0
    topPadding: 28
    spacing: 6

    StyledText {
        width: parent.width
        text: root.title
        font.pixelSize: Appearance.fontSize.large
        font.weight: Font.Bold
        color: Appearance.colors.onSurface
    }

    Column {
        id: rows
        width: parent.width
    }
}
