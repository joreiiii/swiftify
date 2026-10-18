pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Swiftify

// the bar over the page: the open playlist's actions and its find field. it
// has no background: the pages scroll up under it, and each button sits on a
// shape of its own. back, the playback menu and search are in the window's
// top bar and the sidebar.
Item {
    id: root

    property Item backdropSource
    readonly property bool onPlaylist: Library.page === Library.Page.Playlist && Library.selectedPlaylist.valid
    readonly property bool compact: width < 600
    readonly property real buttonSize: width < 420 ? 26 : (compact ? 34 : 46)
    readonly property real searchLeftEdge: 12
    readonly property real searchRightEdge: rightControls.x - 8
    // Reserve the collapsed field's space even while its overlay is focused.
    readonly property real reservedSearchWidth: Math.max(40, Math.min(340, searchRightEdge - searchLeftEdge - (onPlaylist ? playlistActions.implicitWidth + 8 : 0)))
    readonly property string playlistLink: "https://open.spotify.com/playlist/" + Library.selectedPlaylist.id

    function focusSearch() {
        if (search.visible) {
            search.focusField();
        }
    }

    implicitHeight: Appearance.sizes.topBarHeight

    Item {
        id: toolbarButtons
        anchors.fill: parent

        Item {
            id: rightControls
            anchors.right: parent.right
            anchors.rightMargin: 4
            width: 0
            height: parent.height
        }

        Row {
            id: playlistActions
            objectName: "playlistActions"
            x: root.searchRightEdge - root.reservedSearchWidth - 8 - width
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.compact ? 0 : 2
            Reveal.shown: root.onPlaylist

            ToolbarButton {
                effect: ToolbarButton.Spin
                size: root.buttonSize
                iconSize: root.compact ? 19 : 26
                shape: "circle"
                symbol: "add"
                onClicked: Library.selectedPlaylist.isLocal ? UiState.createLocalPlaylistRequested(null) : UiState.beginCreatePlaylist()
                tooltip: "New Playlist"
            }
            ToolbarButton {
                effect: ToolbarButton.Pop
                Reveal.shown: Library.selectedPlaylistEditable
                size: root.buttonSize
                iconSize: root.compact ? 19 : 26
                shape: "circle"
                symbol: "edit"
                onClicked: UiState.editPlaylistRequested()
                tooltip: "Edit Playlist"
            }
            ToolbarButton {
                effect: ToolbarButton.Pop
                Reveal.shown: !Library.selectedPlaylist.isLocal
                size: root.buttonSize
                iconSize: root.compact ? 19 : 26
                shape: "circle"
                symbol: "ios_share"
                onClicked: {
                    if (App.share(root.Window.window, Library.selectedPlaylist.name, root.playlistLink)) {
                        UiState.toastRequested("Playlist link copied");
                    }
                }
                tooltip: "Share"
            }
            ToolbarButton {
                id: more
                effect: ToolbarButton.Pop
                size: root.buttonSize
                iconSize: root.compact ? 19 : 26
                shape: "circle"
                symbol: "more_horiz"
                onClicked: moreMenu.popupAt(more, 0, more.height)
                tooltip: "More"
            }
            ToolbarButton {
                id: sort
                effect: ToolbarButton.Pop
                size: root.buttonSize
                iconSize: root.compact ? 19 : 26
                shape: "circle"
                symbol: "sort"
                onClicked: sortMenu.popupAt(sort, 0, sort.height)
                tooltip: "Sort Options"
            }
        }
    }

    Rectangle {
        id: searchMask
        width: search.width
        height: search.height
        radius: height / 2
        layer.enabled: true
        visible: false
    }

    Item {
        id: searchBlur
        anchors.left: search.left
        anchors.right: search.right
        anchors.top: search.top
        anchors.bottom: search.bottom
        z: 8
        visible: search.editing && !!root.backdropSource

        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: Appearance.colors.layer1
        }

        ShaderEffectSource {
            id: searchBackdrop
            anchors.fill: parent
            sourceItem: root.backdropSource
            live: searchBlur.visible
            hideSource: false
            sourceRect: {
                const origin = root.mapToItem(root.backdropSource, search.x, search.y);
                return Qt.rect(origin.x, origin.y, search.width, search.height);
            }
            textureSize: Qt.size(Math.max(1, Math.ceil(search.width)), Math.max(1, Math.ceil(search.height)))
            visible: false
        }
        MultiEffect {
            anchors.fill: parent
            source: searchBackdrop
            blurEnabled: true
            blur: 0.8
            blurMax: 48
            maskEnabled: true
            maskSource: searchMask
        }
        // Capture only the buttons, so the field never samples itself.
        ShaderEffectSource {
            id: buttonBackdrop
            anchors.fill: parent
            sourceItem: toolbarButtons
            sourceRect: Qt.rect(search.x, search.y, search.width, search.height)
            live: searchBlur.visible
            hideSource: false
            visible: false
        }
        MultiEffect {
            anchors.fill: parent
            source: buttonBackdrop
            blurEnabled: true
            blur: 0.8
            blurMax: 48
            maskEnabled: true
            maskSource: searchMask
        }
        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: Qt.alpha(Appearance.colors.surfaceContainerHighest, 0.18)
        }
    }

    SearchField {
        id: search
        objectName: "toolbarSearch"
        x: root.searchRightEdge - width
        anchors.verticalCenter: parent.verticalCenter
        z: editing ? 9 : 0
        Reveal.shown: root.onPlaylist
        width: {
            if (!visible)
                return 0;
            return editing ? Math.max(40, Math.min(340, root.searchRightEdge - root.searchLeftEdge)) : root.reservedSearchWidth;
        }
        placeholder: "Find in Playlist"
        text: Library.playlistFilterQuery
        onTextChanged: if (root.onPlaylist) Library.playlistFilterQuery = text

        Behavior on width {
            ElementMoveSmall {}
        }
    }

    MusicPicker {
        id: trackPicker
        playlistId: Library.selectedPlaylist.isLocal ? Library.selectedPlaylist.id : ""
    }

    MenuLoader {
        id: moreMenu
        sourceComponent: StyledMenu {
            StyledMenuItem {
                text: "New Playlist"
                symbol: "add"
                onTriggered: Library.selectedPlaylist.isLocal ? UiState.createLocalPlaylistRequested(null) : UiState.beginCreatePlaylist()
            }
            StyledMenuItem {
                visible: Library.selectedPlaylistEditable
                height: visible ? implicitHeight : 0
                text: "Edit Playlist"
                symbol: "edit"
                onTriggered: UiState.editPlaylistRequested()
            }
            StyledMenuItem {
                visible: Library.selectedPlaylist.isLocal
                height: visible ? implicitHeight : 0
                text: "Add Tracks…"
                symbol: "playlist_add"
                onTriggered: trackPicker.pickFiles()
            }
            StyledMenuItem {
                visible: Library.selectedPlaylist.isLocal
                height: visible ? implicitHeight : 0
                text: "Add a Folder…"
                symbol: "create_new_folder"
                onTriggered: trackPicker.pickFolder()
            }
            StyledMenuItem {
                visible: !Library.selectedPlaylist.isLocal
                height: visible ? implicitHeight : 0
                text: "Share"
                symbol: "ios_share"
                onTriggered: {
                    if (App.share(root.Window.window, Library.selectedPlaylist.name, root.playlistLink)) {
                        UiState.toastRequested("Playlist link copied");
                    }
                }
            }
            StyledMenuSeparator {
                visible: Library.selectedPlaylistEditable
                height: visible ? implicitHeight : 0
            }
            StyledMenuItem {
                visible: Library.selectedPlaylistEditable
                height: visible ? implicitHeight : 0
                text: "Delete Playlist"
                symbol: "delete"
                destructive: true
                onTriggered: UiState.deletePlaylistRequested(Library.selectedPlaylist)
            }
        }
    }

    MenuLoader {
        id: sortMenu
        sourceComponent: StyledMenu {
            Repeater {
                model: [
                    {
                        label: "Playlist Order",
                        order: Library.SortOrder.Playlist
                    },
                    {
                        label: "Title",
                        order: Library.SortOrder.Title
                    },
                    {
                        label: "Artist",
                        order: Library.SortOrder.Artist
                    },
                    {
                        label: "Album",
                        order: Library.SortOrder.Album
                    },
                    {
                        label: "Time",
                        order: Library.SortOrder.Duration
                    }
                ]

                StyledMenuItem {
                    required property var modelData
                    text: modelData.label
                    checkmark: true
                    checked: Library.playlistSortOrder === modelData.order
                    onTriggered: Library.playlistSortOrder = modelData.order
                }
            }
        }
    }
}
