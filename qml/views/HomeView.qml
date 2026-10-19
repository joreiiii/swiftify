pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import Swiftify

// Listen Now (MusicHomeView)
Flickable {
    id: root

    // no toolbar floats over this page: only a small gap above it
    topMargin: Appearance.sizes.pageTop

    readonly property real margin: Appearance.sizes.pageMargin
    /// spotify's quick access: favourite songs, then what was played or
    /// added last, playlists and artists together, as the sidebar's recents
    readonly property var quickEntries: {
        const playlistCount = Library.playlists.count
        const artistCount = Library.followedArtists.count
        const rest = []
        for (let index = 0; index < playlistCount; ++index) {
            rest.push({ type: "playlist", index: index, recency: Library.playlists.at(index).recency })
        }
        for (let index = 0; index < artistCount; ++index) {
            rest.push({ type: "artist", index: index, recency: Library.followedArtists.at(index).recency })
        }
        rest.sort((a, b) => b.recency - a.recency)
        return [{ type: "liked", index: -1 }].concat(rest)
    }

    contentHeight: column.implicitHeight + 24 + Appearance.sizes.playerBarClearance
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: StyledScrollBar { topPadding: 3 + Appearance.sizes.pageTop }

    /// whether something `top` down the page and `height` tall is in sight,
    /// or within `slack` of it
    function reaches(top: real, height: real, slack: real): bool {
        return top + height > root.contentY - slack && top < root.contentY + root.height + slack
    }

    /// spotify's page for the genre, found among its categories by name;
    /// a search for it where spotify has none by that name
    function openGenre(name: string) {
        const plain = (text) => String(text).toLowerCase().replace(/[^a-z0-9]/g, "")
        const wanted = plain(name)
        const categories = Library.genres
        let match = null
        for (let index = 0; index < categories.length && !match; ++index) {
            if (plain(categories[index].title) === wanted) {
                match = categories[index]
            }
        }
        for (let index = 0; index < categories.length && !match; ++index) {
            const title = plain(categories[index].title)
            if (title.startsWith(wanted) || wanted.startsWith(title)) {
                match = categories[index]
            }
        }
        // "Electronic" is spotify's "Dance/Electronic"
        for (let index = 0; index < categories.length && !match; ++index) {
            if (plain(categories[index].title).includes(wanted)) {
                match = categories[index]
            }
        }
        if (match) {
            Library.showGenre(match.uri, match.title, match.color)
        } else {
            Library.searchQuery = name
            Library.showSearch()
        }
    }

    Genres {
        id: genres
    }

    // a few faint covers floating behind the page's heading
    FloatingCovers {
        width: root.width
        height: 260
        key: "home"
        // the covers of what was played last, as the quick access has them
        covers: root.quickEntries.filter(entry => entry.type !== "liked").slice(0, 5).map(entry => entry.type === "artist"
            ? { url: Library.followedArtists.at(entry.index).artworkUrl, circular: true }
            : { url: Library.playlists.at(entry.index).artworkUrl, circular: false })
    }

    Column {
        id: column
        y: 24
        width: root.width
        spacing: Appearance.sizes.sectionGap

        Column {
            x: root.margin
            spacing: 6

            TitleText {
                text: Library.profileName.length > 0 ? "Hey, " + Library.profileName + "!" : "Hey!"
                font.pixelSize: Appearance.fontSize.display
                font.weight: Font.Bold
                font.letterSpacing: -0.8
            }
            // a greeting for the time of day, on a shape to match it
            Row {
                id: greeting

                readonly property int hour: new Date().getHours()
                readonly property int part: hour < 5 ? 3 : (hour < 12 ? 0 : (hour < 17 ? 1 : (hour < 21 ? 2 : 3)))

                spacing: 10

                ShapeIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    size: 30
                    iconSize: 17
                    shape: ["sunny", "softBurst", "flower", "ghostish"][greeting.part]
                    symbol: ["wb_sunny", "light_mode", "wb_twilight", "dark_mode"][greeting.part]
                    color: Appearance.colors.tertiaryContainer
                    iconColor: Appearance.colors.onTertiaryContainer
                    hovered: greetingHover.hovered
                }
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: ["Good morning", "Good afternoon", "Good evening", "Up late..."][greeting.part]
                          + "."
                    color: Appearance.colors.onSurfaceVariant
                }

                HoverHandler {
                    id: greetingHover
                }
            }
        }

        Item {
            width: root.width
            height: 220
            Reveal.shown: Library.loadingHome && Library.recentlyPlayed.count === 0

            Column {
                anchors.centerIn: parent
                spacing: 12
                LoadingSpinner { anchors.horizontalCenter: parent.horizontalCenter }
                StyledText {
                    text: "Loading your music…"
                    color: Appearance.colors.onSurfaceVariant
                }
            }
        }

        // quick access, as spotify's grid at the top of home
        Grid {
            id: quick
            readonly property real gap: 8
            x: root.margin
            width: root.width - 2 * root.margin
            columns: width >= 760 ? 4 : 2
            columnSpacing: gap
            rowSpacing: gap
            Reveal.shown: !(Library.loadingHome && Library.recentlyPlayed.count === 0)

            Repeater {
                // three rows at most
                model: root.quickEntries.slice(0, quick.columns * 3)

                QuickTile {
                    id: tile
                    required property var modelData
                    readonly property playlist playlist: Library.playlists.at(modelData.type === "playlist" ? modelData.index : -1)
                    readonly property artist artist: Library.followedArtists.at(modelData.type === "artist" ? modelData.index : -1)

                    width: (quick.width - quick.gap * (quick.columns - 1)) / quick.columns
                    title: modelData.type === "liked" ? "Favourite Songs"
                         : modelData.type === "artist" ? artist.name : playlist.name
                    symbol: modelData.type === "liked" ? "favorite" : ""
                    artworkUrl: modelData.type === "artist" ? artist.artworkUrl : playlist.artworkUrl
                    circular: modelData.type === "artist"
                    placeholderSymbol: modelData.type === "artist" ? "person" : "queue_music"
                    onClicked: {
                        switch (modelData.type) {
                        case "liked": Library.showSavedSongs(); break
                        case "playlist": Library.selectPlaylist(playlist); break
                        case "artist": Library.selectArtist(artist); break
                        }
                    }
                    onPlayRequested: {
                        switch (modelData.type) {
                        case "liked": Player.playFromModel(Library.savedSongs, 0); break
                        case "playlist": Library.playPlaylist(playlist); break
                        case "artist": Library.playArtist(artist); break
                        }
                    }
                }
            }
        }

        Flow {
            x: root.margin
            width: root.width - 2 * root.margin
            spacing: 12
            Reveal.shown: !(Library.loadingHome && Library.recentlyPlayed.count === 0)

            readonly property bool sideBySide: width >= 520

            HomeShortcut {
                width: parent.sideBySide ? (parent.width - 12) / 2 : parent.width
                title: "Favourite Songs"
                // spotify's count, until the list itself has loaded
                subtitle: Library.savedSongTotal >= 0 ? Library.savedSongTotal + " favourited" : "Made for repeat"
                symbol: "star"
                iconShape: "heart"
                keepsShape: true
                onClicked: Library.showSavedSongs()
            }
            HomeShortcut {
                width: parent.sideBySide ? (parent.width - 12) / 2 : parent.width
                title: "Your Playlists"
                subtitle: Library.playlists.count + " collections to explore"
                symbol: "library_music"
                iconShape: "bun"
                onClicked: Library.showPlaylists()
            }
        }

        Shelf {
            width: root.width
            onScreen: root.reaches(column.y + y, height, 0)
            nearScreen: root.reaches(column.y + y, height, root.height / 2)
            Reveal.shown: Library.pinnedPlaylists.count > 0
            title: "Pinned Playlists"
            symbol: "push_pin"
            iconShape: "flower"
            showsSeeAll: true
            onSeeAll: Library.showPinnedPlaylists()
            model: Math.min(8, Library.pinnedPlaylists.count)
            delegate: MediaCard {
                required property int index
                readonly property playlist playlist: Library.pinnedPlaylists.at(index)
                artworkUrl: playlist.artworkUrl
                title: playlist.name
                subtitle: playlist.ownerDisplayName
                onClicked: Library.selectPlaylist(playlist)
            }
        }

        Shelf {
            width: root.width
            onScreen: root.reaches(column.y + y, height, 0)
            nearScreen: root.reaches(column.y + y, height, root.height / 2)
            Reveal.shown: Library.playlists.count > 0
            title: "Your Playlists"
            symbol: "queue_music"
            iconShape: "bun"
            showsSeeAll: true
            onSeeAll: Library.showPlaylists()
            model: Math.min(8, Library.playlists.count)
            delegate: MediaCard {
                required property int index
                readonly property playlist playlist: Library.playlists.at(index)
                artworkUrl: playlist.artworkUrl
                title: playlist.name
                subtitle: playlist.ownerDisplayName
                onClicked: Library.selectPlaylist(playlist)
            }
        }

        Shelf {
            width: root.width
            onScreen: root.reaches(column.y + y, height, 0)
            nearScreen: root.reaches(column.y + y, height, root.height / 2)
            Reveal.shown: Library.recentlyPlayed.count > 0
            title: "Recently Played"
            symbol: "history"
            iconShape: "clamShell"
            model: Library.recentlyPlayed
            delegate: MediaCard {
                required property int index
                required property song song
                artworkUrl: song.artworkUrl
                title: song.name
                subtitle: song.artists
                current: Player.hasSong && Player.currentSong.instanceId === song.instanceId
                badgeSymbol: current && Player.playing ? "graphic_eq" : "play_arrow"
                onClicked: Player.playFromModel(Library.recentlyPlayed, index)
                onSecondaryClicked: SongMenus.open(song, false)
            }
        }

        Shelf {
            width: root.width
            onScreen: root.reaches(column.y + y, height, 0)
            nearScreen: root.reaches(column.y + y, height, root.height / 2)
            Reveal.shown: Library.recommendedArtists.count > 0
            title: "Artists in Your Rotation"
            symbol: "person"
            iconShape: "cookie12"
            model: Math.min(10, Library.recommendedArtists.count)
            delegate: MediaCard {
                required property int index
                readonly property artist artist: Library.recommendedArtists.at(index)
                artworkUrl: artist.artworkUrl
                title: artist.name
                circular: true
                titleLines: 1
                badgeSymbol: "chevron_right"
                onClicked: Library.selectArtist(artist)
            }
        }

        Shelf {
            width: root.width
            onScreen: root.reaches(column.y + y, height, 0)
            nearScreen: root.reaches(column.y + y, height, root.height / 2)
            Reveal.shown: Library.recommendedAlbums.count > 0
            title: "Albums From Your Listening"
            symbol: "album"
            iconShape: "sunny"
            model: Math.min(10, Library.recommendedAlbums.count)
            delegate: MediaCard {
                required property int index
                readonly property album album: Library.recommendedAlbums.at(index)
                artworkUrl: album.artworkUrl
                title: album.name
                subtitle: album.artists
                onClicked: Library.selectAlbum(album)
            }
        }

        Shelf {
            width: root.width
            onScreen: root.reaches(column.y + y, height, 0)
            nearScreen: root.reaches(column.y + y, height, root.height / 2)
            title: "Explore Genres"
            symbol: "explore"
            iconShape: "clover8"
            rowHeight: 120
            model: genres.featured
            delegate: GenreCard {
                required property var modelData
                name: modelData.name
                symbol: modelData.symbol
                startColor: modelData.start
                endColor: modelData.end
                onClicked: root.openGenre(name)
            }
        }
    }
}
