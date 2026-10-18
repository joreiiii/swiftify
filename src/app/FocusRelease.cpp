#include "app/FocusRelease.h"

#include <QMouseEvent>
#include <QQuickItem>
#include <QQuickWindow>

namespace swiftify {

namespace {

/// whether `scene` (a point in the window) is on `item`
bool covers(const QQuickItem *item, const QPointF &scene)
{
    return item && item->isVisible() && item->contains(item->mapFromScene(scene));
}

} // namespace

void FocusRelease::watch(QQuickWindow *window)
{
    if (window) {
        window->installEventFilter(this);
    }
}

bool FocusRelease::eventFilter(QObject *watched, QEvent *event)
{
    const bool titleBar = event->type() == QEvent::NonClientAreaMouseButtonPress;
    if (event->type() != QEvent::MouseButtonPress && !titleBar) {
        return false;
    }
    auto *window = qobject_cast<QQuickWindow *>(watched);
    QQuickItem *focused = window ? window->activeFocusItem() : nullptr;
    if (!focused || !(focused->inherits("QQuickTextInput") || focused->inherits("QQuickTextEdit"))) {
        return false;
    }
    // a press on the title bar (WindowsIntegration's caption) is outside it
    if (titleBar) {
        focused->setFocus(false, Qt::MouseFocusReason);
        return false;
    }
    const QPointF scene = static_cast<QMouseEvent *>(event)->scenePosition();
    // the field itself, its frame (a search field's clear button is on it),
    // and what drops down from it keep the focus
    if (covers(focused, scene) || covers(focused->parentItem(), scene)) {
        return false;
    }
    if (covers(window->contentItem()->findChild<QQuickItem *>(QStringLiteral("recentSearches")), scene)) {
        return false;
    }
    // the field's own focus goes: the window's content is the focus scope
    // the field sits in, so focusing that would leave the field as it was
    focused->setFocus(false, Qt::MouseFocusReason);
    return false;
}

} // namespace swiftify
