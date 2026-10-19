pragma ComponentBehavior: Bound
import QtQuick
import Swiftify

// the small print under a setting, as spotify's.
StyledText {
    width: parent ? parent.width : 0
    rightPadding: 64
    bottomPadding: 8
    wrapMode: Text.Wrap
    font.pixelSize: Appearance.fontSize.smaller
    color: Appearance.colors.outline
}
