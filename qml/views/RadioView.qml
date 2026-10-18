pragma ComponentBehavior: Bound
import QtQuick
import Swiftify

// a song radio, as spotify's: the song it is made from, then songs like it
SongListPage {
    id: root

    /// the song it opened on. a page kept behind a newer one (PageHost)
    /// holds on to its own rather than following the library elsewhere
    property song seed

    Binding {
        target: root
        property: "seed"
        value: Library.radioSeed
        when: root.visible
        restoreMode: Binding.RestoreNone
    }

    songs: Library.radioSongs
    loading: Library.loadingSongs
    loadingText: "Tuning in…"

    hero: CollectionHero {
        artworkUrl: root.seed.artworkUrl
        kind: "RADIO"
        title: root.seed.name + " Radio"
        description: "Based on " + root.seed.name + " by " + root.seed.artists
        facts: Format.joined([Format.songCount(Library.radioSongs.count), Format.totalDuration(Library.radioSongs.totalDurationMs)], "  •  ")

        actions: [
            TextButton {
                iconOnly: parent ? parent.compactActions : false
                compactSize: parent ? parent.actionSize : 48
                implicitHeight: iconOnly ? compactSize : 48
                symbol: "play_arrow"
                burst: "play"
                text: "Play"
                enabled: Library.radioSongs.count > 0
                onClicked: Player.playFromModel(Library.radioSongs, 0)
            },
            TextButton {
                iconOnly: parent ? parent.compactActions : false
                compactSize: parent ? parent.actionSize : 48
                implicitHeight: iconOnly ? compactSize : 48
                variant: TextButton.Tonal
                symbol: "shuffle"
                text: "Shuffle"
                enabled: Library.radioSongs.count > 0
                onClicked: Player.shufflePlay(Library.radioSongs)
            }
        ]
    }
}
