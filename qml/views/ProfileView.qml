pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import Swiftify

// the person's profile, as spotify's: their picture and name, then their
// own playlists, the artists they follow and what they played last
Flickable {
    id: root

    topMargin: Appearance.sizes.pageTop

    readonly property real margin: Appearance.sizes.pageMargin
    /// the playlists the person made, as indices into Library.playlists
    readonly property var ownPlaylists: {
        const own = []
        for (let index = 0; index < Library.playlists.count; ++index) {
            if (Library.playlists.at(index).ownerId === Library.profileId) {
                own.push(index)
            }
        }
        return own
    }

    contentHeight: column.implicitHeight + 24 + Appearance.sizes.playerBarClearance
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: StyledScrollBar { topPadding: 3 + Appearance.sizes.pageTop }

    function reaches(top: real, height: real, slack: real): bool {
        return top + height > root.contentY - slack && top < root.contentY + root.height + slack
    }

    Column {
        id: column
        width: root.width
        spacing: 8

        // the head: the picture, round, and the name large beside it
        Item {
            x: root.margin
            width: root.width - 2 * root.margin
            height: 220

            Rectangle {
                id: picture
                anchors.verticalCenter: parent.verticalCenter
                width: 180
                height: 180
                radius: 90
                color: Appearance.colors.tertiary
                visible: !avatar.ready

                StyledText {
                    anchors.centerIn: parent
                    text: Library.profileName.length > 0 ? Library.profileName.charAt(0).toUpperCase() : "?"
                    font.pixelSize: 72
                    font.weight: Font.Bold
                    color: Appearance.colors.onTertiary
                }
            }
            ArtworkImage {
                id: avatar
                anchors.fill: picture
                circular: true
                squiggly: false
                visible: Library.profileArtworkUrl.toString().length > 0
                source: Library.profileArtworkUrl
            }

            Column {
                anchors.left: picture.right
                anchors.leftMargin: 28
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6

                StyledText {
                    text: "Profile"
                    font.weight: Font.DemiBold
                }
                TitleText {
                    width: parent.width
                    elide: Text.ElideRight
                    text: Library.profileName
                    font.pixelSize: Appearance.fontSize.display
                    font.weight: Font.Bold
                }
                StyledText {
                    color: Appearance.colors.onSurfaceVariant
                    text: Format.joined([
                        root.ownPlaylists.length + (root.ownPlaylists.length === 1 ? " playlist" : " playlists"),
                        Library.followedArtists.count + " following"
                    ], "  •  ")
                }
            }
        }

        Shelf {
            width: root.width
            onScreen: root.reaches(column.y + y, height, 0)
            nearScreen: root.reaches(column.y + y, height, root.height / 2)
            Reveal.shown: root.ownPlaylists.length > 0
            title: "Playlists"
            symbol: "queue_music"
            showsSeeAll: true
            onSeeAll: Library.showPlaylists()
            model: root.ownPlaylists.length
            delegate: MediaCard {
                required property int index
                readonly property playlist playlist: Library.playlists.at(root.ownPlaylists[index] ?? -1)
                artworkUrl: playlist.artworkUrl
                title: playlist.name
                subtitle: Format.songCount(playlist.songCount)
                onClicked: Library.selectPlaylist(playlist)
            }
        }

        Shelf {
            width: root.width
            onScreen: root.reaches(column.y + y, height, 0)
            nearScreen: root.reaches(column.y + y, height, root.height / 2)
            Reveal.shown: Library.followedArtists.count > 0
            title: "Following"
            symbol: "person"
            model: Library.followedArtists.count
            delegate: MediaCard {
                required property int index
                readonly property artist artist: Library.followedArtists.at(index)
                artworkUrl: artist.artworkUrl
                title: artist.name
                subtitle: "Artist"
                circular: true
                titleLines: 1
                onClicked: Library.selectArtist(artist)
            }
        }

        Shelf {
            width: root.width
            onScreen: root.reaches(column.y + y, height, 0)
            nearScreen: root.reaches(column.y + y, height, root.height / 2)
            Reveal.shown: Library.recentlyPlayed.count > 0
            title: "Recently Played"
            symbol: "history"
            model: Library.recentlyPlayed.count
            delegate: MediaCard {
                required property int index
                readonly property song song: Library.recentlyPlayed.at(index)
                artworkUrl: song.artworkUrl
                title: song.name
                subtitle: song.artists
                onClicked: Player.playSong(song)
            }
        }
    }
}
