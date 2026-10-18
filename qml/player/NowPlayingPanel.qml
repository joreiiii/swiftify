pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import Swiftify

// Now Playing, as spotify's view beside the page but kept small: the cover
// (where spotify shows a music video), the song with save and share, the
// artist with their picture and story, and the song that plays next.
Item {
    id: root

    property MaterialScheme scheme: Appearance.colors
    readonly property song song: Player.currentSong
    readonly property bool saved: Library.savedRevision >= 0 && Library.isSaved(song.uri)
    readonly property var card: Library.artistCard
    readonly property bool cardFits: root.song.artistId.length > 0 && card.id === root.song.artistId
    readonly property song next: Player.upNext.at(Player.upNext.count > 0 ? 0 : -1)

    onSongChanged: if (visible && song.artistId.length > 0) Library.loadArtistCard(song.artistId)
    onVisibleChanged: if (visible && song.artistId.length > 0) Library.loadArtistCard(song.artistId)

    function share() {
        const link = "https://open.spotify.com/track/" + root.song.uri.split(":").pop()
        if (App.share(root.Window.window, root.song.name + " – " + root.song.artists, link)) {
            UiState.toastRequested("Song link copied")
        }
    }

    StyledText {
        id: header
        x: 18
        y: 16
        width: parent.width - 36
        elide: Text.ElideRight
        text: Player.hasSong ? root.song.name : "Now Playing"
        font.pixelSize: Appearance.fontSize.normal
        font.weight: Font.DemiBold
        color: root.scheme.onSurfaceVariant
    }

    EmptyState {
        anchors.centerIn: parent
        Reveal.shown: !Player.hasSong
        symbol: "music_note"
        title: "Nothing Playing"
        description: "Play something to see it here."
    }

    Flickable {
        anchors.fill: parent
        anchors.topMargin: header.y + header.height + 12
        contentHeight: column.implicitHeight + 24
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        visible: Player.hasSong
        ScrollBar.vertical: StyledScrollBar {}

        Column {
            id: column
            x: 16
            width: parent.width - 32
            spacing: 14

            // the cover, where spotify plays a music video
            ArtworkImage {
                width: parent.width
                height: width
                radius: Appearance.sizes.artworkRadius
                source: root.song.artworkUrl
                placeholderSymbol: "music_note"
            }

            // the song, with save and share beside it
            Item {
                width: parent.width
                height: Math.max(titles.implicitHeight, actions.implicitHeight)

                Column {
                    id: titles
                    anchors.left: parent.left
                    anchors.right: actions.left
                    anchors.rightMargin: 8
                    spacing: 2

                    TitleText {
                        width: parent.width
                        text: root.song.name
                        elide: Text.ElideRight
                        font.pixelSize: Appearance.fontSize.larger
                        color: root.scheme.onSurface
                    }
                    StyledText {
                        width: parent.width
                        text: root.song.artists
                        elide: Text.ElideRight
                        color: root.scheme.onSurfaceVariant
                    }
                }
                Row {
                    id: actions
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    IconButton {
                        visible: !root.song.isLocalFile
                        scheme: root.scheme
                        symbol: "ios_share"
                        size: 34
                        iconSize: 20
                        tooltip: "Share"
                        onClicked: root.share()
                    }
                    IconButton {
                        visible: !root.song.isLocalFile
                        scheme: root.scheme
                        symbol: root.saved ? "check_circle" : "add_circle"
                        toggled: root.saved
                        size: 34
                        iconSize: 20
                        iconColor: root.saved ? root.scheme.primary : root.scheme.onSurfaceVariant
                        tooltip: root.saved ? "Remove from Favourite Songs" : "Save to Favourite Songs"
                        onClicked: Library.toggleSaved(root.song)
                    }
                }
            }

            // about the artist: their picture, name and story
            Rectangle {
                width: parent.width
                height: about.implicitHeight
                visible: root.cardFits
                radius: Appearance.sizes.artworkRadius
                color: root.scheme.surfaceContainerHigh
                clip: true

                Column {
                    id: about
                    width: parent.width
                    spacing: 10
                    bottomPadding: 14

                    Item {
                        width: parent.width
                        height: Math.round(width * 0.62)
                        visible: String(root.card.imageUrl ?? "").length > 0

                        ArtworkImage {
                            anchors.fill: parent
                            radius: 0
                            source: root.card.imageUrl ?? ""
                        }
                        StyledText {
                            x: 14
                            y: 12
                            text: "About the artist"
                            font.weight: Font.Bold
                            color: "white"
                            style: Text.Raised
                            styleColor: Qt.rgba(0, 0, 0, 0.4)
                        }
                    }
                    Item {
                        x: 14
                        width: parent.width - 28
                        height: artistName.implicitHeight

                        StyledText {
                            id: artistName
                            anchors.left: parent.left
                            anchors.right: goTo.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.card.name ?? ""
                            elide: Text.ElideRight
                            font.weight: Font.Bold
                            font.pixelSize: Appearance.fontSize.normal
                            color: root.scheme.onSurface
                        }
                        TextButton {
                            id: goTo
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            variant: TextButton.Tonal
                            text: "Go to Artist"
                            implicitHeight: 32
                            onClicked: UiState.goToArtist(root.song)
                        }
                    }
                    StyledText {
                        x: 14
                        width: parent.width - 28
                        visible: text.length > 0
                        text: root.card.biography ?? ""
                        wrapMode: Text.WordWrap
                        maximumLineCount: 5
                        elide: Text.ElideRight
                        font.pixelSize: Appearance.fontSize.smaller
                        color: root.scheme.onSurfaceVariant
                    }
                }
            }

            // what plays next
            Rectangle {
                width: parent.width
                height: nextColumn.implicitHeight + 24
                visible: root.next.valid
                radius: Appearance.sizes.artworkRadius
                color: root.scheme.surfaceContainerHigh

                Column {
                    id: nextColumn
                    x: 14
                    y: 12
                    width: parent.width - 28
                    spacing: 10

                    Item {
                        width: parent.width
                        height: 20

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Next in queue"
                            font.weight: Font.Bold
                            color: root.scheme.onSurface
                        }
                        StyledText {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Open queue"
                            font.pixelSize: Appearance.fontSize.smaller
                            font.weight: Font.DemiBold
                            color: root.scheme.onSurfaceVariant

                            TapHandler {
                                onTapped: Player.showingQueue = true
                            }
                            HoverHandler {
                                cursorShape: Qt.PointingHandCursor
                            }
                        }
                    }
                    Row {
                        width: parent.width
                        spacing: 10

                        ArtworkImage {
                            width: 44
                            height: 44
                            radius: 6
                            source: root.next.artworkUrl
                        }
                        Column {
                            width: parent.width - 54
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2

                            StyledText {
                                width: parent.width
                                text: root.next.name
                                elide: Text.ElideRight
                                font.weight: Font.DemiBold
                                color: root.scheme.onSurface
                            }
                            StyledText {
                                width: parent.width
                                text: root.next.artists
                                elide: Text.ElideRight
                                font.pixelSize: Appearance.fontSize.smaller
                                color: root.scheme.onSurfaceVariant
                            }
                        }
                    }
                }
            }
        }
    }
}
