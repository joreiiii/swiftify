pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Swiftify

// the head of a playlist, album, artist or favourites page: glowing artwork
// on a soft burst in its own colour, beside a kind chip, the title, a
// description and the facts as chips, with the page's buttons underneath.
Item {
    id: root

    property url artworkUrl
    /// the artwork's address is still on its way
    property bool artworkPending: false
    property bool circular: false
    property string kind
    property string title
    property string description
    property string facts
    property real titleSize: 34
    property alias actions: actionSlot.data
    property alias artwork: artworkSlot.data
    readonly property real sideArtworkSpace: width - 2 * Appearance.sizes.pageMargin - 24 - 220
    readonly property bool stacked: sideArtworkSpace < 160
    readonly property real artworkSize: stacked ? Math.min(176, (width - 2 * Appearance.sizes.pageMargin) * 0.5)
                                              : Math.min(Appearance.sizes.headerArtwork, sideArtworkSpace)

    implicitHeight: stacked ? artworkSize + details.implicitHeight + 100
                            : Math.max(artworkSize, details.implicitHeight) + 80

    /// a picture behind the whole head, blurred and fading out downwards, as
    /// spotify's artist pages have the artist's
    property url backdropUrl
    /// how far above the head the backdrop reaches, up to the page's top
    /// edge over the gap a page leaves above its content
    property real backdropBleed: 0

    Item {
        id: backdrop
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: -root.backdropBleed
        height: parent.height + 60 + root.backdropBleed
        visible: root.backdropUrl.toString().length > 0

        Item {
            id: backdropSource
            anchors.fill: parent
            visible: false
            layer.enabled: true
            layer.textureSize: Qt.size(Math.ceil(width / 3), Math.ceil(height / 3))

            Image {
                readonly property string picture: root.backdropUrl.toString()
                anchors.fill: parent
                asynchronous: true
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(96, 96)
                source: picture.length > 0 ? "image://art/" + encodeURIComponent(picture) : ""
            }
        }
        // the page's own rounded top, so nothing shows past its corners
        Rectangle {
            id: backdropMask
            anchors.fill: parent
            visible: false
            layer.enabled: true
            topLeftRadius: Appearance.rounding.large
            topRightRadius: Appearance.rounding.large
            color: "white"
        }
        MultiEffect {
            id: backdropBlur
            anchors.fill: parent
            visible: false
            layer.enabled: true
            source: backdropSource
            blurEnabled: true
            blur: 1
            blurMax: 64
            autoPaddingEnabled: false
            saturation: 0.1
        }
        ShaderEffect {
            anchors.fill: parent
            property var source: backdropBlur
            property var mask: backdropMask
            property real shift: 0
            fragmentShader: "qrc:/shaders/scroll_wash.frag.qsb"
            opacity: Appearance.colors.dark ? 0.55 : 0.4
        }
    }

    // the collection's own scatter of faint shapes, behind it all
    Stickers {
        anchors.fill: parent
        key: root.kind + root.title
        count: 5
        minimumSize: 80
        maximumSize: 230
    }

    Item {
        id: artworkBox
        // how the page host finds it, to fly its cover home on the way back
        objectName: "heroArtwork"
        x: Appearance.sizes.pageMargin
        y: 40
        width: root.artworkSize
        height: width

        /// a clicked cover is flying in to land here; until it does, the
        /// page's own stays hidden under it
        readonly property bool awaitingFlight: UiState.heroTarget === artworkBox
        readonly property bool ready: artworkSlot.children.length > 0 || cover.ready

        Component.onCompleted: UiState.claimHero(artworkBox)

        Binding {
            target: UiState
            property: "heroReady"
            value: artworkBox.ready
            when: artworkBox.awaitingFlight
        }


        ArtworkGlow {
            anchors.fill: parent
            visible: artworkSlot.children.length === 0
            opacity: artworkBox.awaitingFlight ? 0 : 1
            source: root.artworkUrl
            circular: root.circular
            intensity: 0.24
            glowRadius: 30

            Behavior on opacity {
                NumberAnimation { duration: Appearance.duration(320); easing.type: Easing.OutCubic }
            }
        }

        ArtworkImage {
            id: cover
            anchors.fill: parent
            pending: root.artworkPending
            visible: artworkSlot.children.length === 0
            opacity: artworkBox.awaitingFlight ? 0 : 1
            source: root.artworkUrl
            circular: root.circular
        }

        Item {
            id: artworkSlot
            anchors.fill: parent
            opacity: artworkBox.awaitingFlight ? 0 : 1
        }
    }

    Column {
        id: details
        objectName: "heroDetails"
        x: root.stacked ? Appearance.sizes.pageMargin : artworkBox.x + artworkBox.width + 24
        // beside the cover, centred on it, as spotify's page heads are
        y: root.stacked ? artworkBox.y + artworkBox.height + 20
                        : 40 + Math.max(0, (artworkBox.height - implicitHeight) / 2)
        width: Math.max(0, root.width - x - Appearance.sizes.pageMargin)
        spacing: 9

        // the kind, as a chip with a symbol
        Rectangle {
            width: Math.min(parent.width, kindRow.implicitWidth + 20)
            height: 26
            radius: height / 2
            color: Appearance.colors.primaryContainer

            Row {
                id: kindRow
                anchors.centerIn: parent
                spacing: 5

                MaterialSymbol {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.kind === "ALBUM" ? "album" : root.kind === "ARTIST" ? "person"
                        : root.kind === "LOCAL FILES" ? "folder" : "queue_music"
                    iconSize: 15
                    fill: 1
                    color: Appearance.colors.onPrimaryContainer
                }
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.kind
                    font.pixelSize: Appearance.fontSize.smallest
                    font.weight: Font.Bold
                    font.letterSpacing: 0.8
                    color: Appearance.colors.onPrimaryContainer
                }
            }
        }

        TitleText {
            width: parent.width
            text: root.title
            maximumLineCount: 2
            wrapMode: Text.Wrap
            elide: Text.ElideRight
            font.pixelSize: root.titleSize
            font.weight: Font.Bold
        }

        StyledText {
            width: parent.width
            visible: root.description.length > 0
            text: root.description
            maximumLineCount: 3
            wrapMode: Text.Wrap
            elide: Text.ElideRight
            color: Appearance.colors.onSurfaceVariant
        }

        // the facts, a chip each
        Flow {
            width: parent.width
            visible: root.facts.length > 0
            spacing: 6

            Repeater {
                model: root.facts.split("  •  ")

                Rectangle {
                    id: chip

                    required property string modelData

                    visible: modelData.length > 0
                    // a fact still to come keeps its row, and fades in
                    opacity: modelData.trim().length > 0 ? 1 : 0
                    width: Math.min(parent.width, factText.implicitWidth + 18)

                    Behavior on opacity {
                        NumberAnimation { duration: Appearance.duration(220); easing.type: Easing.OutCubic }
                    }
                    height: 24
                    radius: height / 2
                    color: Appearance.colors.surfaceContainerHigh

                    StyledText {
                        id: factText
                        anchors.centerIn: parent
                        width: Math.max(0, parent.width - 18)
                        elide: Text.ElideRight
                        text: chip.modelData
                        font.pixelSize: Appearance.fontSize.smaller
                        color: Appearance.colors.onSurfaceVariant
                    }
                }
            }
        }

        Flow {
            id: actionSlot
            objectName: "heroActions"
            width: parent.width
            readonly property bool compactActions: width < 130
            readonly property real actionSize: Math.max(28, Math.min(48, (width - 30) / 4))
            topPadding: 6
            spacing: 10
        }
    }
}
