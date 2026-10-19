pragma ComponentBehavior: Bound
import QtQuick
import Swiftify

// sharing, as spotify's share menu, in the app's own menu: the link, the
// spotify uri and the name, each copied to paste wherever. a submenu of a
// song's menu, or a menu of its own under a share button (MenuLoader).
StyledMenu {
    id: root

    /// a spotify uri: spotify:track:..., spotify:playlist:...
    property string uri
    /// what is shared, by name: "Song – Artist", a playlist's name
    property string label
    readonly property string kind: uri.split(":")[1] ?? ""
    readonly property string link: "https://open.spotify.com/" + kind + "/" + uri.split(":").pop()
    readonly property string noun: kind === "playlist" ? "Playlist" : kind === "album" ? "Album" : kind === "artist" ? "Artist" : "Song"

    title: "Share"

    function copied(what: string) {
        UiState.toastRequested(what + " copied")
    }

    StyledMenuItem {
        text: "Copy " + root.noun + " Link"
        symbol: "link"
        onTriggered: {
            App.copyToClipboard(root.link)
            root.copied("Link")
        }
    }
    StyledMenuItem {
        text: "Copy Spotify URI"
        symbol: "tag"
        onTriggered: {
            App.copyToClipboard(root.uri)
            root.copied("Spotify URI")
        }
    }
    StyledMenuItem {
        visible: root.label.length > 0
        height: visible ? implicitHeight : 0
        text: "Copy " + (root.kind === "track" ? "Title and Artist" : "Name")
        symbol: "content_copy"
        onTriggered: {
            App.copyToClipboard(root.label)
            root.copied(root.kind === "track" ? "Title and artist" : "Name")
        }
    }
}
