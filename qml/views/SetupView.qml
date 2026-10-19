pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import Swiftify

// connecting the library and playback for the first time (SpotifySetupView)
Flickable {
    id: root

    // no toolbar floats over this page: only a small gap above it
    topMargin: Appearance.sizes.pageTop

    contentHeight: Math.max(height, column.implicitHeight + 72)
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: StyledScrollBar { topPadding: 3 + Appearance.sizes.pageTop }

    Stickers {
        width: root.width
        height: Math.max(root.height, column.y + column.height)
        key: "setup"
        count: 6
    }

    Column {
        id: column
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.max(36, (root.height - implicitHeight) / 2)
        width: Math.min(560, root.width - 72)
        spacing: 20

        MaterialSymbol {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 64
            height: 64
            text: "library_music"
            iconSize: 56
            fill: 1
            color: Appearance.colors.primary
        }

        TitleText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Connect Your Music"
            font.pixelSize: Appearance.fontSize.display
            font.weight: Font.Bold
        }

        StyledText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: "Sign in with your Spotify account to see your library and play music. Spotify Premium is needed to play music."
            color: Appearance.colors.onSurfaceVariant
        }

        // one login, as in spotify's own app: the library rides on the
        // playback session, so the screen goes once it is connected
        TextButton {
            anchors.horizontalCenter: parent.horizontalCenter
            variant: TextButton.Filled
            symbol: Session.loginInProgress ? "" : "login"
            text: Session.loginInProgress ? "Signing In…" : "Sign In with Spotify"
            enabled: !Session.loginInProgress
            onClicked: Session.beginPlaybackLogin()
        }
    }
}
