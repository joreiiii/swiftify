pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import Swiftify

// an artist (ArtistDetailView): top songs, then albums and singles
Flickable {
    id: root

    // no toolbar floats over this page: only a small gap above it
    topMargin: Appearance.sizes.pageTop

    /// the artist it opened on. a page kept behind a newer one (PageHost)
    /// holds on to its own rather than following the library elsewhere
    property artist artist

    Binding {
        target: root
        property: "artist"
        value: Library.currentArtist
        when: root.visible
        restoreMode: Binding.RestoreNone
    }
    readonly property real margin: Appearance.sizes.pageMargin

    /// whether something `top` down the page and `height` tall is in sight,
    /// or within `slack` of it (HomeView.reaches)
    function reaches(top: real, height: real, slack: real): bool {
        return top + height > root.contentY - slack && top < root.contentY + root.height + slack;
    }

    contentHeight: column.implicitHeight + Appearance.sizes.playerBarClearance
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: StyledScrollBar {
        topPadding: 3 + Appearance.sizes.pageTop
    }

    Column {
        id: column
        width: root.width

        CollectionHero {
            width: root.width
            artworkUrl: root.artist.artworkUrl
            // their picture, blurred, behind the whole head
            backdropUrl: root.artist.artworkUrl
            backdropBleed: root.topMargin
            artworkPending: Library.loadingArtist
            circular: true
            kind: "ARTIST"
            title: root.artist.name
            titleSize: 38
            facts: Library.artistListeners > 0
                   ? Library.artistListeners.toLocaleString(Qt.locale("en_US"), "f", 0) + " monthly listeners"
                   // its place, until spotify has said
                   : "                                "

            actions: [
                TextButton {
                    id: playButton
                    iconOnly: parent ? parent.compactActions : false
                    compactSize: parent ? parent.actionSize : 48
                    implicitHeight: iconOnly ? compactSize : 48
                    symbol: "play_arrow"
                    burst: "play"
                    text: "Play"
                    enabled: Library.artistTopSongs.count > 0
                    onClicked: Player.playFromModel(Library.artistTopSongs, 0)
                },
                // spotify's follow button: the play button's own kind, outlined.
                // its outline reads as part of it, so it is a little smaller
                // than play to look the same size, and centred beside it
                Item {
                    width: follow.width
                    height: playButton.implicitHeight
                    visible: root.artist.id.length > 0

                    TextButton {
                        id: follow
                        readonly property bool following: Library.followRevision >= 0 && Library.followedArtists.count >= 0
                                                          && Library.isFollowing(root.artist.id)
                        anchors.verticalCenter: parent.verticalCenter
                        variant: TextButton.Outlined
                        labelColor: Appearance.colors.onSurface
                        // a white wash on hover and press, not the theme's green
                        colBackgroundHover: Qt.rgba(1, 1, 1, 0.06)
                        colRipple: Qt.rgba(1, 1, 1, 0.12)
                        backgroundItem.border.color: Appearance.colors.onSurface
                        implicitHeight: playButton.implicitHeight - 3
                        text: following ? "Following" : "Follow"
                        onClicked: Library.toggleFollow(root.artist)
                    }
                }
            ]
        }

        Item {
            width: root.width
            height: 240
            Reveal.shown: Library.loadingArtist

            Column {
                anchors.centerIn: parent
                spacing: 12
                LoadingSpinner {
                    anchors.horizontalCenter: parent.horizontalCenter
                }
                StyledText {
                    text: "Loading albums…"
                    color: Appearance.colors.onSurfaceVariant
                }
            }
        }

        TitleText {
            x: root.margin
            Reveal.shown: Library.artistTopSongs.count > 0
            bottomPadding: 10
            text: "Top Songs"
            font.pixelSize: Appearance.fontSize.title
            font.weight: Font.Bold
        }

        Repeater {
            model: Library.artistTopSongs

            SongRow {
                x: root.margin
                width: root.width - 2 * root.margin
                songs: Library.artistTopSongs
            }
        }

        TitleText {
            x: root.margin
            Reveal.shown: !Library.loadingArtist
            topPadding: 28
            bottomPadding: 14
            text: "Albums & Singles"
            font.pixelSize: Appearance.fontSize.title
            font.weight: Font.Bold
        }

        EmptyState {
            anchors.horizontalCenter: parent.horizontalCenter
            Reveal.shown: !Library.loadingArtist && Library.artistAlbums.count === 0
            symbol: "album"
            title: "No Albums Found"
        }

        Flow {
            id: albums
            x: root.margin
            width: root.width - 2 * root.margin
            spacing: Appearance.sizes.shelfGap

            Repeater {
                model: Library.artistAlbums

                // a card's place, kept whether the card is there or not: out
                // of sight it is let go of, and its cover with it. a long
                // discography had every cover decoded at once, most of them
                // never drawn and so never handed to the gpu
                Item {
                    id: place

                    required property album album

                    width: Appearance.sizes.cardSize
                    height: Appearance.sizes.cardSize + 64

                    // built half a screen ahead, drawn only in sight; the
                    // place itself stays, as the flow lays out only what shows
                    Loader {
                        active: root.reaches(column.y + albums.y + place.y, place.height, root.height / 2)
                        visible: root.reaches(column.y + albums.y + place.y, place.height, 0)
                        asynchronous: true
                        sourceComponent: MediaCard {
                            artworkUrl: place.album.artworkUrl
                            title: place.album.name
                            subtitle: place.album.releaseDate.slice(0, 4)
                            onClicked: Library.selectAlbum(place.album)
                        }
                    }
                }
            }
        }
    }
}
