pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Templates as T
import Swiftify

// a setting with a range, as spotify's crossfade row: what it is in grey on
// the left, the slider with its value on the right.
Item {
    id: root

    property string text
    property real value
    property real from: 0
    property real to: 1
    property real stepSize: 0
    property string valueText: String(Math.round(value))
    signal moved(real value)

    width: parent ? parent.width : 0
    implicitHeight: 44
    opacity: enabled ? 1 : 0.4

    StyledText {
        anchors.left: parent.left
        anchors.right: slider.left
        anchors.rightMargin: 24
        anchors.verticalCenter: parent.verticalCenter
        text: root.text
        elide: Text.ElideRight
        font.pixelSize: Appearance.fontSize.small
        color: Appearance.colors.onSurfaceVariant
    }

    StyledSlider {
        id: slider
        anchors.right: valueLabel.left
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(220, root.width * 0.35)
        from: root.from
        to: root.to
        stepSize: root.stepSize
        snapMode: T.Slider.SnapAlways
        value: root.value
        trackThickness: 4
        dotHandle: true
        enabled: root.enabled
        onMoved: root.moved(value)
    }
    StyledText {
        id: valueLabel
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: 36
        horizontalAlignment: Text.AlignRight
        text: root.valueText
        tabularNumbers: true
        font.pixelSize: Appearance.fontSize.smaller
        color: Appearance.colors.onSurfaceVariant
    }
}
