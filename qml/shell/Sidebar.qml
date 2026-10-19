pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import Swiftify

// the navigation drawer (MusicSidebar): home and the search field (with the
// recent searches under it while it is empty), then the library as spotify's
// sidebar lists it, favourite songs first, then pinned playlists, then
// playlists and followed artists together, each with its cover and what it
// is. filter chips narrow it to playlists or artists. the list is
// virtualized, so a library of hundreds costs only the rows on screen.
Item {
    id: root

    property playlist menuPlaylist
    readonly property bool menuPlaylistEditable: menuPlaylist.isLocal || menuPlaylist.isCollaborative
        || (Library.profileId.length > 0 && menuPlaylist.ownerId === Library.profileId)

    /// "" for everything, or "playlists" or "artists"
    property string kind: ""
    /// a to z, or as spotify keeps them (playlists, then artists)
    property bool alphabetical: false

    /// the rows, in order: { type, index, name, pinned } with type "liked",
    /// "local", "playlist" (index into Library.playlists) or "artist" (into
    /// Library.followedArtists)
    readonly property var entries: {
        // read so the list follows the pins
        Library.pinsRevision
        const playlistCount = Library.playlists.count
        const artistCount = Library.followedArtists.count

        const rows = []
        if (kind !== "artists") {
            rows.push({ type: "liked", index: -1, name: "Favourite Songs", pinned: true })
        }
        const rest = []
        if (kind !== "artists") {
            for (let index = 0; index < playlistCount; ++index) {
                const playlist = Library.playlists.at(index)
                const row = { type: "playlist", index: index, name: playlist.name, pinned: Library.isPinned(playlist.id), recency: playlist.recency }
                if (row.pinned) {
                    rows.push(row)
                } else {
                    rest.push(row)
                }
            }
        }
        if (kind !== "playlists") {
            for (let index = 0; index < artistCount; ++index) {
                const artist = Library.followedArtists.at(index)
                rest.push({ type: "artist", index: index, name: artist.name, pinned: false, recency: artist.recency })
            }
        }
        // a to z, or spotify's recents: playlists and artists together, the
        // one played or added last first
        if (alphabetical) {
            rest.sort((a, b) => a.name.localeCompare(b.name))
        } else {
            rest.sort((a, b) => b.recency - a.recency)
        }
        return rows.concat(rest)
    }

    function focusSearch() {
        search.focusField()
    }

    function setKind(next: string) {
        kind = kind === next ? "" : next
    }

    // home and search, above the library, unless the top bar has them
    Column {
        id: top
        visible: !Settings.centeredSearch
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        topPadding: 8
        spacing: 8

        NavigationItem {
            x: 10
            width: parent.width - 20
            text: "Home"
            symbol: "home"
            selected: Library.page === Library.Page.Home
            onClicked: Library.showHome()
        }
        // as wide and tall as home above it, so the two read as one column
        Item {
            x: 10
            width: parent.width - 20
            height: 40

            SearchField {
                id: search
                objectName: "sidebarSearch"
                anchors.fill: parent
                placeholder: "Search"
                text: Library.searchQuery
                onTextChanged: {
                    if (Library.searchQuery !== text) {
                        Library.searchQuery = text
                    }
                    if (text.trim().length > 0 && Library.page !== Library.Page.Search) {
                        Library.showSearch()
                    } else if (text.trim().length === 0 && Library.page === Library.Page.Search) {
                        // no empty search page: back to what was open before
                        Library.canGoBack ? Library.goBack() : Library.showHome()
                    }
                }
            }
        }
    }

    // the library's head: its name, the sort, a new playlist, the chips and the filter
    Column {
        id: head
        anchors.left: parent.left
        anchors.right: parent.right
        // right at the top while home and search are in the top bar
        anchors.top: Settings.centeredSearch ? parent.top : top.bottom
        anchors.topMargin: Settings.centeredSearch ? 4 : 10
        spacing: 8

        Item {
            width: parent.width
            height: 32

            StyledText {
                x: 16
                anchors.verticalCenter: parent.verticalCenter
                text: "Your Library"
                font.weight: Font.Bold
                font.pixelSize: Appearance.fontSize.large
            }
            Row {
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                IconButton {
                    symbol: root.alphabetical ? "sort_by_alpha" : "sort"
                    size: 32
                    iconSize: 20
                    tooltip: root.alphabetical ? "Sorted A to Z" : "Sorted as in Spotify"
                    onClicked: root.alphabetical = !root.alphabetical
                }
                IconButton {
                    symbol: "add"
                    size: 32
                    iconSize: 20
                    iconColor: Appearance.colors.primary
                    tooltip: "New playlist"
                    onClicked: UiState.beginCreatePlaylist()
                }
            }
        }

        Row {
            x: 12
            spacing: 6

            FilterChip {
                text: "Playlists"
                checked: root.kind === "playlists"
                onClicked: root.setKind("playlists")
            }
            FilterChip {
                text: "Artists"
                checked: root.kind === "artists"
                onClicked: root.setKind("artists")
            }
        }

    }

    ListView {
        id: list
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: head.bottom
        // as far below the chips as the chips are below the title's text
        // (its 32 px row leaves 5 px under the text, plus the column's 8)
        anchors.topMargin: 13
        anchors.bottom: settingsButton.top
        anchors.bottomMargin: 6
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.entries
        ScrollBar.vertical: StyledScrollBar {}

        delegate: LibraryRow {
            required property var modelData
            width: list.width
            entry: modelData
        }

        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 12
            visible: root.entries.length === 0
            text: "Nothing here yet"
            font.pixelSize: Appearance.fontSize.smaller
            color: Appearance.colors.onSurfaceVariant
        }
    }

    // the recent searches, under the field while it is focused and empty
    RecentSearches {
        // level with the field: it sits in a row inset like Home's
        x: search.parent.x + search.x
        y: top.y + search.parent.y + search.y + search.height + 6
        width: search.width
        field: search
        focusTarget: root
    }

    // a library row: a cover (round for an artist), the name, and what it is
    component LibraryRow: Item {
        id: row

        property var entry
        readonly property bool isPlaylist: entry.type === "playlist"
        readonly property bool isArtist: entry.type === "artist"
        readonly property playlist playlist: Library.playlists.at(isPlaylist ? entry.index : -1)
        readonly property artist artist: Library.followedArtists.at(isArtist ? entry.index : -1)
        readonly property bool selected: {
            switch (entry.type) {
            case "liked": return Library.page === Library.Page.Songs
            case "local": return Library.page === Library.Page.LocalFiles || Library.page === Library.Page.LocalTracks
            case "playlist": return Library.page === Library.Page.Playlist && Library.selectedPlaylistId === playlist.id
            case "artist": return Library.page === Library.Page.Artist && Library.currentArtist.id === artist.id
            }
            return false
        }

        function open() {
            // the dj has no page of its own: it plays, as in spotify
            if (isPlaylist && playlist.isDj) {
                play()
                return
            }
            switch (entry.type) {
            case "liked": Library.showSavedSongs(); break
            case "local": Library.showLocalFiles(); break
            case "playlist": Library.selectPlaylist(playlist); break
            case "artist": Library.selectArtist(artist); break
            }
        }

        function play() {
            switch (entry.type) {
            case "liked": Player.playFromModel(Library.savedSongs, 0); break
            case "local": Player.playFromModel(LocalFiles.songs, 0); break
            case "playlist": Library.playPlaylist(playlist); break
            case "artist": Library.playArtist(artist); break
            }
        }

        // spotify's compact layout: smaller rows and covers
        readonly property real coverSize: Settings.compactLibrary ? 32 : 44
        height: Settings.compactLibrary ? 44 : 60

        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 6
            anchors.rightMargin: 6
            radius: 8
            color: row.selected ? Appearance.colors.secondaryContainer
                 : hover.hovered ? Appearance.colors.surfaceContainerHigh : "transparent"

            Behavior on color {
                ElementMoveFastColor {}
            }
        }

        // favourite songs and local files have covers of their own
        Rectangle {
            x: 14
            anchors.verticalCenter: parent.verticalCenter
            visible: !row.isPlaylist && !row.isArtist
            width: row.coverSize
            height: row.coverSize
            radius: 6
            gradient: Gradient {
                GradientStop { position: 0; color: row.entry.type === "liked" ? "#4a2bd6" : Appearance.colors.tertiaryContainer }
                GradientStop { position: 1; color: row.entry.type === "liked" ? "#8fc1d4" : Appearance.colors.secondaryContainer }
            }

            MaterialSymbol {
                anchors.centerIn: parent
                text: row.entry.type === "liked" ? "favorite" : "folder_open"
                iconSize: 22
                fill: 1
                color: "white"
            }
        }

        ArtworkImage {
            x: 14
            anchors.verticalCenter: parent.verticalCenter
            visible: row.isPlaylist || row.isArtist
            width: row.coverSize
            height: row.coverSize
            radius: 6
            circular: row.isArtist
            squiggly: false
            source: row.isArtist ? row.artist.artworkUrl : row.playlist.artworkUrl
            placeholderSymbol: row.isArtist ? "person" : "queue_music"
        }

        // hovering the row shows a play button over the cover: the cover
        // plays at once, the rest of the row opens the page
        Rectangle {
            id: coverPlay
            x: 14
            anchors.verticalCenter: parent.verticalCenter
            width: row.coverSize
            height: row.coverSize
            radius: row.isArtist ? width / 2 : 6
            color: Qt.rgba(0, 0, 0, coverArea.containsMouse ? 0.55 : 0.4)
            opacity: hover.hovered ? 1 : 0
            visible: opacity > 0

            Behavior on opacity {
                NumberAnimation { duration: Appearance.duration(140); easing.type: Easing.OutCubic }
            }

            MaterialSymbol {
                anchors.centerIn: parent
                text: "play_arrow"
                iconSize: coverArea.containsMouse ? 28 : 24
                fill: 1
                color: "white"

                Behavior on iconSize {
                    NumberAnimation { duration: Appearance.motion(160); easing.type: Easing.OutBack }
                }
            }

            MouseArea {
                id: coverArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: row.play()
            }
        }

        Column {
            anchors.left: parent.left
            anchors.leftMargin: row.coverSize + 26
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            StyledText {
                width: parent.width
                text: row.entry.name
                elide: Text.ElideRight
                font.weight: Font.DemiBold
                color: row.selected ? Appearance.colors.primary : Appearance.colors.onSurface
            }
            Row {
                width: parent.width
                spacing: 4

                MaterialSymbol {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: row.entry.pinned
                    text: "push_pin"
                    iconSize: 13
                    fill: 1
                    color: Appearance.colors.primary
                }
                StyledText {
                    width: parent.width - (row.entry.pinned ? 17 : 0)
                    elide: Text.ElideRight
                    font.pixelSize: Appearance.fontSize.smaller
                    color: Appearance.colors.onSurfaceVariant
                    text: {
                        switch (row.entry.type) {
                        case "liked": return Library.savedSongTotal > 0 ? "Playlist  •  " + Format.songCount(Library.savedSongTotal) : "Playlist"
                        case "local": return "Local  •  " + Format.songCount(LocalFiles.songs.count)
                        case "artist": return "Artist"
                        }
                        const owner = row.playlist.ownerDisplayName
                        return owner.length > 0 ? "Playlist  •  " + owner : "Playlist"
                    }
                }
            }
        }

        HoverHandler {
            id: hover
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            onTapped: if (!coverArea.containsMouse) row.open()
        }
        TapHandler {
            acceptedButtons: Qt.RightButton
            enabled: row.isPlaylist
            onTapped: {
                root.menuPlaylist = row.playlist
                playlistMenu.popupHere()
            }
        }
    }

    MenuLoader {
        id: playlistMenu
        sourceComponent: StyledMenu {
            StyledMenuItem {
                id: pinItem
                readonly property bool pinned: Library.pinsRevision >= 0 && Library.isPinned(root.menuPlaylist.id)
                text: pinned ? "Unpin Playlist" : "Pin Playlist"
                symbol: pinned ? "keep_off" : "keep"
                onTriggered: Library.togglePinned(root.menuPlaylist)
            }
            StyledMenuSeparator {
                visible: root.menuPlaylistEditable
                height: visible ? implicitHeight : 0
            }
            StyledMenuItem {
                visible: root.menuPlaylistEditable
                height: visible ? implicitHeight : 0
                text: "Delete Playlist"
                symbol: "delete"
                destructive: true
                onTriggered: UiState.deletePlaylistRequested(root.menuPlaylist)
            }
        }
    }

    // the settings at the sidebar's foot, the account among them
    NavigationItem {
        id: settingsButton
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 8
        text: "Settings"
        symbol: "settings"
        onClicked: UiState.settingsRequested()
    }
}
