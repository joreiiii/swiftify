pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Swiftify

// the floating player (FloatingPlayerBar): transport, what is playing with its
// seek line, and lyrics, queue and volume. its colours follow the cover.
Item {
    id: root

    // the app's theme, as the rest of the window is
    property MaterialScheme scheme: Appearance.colors
    signal immersiveRequested()

    // Give the title useful space before the controls start colliding with it.
    readonly property bool compact: width < 560
    readonly property bool tiny: width < 400
    readonly property real buttonSize: tiny ? 26 : (compact ? 28 : 32)
    readonly property real innerGap: tiny ? 6 : (compact ? 8 : 14)
    readonly property bool titleFits: nowPlaying.width - artwork.width - 8 >= 48
    readonly property bool showsMeter: !compact && Settings.visualizersEnabled && Player.hasSong
    property bool progressExpanded: seek.expanded
    /// laid out as spotify's bar (Settings.spotifyPlayerLayout): the song on
    /// the left, the controls over the seek line in the middle. a narrow
    /// window keeps swiftify's, which fits
    readonly property bool spotify: Settings.spotifyPlayerLayout && !compact
    /// spotify's middle: two fifths of the bar, within reason, whatever
    /// the transport is doing
    readonly property real centerWidth: Math.max(260, Math.min(width * 0.4, 680))

    implicitHeight: spotify ? 72 : (tiny ? 56 : 64)
    opacity: Window.active ? 1 : 0.82

    Behavior on opacity {
        NumberAnimation { duration: Appearance.duration(160); easing.type: Easing.OutCubic }
    }

    SoftShadow {
        anchors.fill: surface
        radius: surface.radius
        blur: 18
        offset: Qt.vector2d(0, 6)
        color: Qt.rgba(0, 0, 0, 0.2)
    }

    Rectangle {
        id: surface
        anchors.fill: parent

        // the bar is solid: clicks, hovers and the wheel stop here rather
        // than reaching the page underneath
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            onWheel: (wheel) => wheel.accepted = true
        }
        radius: 20
        color: root.scheme.surfaceContainerHigh
        border.width: 1
        border.color: Qt.rgba(root.scheme.outlineVariant.r, root.scheme.outlineVariant.g, root.scheme.outlineVariant.b, 0.4)
    }

    Row {
        id: transport
        objectName: "playerTransport"
        // placed rather than anchored: anchors swapped by a binding as the
        // layout changes could end up set together, and stuck that way
        x: root.spotify ? Math.round((root.width - width) / 2) : (root.compact ? 8 : 12)
        y: root.spotify ? 12 : Math.round((root.height - height) / 2)
        spacing: root.tiny ? 0 : 4

        TransportButton {
            visible: !root.tiny
            anchors.verticalCenter: parent.verticalCenter
            scheme: root.scheme
            effect: TransportButton.Bounce
            symbol: "shuffle"
            toggledShape: "clover4"
            size: root.buttonSize
            iconSize: root.tiny ? 18 : 20
            toggled: Player.shuffle
            fillWhenToggled: false
            tooltip: Player.shuffle ? "Disable shuffle" : "Enable shuffle"
            onClicked: Player.toggleShuffle()
        }
        TransportButton {
            anchors.verticalCenter: parent.verticalCenter
            scheme: root.scheme
            effect: TransportButton.NudgeLeft
            symbol: "skip_previous"
            hoverShape: "arrow"
            hoverAngle: -90
            size: root.buttonSize
            iconSize: root.tiny ? 20 : 24
            fillWhenToggled: false
            enabled: Player.canSkipBackward
            tooltip: "Previous song"
            onClicked: Player.skipBackward()
            alwaysFilled: true
        }

        PlayButton {
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: root.spotify || root.tiny ? 36 : (root.compact ? 40 : 44)
            implicitHeight: implicitWidth
            enabled: Player.hasSong
            color: root.scheme.primary
            hoverColor: root.scheme.primaryHover
            iconColor: root.scheme.onPrimary
            onClicked: Player.togglePlayback()
        }

        TransportButton {
            anchors.verticalCenter: parent.verticalCenter
            scheme: root.scheme
            effect: TransportButton.NudgeRight
            symbol: "skip_next"
            hoverShape: "arrow"
            hoverAngle: 90
            size: root.buttonSize
            iconSize: root.tiny ? 20 : 24
            enabled: Player.canSkipForward
            tooltip: "Next song"
            onClicked: Player.skipForward()
            alwaysFilled: true
        }
        TransportButton {
            anchors.verticalCenter: parent.verticalCenter
            scheme: root.scheme
            effect: TransportButton.Bounce
            symbol: Player.repeatMode === Player.RepeatMode.One ? "repeat_one" : "repeat"
            visible: !root.tiny
            toggledShape: Player.repeatMode === Player.RepeatMode.One ? "cookie4" : "cookie6"
            size: root.buttonSize
            iconSize: root.tiny ? 18 : 20
            toggled: Player.repeatMode !== Player.RepeatMode.Off
            fillWhenToggled: false
            enabled: Player.hasSong
            tooltip: Player.repeatMode === Player.RepeatMode.One ? "Repeat song" : (Player.repeatMode === Player.RepeatMode.All ? "Repeat queue" : "Repeat off")
            onClicked: Player.cycleRepeatMode()
        }
    }

    Item {
        id: nowPlaying
        objectName: "playerNowPlaying"
        anchors.left: root.spotify ? parent.left : transport.right
        anchors.leftMargin: root.spotify ? 12 : root.innerGap
        anchors.right: root.spotify ? center.left : utilities.left
        anchors.rightMargin: root.innerGap
        anchors.top: parent.top
        anchors.bottom: parent.bottom

        // the cover: grows on hover and opens the immersive player
        Item {
            id: artwork
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: root.spotify ? 0 : -4
            width: root.spotify ? 48 : (root.tiny ? 30 : 40)
            height: width
            z: 2
            // a new song's cover pops in with a spring
            transform: Scale {
                id: pop
                origin.x: artwork.width / 2
                origin.y: artwork.height / 2
            }

            Connections {
                target: Player
                function onCurrentSongChanged() {
                    if (!Appearance.performanceMode) {
                        popIn.restart()
                    }
                }
            }
            NumberAnimation {
                id: popIn
                target: pop
                properties: "xScale,yScale"
                from: 0.7
                to: 1
                duration: 560
                easing.type: Easing.OutBack
                easing.overshoot: 2.4
            }

            Behavior on scale {
                NumberAnimation {
                    duration: Appearance.motion(artHover.hovered ? 220 : 340)
                    easing.type: artHover.hovered ? Easing.OutBack : Easing.OutCubic
                }
            }

            SoftShadow {
                anchors.fill: parent
                radius: Appearance.sizes.smallArtworkRadius
                blur: 7
                offset: Qt.vector2d(0, 3)
                color: Qt.rgba(0, 0, 0, artHover.hovered ? 0.22 : 0)
            }

            ArtworkImage {
                anchors.fill: parent
                radius: Appearance.sizes.smallArtworkRadius
                source: Player.currentSong.artworkUrl
                crossfade: true
            }

            Rectangle {
                anchors.fill: parent
                radius: Appearance.sizes.smallArtworkRadius
                color: Qt.rgba(0, 0, 0, artHover.hovered && Player.hasSong ? 0.25 : 0)

                Behavior on color {
                    ColorAnimation { duration: Appearance.duration(160) }
                }

                MaterialSymbol {
                    anchors.centerIn: parent
                    text: "open_in_full"
                    iconSize: 16
                    weight: 600
                    color: "white"
                    opacity: artHover.hovered && Player.hasSong ? 1 : 0
                }
            }

            HoverHandler {
                id: artHover
                cursorShape: Player.hasSong ? Qt.PointingHandCursor : Qt.ArrowCursor
            }
            TapHandler {
                acceptedButtons: Qt.LeftButton
                acceptedModifiers: Qt.NoModifier
                onTapped: if (Player.hasSong) root.immersiveRequested()
            }
            TapHandler {
                acceptedButtons: Qt.LeftButton
                acceptedModifiers: Qt.AltModifier
                onTapped: if (Player.hasSong) UiState.showCatchphrase("")
            }
            TapHandler {
                acceptedButtons: Qt.RightButton
                onTapped: artMenu.popupHere()
            }
        }

        Item {
            id: info
            visible: root.titleFits
            clip: true

            anchors.left: artwork.right
            anchors.leftMargin: root.spotify ? 12 : 8
            anchors.right: root.showsMeter ? meter.left : parent.right
            anchors.rightMargin: root.showsMeter ? 9 : 0
            anchors.top: parent.top
            anchors.topMargin: root.spotify ? 0 : 7
            anchors.bottom: root.spotify ? parent.bottom : seek.top

            Column {
                id: titles
                anchors.left: parent.left
                // spotify's save check sits right after the names
                width: root.spotify
                       ? Math.min(Math.max(titleMetrics.advanceWidth, artistMetrics.advanceWidth) + 2,
                                  parent.width - (saveButton.visible ? saveButton.width + 8 : 0))
                       : (more.visible ? more.x - 4 : parent.width)
                anchors.rightMargin: more.visible ? 4 : 0
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                TitleText {
                    id: titleText
                    width: parent.width
                    text: Player.hasSong ? Player.currentSong.name : "Not Playing"
                    elide: Text.ElideRight
                    animateChange: true
                    changeDistanceX: 6
                    changeDistanceY: 0
                    font.pixelSize: Appearance.fontSize.small
                    color: root.scheme.onSurface

                    // a gleam sweeps under the title while the song loads
                    // (end4-pC's title scan line). it comes in from past one
                    // end and leaves past the other, fading towards both, so
                    // each sweep runs on into the next; it fades in as
                    // loading starts and out when it is done
                    ShaderEffect {
                        id: scan

                        property color color: root.scheme.primary
                        property real halfWidth: 0.22
                        property real edge: 0.18
                        property real position: -halfWidth

                        anchors.top: parent.bottom
                        anchors.topMargin: 1
                        width: parent.width
                        height: 2
                        opacity: Player.loading ? 1 : 0
                        visible: opacity > 0
                        fragmentShader: "qrc:/shaders/gleam.frag.qsb"

                        Behavior on opacity {
                            NumberAnimation { duration: Appearance.duration(260); easing.type: Easing.InOutSine }
                        }

                        NumberAnimation on position {
                            running: scan.visible && !Appearance.reduceMotion
                            from: -scan.halfWidth
                            to: 1 + scan.halfWidth
                            duration: 1300
                            loops: Animation.Infinite
                        }
                    }
                }
                StyledText {
                    id: artistText
                    width: parent.width
                    text: Player.hasSong ? Player.currentSong.artists : "Choose something to play"
                    elide: Text.ElideRight
                    font.pixelSize: Appearance.fontSize.smaller
                    color: root.scheme.onSurfaceVariant
                }
            }

            // the names' own widths, for the save check after them
            TextMetrics {
                id: titleMetrics
                font: titleText.font
                text: titleText.text
            }
            TextMetrics {
                id: artistMetrics
                font: artistText.font
                text: artistText.text
            }

            IconButton {
                id: saveButton
                readonly property bool saved: Library.savedRevision >= 0 && Library.isSaved(Player.currentSong.uri)
                anchors.left: titles.right
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                visible: root.spotify && Player.hasSong && !Player.currentSong.isLocalFile
                scheme: root.scheme
                symbol: saved ? "check_circle" : "add_circle"
                toggled: saved
                size: 28
                iconSize: 18
                iconColor: saved ? root.scheme.primary : root.scheme.onSurfaceVariant
                tooltip: saved ? "Remove from Favourite Songs" : "Save to Favourite Songs"
                onClicked: Library.toggleSaved(Player.currentSong)
            }

            IconButton {
                id: more
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                Reveal.shown: Player.hasSong && !root.compact && !root.spotify
                scheme: root.scheme
                symbol: "more_horiz"
                size: 28
                iconSize: 18
                onClicked: SongMenus.open(Player.currentSong, false)
            }
        }

        // centred on the bar; the seek line stops short of it
        CompactMeter {
            id: meter
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: 30
            height: 34
            Reveal.shown: root.showsMeter
            active: Player.playing
        }

        // the seek line starts where the cover ends, so the first seconds of
        // a song stay clickable
        SeekBar {
            id: seek
            visible: !root.spotify

            anchors.left: root.titleFits ? artwork.right : parent.left
            anchors.leftMargin: root.titleFits ? 8 : 0
            anchors.right: parent.right
            anchors.rightMargin: root.showsMeter ? 39 : 0
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 2
            height: 18
            scheme: root.scheme
        }

    }

    // spotify's middle: the times either side of the seek line, under the
    // controls
    Item {
        id: center
        visible: root.spotify
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 5
        width: root.centerWidth
        height: 18

        StyledText {
            id: elapsed
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: 40
            horizontalAlignment: Text.AlignRight
            text: Format.playbackTime(centerSeek.displayPositionMs)
            tabularNumbers: true
            font.pixelSize: Appearance.fontSize.smallest
            color: root.scheme.onSurfaceVariant
        }
        SeekBar {
            id: centerSeek
            anchors.left: elapsed.right
            anchors.leftMargin: 8
            anchors.right: total.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            height: 18
            scheme: root.scheme
        }
        StyledText {
            id: total
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: 40
            text: Format.playbackTime(centerSeek.durationMs)
            tabularNumbers: true
            font.pixelSize: Appearance.fontSize.smallest
            color: root.scheme.onSurfaceVariant
        }
    }

    Row {
        id: utilities
        objectName: "playerUtilities"
        anchors.right: parent.right
        anchors.rightMargin: root.compact ? 8 : 12
        anchors.verticalCenter: parent.verticalCenter
        spacing: root.tiny ? 0 : 6
        z: 3

        IconButton {
            anchors.verticalCenter: parent.verticalCenter
            scheme: root.scheme
            id: nowPlayingButton
            enabled: UiState.nowPlayingAvailable
            opacity: enabled ? 1 : 0.38
            size: root.buttonSize
            iconSize: root.tiny ? 18 : 20
            toggled: Player.showingNowPlaying && enabled
            tooltip: "Now Playing View"
            onClicked: Player.toggleNowPlayingPanel()

            NowPlayingGlyph {
                anchors.centerIn: parent
                size: nowPlayingButton.iconSize
                color: nowPlayingButton.iconColor
                filled: nowPlayingButton.toggled
            }
        }
        IconButton {
            anchors.verticalCenter: parent.verticalCenter
            scheme: root.scheme
            id: lyricsButton
            enabled: UiState.lyricsAvailable
            opacity: enabled ? 1 : 0.38
            size: root.buttonSize
            iconSize: root.tiny ? 18 : 20
            toggled: Player.showingLyrics && enabled
            tooltip: "Lyrics"
            onClicked: Player.toggleLyricsPanel()

            LyricsGlyph {
                anchors.centerIn: parent
                size: lyricsButton.iconSize
                color: lyricsButton.iconColor
                filled: lyricsButton.toggled
            }
        }
        IconButton {
            anchors.verticalCenter: parent.verticalCenter
            scheme: root.scheme
            id: queueButton
            enabled: UiState.queueAvailable
            opacity: enabled ? 1 : 0.38
            size: root.buttonSize
            iconSize: root.tiny ? 18 : 20
            toggled: Player.showingQueue && enabled
            tooltip: "Playing Next"
            onClicked: Player.toggleQueuePanel()

            QueueGlyph {
                anchors.centerIn: parent
                size: queueButton.iconSize
                color: queueButton.iconColor
                filled: queueButton.toggled
            }
        }
        VolumeControl {
            anchors.verticalCenter: parent.verticalCenter
            scheme: root.scheme
        }
    }

    MenuLoader {
        id: artMenu
        sourceComponent: StyledMenu {
            StyledMenuItem {
                text: "Open Immersive Player"
                symbol: "open_in_full"
                enabled: Player.hasSong
                onTriggered: root.immersiveRequested()
            }
        }
    }
}
