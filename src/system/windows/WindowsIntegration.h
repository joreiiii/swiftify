#pragma once

#include <QAbstractNativeEventFilter>
#include <QObject>
#include <QPointer>

#include <memory>

class QWindow;

namespace swiftify {

class PlaybackController;
class Theme;

class WindowsIntegration : public QObject, public QAbstractNativeEventFilter {
    Q_OBJECT

public:
    WindowsIntegration(PlaybackController *player, Theme *theme, QObject *parent = nullptr);
    ~WindowsIntegration() override;

    static void initializeProcess();
    static void setNativeTitleBar(QWindow *window, bool enabled);
    static void toggleMaximized(QWindow *window);
    static void minimize(QWindow *window);
    /// windows' own share sheet, with a link and its title
    static void share(QWindow *window, const QString &title, const QString &url);
    void setWindow(QWindow *window);
    bool nativeEventFilter(const QByteArray &eventType, void *message, qintptr *result) override;
    bool eventFilter(QObject *watched, QEvent *event) override;

    void handleMediaButton(int button);

private:
    struct Native;

    void attachWindow();
    void styleWindow();
    /// whether the window's own title bar is at `point` (in the window's
    /// logical pixels): an item named "windowCaption" with nothing that
    /// takes the pointer above it. there windows moves, snaps and maximizes
    /// the window itself, as it does by a native title bar
    bool isCaptionAt(const QPointF &point) const;
    void initializeTaskbar();
    void updateButtons();
    void updateProgress();
    void initializeMediaControls();
    void updateMediaControls();
    void updateMediaMetadata();

    PlaybackController *m_player;
    Theme *m_theme;
    QPointer<QWindow> m_window;
    std::unique_ptr<Native> m_native;
};

} // namespace swiftify
