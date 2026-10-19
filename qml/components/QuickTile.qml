import QtQuick
import Swiftify

// a tile of home's quick access, as spotify's grid at the top of home: the
// cover on the left, rounded inside the tile, the name beside it, and on hover a play button
// at the end. the tile opens the page, the button plays it
Rectangle {
    id: root

    property string title
    property url artworkUrl
    property bool circular: false
    property string placeholderSymbol: "queue_music"
    /// a symbol on a gradient instead of a cover, as favourite songs has
    property string symbol

    signal clicked
    signal playRequested

    implicitHeight: 48
    radius: 8
    clip: true
    color: hover.hovered ? Appearance.colors.surfaceContainerHigh : Appearance.colors.surfaceContainerLow
    border.width: 0.75
    border.color: Qt.rgba(1, 1, 1, 0.07)
    scale: tap.pressed ? 0.98 : 1

    Behavior on color {
        ColorAnimation { duration: Appearance.duration(140) }
    }
    Behavior on scale {
        NumberAnimation { duration: Appearance.motion(120); easing.type: Easing.OutCubic }
    }

    HoverHandler {
        id: hover
        cursorShape: Qt.PointingHandCursor
    }
    TapHandler {
        id: tap
        onTapped: root.clicked()
    }

    Item {
        id: cover
        x: 5
        y: 5
        width: root.height - 10
        height: width

        ArtworkImage {
            anchors.fill: parent
            visible: root.symbol.length === 0
            radius: root.circular ? width / 2 : 4
            circular: root.circular
            squiggly: false
            source: root.artworkUrl
            placeholderSymbol: root.placeholderSymbol
        }
        Rectangle {
            anchors.fill: parent
            visible: root.symbol.length > 0
            radius: 4
            gradient: Gradient {
                GradientStop { position: 0; color: "#4a2fbd" }
                GradientStop { position: 1; color: "#8fb8d8" }
            }

            MaterialSymbol {
                anchors.centerIn: parent
                text: root.symbol
                iconSize: 20
                fill: 1
                color: "white"
            }
        }
    }

    StyledText {
        anchors.left: cover.right
        anchors.leftMargin: 10
        anchors.right: play.left
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        text: root.title
        maximumLineCount: 1
        elide: Text.ElideRight
        font.pixelSize: Appearance.fontSize.small
        font.weight: Font.Bold
    }

    PlayButton {
        id: play
        anchors.right: parent.right
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        implicitWidth: 32
        implicitHeight: 32
        playing: false
        opacity: hover.hovered ? 1 : 0
        visible: opacity > 0
        scale: hover.hovered ? 1 : 0.8
        tooltip: "Play"
        onClicked: root.playRequested()

        Behavior on opacity {
            NumberAnimation { duration: Appearance.duration(140); easing.type: Easing.OutCubic }
        }
        Behavior on scale {
            NumberAnimation { duration: Appearance.motion(160); easing.type: Easing.OutBack }
        }
    }
}
