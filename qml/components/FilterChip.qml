pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import Swiftify

// a filter chip, as spotify's: a pill that lights up while it narrows a list
AbstractButton {
    id: chip

    implicitWidth: label.implicitWidth + 24
    implicitHeight: 30
    hoverEnabled: true

    background: Rectangle {
        radius: height / 2
        color: chip.checked ? Appearance.colors.primary
             : chip.hovered ? Appearance.colors.surfaceContainerHighest : Appearance.colors.surfaceContainerHigh

        Behavior on color {
            ElementMoveFastColor {}
        }
    }
    contentItem: StyledText {
        id: label
        text: chip.text
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        font.pixelSize: Appearance.fontSize.smaller
        font.weight: Font.DemiBold
        color: chip.checked ? Appearance.colors.onPrimary : Appearance.colors.onSurface
    }

    HoverHandler {
        cursorShape: Qt.PointingHandCursor
    }
}
