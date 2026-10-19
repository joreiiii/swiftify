pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import Swiftify

// a filter chip, as spotify's: a pill that lights up while it narrows a list
AbstractButton {
    id: chip

    /// its fill at rest: lighter where it sits on a card of the same colour
    property color baseColor: Appearance.colors.surfaceContainerHigh

    implicitWidth: label.implicitWidth + 24
    implicitHeight: 30
    hoverEnabled: true

    background: Rectangle {
        radius: height / 2
        color: chip.checked ? Appearance.colors.primary
             : chip.hovered ? Qt.lighter(chip.baseColor, 1.25) : chip.baseColor

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
