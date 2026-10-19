pragma ComponentBehavior: Bound
import QtQuick
import Swiftify

// SongOptionsContent, laid out as spotify's song menu: add to a playlist,
// save, queue, remove from the playlist open, the sleep timer, then the
// song's radio, artist and album, and share. one instance per window,
// opened at the pointer. a file of the person's own is nothing spotify
// knows: it queues, shows where it is kept, and goes in playlists made on
// this computer.
StyledMenu {
    id: root

    property song song
    property bool allowsPlaylistRemoval: false
    readonly property bool saved: Library.savedRevision >= 0 && Library.isSaved(song.uri)
    property var editablePlaylists: []
    readonly property bool local: song.isLocalFile

    function openFor(target: song, allowsRemoval: bool) {
        song = target
        allowsPlaylistRemoval = allowsRemoval
        editablePlaylists = target.isLocalFile ? LocalFiles.playlistChoices() : Library.editablePlaylists()
        popup()
    }

    StyledMenu {
        id: addMenu
        title: "Add to Playlist"

        Instantiator {
            model: root.editablePlaylists

            StyledMenuItem {
                id: playlistItem
                required property var modelData
                text: modelData.name
                onTriggered: {
                    UiState.burst(playlistItem, "playlist")
                    Library.addToPlaylist(root.song, playlistItem.modelData)
                }
            }

            onObjectAdded: (index, object) => addMenu.insertItem(index, object as StyledMenuItem)
            onObjectRemoved: (index, object) => addMenu.removeItem(object as StyledMenuItem)
        }

        // spotify's playlists hold spotify's songs, and a file starts a
        // playlist of files
        StyledMenuSeparator {
            visible: root.local && root.editablePlaylists.length > 0
            height: visible ? implicitHeight : 0
        }
        StyledMenuItem {
            visible: root.local
            height: visible ? implicitHeight : 0
            text: "New Playlist…"
            symbol: "add"
            onTriggered: UiState.createLocalPlaylistRequested(root.song)
        }
    }

    // saved, the check is filled in the theme's green, as spotify's is
    StyledMenuItem {
        id: saveItem
        visible: !root.local
        height: visible ? implicitHeight : 0
        text: root.saved ? "Remove from Favourite Songs" : "Save to Favourite Songs"
        symbol: root.saved ? "check_circle" : "add_circle"
        accent: root.saved
        onTriggered: {
            if (!root.saved) {
                UiState.burst(saveItem, "hearts")
            }
            Library.toggleSaved(root.song)
        }
    }
    StyledMenuItem {
        text: "Add to Queue"
        symbol: "playlist_add"
        onTriggered: Player.playLast(root.song)
    }
    StyledMenuItem {
        text: "Play Next"
        symbol: "queue_play_next"
        onTriggered: Player.playNext(root.song)
    }
    StyledMenuItem {
        visible: root.allowsPlaylistRemoval
        height: visible ? implicitHeight : 0
        text: "Remove from this Playlist"
        symbol: "remove_circle_outline"
        destructive: true
        onTriggered: Library.removeFromSelectedPlaylist(root.song)
    }

    StyledMenu {
        id: sleepMenu
        title: "Sleep Timer"

        Repeater {
            model: [5, 15, 30, 45, 60]

            StyledMenuItem {
                required property int modelData
                text: modelData + " minutes"
                onTriggered: Player.startSleepTimer(modelData * 60, "finalSeconds")
            }
        }
        StyledMenuSeparator {
            visible: Player.sleepTimerRunning
            height: visible ? implicitHeight : 0
        }
        StyledMenuItem {
            visible: Player.sleepTimerRunning
            height: visible ? implicitHeight : 0
            text: "Turn Off Timer"
            symbol: "timer_off"
            onTriggered: Player.cancelSleepTimer()
        }
    }

    StyledMenuSeparator {}
    StyledMenuItem {
        visible: !root.local
        height: visible ? implicitHeight : 0
        text: "Go to Song Radio"
        symbol: "sensors"
        onTriggered: Library.showRadio(root.song)
    }
    StyledMenuItem {
        visible: !root.local && root.song.artists.length > 0
        height: visible ? implicitHeight : 0
        text: "Go to Artist"
        symbol: "person"
        onTriggered: UiState.goToArtist(root.song)
    }
    StyledMenuItem {
        visible: !root.local && root.song.albumName.length > 0
        height: visible ? implicitHeight : 0
        text: "Go to Album"
        symbol: "album"
        onTriggered: UiState.goToAlbum(root.song)
    }

    // a file of the person's own: its tags and its folder
    StyledMenuItem {
        visible: root.local
        height: visible ? implicitHeight : 0
        text: "Edit Info…"
        symbol: "edit_note"
        onTriggered: UiState.editLocalTrackRequested(root.song)
    }
    StyledMenuItem {
        visible: root.local
        height: visible ? implicitHeight : 0
        text: App.macOS ? "Show in Finder" : "Show in Folder"
        symbol: "folder_open"
        onTriggered: App.openUrl(root.song.uri.substring(0, root.song.uri.lastIndexOf("/")))
    }

    StyledMenuSeparator {
        visible: !root.local
        height: visible ? implicitHeight : 0
    }
    ShareMenu {
        // a submenu only spotify's songs have
        enabled: !root.local
        uri: root.local ? "" : root.song.uri
        label: root.song.name + " – " + root.song.artists
    }
}
