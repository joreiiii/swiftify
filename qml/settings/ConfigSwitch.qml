pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Templates as T
import Swiftify

// a setting that is on or off, as spotify's settings rows: what it does in
// grey on the left, spotify's small switch on the right.
Item {
    id: root

    property string text
    property bool checked
    signal toggledTo(bool checked)

    width: parent ? parent.width : 0
    implicitHeight: Math.max(44, label.implicitHeight + 16)
    opacity: enabled ? 1 : 0.4

    StyledText {
        id: label
        anchors.left: parent.left
        anchors.right: toggle.left
        anchors.rightMargin: 24
        anchors.verticalCenter: parent.verticalCenter
        text: root.text
        wrapMode: Text.Wrap
        font.pixelSize: Appearance.fontSize.small
        color: Appearance.colors.onSurfaceVariant
    }

    T.Switch {
        id: toggle
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        implicitWidth: 40
        implicitHeight: 24
        checked: root.checked
        enabled: root.enabled
        hoverEnabled: true
        onToggled: root.toggledTo(checked)

        indicator: Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: toggle.checked
                   ? (toggle.hovered ? Appearance.colors.primaryHover : Appearance.colors.primary)
                   : (toggle.hovered ? Appearance.colors.onSurfaceVariant : Appearance.colors.outline)

            Behavior on color {
                ColorAnimation { duration: Appearance.duration(120) }
            }

            Rectangle {
                width: 16
                height: 16
                radius: 8
                anchors.verticalCenter: parent.verticalCenter
                x: toggle.checked ? parent.width - width - 4 : 4
                color: Appearance.colors.layer0

                Behavior on x {
                    NumberAnimation { duration: Appearance.duration(140); easing.type: Easing.OutCubic }
                }
            }
        }
        contentItem: Item {}

        HoverHandler {
            cursorShape: toggle.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        }
    }
}
