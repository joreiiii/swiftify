import QtQuick
import Swiftify

// one of spotify's categories: a card in its colour, its name on top and its
// picture tilted into the corner, as spotify's browse grid has them
Rectangle {
    id: root

    property string title
    property string image
    property string tint

    signal clicked

    radius: 8
    clip: true
    color: tint.length > 0 ? tint : Appearance.colors.primaryContainer
    scale: hover.hovered ? 1.02 : 1

    Behavior on scale {
        NumberAnimation { duration: Appearance.motion(160); easing.type: Easing.OutCubic }
    }

    StyledText {
        x: 16
        y: 14
        width: parent.width - 32
        text: root.title
        wrapMode: Text.Wrap
        maximumLineCount: 2
        font.pixelSize: Appearance.fontSize.larger
        font.weight: Font.Bold
        color: "white"
    }
    ArtworkImage {
        width: parent.height * 0.62
        height: width
        x: parent.width - width * 0.78
        y: parent.height - height * 0.82
        rotation: 25
        radius: 4
        squiggly: false
        source: root.image
    }
    HoverHandler {
        id: hover
        cursorShape: Qt.PointingHandCursor
    }
    TapHandler {
        onTapped: root.clicked()
    }
}
