pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Templates as T
import Swiftify

// the bar across the top of the window, as spotify's: the playback menu and
// back on the left, what's new, friend activity and the account on the
// right, then the window's own buttons. its empty stretches are the
// window's title bar (WindowsIntegration).
Item {
    id: root

    required property Window window
    property bool showWindowControls: true

    objectName: "windowCaption"
    implicitHeight: 64

    // where windows has no title bar of its own to move the window by
    DragHandler {
        target: null
        grabPermissions: PointerHandler.CanTakeOverFromAnything
        onActiveChanged: if (active) root.window.startSystemMove()
    }
    TapHandler {
        acceptedButtons: Qt.LeftButton
        onDoubleTapped: App.toggleMaximized(root.window)
    }

    // --- left: the playback menu and back ---------------------------------------------

    Row {
        id: left
        anchors.left: parent.left
        anchors.leftMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        spacing: 4

        // the window's buttons on the left, close first, unless the
        // settings put them on the right
        WindowControls {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.showWindowControls && !Settings.windowControlsOnRight
            compact: true
            window: root.window
            layoutDirection: Qt.LeftToRight
        }
        Item {
            visible: root.showWindowControls && !Settings.windowControlsOnRight
            width: 8
            height: 1
        }
        ToolbarButton {
            id: overflow
            size: 36
            iconSize: 20
            symbol: "more_horiz"
            tooltip: "Playback"
            onClicked: playbackMenu.popupAt(overflow, 0, overflow.height)
        }
        ToolbarButton {
            size: 36
            iconSize: 20
            effect: ToolbarButton.NudgeLeft
            turnsOnHover: false
            symbol: "arrow_back"
            enabled: Library.canGoBack
            tooltip: "Go back"
            onClicked: Library.goBack()
        }
    }

    // --- middle: home and search, as spotify has them (Settings.centeredSearch) ----------

    function focusSearch() {
        centerSearch.focusField()
    }

    // leaving search for any other page clears it, as spotify's does; both
    // search fields follow Library.searchQuery
    Connections {
        target: Library
        function onDestinationChanged() {
            if (Library.page !== Library.Page.Search && Library.searchQuery.length > 0) {
                Library.searchQuery = ""
            }
        }
    }

    Row {
        id: middle
        visible: Settings.centeredSearch
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        spacing: 8

        // a round home, filled while home is open
        AbstractButton {
            id: homeButton
            anchors.verticalCenter: parent.verticalCenter
            width: 40
            height: 40
            hoverEnabled: true
            onClicked: Library.showHome()

            background: Rectangle {
                radius: width / 2
                color: homeButton.hovered ? Appearance.colors.surfaceContainerHighest : Appearance.colors.surfaceContainerHigh
                scale: homeButton.hovered ? 1.04 : 1

                Behavior on color {
                    ElementMoveFastColor {}
                }
                Behavior on scale {
                    NumberAnimation { duration: Appearance.motion(160); easing.type: Easing.OutCubic }
                }
            }
            contentItem: Item {
                MaterialSymbol {
                    anchors.centerIn: parent
                    text: "home"
                    iconSize: 24
                    fill: Library.page === Library.Page.Home ? 1 : 0
                    color: Library.page === Library.Page.Home ? Appearance.colors.onSurface : Appearance.colors.onSurfaceVariant
                }
            }

            StyledToolTip {
                visible: homeButton.hovered
                text: "Home"
            }
        }

        SearchField {
            id: centerSearch
            objectName: "topBarSearch"
            anchors.verticalCenter: parent.verticalCenter
            // as wide as fits between the bar's two ends, up to spotify's
            width: Math.max(200, Math.min(480, root.width - 2 * Math.max(left.width, right.width) - 120))
            height: 40
            placeholder: "What do you want to play?"
            text: Library.searchQuery
            trailingInset: 44

            // spotify's browse: search's categories, with nothing typed
            Rectangle {
                anchors.right: parent.right
                anchors.rightMargin: 44
                anchors.verticalCenter: parent.verticalCenter
                width: 1
                height: 22
                color: Appearance.colors.outlineVariant
            }
            IconButton {
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                symbol: "inventory_2"
                size: 32
                iconSize: 20
                toggled: Library.page === Library.Page.Search && Library.searchQuery.length === 0
                tooltip: "Browse"
                onClicked: {
                    Library.searchQuery = ""
                    Library.showSearch()
                }
            }
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

    RecentSearches {
        x: middle.x + centerSearch.x
        y: middle.y + centerSearch.y + centerSearch.height + 6
        width: centerSearch.width
        field: centerSearch
        focusTarget: root
    }

    // --- right: what's new, friends, the account, the window ---------------------------------

    Row {
        id: right
        anchors.right: parent.right
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6

        ToolbarButton {
            id: bell
            anchors.verticalCenter: parent.verticalCenter
            size: 36
            iconSize: 20
            symbol: "notifications"
            tooltip: "What's New"
            onClicked: {
                Library.loadNewReleases()
                newsPopup.open()
            }
        }
        ToolbarButton {
            id: friends
            visible: Settings.showFriendActivity
            anchors.verticalCenter: parent.verticalCenter
            size: 36
            iconSize: 20
            symbol: "group"
            tooltip: "Friend Activity"
            onClicked: {
                Library.loadFriendActivity()
                friendsPopup.open()
            }
        }

        // the account: its picture, or its initial
        AbstractButton {
            id: account
            anchors.verticalCenter: parent.verticalCenter
            width: 40
            height: 40
            hoverEnabled: true
            onClicked: accountMenu.popupAt(account, account.width - 220, account.height + 4)

            background: Rectangle {
                radius: width / 2
                color: Appearance.colors.surfaceContainerHigh
                border.width: account.hovered ? 2 : 0
                border.color: Appearance.colors.onSurface
            }
            contentItem: Item {
                Rectangle {
                    anchors.centerIn: parent
                    width: 30
                    height: 30
                    radius: 15
                    color: Appearance.colors.tertiary
                    visible: !avatar.ready

                    StyledText {
                        anchors.centerIn: parent
                        text: Library.profileName.length > 0 ? Library.profileName.charAt(0).toUpperCase() : "?"
                        font.weight: Font.Bold
                        color: Appearance.colors.onTertiary
                    }
                }
                ArtworkImage {
                    id: avatar
                    anchors.centerIn: parent
                    width: 30
                    height: 30
                    circular: true
                    squiggly: false
                    visible: Library.profileArtworkUrl.toString().length > 0
                    source: Library.profileArtworkUrl
                }
            }

            HoverHandler {
                cursorShape: Qt.PointingHandCursor
            }
            StyledToolTip {
                visible: account.hovered
                text: Library.profileName.length > 0 ? Library.profileName : "Account"
            }
        }

        WindowControls {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.showWindowControls && Settings.windowControlsOnRight
            compact: true
            window: root.window
            // close at the far right, as windows has it
            layoutDirection: Qt.RightToLeft
        }
    }

    MenuLoader {
        id: playbackMenu
        sourceComponent: PlaybackMenu {}
    }

    MenuLoader {
        id: accountMenu
        sourceComponent: StyledMenu {
            StyledMenuItem {
                text: "Profile"
                symbol: "person"
                onTriggered: Library.showProfile()
            }
            StyledMenuItem {
                text: "Settings"
                symbol: "settings"
                onTriggered: UiState.settingsRequested()
            }
            StyledMenuSeparator {}
            StyledMenuItem {
                text: "Log out"
                symbol: "logout"
                destructive: true
                onTriggered: Session.logOut()
            }
        }
    }

    // what's new: the newest releases of the artists the person follows
    ListPopup {
        id: newsPopup
        anchor: bell
        title: "What's New"
        loading: Library.loadingNewReleases
        emptyText: Library.newReleasesMessage.length > 0 ? Library.newReleasesMessage
                 : Library.followedArtists.count === 0
                   ? "Follow artists to see their new releases here."
                   : "Nothing new from the artists you follow in the last four weeks."
        model: Library.newReleases.count

        delegate: ListRow {
            required property int index
            readonly property album album: Library.newReleases.at(index)
            artworkUrl: album.artworkUrl
            title: album.name
            subtitle: album.artists + "  •  " + album.releaseDate
            onActivated: {
                newsPopup.close()
                Library.selectAlbum(album)
            }
        }
    }

    // friend activity: what the people the person follows are listening to
    ListPopup {
        id: friendsPopup
        anchor: friends
        title: "Friend Activity"
        loading: Library.loadingFriendActivity
        emptyText: Library.friendActivityMessage.length > 0
                   ? Library.friendActivityMessage
                   : "Follow friends on Spotify to see what they're listening to."
        model: Library.friendActivity.length

        delegate: ListRow {
            required property int index
            readonly property var friend: Library.friendActivity[index]
            artworkUrl: friend.imageUrl
            circular: true
            title: friend.name
            subtitle: friend.track + "  •  " + friend.artist
            trailing: Format.timeAgo(friend.timestamp)
            onActivated: {
                friendsPopup.close()
                Library.playTrackUri(friend.trackUri)
            }
        }
    }

    // a popup of rows under one of the bar's buttons
    component ListPopup: T.Popup {
        id: popup

        property Item anchor
        property string title
        property bool loading: false
        property string emptyText
        property alias model: rows.model
        property alias delegate: rows.delegate

        // under the button, right edges level. placed in the bar, not in the
        // button, whose hover and press scaling would carry the popup along
        // and make it jump as the pointer leaves the button
        parent: root
        width: 340
        transformOrigin: Item.TopRight
        onAboutToShow: {
            const corner = anchor.parent.mapToItem(root, anchor.x + anchor.width, anchor.y + anchor.height)
            x = corner.x - width
            y = corner.y + 8
        }
        height: Math.min(460, content.implicitHeight + 16)
        padding: 8
        modal: false
        focus: true
        closePolicy: T.Popup.CloseOnEscape | T.Popup.CloseOnPressOutside

        // it grows out of its button's corner, as the menus fade in
        enter: Transition {
            ParallelAnimation {
                NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Appearance.duration(160); easing.type: Easing.OutCubic }
                NumberAnimation { property: "scale"; from: 0.92; to: 1; duration: Appearance.motion(260); easing.type: Easing.OutBack; easing.overshoot: 1.4 }
            }
        }
        exit: Transition {
            ParallelAnimation {
                NumberAnimation { property: "opacity"; to: 0; duration: Appearance.duration(110) }
                NumberAnimation { property: "scale"; to: 0.96; duration: Appearance.duration(110) }
            }
        }

        background: Rectangle {
            radius: 12
            color: Appearance.colors.surfaceContainerHigh
            border.width: 1
            border.color: Appearance.colors.outlineVariant
        }

        contentItem: Flickable {
            clip: true
            contentHeight: content.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: content
                width: parent.width

                StyledText {
                    leftPadding: 8
                    height: 36
                    verticalAlignment: Text.AlignVCenter
                    text: popup.title
                    font.weight: Font.Bold
                    font.pixelSize: Appearance.fontSize.normal
                }
                StyledText {
                    width: parent.width
                    leftPadding: 8
                    rightPadding: 8
                    bottomPadding: 8
                    visible: popup.loading || rows.count === 0
                    wrapMode: Text.WordWrap
                    text: popup.loading ? "Loading…" : popup.emptyText
                    color: Appearance.colors.onSurfaceVariant
                    font.pixelSize: Appearance.fontSize.smaller
                }
                Repeater {
                    id: rows
                }
            }
        }
    }

    component ListRow: Item {
        id: listRow

        property url artworkUrl
        property bool circular: false
        property string title
        property string subtitle
        property string trailing
        signal activated()

        width: parent ? parent.width : 0
        height: 60

        Rectangle {
            anchors.fill: parent
            radius: 8
            color: hover.hovered ? Appearance.colors.surfaceContainerHighest : "transparent"
        }
        ArtworkImage {
            x: 8
            anchors.verticalCenter: parent.verticalCenter
            width: 44
            height: 44
            radius: 4
            circular: listRow.circular
            squiggly: false
            source: listRow.artworkUrl
            placeholderSymbol: listRow.circular ? "person" : "album"
        }
        Column {
            anchors.left: parent.left
            anchors.leftMargin: 64
            anchors.right: when.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            StyledText {
                width: parent.width
                elide: Text.ElideRight
                text: listRow.title
                font.weight: Font.DemiBold
            }
            StyledText {
                width: parent.width
                elide: Text.ElideRight
                text: listRow.subtitle
                font.pixelSize: Appearance.fontSize.smaller
                color: Appearance.colors.onSurfaceVariant
            }
        }
        StyledText {
            id: when
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: listRow.trailing
            font.pixelSize: Appearance.fontSize.smallest
            color: Appearance.colors.onSurfaceVariant
        }
        HoverHandler {
            id: hover
            cursorShape: Qt.PointingHandCursor
        }
        TapHandler {
            onTapped: listRow.activated()
        }
    }
}
