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
        if (kind !== "artists" && LocalFiles.songs.count > 0) {
            rows.push({ type: "local", index: -1, name: "Local Files", pinned: true })
        }
        const rest = []
        if (kind !== "artists") {
            for (let index = 0; index < playlistCount; ++index) {
                const playlist = Library.playlists.at(index)
                const row = { type: "playlist", index: index, name: playlist.name, pinned: Library.isPinned(playlist.id) }
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
                rest.push({ type: "artist", index: index, name: artist.name, pinned: false })
            }
        }
        if (alphabetical) {
            rest.sort((a, b) => a.name.localeCompare(b.name))
        }
        return rows.concat(rest)
    }

    function focusSearch() {
        search.focusField()
    }

    function setKind(next: string) {
        kind = kind === next ? "" : next
    }

    // home and search, above the library
    Column {
        id: top
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
        anchors.top: top.bottom
        anchors.topMargin: 10
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
    Rectangle {
        id: recent
        objectName: "recentSearches"
        x: search.x
        y: top.y + search.parent.y + search.y + search.height + 6
        z: 20
        width: search.width
        height: recentColumn.implicitHeight + 16
        radius: 12
        color: Appearance.colors.surfaceContainerHigh
        border.width: 1
        border.color: Appearance.colors.outlineVariant
        visible: search.editing && search.text.length === 0 && Library.searchHistoryPreview.count > 0

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
                    TapHandler {
                        onTapped: {
                            Player.playSong(row.song)
                            root.forceActiveFocus()
                        }
                    }
                }
            }
        }
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
            switch (entry.type) {
            case "liked": Library.showSavedSongs(); break
            case "local": Library.showLocalFiles(); break
            case "playlist": Library.selectPlaylist(playlist); break
            case "artist": Library.selectArtist(artist); break
            }
        }

        height: 60

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
            width: 44
            height: 44
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
            width: 44
            height: 44
            radius: 6
            circular: row.isArtist
            squiggly: false
            source: row.isArtist ? row.artist.artworkUrl : row.playlist.artworkUrl
            placeholderSymbol: row.isArtist ? "person" : "queue_music"
        }

        Column {
            anchors.left: parent.left
            anchors.leftMargin: 70
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
            onTapped: row.open()
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
