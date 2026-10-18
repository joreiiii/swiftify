#pragma once

#include <QObject>

class QQuickWindow;

namespace swiftify {

/// a press anywhere outside the text field being typed in takes its focus
/// away, as in a browser: qt quick leaves the focus where it was when what
/// was pressed takes none of its own, and a search field kept its recent
/// searches showing until something else was typed into
class FocusRelease : public QObject {
    Q_OBJECT

public:
    using QObject::QObject;

    void watch(QQuickWindow *window);

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;
};

} // namespace swiftify
