pragma ComponentBehavior: Bound
import QtQuick
import Swiftify

// while the spotify login is open in the browser. the browser lands on
// swiftify's local redirect address, and this closes by itself.
StyledDialog {
    id: root

    // the callback ending the wait is not a cancel; only Esc or Cancel is.
    Connections {
        target: Session
        function onLoginChanged() {
            if (Session.loginInProgress && !root.opened) {
                root.open()
            } else if (!Session.loginInProgress && root.opened) {
                root.accept()
            }
        }
    }

    headline: "Waiting for your browser…"
symbol: "key"
iconShape: "clover4"
    body: "Sign in to Spotify in the browser window that just opened."
    onRejected: Session.cancelLogin()

    buttons: [
        TextButton {
            variant: TextButton.Text
            text: "Cancel"
            onClicked: Session.cancelLogin()
        },
        TextButton {
            variant: TextButton.Text
            text: "Copy Link"
            onClicked: {
                App.copyToClipboard(Session.authorizationUrl.toString())
                UiState.toastRequested("Login link copied")
            }
        },
        TextButton {
            variant: TextButton.Tonal
            text: "Open Again"
            onClicked: Session.reopenLoginPage()
        }
    ]
}
