pragma ComponentBehavior: Bound
import QtQuick
import Swiftify

// a setting that is one of a few choices: what it does in grey on the left,
// as spotify's settings rows, and the choices as swiftify's segmented
// buttons on the right (end4's ConfigSelectionArray).
Item {
    id: root

    property string text
    property alias segments: choices.segments
    property alias currentIndex: choices.currentIndex
    signal activated(int index)

    width: parent ? parent.width : 0
    implicitHeight: Math.max(52, label.implicitHeight + 16, choices.implicitHeight + 12)
    opacity: enabled ? 1 : 0.4

    StyledText {
        id: label
        anchors.left: parent.left
        anchors.right: choices.left
        anchors.rightMargin: 24
        anchors.verticalCenter: parent.verticalCenter
        text: root.text
        wrapMode: Text.Wrap
        font.pixelSize: Appearance.fontSize.small
        color: Appearance.colors.onSurfaceVariant
    }

    SegmentedControl {
        id: choices
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        segmentHeight: 32
        enabled: root.enabled
        onActivated: (index) => root.activated(index)
    }
}
