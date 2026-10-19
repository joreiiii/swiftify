pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Effects
import Swiftify

// Now Playing, as spotify's view beside the page but kept small: the cover
// (where spotify shows a music video), the song with save and share, the
// artist with their picture and story, and the song that plays next.
Item {
    id: root

    property MaterialScheme scheme: Appearance.colors
    readonly property song song: Player.currentSong
    readonly property bool saved: Library.savedRevision >= 0 && Library.isSaved(song.uri)
    readonly property var card: Library.artistCard
    readonly property bool cardFits: root.song.artistId.length > 0 && card.id === root.song.artistId
    readonly property song next: Player.upNext.at(Player.upNext.count > 0 ? 0 : -1)
    // the song's credits and its artist's listeners and concerts (extras.rs)
    readonly property var extras: Library.songExtras
    readonly property int listeners: cardFits ? (extras.monthlyListeners ?? 0) : 0
    readonly property var credits: extras.credits ?? []
    readonly property var concerts: cardFits ? (extras.concerts ?? []) : []

    onSongChanged: load()
    onVisibleChanged: load()
    function load() {
        if (visible && song.artistId.length > 0) {
            Library.loadArtistCard(song.artistId)
            Library.loadSongExtras(song.uri, song.artistId)
        }
    }

    MenuLoader {
        id: shareMenu
        sourceComponent: ShareMenu {
            uri: root.song.uri
            label: root.song.name + " – " + root.song.artists
        }
    }

    // the cover, blurred and faint, behind the top of the panel where the
    // cover itself is, fading out below it, as the home spotlight's wash
    Item {
        id: backdrop
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: Math.min(parent.height, header.y + header.height + 12 + parent.width + 40)
        visible: Player.hasSong

        Item {
            id: backdropSource
            anchors.fill: parent
            visible: false
            layer.enabled: true
            layer.textureSize: Qt.size(Math.ceil(width / 2), Math.ceil(height / 2))

            // a plain image: ArtworkImage draws through shader effects of
            // its own hidden images, which a hidden layer leaves blank
            Image {
                readonly property string cover: root.song.artworkUrl.toString()

                anchors.fill: parent
                asynchronous: true
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(64, 64)
                source: cover.length > 0 ? "image://art/" + encodeURIComponent(cover) : ""
            }

            // the blur keeps buffers of the size it was first drawn at: it
            // is given its source again once a new size settles (HomeView)
            onWidthChanged: rebuffer.restart()
            onHeightChanged: rebuffer.restart()
            Timer {
                id: rebuffer
                interval: 60
                onTriggered: {
                    backdropWash.source = null
                    Qt.callLater(() => backdropWash.source = backdropSource)
                }
            }
        }
        // the panel's rounded top, fading to nothing towards the bottom
        Rectangle {
            id: backdropMask
            anchors.fill: parent
            visible: false
            layer.enabled: true
            topLeftRadius: Appearance.rounding.large
            topRightRadius: Appearance.rounding.large
            color: "white"
        }
        // the blur alone, drawn into a texture of the panel's size: padding
        // for it would push it past the panel's edges
        MultiEffect {
            id: backdropWash
            anchors.fill: parent
            visible: false
            layer.enabled: true
            source: backdropSource
            blurEnabled: true
            blur: 1
            blurMax: 64
            autoPaddingEnabled: false
            saturation: 0.2
        }
        // inside the panel's rounded corners, moving up with what scrolls
        // and fading out smoothly downwards (scroll_wash.frag)
        ShaderEffect {
            anchors.fill: parent
            property var source: backdropWash
            property var mask: backdropMask
            property real shift: scroller.contentY / Math.max(1, height)
            fragmentShader: "qrc:/shaders/scroll_wash.frag.qsb"
            opacity: Appearance.colors.dark ? 0.4 : 0.28
        }
    }

    StyledText {
        id: header
        x: 18
        y: 16
        width: parent.width - 36
        elide: Text.ElideRight
        text: "Now playing..."
        font.pixelSize: Appearance.fontSize.normal
        font.weight: Font.DemiBold
        color: root.scheme.onSurfaceVariant
    }

    EmptyState {
        anchors.centerIn: parent
        Reveal.shown: !Player.hasSong
        symbol: "music_note"
        title: "Nothing Playing"
        description: "Play something to see it here."
    }

    Flickable {
        id: scroller
        anchors.fill: parent
        anchors.topMargin: header.y + header.height + 12
        contentHeight: column.implicitHeight + 24
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        visible: Player.hasSong
        ScrollBar.vertical: StyledScrollBar {}

        Column {
            id: column
            x: 16
            width: parent.width - 32
            spacing: 14

            // the cover, where spotify plays a music video
            ArtworkImage {
                width: parent.width
                height: width
                radius: Appearance.sizes.artworkRadius
                source: root.song.artworkUrl
                placeholderSymbol: "music_note"
            }

            // the song, with save and share beside it
            Item {
                width: parent.width
                height: Math.max(titles.implicitHeight, actions.implicitHeight)

                Column {
                    id: titles
                    anchors.left: parent.left
                    anchors.right: actions.left
                    anchors.rightMargin: 8
                    spacing: 2

                    TitleText {
                        width: parent.width
                        text: root.song.name
                        elide: Text.ElideRight
                        font.pixelSize: Appearance.fontSize.larger
                        color: root.scheme.onSurface
                    }
                    StyledText {
                        width: parent.width
                        text: root.song.artists
                        elide: Text.ElideRight
                        color: root.scheme.onSurfaceVariant
                    }
                }
                Row {
                    id: actions
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    IconButton {
                        id: shareButton
                        visible: !root.song.isLocalFile
                        scheme: root.scheme
                        symbol: "ios_share"
                        size: 34
                        iconSize: 20
                        tooltip: "Share"
                        onClicked: shareMenu.popupAt(shareButton, shareButton.width - 220, shareButton.height)
                    }
                    IconButton {
                        visible: !root.song.isLocalFile
                        scheme: root.scheme
                        symbol: root.saved ? "check_circle" : "add_circle"
                        toggled: root.saved
                        size: 34
                        iconSize: 20
                        iconColor: root.saved ? root.scheme.primary : root.scheme.onSurfaceVariant
                        tooltip: root.saved ? "Remove from Favourite Songs" : "Save to Favourite Songs"
                        onClicked: Library.toggleSaved(root.song)
                    }
                }
            }

            // about the artist: their picture, name and story
            Rectangle {
                width: parent.width
                height: about.implicitHeight
                visible: root.cardFits
                radius: Appearance.sizes.artworkRadius
                color: root.scheme.surfaceContainerHigh
                clip: true

                Column {
                    id: about
                    width: parent.width
                    // as much under the name (or the story) as over it
                    spacing: 12
                    bottomPadding: 12

                    // round at the top with the card; its own bottom
                    // corners are cut off, so it meets the text square
                    Item {
                        width: parent.width
                        height: Math.round(width * 0.62)
                        visible: String(root.card.imageUrl ?? "").length > 0
                        clip: true

                        ArtworkImage {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            height: parent.height + radius
                            radius: Appearance.sizes.artworkRadius
                            source: root.card.imageUrl ?? ""
                        }
                        StyledText {
                            x: 14
                            y: 12
                            text: "About the artist"
                            font.weight: Font.Bold
                            color: "white"
                            style: Text.Raised
                            styleColor: Qt.rgba(0, 0, 0, 0.4)
                        }
                    }
                    Item {
                        x: 14
                        width: parent.width - 28
                        height: 32

                        StyledText {
                            id: artistName
                            anchors.left: parent.left
                            anchors.right: goTo.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.card.name ?? ""
                            elide: Text.ElideRight
                            font.weight: Font.Bold
                            font.pixelSize: Appearance.fontSize.normal
                            color: root.scheme.onSurface
                        }
                        // a small pill, as the filter chips are, level with the name
                        FilterChip {
                            id: goTo
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Go to artist"
                            baseColor: root.scheme.surfaceContainerHighest
                            onClicked: UiState.goToArtist(root.song)
                        }
                    }
                    // how many listen to them a month, as spotify counts it
                    StyledText {
                        x: 14
                        width: parent.width - 28
                        visible: root.listeners > 0
                        topPadding: -8
                        text: Number(root.listeners).toLocaleString(Qt.locale(), "f", 0) + " monthly listeners"
                        font.pixelSize: Appearance.fontSize.smaller
                        color: root.scheme.onSurfaceVariant
                    }
                    StyledText {
                        x: 14
                        width: parent.width - 28
                        visible: text.length > 0
                        text: root.card.biography ?? ""
                        wrapMode: Text.WordWrap
                        maximumLineCount: 5
                        elide: Text.ElideRight
                        font.pixelSize: Appearance.fontSize.smaller
                        color: root.scheme.onSurfaceVariant
                    }
                }
            }

            // who made the song, as spotify credits them
            Rectangle {
                width: parent.width
                height: creditColumn.implicitHeight + 24
                visible: root.credits.length > 0
                radius: Appearance.sizes.artworkRadius
                color: root.scheme.surfaceContainerHigh

                Column {
                    id: creditColumn
                    x: 14
                    y: 12
                    width: parent.width - 28
                    spacing: 12

                    StyledText {
                        text: "Credits"
                        font.weight: Font.Bold
                        color: root.scheme.onSurface
                    }
                    Repeater {
                        model: root.credits

                        Column {
                            required property var modelData
                            width: creditColumn.width
                            spacing: 1

                            StyledText {
                                width: parent.width
                                text: parent.modelData.name
                                elide: Text.ElideRight
                                font.weight: Font.DemiBold
                                color: root.scheme.onSurface
                            }
                            StyledText {
                                width: parent.width
                                visible: text.length > 0
                                text: parent.modelData.roles
                                elide: Text.ElideRight
                                font.pixelSize: Appearance.fontSize.smaller
                                color: root.scheme.onSurfaceVariant
                            }
                        }
                    }
                    StyledText {
                        visible: (root.extras.moreCredits ?? 0) > 0
                        text: "and " + root.extras.moreCredits + " more"
                        font.pixelSize: Appearance.fontSize.smaller
                        color: root.scheme.onSurfaceVariant
                    }
                }
            }

            // where the artist plays next: a date, the city, the venue
            Rectangle {
                width: parent.width
                height: tourColumn.implicitHeight + 24
                visible: root.concerts.length > 0
                radius: Appearance.sizes.artworkRadius
                color: root.scheme.surfaceContainerHigh

                Column {
                    id: tourColumn
                    x: 14
                    y: 12
                    width: parent.width - 28
                    spacing: 12

                    StyledText {
                        text: "On tour"
                        font.weight: Font.Bold
                        color: root.scheme.onSurface
                    }
                    Repeater {
                        model: root.concerts

                        Row {
                            id: show
                            required property var modelData
                            // the concert's own local date and time, as written
                            readonly property var when: {
                                const parts = String(modelData.date).match(/^(\d+)-(\d+)-(\d+)(?:T(\d+):(\d+))?/)
                                return parts ? { year: +parts[1], month: +parts[2], day: +parts[3],
                                                 time: parts[4] !== undefined ? parts[4] + ":" + parts[5] : "" }
                                             : null
                            }
                            width: tourColumn.width
                            spacing: 12

                            Rectangle {
                                width: 48
                                height: 52
                                radius: 8
                                color: root.scheme.surfaceContainerHighest

                                Column {
                                    anchors.centerIn: parent

                                    StyledText {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: show.when ? Qt.locale().monthName(show.when.month - 1, Locale.ShortFormat) : ""
                                        font.pixelSize: Appearance.fontSize.smallest
                                        font.weight: Font.DemiBold
                                        color: root.scheme.onSurface
                                    }
                                    StyledText {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: show.when ? show.when.day : ""
                                        font.pixelSize: Appearance.fontSize.larger
                                        font.weight: Font.Bold
                                        color: root.scheme.onSurface
                                    }
                                }
                            }
                            Column {
                                width: parent.width - 60
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 1

                                StyledText {
                                    width: parent.width
                                    text: show.modelData.city.length > 0 ? show.modelData.city : show.modelData.title
                                    elide: Text.ElideRight
                                    font.weight: Font.DemiBold
                                    color: root.scheme.onSurface
                                }
                                StyledText {
                                    width: parent.width
                                    text: show.modelData.festival ? show.modelData.title : (root.card.name ?? "")
                                    elide: Text.ElideRight
                                    font.pixelSize: Appearance.fontSize.smaller
                                    color: root.scheme.onSurfaceVariant
                                }
                                StyledText {
                                    width: parent.width
                                    text: {
                                        const parts = []
                                        if (show.when) {
                                            const day = new Date(show.when.year, show.when.month - 1, show.when.day).getDay()
                                            parts.push(Qt.locale().dayName(day, Locale.ShortFormat) + (show.when.time ? ", " + show.when.time : ""))
                                        }
                                        if (show.modelData.venue.length > 0) {
                                            parts.push(show.modelData.venue)
                                        }
                                        return parts.join("  •  ")
                                    }
                                    elide: Text.ElideRight
                                    font.pixelSize: Appearance.fontSize.smaller
                                    color: root.scheme.onSurfaceVariant
                                }
                            }
                        }
                    }
                    StyledText {
                        visible: (root.extras.moreConcerts ?? 0) > 0
                        text: "and " + root.extras.moreConcerts + " more dates"
                        font.pixelSize: Appearance.fontSize.smaller
                        color: root.scheme.onSurfaceVariant
                    }
                }
            }

            // what plays next
            Rectangle {
                width: parent.width
                height: nextColumn.implicitHeight + 24
                visible: root.next.valid
                radius: Appearance.sizes.artworkRadius
                color: root.scheme.surfaceContainerHigh

                Column {
                    id: nextColumn
                    x: 14
                    y: 12
                    width: parent.width - 28
                    spacing: 10

                    Item {
                        width: parent.width
                        height: 20

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Next in queue"
                            font.weight: Font.Bold
                            color: root.scheme.onSurface
                        }
                        StyledText {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Open queue"
                            font.pixelSize: Appearance.fontSize.smaller
                            font.weight: Font.DemiBold
                            color: root.scheme.onSurfaceVariant

                            TapHandler {
                                onTapped: Player.showingQueue = true
                            }
                            HoverHandler {
                                cursorShape: Qt.PointingHandCursor
                            }
                        }
                    }
                    Row {
                        width: parent.width
                        spacing: 10

                        ArtworkImage {
                            width: 44
                            height: 44
                            radius: 6
                            source: root.next.artworkUrl
                        }
                        Column {
                            width: parent.width - 54
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2

                            StyledText {
                                width: parent.width
                                text: root.next.name
                                elide: Text.ElideRight
                                font.weight: Font.DemiBold
                                color: root.scheme.onSurface
                            }
                            StyledText {
                                width: parent.width
                                text: root.next.artists
                                elide: Text.ElideRight
                                font.pixelSize: Appearance.fontSize.smaller
                                color: root.scheme.onSurfaceVariant
                            }
                        }
                    }
                }
            }
        }
    }
}
