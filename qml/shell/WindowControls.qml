pragma ComponentBehavior: Bound
import QtQuick
import Swiftify

// minimise, maximise and close, for compositors that do not draw their own,
// each on a shape of its own as the top bar's other buttons are
Row {
    id: root

    required property Window window
    property bool compact: false
    property MaterialScheme scheme: Appearance.colors
    layoutDirection: Settings.windowControlsOnRight ? Qt.RightToLeft : Qt.LeftToRight

    spacing: 4

    ToolbarButton {
        objectName: "closeWindowButton"
        scheme: root.scheme
        size: root.compact ? 28 : 36
        iconSize: root.compact ? 15 : 18
        shape: "circle"
        shapeHoverColor: root.scheme.errorContainer
        shapePressedColor: root.scheme.errorContainerActive
        symbol: "close"
        tooltip: "Close window"
        onClicked: root.window.close()
    }
    ToolbarButton {
        objectName: "maximizeWindowButton"
        scheme: root.scheme
        size: root.compact ? 28 : 36
        iconSize: root.compact ? 14 : 16
        shape: "circle"
        symbol: root.window.visibility === Window.Maximized ? "close_fullscreen" : "open_in_full"
        tooltip: root.window.visibility === Window.Maximized ? "Restore" : "Maximize"
        onClicked: App.toggleMaximized(root.window)
    }
    ToolbarButton {
        objectName: "minimizeWindowButton"
        scheme: root.scheme
        size: root.compact ? 28 : 36
        iconSize: root.compact ? 15 : 18
        shape: "circle"
        turnsOnHover: false
        symbol: "remove"
        tooltip: "Minimize"
        onClicked: App.minimizeWindow(root.window)
    }
}
