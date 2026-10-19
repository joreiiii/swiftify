pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Templates as T
import Swiftify

// a setting with too many choices for segmented buttons: what it does in grey
// on the left, and on the right a dropdown dressed as the segmented
// buttons are, the choice on its pill in the track, and a menu of pills.
Item {
    id: root

    property string text
    /// the choices' names
    property var options: []
    property int currentIndex: 0
    signal activated(int index)

    width: parent ? parent.width : 0
    implicitHeight: Math.max(52, label.implicitHeight + 16)
    opacity: enabled ? 1 : 0.4

    StyledText {
        id: label
        anchors.left: parent.left
        anchors.right: box.left
        anchors.rightMargin: 24
        anchors.verticalCenter: parent.verticalCenter
        text: root.text
        wrapMode: Text.Wrap
        font.pixelSize: Appearance.fontSize.small
        color: Appearance.colors.onSurfaceVariant
    }

    T.ComboBox {
        id: box

        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        implicitWidth: Math.min(260, Math.max(140, widest.advanceWidth + 64))
        implicitHeight: 40
        enabled: root.enabled
        hoverEnabled: true
        model: root.options
        currentIndex: root.currentIndex
        onActivated: (index) => root.activated(index)

        TextMetrics {
            id: widest
            font.pixelSize: Appearance.fontSize.small
            font.weight: Font.DemiBold
            text: root.options.reduce((longest, name) => String(name).length > longest.length ? String(name) : longest, "")
        }

        // the segmented buttons' track, and the choice on its pill
        background: Rectangle {
            radius: height / 2
            color: Appearance.colors.surfaceContainerHigh

            Rectangle {
                x: 4
                y: 4
                width: parent.width - 8
                height: parent.height - 8
                radius: height / 2
                color: box.hovered || box.popup.visible ? Appearance.colors.secondaryContainerHover : Appearance.colors.secondaryContainer

                Behavior on color {
                    ColorAnimation { duration: Appearance.duration(120) }
                }
            }
        }
        contentItem: StyledText {
            leftPadding: 18
            rightPadding: 36
            text: box.displayText
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
            font.pixelSize: Appearance.fontSize.small
            font.weight: Font.DemiBold
            color: Appearance.colors.onSecondaryContainer
        }
        indicator: MaterialSymbol {
            x: box.width - width - 14
            anchors.verticalCenter: parent.verticalCenter
            text: "expand_more"
            rotation: box.popup.visible ? 180 : 0
            iconSize: 20
            color: Appearance.colors.onSecondaryContainer

            Behavior on rotation {
                NumberAnimation { duration: Appearance.duration(160); easing.type: Easing.OutCubic }
            }
        }

        delegate: T.ItemDelegate {
            id: choice
            required property int index
            required property var modelData

            readonly property bool chosen: box.currentIndex === index

            width: box.popup.width - box.popup.leftPadding - box.popup.rightPadding
            implicitHeight: 36
            hoverEnabled: true
            highlighted: box.highlightedIndex === index

            contentItem: Item {
                StyledText {
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    anchors.right: tick.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(choice.modelData)
                    elide: Text.ElideRight
                    font.pixelSize: Appearance.fontSize.small
                    font.weight: choice.chosen ? Font.DemiBold : Font.Normal
                    color: choice.chosen ? Appearance.colors.onSecondaryContainer : Appearance.colors.onSurfaceVariant
                }
                MaterialSymbol {
                    id: tick
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    visible: choice.chosen
                    text: "check"
                    iconSize: 18
                    color: Appearance.colors.onSecondaryContainer
                }
            }
            // the chosen one on its pill, as in the track
            background: Rectangle {
                radius: height / 2
                color: choice.chosen ? Appearance.colors.secondaryContainer
                     : (choice.highlighted || choice.hovered ? Appearance.colors.layer1Hover : "transparent")
            }
        }

        popup: T.Popup {
            y: box.height + 6
            width: Math.max(box.width, 200)
            x: box.width - width
            padding: 4
            implicitHeight: Math.min(contentItem.implicitHeight + 8, 340)

            enter: Transition {
                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Appearance.duration(120) }
                NumberAnimation { property: "scale"; from: 0.96; to: 1; duration: Appearance.duration(160); easing.type: Easing.OutCubic }
            }

            contentItem: ListView {
                clip: true
                spacing: 2
                implicitHeight: contentHeight
                model: box.popup.visible ? box.delegateModel : null
                currentIndex: box.highlightedIndex
                boundsBehavior: Flickable.StopAtBounds
            }
            background: Rectangle {
                radius: 20
                color: Appearance.colors.surfaceContainerHigh
                border.width: 1
                border.color: Qt.rgba(1, 1, 1, 0.06)
            }
        }
    }
}
