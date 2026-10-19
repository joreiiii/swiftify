pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import Swiftify

// a category's page, as spotify's genre pages: its name over its colour,
// then its shelves of playlists, albums, artists and podcasts, and its
// own categories as a grid
Flickable {
    id: root

    readonly property var page: Library.genre
    readonly property color tint: page.color && page.color.length > 0 ? page.color : Appearance.colors.primary
    readonly property real margin: Appearance.sizes.pageMargin

    topMargin: 0
    contentHeight: column.implicitHeight + Appearance.sizes.playerBarClearance
    boundsBehavior: Flickable.StopAtBounds
    clip: true
    ScrollBar.vertical: StyledScrollBar {}

    /// whether something `top` down the page and `height` tall is in sight
    function reaches(top: real, height: real, slack: real): bool {
        return top + height > root.contentY - slack && top < root.contentY + root.height + slack
    }

    function open(card: var) {
        switch (card.kind) {
        case "playlist": Library.selectPlaylist(card.playlist); break
        case "album": Library.selectAlbum(card.album); break
        case "artist": Library.selectArtist(card.artist); break
        case "category": Library.showGenre(card.uri, card.name, card.color); break
        // podcasts play in spotify itself
        case "show":
        case "episode": Qt.openUrlExternally("https://open.spotify.com/" + card.kind + "/" + card.uri.split(":").pop()); break
        }
    }

    // the category's colour, fading into the page
    Rectangle {
        width: root.width
        height: 320
        gradient: Gradient {
            GradientStop { position: 0; color: Qt.alpha(root.tint, 0.85) }
            GradientStop { position: 1; color: "transparent" }
        }
    }

    Column {
        id: column
        width: root.width

        Item {
            width: root.width
            height: 200

            TitleText {
                x: root.margin
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 24
                width: root.width - 2 * root.margin
                text: root.page.title ?? ""
                elide: Text.ElideRight
                font.pixelSize: 72
                font.weight: Font.Black
                color: "white"
            }
        }

        Item {
            width: root.width
            height: 240
            visible: Library.loadingGenre

            LoadingSpinner {
                anchors.centerIn: parent
            }
        }

        EmptyState {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: !Library.loadingGenre && (root.page.sections ?? []).length === 0
            symbol: "explore"
            title: "Nothing Here Yet"
            description: "Spotify has nothing to show for this category right now."
        }

        Repeater {
            model: root.page.sections ?? []

            // a shelf of cards, or a grid where the section is more categories
            Loader {
                id: section
                required property var modelData
                readonly property bool categories: modelData.items.every(card => card.kind === "category")
                width: root.width
                sourceComponent: categories ? categoryGrid : shelf

                Component {
                    id: shelf

                    Shelf {
                        width: root.width
                        topPadding: 12
                        onScreen: root.reaches(column.y + section.y, height, 0)
                        nearScreen: root.reaches(column.y + section.y, height, root.height / 2)
                        title: section.modelData.title
                        symbol: "explore"
                        model: section.modelData.items
                        delegate: MediaCard {
                            required property var modelData
                            artworkUrl: modelData.artworkUrl
                            title: modelData.name
                            subtitle: modelData.subtitle ?? ""
                            circular: modelData.kind === "artist"
                            onClicked: root.open(modelData)
                        }
                    }
                }

                Component {
                    id: categoryGrid

                    Column {
                        width: root.width
                        topPadding: 12
                        bottomPadding: 12
                        spacing: 14

                        TitleText {
                            x: root.margin
                            visible: text.length > 0
                            text: section.modelData.title
                            font.pixelSize: Appearance.fontSize.title
                            font.weight: Font.Bold
                        }
                        Flow {
                            id: grid
                            readonly property int columns: Math.max(2, Math.floor((width + 16) / 216))
                            readonly property real cardWidth: (width - 16 * (columns - 1)) / columns
                            x: root.margin
                            width: root.width - 2 * root.margin
                            spacing: 16

                            Repeater {
                                model: section.modelData.items

                                CategoryCard {
                                    required property var modelData
                                    width: grid.cardWidth
                                    height: Math.round(width * 0.56)
                                    title: modelData.name
                                    image: modelData.artworkUrl
                                    tint: modelData.color ?? ""
                                    onClicked: root.open(modelData)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
