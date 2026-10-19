pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import Swiftify

// the settings, as spotify's settings page: a page of its own in the middle,
// one long column of plain sections in spotify's order, each row what it
// does on the left and its control on the right. every change applies at
// once, but what says otherwise.
Flickable {
    id: root

    readonly property list<string> fades: ["none", "finalSeconds", "entire"]
    readonly property list<int> qualities: [96, 160, 320]
    readonly property list<int> cacheSizes: [500, 1000, 2000]
    readonly property list<real> zoomLevels: [0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3]
    readonly property var devices: [""].concat(Player.outputDevices())

    topMargin: Appearance.sizes.pageTop
    contentHeight: column.implicitHeight + 40 + Appearance.sizes.playerBarClearance
    boundsBehavior: Flickable.StopAtBounds
    clip: true
    ScrollBar.vertical: StyledScrollBar {}

    Column {
        id: column
        x: Appearance.sizes.pageMargin
        y: 24
        width: Math.min(820, root.width - 2 * Appearance.sizes.pageMargin)

        TitleText {
            text: "Settings"
            font.pixelSize: 32
            font.weight: Font.Bold
        }

        // --- account ---------------------------------------------------------------

        ContentSection {
            title: "Account"

            Item {
                width: parent.width
                height: 64

                ArtworkImage {
                    id: avatar
                    anchors.verticalCenter: parent.verticalCenter
                    width: 44
                    height: 44
                    circular: true
                    squiggly: false
                    source: Library.profileArtworkUrl
                    placeholderSymbol: "person"
                }
                Column {
                    anchors.left: avatar.right
                    anchors.leftMargin: 14
                    anchors.right: logOut.left
                    anchors.rightMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    StyledText {
                        width: parent.width
                        text: Library.profileName.length > 0 ? Library.profileName : "Spotify"
                        elide: Text.ElideRight
                        font.weight: Font.Bold
                    }
                    StyledText {
                        width: parent.width
                        text: Session.connected ? "Signed in to Spotify" : "Not signed in"
                        elide: Text.ElideRight
                        font.pixelSize: Appearance.fontSize.smaller
                        color: Appearance.colors.onSurfaceVariant
                    }
                }
                // spotify's outlined pill
                Rectangle {
                    id: logOut
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: logOutLabel.implicitWidth + 32
                    height: 32
                    radius: height / 2
                    color: "transparent"
                    border.width: 1
                    border.color: logOutHover.hovered ? Appearance.colors.onSurface : Appearance.colors.outline
                    scale: logOutHover.hovered ? 1.04 : 1
                    opacity: Session.libraryConnected || Session.connected ? 1 : 0.4

                    StyledText {
                        id: logOutLabel
                        anchors.centerIn: parent
                        text: "Log out"
                        font.pixelSize: Appearance.fontSize.small
                        font.weight: Font.Bold
                    }
                    HoverHandler {
                        id: logOutHover
                        cursorShape: Qt.PointingHandCursor
                    }
                    TapHandler {
                        enabled: Session.libraryConnected || Session.connected
                        onTapped: logOutDialog.open()
                    }
                }
            }

            StyledDialog {
                id: logOutDialog
                headline: "Log out of Spotify?"
                symbol: "logout"
                iconShape: "ghostish"
                body: "Your Spotify login is forgotten on this computer. You can sign in again any time."

                buttons: [
                    TextButton {
                        text: "Log out"
                        colBackground: Appearance.colors.error
                        colBackgroundHover: Appearance.colors.errorHover
                        labelColor: Appearance.colors.onError
                        onClicked: {
                            Session.logOut()
                            logOutDialog.accept()
                        }
                    },
                    TextButton {
                        variant: TextButton.Text
                        text: "Cancel"
                        onClicked: logOutDialog.close()
                    }
                ]
            }
        }

        // --- your library ----------------------------------------------------------

        ContentSection {
            title: "Your Library"

            ConfigSwitch {
                text: "Use compact library layout"
                checked: Settings.compactLibrary
                onToggledTo: (checked) => Settings.compactLibrary = checked
            }
        }

        // --- display ---------------------------------------------------------------

        ContentSection {
            title: "Display"

            ConfigSwitch {
                text: "Show the now-playing panel on click of play"
                checked: Settings.showNowPlayingOnPlay
                onToggledTo: (checked) => Settings.showNowPlayingOnPlay = checked
            }
            ConfigSwitch {
                text: "Show desktop notifications when the song changes"
                checked: Settings.trackNotifications
                onToggledTo: (checked) => Settings.trackNotifications = checked
            }
            ConfigSelection {
                text: "Player bar layout"
                currentIndex: Settings.spotifyPlayerLayout ? 0 : 1
                segments: [
                    Segment { text: "Spotify" },
                    Segment { text: "Swiftify" }
                ]
                onActivated: (index) => Settings.spotifyPlayerLayout = index === 0
            }
            NoteText {
                text: "Spotify puts the song on the left and the controls in the middle. Swiftify keeps them together."
            }
            ConfigSelection {
                text: "Home and search"
                currentIndex: Settings.centeredSearch ? 0 : 1
                segments: [
                    Segment { text: "Top bar" },
                    Segment { text: "Sidebar" }
                ]
                onActivated: (index) => Settings.centeredSearch = index === 0
            }
        }

        // --- social ----------------------------------------------------------------

        ContentSection {
            title: "Social"

            ConfigSwitch {
                text: "Start a private session to listen anonymously"
                checked: Settings.privateSession
                onToggledTo: (checked) => Settings.privateSession = checked
            }
            ConfigSwitch {
                text: "Share my listening activity on Spotify"
                checked: Settings.shareListeningActivity
                enabled: !Settings.privateSession
                onToggledTo: (checked) => Settings.shareListeningActivity = checked
            }
            ConfigSwitch {
                text: "See what your friends are playing"
                checked: Settings.showFriendActivity
                onToggledTo: (checked) => Settings.showFriendActivity = checked
            }
        }

        // --- playback --------------------------------------------------------------

        ContentSection {
            title: "Playback"

            ConfigSwitch {
                text: "Autoplay similar content when your music ends"
                checked: Settings.autoplayEnabled
                onToggledTo: (checked) => Settings.autoplayEnabled = checked
            }
            ConfigSwitch {
                text: "Allow the playback of explicit-rated content"
                checked: Settings.allowExplicit
                onToggledTo: (checked) => Settings.allowExplicit = checked
            }
            ConfigSwitch {
                text: "Normalize volume - Set the same volume level for all songs"
                checked: Settings.normalizeVolume
                onToggledTo: (checked) => Settings.normalizeVolume = checked
            }
            ConfigSelection {
                text: "Volume level - Adjust the volume for your environment. Loud may diminish audio quality."
                enabled: Settings.normalizeVolume
                currentIndex: Math.max(0, ["quiet", "normal", "loud"].indexOf(Settings.volumeLevel))
                segments: [
                    Segment { text: "Quiet" },
                    Segment { text: "Normal" },
                    Segment { text: "Loud" }
                ]
                onActivated: (index) => Settings.volumeLevel = ["quiet", "normal", "loud"][index]
            }
            ConfigSwitch {
                text: "Mono audio - Makes the left and right speakers play the same audio"
                checked: Settings.monoAudio
                onToggledTo: (checked) => Settings.monoAudio = checked
            }
            ConfigSwitch {
                text: "Crossfade songs"
                checked: Settings.crossfadeEnabled
                onToggledTo: (checked) => Settings.crossfadeEnabled = checked
            }
            ConfigSlider {
                text: "Crossfade duration"
                visible: Settings.crossfadeEnabled
                from: 1
                to: 12
                stepSize: 1
                value: Settings.crossfadeDurationSeconds
                valueText: Settings.crossfadeDurationSeconds + " s"
                onMoved: (value) => Settings.crossfadeDurationSeconds = Math.round(value)
            }
            ConfigSelection {
                text: "Sleep timer fade-out"
                currentIndex: Math.max(0, root.fades.indexOf(Settings.sleepTimerFade))
                segments: [
                    Segment { text: "None" },
                    Segment { text: "Last 10 seconds" },
                    Segment { text: "Whole timer" }
                ]
                onActivated: (index) => Settings.sleepTimerFade = root.fades[index]
            }
        }

        // --- audio quality ---------------------------------------------------------

        ContentSection {
            title: "Audio quality"

            ConfigSelection {
                text: "Streaming quality"
                currentIndex: Math.max(0, root.qualities.indexOf(Settings.streamingQuality))
                segments: [
                    Segment { text: "96 kbps" },
                    Segment { text: "160 kbps" },
                    Segment { text: "320 kbps" }
                ]
                onActivated: (index) => Settings.streamingQuality = root.qualities[index]
            }
            ConfigSelection {
                text: "Song cache size"
                currentIndex: Math.max(0, root.cacheSizes.indexOf(Settings.songCacheMegabytes))
                segments: [
                    Segment { text: "500 MB" },
                    Segment { text: "1 GB" },
                    Segment { text: "2 GB" }
                ]
                onActivated: (index) => Settings.songCacheMegabytes = root.cacheSizes[index]
            }
            NoteText {
                text: "Quality and cache size apply the next time playback connects."
            }
            ConfigDropdown {
                text: "Output device"
                options: root.devices.map(device => device.length > 0 ? device : "System default")
                currentIndex: Math.max(0, root.devices.indexOf(Settings.outputDevice))
                onActivated: (index) => Settings.outputDevice = root.devices[index]
            }
        }

        // --- equalizer -------------------------------------------------------------

        ContentSection {
            title: "Equalizer"

            ConfigSwitch {
                text: "Equalizer"
                checked: Sound.equalizerEnabled
                onToggledTo: (checked) => Sound.equalizerEnabled = checked
            }
            Flow {
                width: parent.width
                spacing: 8
                topPadding: 4
                visible: Sound.equalizerEnabled

                Repeater {
                    model: Sound.presetNames

                    FilterChip {
                        required property string modelData
                        text: modelData
                        checked: Sound.activePresetName === modelData
                        onClicked: Sound.applyPreset(modelData)
                    }
                }
            }
            Row {
                id: bands
                width: parent.width
                height: 190
                topPadding: 8
                visible: Sound.equalizerEnabled

                Repeater {
                    model: Sound.bandLabels.length

                    Column {
                        id: band
                        required property int index
                        width: bands.width / Sound.bandLabels.length
                        spacing: 6

                        StyledSlider {
                            anchors.horizontalCenter: parent.horizontalCenter
                            orientation: Qt.Vertical
                            height: 150
                            trackThickness: 4
                            dotHandle: true
                            showStopIndicator: false
                            from: -12
                            to: 12
                            value: Sound.gains[band.index] ?? 0
                            onMoved: Sound.setGain(band.index, value)
                        }
                        StyledText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: Sound.bandLabels[band.index]
                            font.pixelSize: Appearance.fontSize.smallest
                            color: Appearance.colors.onSurfaceVariant
                        }
                    }
                }
            }
            Item {
                width: parent.width
                height: 44
                visible: Sound.equalizerEnabled

                // spotify's outlined pill
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: resetLabel.implicitWidth + 32
                    height: 32
                    radius: height / 2
                    color: "transparent"
                    border.width: 1
                    border.color: resetHover.hovered ? Appearance.colors.onSurface : Appearance.colors.outline
                    opacity: Sound.flat ? 0.4 : 1

                    StyledText {
                        id: resetLabel
                        anchors.centerIn: parent
                        text: "Reset"
                        font.pixelSize: Appearance.fontSize.small
                        font.weight: Font.Bold
                    }
                    HoverHandler {
                        id: resetHover
                        cursorShape: Qt.PointingHandCursor
                    }
                    TapHandler {
                        enabled: !Sound.flat
                        onTapped: Sound.reset()
                    }
                }
            }
        }

        // --- appearance ------------------------------------------------------------

        ContentSection {
            title: "Appearance"

            ConfigSelection {
                text: "Theme"
                currentIndex: Math.max(0, ["system", "light", "dark"].indexOf(Settings.themeMode))
                segments: [
                    Segment { text: "System"; symbol: "brightness_auto" },
                    Segment { text: "Light"; symbol: "light_mode" },
                    Segment { text: "Dark"; symbol: "dark_mode" }
                ]
                onActivated: (index) => Settings.themeMode = ["system", "light", "dark"][index]
            }
            StyledText {
                width: parent.width
                topPadding: 8
                bottomPadding: 10
                text: "Colours"
                font.pixelSize: Appearance.fontSize.small
                color: Appearance.colors.onSurfaceVariant
            }
            Flow {
                width: parent.width
                spacing: 10
                bottomPadding: 10

                Repeater {
                    model: Theme.themeOptions(Theme.dark)

                    delegate: ThemeSwatch {
                        required property themeOption modelData
                        option: modelData
                        selected: modelData.id === Settings.themeSource
                        onClicked: Settings.themeSource = modelData.id
                    }
                }
            }
            NoteText {
                visible: Settings.themeSource === "system"
                text: Theme.usingSystemScheme
                    ? "Following " + Theme.systemSchemePath + ". Updates when the file changes."
                    : "Looks for a Matugen colour scheme in the usual config and cache folders."
            }
            ConfigDropdown {
                text: "Zoom level - You can also zoom with Ctrl - and Ctrl +"
                options: root.zoomLevels.map(level => Math.round(level * 100) + "%")
                currentIndex: {
                    let best = 3
                    for (let index = 0; index < root.zoomLevels.length; ++index) {
                        if (Math.abs(root.zoomLevels[index] - Settings.zoom) < Math.abs(root.zoomLevels[best] - Settings.zoom)) {
                            best = index
                        }
                    }
                    return best
                }
                onActivated: (index) => Settings.zoom = root.zoomLevels[index]
            }
        }

        // --- startup and window behaviour ------------------------------------------

        ContentSection {
            title: "Startup and window behavior"
            visible: !App.macOS

            ConfigSelection {
                visible: App.windows
                text: "Open Spotify automatically after you log into the computer"
                currentIndex: Math.max(0, ["no", "minimized", "normal"].indexOf(Settings.openAtLogin))
                segments: [
                    Segment { text: "No" },
                    Segment { text: "Minimized" },
                    Segment { text: "Yes" }
                ]
                onActivated: (index) => Settings.openAtLogin = ["no", "minimized", "normal"][index]
            }
            ConfigSelection {
                objectName: "windowControlsMode"
                visible: App.windows
                text: "Window controls"
                currentIndex: Settings.nativeTitleBar ? 0 : 1
                segments: [
                    Segment { text: "Native title bar" },
                    Segment { text: "In-app" }
                ]
                onActivated: (index) => Settings.nativeTitleBar = index === 0
            }
            ConfigSwitch {
                text: "Window buttons"
                visible: !App.windows
                checked: Settings.showWindowControls
                onToggledTo: (checked) => Settings.showWindowControls = checked
            }
            ConfigSwitch {
                objectName: "windowControlsOnRightSwitch"
                text: App.windows ? "Window controls on the right" : "Window buttons on the right"
                checked: Settings.windowControlsOnRight
                enabled: App.windows ? !Settings.nativeTitleBar : Settings.showWindowControls
                onToggledTo: (checked) => Settings.windowControlsOnRight = checked
            }
            ConfigSwitch {
                text: "Always show the tray icon"
                checked: Settings.trayIcon
                onToggledTo: (checked) => Settings.trayIcon = checked
            }
        }

        // --- about -----------------------------------------------------------------

        ContentSection {
            id: about

            property bool revealed: false

            title: "About"

            Row {
                width: parent.width
                topPadding: 8
                spacing: 16

                Image {
                    width: 44
                    height: 44
                    source: "qrc:/qt/qml/Swiftify/resources/swiftify-icon.png"
                    sourceSize: Qt.size(96, 96)
                    smooth: true
                    mipmap: true
                }
                Column {
                    width: parent.width - 60
                    spacing: 4

                    StyledText {
                        text: "Swiftify (Modded) [by jorei_]"
                        font.weight: Font.Bold

                        TapHandler {
                            onTapped: about.revealed = true
                        }
                    }
                    StyledText {
                        width: Math.min(parent.width, 520)
                        wrapMode: Text.WordWrap
                        text: "This app is a modified version of Swiftify, developed by addenator - to achieve full feature parity with native Spotify and make it more intuitive for users coming from the original app."
                        font.pixelSize: Appearance.fontSize.smaller
                        color: Appearance.colors.onSurfaceVariant
                    }
                    StyledText {
                        text: "Version " + Qt.application.version
                        font.pixelSize: Appearance.fontSize.smaller
                        color: Appearance.colors.outline
                    }
                    StyledText {
                        visible: about.revealed
                        topPadding: 4
                        text: "no secret dev options here..."
                        font.weight: Font.DemiBold
                        color: Appearance.colors.primary
                    }
                }
            }
        }
    }
}
