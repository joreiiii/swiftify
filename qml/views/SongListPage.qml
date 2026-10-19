pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import Swiftify

// a collection page: a header, then its songs as list rows, with room for a
// loading or empty state in between.
ListView {
    id: root

    /// the gap above the page. the playlist page's toolbar floats over it
    /// with no background of its own, so that page starts below it
    property real topInset: Appearance.sizes.pageTop

    topMargin: topInset

    property SongListModel songs
    property Component hero
    property bool loading: false
    property string loadingText: "Loading songs…"
    property bool showsEmpty: false
    property string emptySymbol: "music_note"
    property string emptyTitle
    property string emptyDescription
    property bool allowsPlaylistRemoval: false
    property bool reorderable: false
    /// filter chips over the songs, as spotify's playlists have
    property bool filterable: true
    /// the songs shown: all of them, or the chip picked's
    readonly property SongListModel shownSongs: filterable ? filter.songs : songs

    readonly property real margin: Appearance.sizes.pageMargin

    SongFilter {
        id: filter
        source: root.filterable ? root.songs : null
    }

    model: loading ? null : shownSongs
    boundsBehavior: Flickable.StopAtBounds
    reuseItems: true
    cacheBuffer: 600
    bottomMargin: Appearance.sizes.playerBarClearance
    ScrollBar.vertical: StyledScrollBar { topPadding: 3 + root.topInset }

    header: Column {
        width: root.width
        // under the rows, which sit at 1 and up: the hero's stickers reach
        // down behind the first of them
        z: 0.5

        Loader {
            width: root.width
            sourceComponent: root.hero
        }

        // the filter chips, scrolling sideways when there are more than fit.
        // their room is kept from the start, so nothing below moves when
        // they come, and drawn up into the hero's bottom margin, nearer its
        // cover; the chips fade in once their genres are known
        Item {
            width: root.width
            height: root.filterable ? 24 : 0
            visible: root.filterable

            Flickable {
                id: chipStrip
                x: root.margin
                y: -24
                width: root.width - 2 * root.margin
                height: 30
                opacity: filter.chips.length > 0 && !root.loading ? 1 : 0

                Behavior on opacity {
                    NumberAnimation { duration: Appearance.duration(260); easing.type: Easing.OutCubic }
                }
                contentWidth: chipRow.width
                flickableDirection: Flickable.HorizontalFlick
                boundsBehavior: Flickable.StopAtBounds
                clip: true

                Row {
                    id: chipRow
                    spacing: 8

                    Repeater {
                        model: filter.chips

                        FilterChip {
                            required property string modelData
                            text: modelData
                            checked: filter.active === modelData
                            onClicked: filter.active = modelData
                        }
                    }
                }
            }
        }

        Rectangle {
            x: root.margin
            width: root.width - 2 * root.margin
            height: 1
            color: Appearance.colors.outlineVariant
        }

        Item { width: 1; height: 12 }

        Item {
            width: root.width
            height: 240
            Reveal.shown: root.loading

            Column {
                anchors.centerIn: parent
                spacing: 12
                LoadingSpinner { anchors.horizontalCenter: parent.horizontalCenter }
                StyledText {
                    text: root.loadingText
                    color: Appearance.colors.onSurfaceVariant
                }
            }
        }

        Item {
            width: root.width
            height: 280
            Reveal.shown: !root.loading && root.showsEmpty

            EmptyState {
                anchors.centerIn: parent
                symbol: root.emptySymbol
                title: root.emptyTitle
                description: root.emptyDescription
            }
        }
    }

    delegate: SongRow {
        id: row

        x: root.margin
        width: root.width - 2 * root.margin
        songs: root.shownSongs
        allowsPlaylistRemoval: root.allowsPlaylistRemoval

        // reordering: hold and drag a row; a line shows where it will land
        DragHandler {
            id: drag
            // a filtered list has gaps: its rows cannot be put in order
            enabled: root.reorderable && filter.active.length === 0
            target: null
            yAxis.enabled: true
            xAxis.enabled: false
            dragThreshold: 6
            onActiveChanged: {
                if (active) {
                    dropMarker.from = row.index
                } else if (dropMarker.from >= 0) {
                    const to = dropMarker.to
                    const from = dropMarker.from
                    dropMarker.from = -1
                    if (to !== from && to !== from + 1) {
                        Library.moveSongs(from, 1, to)
                    }
                }
            }
            onCentroidChanged: {
                if (!active) {
                    return
                }
                const point = row.mapToItem(root.contentItem, centroid.position.x, centroid.position.y)
                const target = root.indexAt(root.width / 2, point.y)
                const targetItem = root.itemAtIndex(target)
                if (target >= 0 && targetItem) {
                    const local = point.y - targetItem.y
                    dropMarker.to = local > targetItem.height / 2 ? target + 1 : target
                    dropMarker.y = (dropMarker.to > target ? targetItem.y + targetItem.height : targetItem.y) - root.contentY + root.originY
                }
            }
        }
    }

    Rectangle {
        id: dropMarker

        property int from: -1
        property int to: -1

        x: root.margin
        width: root.width - 2 * root.margin
        height: 2
        radius: 1
        visible: from >= 0
        color: Appearance.colors.primary
    }
}
