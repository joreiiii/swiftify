import QtQuick
import Swiftify

// spotify's now playing view icon: a window with a panel down its right
// side. on, the panel fills, as a toggled symbol does.
Item {
    id: root

    property color color: Appearance.colors.onSurfaceVariant
    property bool filled: false
    property real size: 20

    implicitWidth: size
    implicitHeight: size

    readonly property real stroke: Math.max(1.5, Math.round(size * 0.09 * 2) / 2)

    Rectangle {
        id: frame
        x: root.size * 0.08
        y: root.size * 0.16
        width: root.size * 0.84
        height: root.size * 0.68
        radius: root.size * 0.1
        color: "transparent"
        border.width: root.stroke
        border.color: root.color
    }
    // the panel, against the frame's right edge
    Rectangle {
        x: frame.x + frame.width * 0.56
        y: frame.y
        width: root.filled ? frame.width * 0.44 : root.stroke
        height: frame.height
        radius: root.filled ? frame.radius : 0
        color: root.color
    }
}
