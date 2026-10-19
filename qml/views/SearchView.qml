pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import Swiftify

// Search (GlobalSearchView): categories and history when empty, results after.
Flickable {
    id: root

    // no toolbar floats over this page: only a small gap above it
    topMargin: Appearance.sizes.pageTop

    readonly property real margin: Appearance.sizes.pageMargin
    readonly property bool empty: Library.searchQuery.trim().length === 0
    /// spotify's filter over the results: all, or one kind of them
    property string filter: "all"
    readonly property var filters: [
        { kind: "all", name: "All" },
        { kind: "songs", name: "Songs" },
        { kind: "artists", name: "Artists" },
        { kind: "albums", name: "Albums" },
        { kind: "playlists", name: "Playlists" }
    ]

    // --- the wave ---------------------------------------------------------------------
    // results arrive on a green wave from the search bar, the play button's
    // press ripple made as big as the page: a circle grows from above the
    // page's middle down past its bottom, showing the results as it goes,
    // its green fading once it has passed

    readonly property bool showingResults: !root.empty && !Library.searchIsCatchphrase && !Library.searching
                                           && Library.hasSearchResults
    /// how far the wave has spread from the search bar
    property real waveRadius: 0
    property bool waving: false
    /// where it starts, in the page's own coordinates: the search bar, just
    /// above the top edge of the page in sight
    readonly property point waveOrigin: Qt.point(root.width / 2, root.contentY - 28)
    readonly property real waveReach: Math.sqrt(Math.pow(root.width / 2, 2) + Math.pow(root.height + 28, 2))

    onShowingResultsChanged: {
        if (showingResults && !Appearance.performanceMode) {
            wave.restart()
            arrive.restart()
        }
    }

    ParallelAnimation {
        id: arrive
        NumberAnimation {
            target: resultsScale
            properties: "xScale,yScale"
            from: 0.95
            to: 1
            duration: Appearance.motion(600)
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Appearance.curves.emphasizedDecel
        }
        NumberAnimation {
            target: results
            property: "opacity"
            from: 0
            to: 1
            duration: Appearance.duration(350)
            easing.type: Easing.OutCubic
        }
    }

    SequentialAnimation {
        id: wave
        ScriptAction { script: { root.waving = true; waveTint.opacity = 1 } }
        ParallelAnimation {
            NumberAnimation {
                target: root
                property: "waveRadius"
                from: 0
                to: root.waveReach
                duration: Appearance.motion(900)
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.curves.standardDecel
            }
            SequentialAnimation {
                PauseAnimation { duration: Appearance.motion(250) }
                NumberAnimation {
                    target: waveTint
                    property: "opacity"
                    to: 0
                    duration: Appearance.duration(800)
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Appearance.curves.standardDecel
                }
            }
        }
        ScriptAction { script: root.waving = false }
    }

    // a new search starts on all of it; the results arriving for it do not
    property string filteredQuery
    Connections {
        target: Library
        function onSearchChanged() {
            const query = Library.searchQuery.trim()
            if (query !== root.filteredQuery) {
                root.filteredQuery = query
                root.filter = "all"
            }
        }
    }

    contentHeight: column.implicitHeight + 24 + Appearance.sizes.playerBarClearance
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: StyledScrollBar { topPadding: 3 + Appearance.sizes.pageTop }

    /// whether something `top` down the page and `height` tall is in sight,
    /// or within `slack` of it
    function reaches(top: real, height: real, slack: real): bool {
        return top + height > root.contentY - slack && top < root.contentY + root.height + slack
    }

    Genres {
        id: genres
    }

    Component.onCompleted: Library.loadBrowse()

    Stickers {
        width: root.width
        height: 220
        key: "search"
        count: 4
    }

    Column {
        id: column
        // the filters sit right under the bar, as spotify's
        y: root.empty ? 24 : 0
        width: root.width
        spacing: 0

        // nothing typed: what was played from here, and categories
        Column {
            width: root.width
            // gone at once, so what follows never waits on it to fade
            visible: root.empty
            opacity: visible ? 1 : 0
            Behavior on opacity {
                NumberAnimation { duration: Appearance.duration(200); easing.type: Easing.OutCubic }
            }

            Item {
                x: root.margin
                width: root.width - 2 * root.margin
                height: 48
                Reveal.shown: Library.searchHistory.count > 0

                TitleText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Played from Search"
                    font.pixelSize: Appearance.fontSize.title
                    font.weight: Font.Bold
                }
                TextButton {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    variant: TextButton.Text
                    text: "Clear"
                    onClicked: Library.clearSearchHistory()
                }
            }

            Repeater {
                model: root.empty ? Library.searchHistoryPreview : null

                SongRow {
                    x: root.margin
                    width: root.width - 2 * root.margin
                    songs: Library.searchHistoryPreview
                    showsNumber: false
                    fromSearch: true
                }
            }

            StyledText {
                x: root.margin
                topPadding: Library.searchHistory.count > 0 ? 26 : 0
                bottomPadding: 18
                text: "Browse All"
                font.pixelSize: 32
                font.weight: Font.Bold
            }

            // spotify's own categories, each opening its page: a card in its
            // colour with its picture tilted into the corner
            Flow {
                id: browseAll
                readonly property int columns: Math.max(2, Math.floor((width + 16) / 216))
                readonly property real cardWidth: (width - 16 * (columns - 1)) / columns
                x: root.margin
                width: root.width - 2 * root.margin
                spacing: 16
                visible: Library.genres.length > 0

                Repeater {
                    model: Library.genres

                    CategoryCard {
                        required property var modelData
                        width: browseAll.cardWidth
                        height: Math.round(width * 0.56)
                        title: modelData.title
                        image: modelData.image
                        tint: modelData.color ?? ""
                        onClicked: Library.showGenre(modelData.uri, modelData.title, modelData.color)
                    }
                }
            }

            // until spotify's are there, a few to search for
            Flow {
                x: root.margin
                width: root.width - 2 * root.margin
                spacing: 16
                visible: Library.genres.length === 0

                Repeater {
                    model: genres.featured

                    GenreCard {
                        required property var modelData
                        name: modelData.name
                        symbol: modelData.symbol
                        startColor: modelData.start
                        endColor: modelData.end
                        onClicked: Library.searchQuery = name
                    }
                }
            }
        }

        // the phrase
        Item {
            width: root.width
            height: 360
            // gone at once, so what follows never waits on it to fade
            visible: !root.empty && Library.searchIsCatchphrase
            opacity: visible ? 1 : 0
            Behavior on opacity {
                NumberAnimation { duration: Appearance.duration(200); easing.type: Easing.OutCubic }
            }

            Column {
                anchors.centerIn: parent
                spacing: 16

                MaterialSymbol {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 48
                    height: 48
                    text: "auto_awesome"
                    iconSize: 42
                    fill: 1
                    color: Appearance.colors.primary
                }
                TitleText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: UiState.catchphrase
                    font.pixelSize: Appearance.fontSize.headline
                    font.weight: Font.Bold
                }
                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "You found it."
                    color: Appearance.colors.onSurfaceVariant
                }
            }
        }

        Item {
            width: root.width
            height: 280
            // gone at once, so what follows never waits on it to fade
            visible: !root.empty && !Library.searchIsCatchphrase && Library.searching
            opacity: visible ? 1 : 0
            Behavior on opacity {
                NumberAnimation { duration: Appearance.duration(200); easing.type: Easing.OutCubic }
            }

            Column {
                anchors.centerIn: parent
                spacing: 12
                LoadingSpinner { anchors.horizontalCenter: parent.horizontalCenter }
                StyledText {
                    text: "Searching Spotify…"
                    color: Appearance.colors.onSurfaceVariant
                }
            }
        }

        Item {
            width: root.width
            height: 360
            // gone at once, so what follows never waits on it to fade
            visible: !root.empty && !Library.searchIsCatchphrase && !Library.searching && !Library.hasSearchResults
            opacity: visible ? 1 : 0
            Behavior on opacity {
                NumberAnimation { duration: Appearance.duration(200); easing.type: Easing.OutCubic }
            }

            EmptyState {
                anchors.centerIn: parent
                symbol: "search_off"
                title: "No Results for “" + Library.searchQuery.trim() + "”"
                description: "Check the spelling or try a new search."
            }
        }

        // results
        Column {
            id: results
            width: root.width
            // they grow in a little from the middle of what is in sight, on
            // the wave, rather than sliding into place
            visible: root.showingResults
            spacing: 0
            transform: Scale {
                id: resultsScale
                origin.x: results.width / 2
                origin.y: Math.max(0, root.contentY + root.height / 2 - column.y - results.y)
            }

            // shown only inside the wave while it spreads
            layer.enabled: root.waving
            layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: waveMask
                maskThresholdMin: 0.5
                maskSpreadAtMin: 0.15
            }

            // spotify's filters, the kinds there are results of
            Flow {
                x: root.margin
                width: root.width - 2 * root.margin
                spacing: 8
                bottomPadding: 20

                Repeater {
                    model: root.filters.filter(entry => entry.kind === "all" || Library.searchOrder.indexOf(entry.kind) >= 0)

                    FilterChip {
                        required property var modelData
                        text: modelData.name
                        checked: root.filter === modelData.kind
                        onClicked: {
                            root.filter = modelData.kind
                            root.contentY = -root.topMargin
                        }
                    }
                }
            }

            // spotify's top result: the best match, large, to open or play
            TopResult {
                x: root.margin
                width: Math.min(root.width - 2 * root.margin, 520)
                visible: root.filter === "all" && Library.searchTop.kind !== undefined
            }

            // the kinds of result in the order of their best match, or the
            // one filtered to
            Repeater {
                model: root.filter === "all" ? Library.searchOrder : [root.filter]

                Loader {
                    id: section
                    required property string modelData
                    width: root.width
                    sourceComponent: modelData === "songs" ? songsSection
                        : root.filter !== "all" ? gridSection
                        : modelData === "albums" ? albumsSection
                        : modelData === "artists" ? artistsSection : playlistsSection
                }
            }
        }
    }

    // the wave's circle, in the results' own coordinates, as their mask
    Item {
        id: waveMask
        x: column.x + results.x
        y: column.y + results.y
        width: results.width
        height: results.height
        visible: false
        layer.enabled: root.waving

        Rectangle {
            readonly property point origin: Qt.point(root.waveOrigin.x - waveMask.x, root.waveOrigin.y - waveMask.y)
            x: origin.x - root.waveRadius
            y: origin.y - root.waveRadius
            width: 2 * root.waveRadius
            height: width
            radius: root.waveRadius
            color: "white"
        }
    }

    // the wave's green, over the page in sight
    Ripple {
        id: waveTint
        x: 0
        y: root.contentY
        width: root.width
        height: root.height
        z: 10
        color: Qt.alpha(Appearance.colors.primary, 0.22)
        center: Qt.point(root.waveOrigin.x, -28)
        radius: root.waveRadius
        visible: root.waving && opacity > 0
    }

    component TopResult: Rectangle {
        id: top
        readonly property var result: Library.searchTop
        height: 116
        radius: Appearance.rounding.normal
        color: topHover.hovered ? Appearance.colors.surfaceContainerHighest : Appearance.colors.surfaceContainerHigh

        Behavior on color {
            ElementMoveFastColor {}
        }

        function open() {
            switch (result.kind) {
            case "songs": Player.playSong(result.song); break
            case "artists": Library.selectArtist(result.artist); break
            case "albums": Library.selectAlbum(result.album); break
            // the dj has no page: it plays
            case "playlists": result.playlist.isDj ? Library.playPlaylist(result.playlist) : Library.selectPlaylist(result.playlist); break
            }
        }

        function play() {
            switch (result.kind) {
            case "songs": Player.playSong(result.song); break
            case "artists": Library.playArtist(result.artist); break
            case "albums": Library.selectAlbum(result.album); break
            case "playlists": Library.playPlaylist(result.playlist); break
            }
        }

        ArtworkImage {
            id: topArt
            x: 16
            anchors.verticalCenter: parent.verticalCenter
            width: 84
            height: 84
            radius: top.result.kind === "artists" ? 42 : Appearance.sizes.smallArtworkRadius
            circular: top.result.kind === "artists"
            squiggly: false
            source: top.result.artworkUrl ?? ""
        }
        Column {
            anchors.left: topArt.right
            anchors.leftMargin: 16
            anchors.right: topPlay.left
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            StyledText {
                text: "Top Result"
                font.pixelSize: Appearance.fontSize.smaller
                font.weight: Font.DemiBold
                color: Appearance.colors.primary
            }
            TitleText {
                width: parent.width
                text: top.result.name ?? ""
                elide: Text.ElideRight
                font.pixelSize: Appearance.fontSize.headline
                font.weight: Font.Bold
            }
            StyledText {
                width: parent.width
                text: top.result.subtitle ?? ""
                elide: Text.ElideRight
                color: Appearance.colors.onSurfaceVariant
            }
        }
        PlayButton {
            id: topPlay
            anchors.right: parent.right
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: 48
            implicitHeight: 48
            visible: top.result.kind !== "albums"
            // playing only when it is the song playing, not whatever plays
            playing: Player.playing && top.result.kind === "songs" && Player.currentSong.uri === top.result.song.uri
            opacity: topHover.hovered || playing ? 1 : 0.0
            color: Appearance.colors.primary
            hoverColor: Appearance.colors.primaryHover
            iconColor: Appearance.colors.onPrimary
            onClicked: top.play()

            Behavior on opacity {
                NumberAnimation { duration: Appearance.duration(140) }
            }
        }

        HoverHandler {
            id: topHover
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            onTapped: (point) => {
                if (topPlay.visible && topPlay.contains(topPlay.mapFromItem(top, point.position))) {
                    top.play()
                } else {
                    top.open()
                }
            }
        }
    }

    Component {
        id: songsSection

        Column {
            // filtered to songs, the chip says what they are
            topPadding: root.filter === "all" ? 28 : 0

            TitleText {
                x: root.margin
                visible: root.filter === "all"
                bottomPadding: 10
                text: "Songs"
                font.pixelSize: Appearance.fontSize.title
                font.weight: Font.Bold
            }
            Repeater {
                model: Library.searchSongs

                SongRow {
                    x: root.margin
                    width: root.width - 2 * root.margin
                    songs: Library.searchSongs
                    showsNumber: false
                    fromSearch: true
                }
            }
        }
    }

    // one kind filtered to: all of its results as a grid, as spotify's
    Component {
        id: gridSection

        Flow {
            id: grid
            readonly property var model: root.filter === "albums" ? Library.searchAlbums
                                       : root.filter === "artists" ? Library.searchArtists : Library.searchPlaylists
            x: root.margin
            width: root.width - 2 * root.margin
            spacing: Appearance.sizes.shelfGap

            Repeater {
                model: grid.model

                MediaCard {
                    required property int index
                    readonly property album album: root.filter === "albums" ? Library.searchAlbums.at(index) : Library.searchAlbums.at(-1)
                    readonly property artist artist: root.filter === "artists" ? Library.searchArtists.at(index) : Library.searchArtists.at(-1)
                    readonly property playlist playlist: root.filter === "playlists" ? Library.searchPlaylists.at(index) : Library.searchPlaylists.at(-1)
                    artworkUrl: root.filter === "albums" ? album.artworkUrl : root.filter === "artists" ? artist.artworkUrl : playlist.artworkUrl
                    title: root.filter === "albums" ? album.name : root.filter === "artists" ? artist.name : playlist.name
                    subtitle: root.filter === "albums" ? album.artists : root.filter === "artists" ? "Artist" : playlist.ownerDisplayName
                    circular: root.filter === "artists"
                    onClicked: {
                        switch (root.filter) {
                        case "albums": Library.selectAlbum(album); break
                        case "artists": Library.selectArtist(artist); break
                        default: Library.selectPlaylist(playlist); break
                        }
                    }
                }
            }
        }
    }

    Component {
        id: albumsSection

        Shelf {
            onScreen: root.reaches(column.y + results.y + parent.y, height, 0)
            nearScreen: root.reaches(column.y + results.y + parent.y, height, root.height / 2)
            topPadding: 28
            title: "Albums"
            symbol: "album"
            iconShape: "sunny"
            model: Library.searchAlbums
            delegate: MediaCard {
                required property album album
                artworkUrl: album.artworkUrl
                title: album.name
                subtitle: album.artists
                onClicked: Library.selectAlbum(album)
            }
        }
    }

    Component {
        id: artistsSection

        Shelf {
            onScreen: root.reaches(column.y + results.y + parent.y, height, 0)
            nearScreen: root.reaches(column.y + results.y + parent.y, height, root.height / 2)
            topPadding: 28
            title: "Artists"
            symbol: "person"
            iconShape: "cookie12"
            model: Library.searchArtists
            delegate: MediaCard {
                required property artist artist
                artworkUrl: artist.artworkUrl
                title: artist.name
                circular: true
                titleLines: 1
                badgeSymbol: "chevron_right"
                onClicked: Library.selectArtist(artist)
            }
        }
    }

    Component {
        id: playlistsSection

        Shelf {
            onScreen: root.reaches(column.y + results.y + parent.y, height, 0)
            nearScreen: root.reaches(column.y + results.y + parent.y, height, root.height / 2)
            topPadding: 28
            title: "Playlists"
            symbol: "queue_music"
            iconShape: "bun"
            model: Library.searchPlaylists
            delegate: MediaCard {
                required property playlist playlist
                artworkUrl: playlist.artworkUrl
                title: playlist.name
                subtitle: playlist.ownerDisplayName
                onClicked: Library.selectPlaylist(playlist)
            }
        }
    }
}
