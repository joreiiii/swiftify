pragma ComponentBehavior: Bound
import QtQuick
import Swiftify

// the recent searches, under a search field while it is focused and empty:
// the songs last played from search, to play again
Rectangle {
    id: recent

    /// the search field it hangs under
    required property SearchField field
    /// what takes the focus from the field once a search is played
    property Item focusTarget

    objectName: "recentSearches"
    z: 20
    height: recentColumn.implicitHeight + 16
    radius: 12
    color: Appearance.colors.surfaceContainerHigh
    border.width: 1
    border.color: Appearance.colors.outlineVariant
    /// played one: closed until the field is focused again
    property bool dismissed: false
    // pressing a row takes the focus off the field; staying open while
    // hovered lets the press become a click
    visible: !dismissed && (recent.field.editing || listHover.hovered) && recent.field.text.length === 0
             && Library.searchHistoryPreview.count > 0

    Connections {
        target: recent.field
        function onEditingChanged() {
            if (recent.field.editing) {
                recent.dismissed = false
            }
        }
    }

    HoverHandler {
        id: listHover
    }

    Column {
        id: recentColumn
        x: 8
        y: 8
        width: parent.width - 16

        StyledText {
            leftPadding: 8
            height: 32
            verticalAlignment: Text.AlignVCenter
            text: "Recent searches"
            font.weight: Font.Bold
        }

        Repeater {
            model: Library.searchHistoryPreview

            delegate: Item {
                id: row

                required property int index
                readonly property song song: Library.searchHistoryPreview.at(index)

                width: recentColumn.width
                height: 56

                Rectangle {
                    anchors.fill: parent
                    radius: 8
                    color: rowHover.hovered ? Appearance.colors.surfaceContainerHighest : "transparent"
                }
                ArtworkImage {
                    x: 8
                    anchors.verticalCenter: parent.verticalCenter
                    width: 40
                    height: 40
                    radius: 4
                    source: row.song.artworkUrl
                }
                // hovered, a play button over the cover, as the sidebar's rows have
                Rectangle {
                    x: 8
                    anchors.verticalCenter: parent.verticalCenter
                    width: 40
                    height: 40
                    radius: 4
                    color: Qt.rgba(0, 0, 0, 0.5)
                    opacity: rowHover.hovered ? 1 : 0
                    visible: opacity > 0

                    Behavior on opacity {
                        NumberAnimation { duration: Appearance.duration(140); easing.type: Easing.OutCubic }
                    }

                    MaterialSymbol {
                        anchors.centerIn: parent
                        text: "play_arrow"
                        iconSize: 24
                        fill: 1
                        color: "white"
                    }
                }
                Column {
                    anchors.left: parent.left
                    anchors.leftMargin: 60
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    StyledText {
                        width: parent.width
                        elide: Text.ElideRight
                        text: row.song.name
                        font.weight: Font.DemiBold
                    }
                    StyledText {
                        width: parent.width
                        elide: Text.ElideRight
                        text: "Song  •  " + row.song.artists
                        font.pixelSize: Appearance.fontSize.smaller
                        color: Appearance.colors.onSurfaceVariant
                    }
                }
                HoverHandler {
                    id: rowHover
                    cursorShape: Qt.PointingHandCursor
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        Player.playSong(row.song)
                        recent.dismissed = true
                        if (recent.focusTarget) recent.focusTarget.forceActiveFocus()
                    }
                }
            }
        }
    }
}
