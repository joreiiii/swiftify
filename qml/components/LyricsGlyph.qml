import QtQuick
import Swiftify

// spotify's lyrics icon, which material's symbols have no match for: a
// handheld microphone held at a slant, its round head up and to the right.
// on, the head fills, as a toggled symbol does.
Item {
    id: root

    property color color: Appearance.colors.onSurfaceVariant
    property bool filled: false
    property real size: 20

    implicitWidth: size
    implicitHeight: size

    readonly property real stroke: Math.max(1.5, Math.round(size * 0.09 * 2) / 2)

    // drawn upright, then turned: the head at the top, the handle below it
    Item {
        anchors.centerIn: parent
        width: root.size
        height: root.size
        rotation: 45

        Rectangle {
            id: head
            anchors.horizontalCenter: parent.horizontalCenter
            y: root.size * 0.04
            width: root.size * 0.44
            height: width
            radius: width / 2
            color: root.filled ? root.color : "transparent"
            border.width: root.stroke
            border.color: root.color
        }
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            y: head.y + head.height + root.size * 0.04
            width: root.stroke * 1.6
            height: root.size * 0.46
            radius: width / 2
            color: root.color
        }
    }
}
