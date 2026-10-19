pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Swiftify

// covers scattered behind something where its stickers would be: blurred,
// faint and drifting slowly up and down, each in its own time. the same key
// lays them out the same way, as the stickers do; artists' pictures are round
Item {
    id: root

    /// what the layout is drawn from: a page's name
    property string key: "swiftify"
    /// the covers, as [{ url, circular }]
    property var covers: []
    property real minimumSize: 70
    property real maximumSize: 200
    property real strength: 1
    readonly property int count: covers.length

    /// a string to a 32-bit seed (fnv-1a)
    function seedOf(text: string): int {
        let hash = 2166136261
        for (let index = 0; index < text.length; ++index) {
            hash ^= text.charCodeAt(index)
            hash = Math.imul(hash, 16777619)
        }
        return hash >>> 0
    }

    /// each cover's place, size and drift, from the key and their number
    readonly property var layout: {
        // mulberry32, so the same key always gives the same scatter
        let state = seedOf(key)
        const next = () => {
            state = (state + 0x6d2b79f5) >>> 0
            let t = state
            t = Math.imul(t ^ (t >>> 15), t | 1)
            t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
            return ((t ^ (t >>> 14)) >>> 0) / 4294967296
        }
        const spots = []
        for (let index = 0; index < count; ++index) {
            // spread across the width a slot each, jittered within it
            spots.push({
                x: (index + 0.15 + 0.7 * next()) / count,
                y: -0.15 + 1.25 * next(),
                size: minimumSize + (maximumSize - minimumSize) * next(),
                angle: -14 + 28 * next(),
                drift: 6 + 8 * next(),
                period: 5200 + 4200 * next()
            })
        }
        return spots
    }

    Repeater {
        model: root.count

        Item {
            id: spot

            required property int index
            readonly property var spec: root.layout[index]
            readonly property var cover: root.covers[index]
            property real lift: 0

            width: spec.size
            height: spec.size
            x: spec.x * root.width - width / 2
            y: spec.y * root.height - height / 2 + lift
            rotation: cover.circular ? 0 : spec.angle
            opacity: (Appearance.colors.dark ? 0.32 : 0.42) * root.strength

            // up and down, slowly, from somewhere along the way
            SequentialAnimation on lift {
                loops: Animation.Infinite
                running: root.visible
                NumberAnimation { from: -spot.spec.drift; to: spot.spec.drift; duration: spot.spec.period / 2; easing.type: Easing.InOutSine }
                NumberAnimation { from: spot.spec.drift; to: -spot.spec.drift; duration: spot.spec.period / 2; easing.type: Easing.InOutSine }
            }

            ArtworkImage {
                anchors.fill: parent
                source: spot.cover.url
                circular: spot.cover.circular
                squiggly: false
                radius: spot.cover.circular ? width / 2 : 10
                layer.enabled: true
                layer.effect: MultiEffect {
                    blurEnabled: true
                    blur: 0.7
                    blurMax: 32
                    saturation: 0.15
                }
            }
        }
    }
}
