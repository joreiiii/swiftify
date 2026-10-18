import QtQuick
import Swiftify

// spotify's queue icon, which material's symbols have no match for: the
// song playing as a rounded box, the ones after it as two lines below. on,
// the box fills, as a toggled symbol does.
Item {
    id: root

    property color color: Appearance.colors.onSurfaceVariant
    property bool filled: false
    property real size: 20

    implicitWidth: size
    implicitHeight: size

    readonly property real stroke: Math.max(1.5, Math.round(size * 0.09 * 2) / 2)

    Rectangle {
        x: size * 0.1
        y: size * 0.12
        width: size * 0.8
        height: size * 0.36
        radius: size * 0.07
        color: root.filled ? root.color : "transparent"
        border.width: root.stroke
        border.color: root.color
    }
    Rectangle {
        x: size * 0.1
        y: size * 0.62
        width: size * 0.8
        height: root.stroke
        radius: height / 2
        color: root.color
    }
    Rectangle {
        x: size * 0.1
        y: size * 0.82
        width: size * 0.8
        height: root.stroke
        radius: height / 2
        color: root.color
    }
}
