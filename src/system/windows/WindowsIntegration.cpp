#include "system/windows/WindowsIntegration.h"

#include "playback/PlaybackController.h"
#include "theme/Theme.h"

#include <QApplication>
#include <QQuickItem>
#include <QImage>
#include <QPlatformSurfaceEvent>
#include <QQuickWindow>
#include <QSet>
#include <QStyle>
#include <QTimer>
#include <QWindow>

#include <windows.h>
#include <windowsx.h>
#include <commctrl.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <shobjidl.h>

#include <roapi.h>
#include <winstring.h>
#include <wrl/client.h>
#include <wrl/event.h>
#include <wrl/wrappers/corewrappers.h>
#include <windows.applicationmodel.datatransfer.h>
#include <windows.media.h>
#include <systemmediatransportcontrolsinterop.h>

#include <algorithm>
#include <array>
#include <cwchar>

#ifndef IID_ISystemMediaTransportControlsInterop
static const GUID IID_ISystemMediaTransportControlsInterop = {
    0xcda0807a, 0x4416, 0x4121, {0x94, 0x07, 0xda, 0x86, 0x9e, 0x99, 0x5e, 0x95}
};
#endif

namespace swiftify {

namespace {

constexpr UINT kPrevious = 1;
constexpr UINT kPlayPause = 2;
constexpr UINT kNext = 3;
constexpr DWORD kImmersiveDarkMode = 20;
constexpr DWORD kCornerPreference = 33;
constexpr DWORD kBorderColor = 34;
constexpr DWORD kCaptionColor = 35;
constexpr DWORD kTextColor = 36;

COLORREF nativeColor(const QColor &color)
{
    return RGB(color.red(), color.green(), color.blue());
}

} // namespace

struct WindowsIntegration::Native {
    ITaskbarList3 *taskbar = nullptr;
    UINT taskbarCreated = RegisterWindowMessageW(L"TaskbarButtonCreated");
    bool ownsCom = false;
    bool buttonsAdded = false;
    QSet<quintptr> readyWindows;
    HWND handle = nullptr;
    std::array<HICON, 4> icons {};

    Microsoft::WRL::ComPtr<ABI::Windows::Media::ISystemMediaTransportControls> controls;
    EventRegistrationToken buttonToken {};

    Native()
    {
        ownsCom = SUCCEEDED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED));
        const std::array<QStyle::StandardPixmap, 4> symbols {
            QStyle::SP_MediaSkipBackward, QStyle::SP_MediaPlay,
            QStyle::SP_MediaPause, QStyle::SP_MediaSkipForward
        };
        for (size_t index = 0; index < symbols.size(); ++index) {
            icons[index] = QApplication::style()->standardIcon(symbols[index]).pixmap(24).toImage().toHICON();
        }
    }

    void cleanupMediaControls()
    {
        if (controls) {
            if (buttonToken.value != 0) {
                controls->remove_ButtonPressed(buttonToken);
                buttonToken.value = 0;
            }
            controls->put_IsEnabled(false);
            controls.Reset();
        }
    }

    ~Native()
    {
        if (handle) RemoveWindowSubclass(handle, &Native::windowProcedure, reinterpret_cast<UINT_PTR>(this));
        if (taskbar) {
            taskbar->Release();
        }
        for (HICON icon : icons) {
            if (icon) DestroyIcon(icon);
        }
        cleanupMediaControls();
        if (ownsCom) CoUninitialize();
    }

    /// the work area of the monitor the window is on, less a pixel on any
    /// edge an auto-hidden taskbar waits at: a window that covers the whole
    /// monitor would keep it from showing (windows takes it for a full
    /// screen game)
    static RECT maximizedBounds(HWND window, RECT *monitorBounds = nullptr)
    {
        MONITORINFO monitor {sizeof(MONITORINFO)};
        RECT bounds {};
        if (!GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor)) {
            GetWindowRect(window, &bounds);
            return bounds;
        }
        bounds = monitor.rcWork;
        if (monitorBounds) {
            *monitorBounds = monitor.rcMonitor;
        }
        const auto autoHidden = [&](UINT edge) {
            APPBARDATA bar {sizeof(APPBARDATA)};
            bar.uEdge = edge;
            bar.rc = monitor.rcMonitor;
            return SHAppBarMessage(ABM_GETAUTOHIDEBAREX, &bar) != 0;
        };
        if (autoHidden(ABE_BOTTOM)) bounds.bottom -= 1;
        else if (autoHidden(ABE_TOP)) bounds.top += 1;
        else if (autoHidden(ABE_LEFT)) bounds.left += 1;
        else if (autoHidden(ABE_RIGHT)) bounds.right -= 1;
        return bounds;
    }

    /// the resize border under the pointer, or HTNOWHERE
    static LRESULT resizeEdge(HWND window, LPARAM lParam, WindowsIntegration *integration)
    {
        RECT bounds {};
        if (!GetWindowRect(window, &bounds)) {
            return HTNOWHERE;
        }
        using WindowDpi = UINT (WINAPI *)(HWND);
        using MetricsForDpi = int (WINAPI *)(int, UINT);
        static const auto windowDpi = reinterpret_cast<WindowDpi>(GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetDpiForWindow"));
        static const auto metricsForDpi = reinterpret_cast<MetricsForDpi>(GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetSystemMetricsForDpi"));
        const UINT dpi = windowDpi ? windowDpi(window) : qRound(96 * integration->m_window->devicePixelRatio());
        const int border = metricsForDpi
            ? metricsForDpi(SM_CXSIZEFRAME, dpi) + metricsForDpi(SM_CXPADDEDBORDER, dpi)
            : GetSystemMetrics(SM_CXSIZEFRAME) + GetSystemMetrics(SM_CXPADDEDBORDER);
        const int horizontal = GET_X_LPARAM(lParam);
        const int vertical = GET_Y_LPARAM(lParam);
        const bool left = horizontal >= bounds.left && horizontal < bounds.left + border;
        const bool right = horizontal < bounds.right && horizontal >= bounds.right - border;
        const bool top = vertical >= bounds.top && vertical < bounds.top + border;
        const bool bottom = vertical < bounds.bottom && vertical >= bounds.bottom - border;
        if (top && left) return HTTOPLEFT;
        if (top && right) return HTTOPRIGHT;
        if (bottom && left) return HTBOTTOMLEFT;
        if (bottom && right) return HTBOTTOMRIGHT;
        if (left) return HTLEFT;
        if (right) return HTRIGHT;
        if (top) return HTTOP;
        if (bottom) return HTBOTTOM;
        return HTNOWHERE;
    }

    static LRESULT CALLBACK windowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam,
                                            UINT_PTR identity, DWORD_PTR context)
    {
        auto *integration = reinterpret_cast<WindowsIntegration *>(context);
        if (message == WM_THEMECHANGED || message == WM_DWMCOMPOSITIONCHANGED || message == WM_STYLECHANGED) {
            QTimer::singleShot(0, integration, &WindowsIntegration::styleWindow);
        }
        if (integration->m_window && !(GetWindowLongPtrW(window, GWL_STYLE) & WS_CAPTION)) {
            const bool fullScreen = integration->m_window->visibility() == QWindow::FullScreen;
            if (message == WM_NCCALCSIZE) {
                // maximized, the window fills the work area and no more: by
                // the monitor it is on, not the rectangle windows proposes,
                // which reaches past the edges, onto a next monitor
                if (IsZoomed(window) && !fullScreen) {
                    auto *bounds = wParam ? &reinterpret_cast<NCCALCSIZE_PARAMS *>(lParam)->rgrc[0]
                                         : reinterpret_cast<RECT *>(lParam);
                    *bounds = maximizedBounds(window);
                }
                return 0;
            }
            if (message == WM_GETMINMAXINFO && !fullScreen) {
                const LRESULT result = DefSubclassProc(window, message, wParam, lParam);
                RECT monitor {};
                const RECT work = maximizedBounds(window, &monitor);
                if (monitor.right > monitor.left) {
                    auto *limits = reinterpret_cast<MINMAXINFO *>(lParam);
                    limits->ptMaxPosition = {work.left - monitor.left, work.top - monitor.top};
                    limits->ptMaxSize = {work.right - work.left, work.bottom - work.top};
                }
                return result;
            }
            if (message == WM_NCHITTEST && !fullScreen) {
                const LRESULT edge = IsZoomed(window) ? HTNOWHERE : resizeEdge(window, lParam, integration);
                if (edge != HTNOWHERE) {
                    return edge;
                }
                // the title bar's empty stretches are windows' own caption:
                // it moves the window, snaps it, restores it from maximized
                // under the pointer and maximizes it on a double click
                POINT point {GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
                if (ScreenToClient(window, &point)) {
                    const qreal ratio = integration->m_window->devicePixelRatio();
                    if (integration->isCaptionAt(QPointF(point.x / ratio, point.y / ratio))) {
                        return HTCAPTION;
                    }
                }
                return HTCLIENT;
            }
        }
        if (message == WM_COMMAND && HIWORD(wParam) == THBN_CLICKED) {
            MSG native {};
            native.hwnd = window;
            native.message = message;
            native.wParam = wParam;
            native.lParam = lParam;
            qintptr result = 0;
            if (integration->nativeEventFilter(QByteArrayLiteral("windows_generic_MSG"), &native, &result)) return result;
        } else if (message == WM_NCDESTROY) {
            RemoveWindowSubclass(window, &Native::windowProcedure, identity);
            integration->m_native->cleanupMediaControls();
            integration->m_native->handle = nullptr;
            integration->m_native->buttonsAdded = false;
            integration->m_native->readyWindows.remove(reinterpret_cast<quintptr>(window));
        }
        return DefSubclassProc(window, message, wParam, lParam);
    }
};

namespace {

/// whether an item takes the pointer itself: a control, or an item with a
/// tap, drag or other pointer handler (one that only watches hovering lets
/// the pointer through, as it does in qt quick)
bool takesPointer(const QQuickItem *item)
{
    if (item->acceptedMouseButtons() != Qt::NoButton) {
        return true;
    }
    for (const QObject *child : item->children()) {
        if (child->inherits("QQuickPointerHandler") && !child->inherits("QQuickHoverHandler")) {
            return true;
        }
    }
    return false;
}

enum class Hit { Nothing, Client, Caption };

/// what takes the pointer at `point` (in `item`'s coordinates), looking from
/// the top of the stack down, as qt quick delivers a press
Hit hitAt(const QQuickItem *item, const QPointF &point)
{
    if (!item->isVisible() || !item->isEnabled() || item->opacity() <= 0) {
        return Hit::Nothing;
    }
    const bool inside = item->contains(point);
    if (item->clip() && !inside) {
        return Hit::Nothing;
    }
    QList<QQuickItem *> children = item->childItems();
    std::stable_sort(children.begin(), children.end(),
                     [](const QQuickItem *a, const QQuickItem *b) { return a->z() < b->z(); });
    for (auto child = children.crbegin(); child != children.crend(); ++child) {
        const Hit hit = hitAt(*child, item->mapToItem(*child, point));
        if (hit != Hit::Nothing) {
            return hit;
        }
    }
    if (!inside) {
        return Hit::Nothing;
    }
    if (item->objectName() == QLatin1StringView("windowCaption")) {
        return Hit::Caption;
    }
    return takesPointer(item) ? Hit::Client : Hit::Nothing;
}

} // namespace

bool WindowsIntegration::isCaptionAt(const QPointF &point) const
{
    const auto *quick = qobject_cast<QQuickWindow *>(m_window.data());
    if (!quick || !quick->contentItem()) {
        return false;
    }
    // the content item sits in the window's root item with any popups'
    // overlay over it
    const QQuickItem *root = quick->contentItem()->parentItem() ? quick->contentItem()->parentItem() : quick->contentItem();
    return hitAt(root, root->mapFromScene(point)) == Hit::Caption;
}

void WindowsIntegration::toggleMaximized(QWindow *window)
{
    if (!window) return;
    // windows' own maximize, as snapping and the title bar's double click do,
    // so windows and qt agree on what the window is
    const HWND handle = reinterpret_cast<HWND>(window->winId());
    ShowWindow(handle, IsZoomed(handle) ? SW_RESTORE : SW_MAXIMIZE);
}

void WindowsIntegration::share(QWindow *window, const QString &title, const QString &url)
{
    if (!window) return;
    using namespace ABI::Windows::ApplicationModel::DataTransfer;
    using namespace ABI::Windows::Foundation;
    using Microsoft::WRL::Callback;
    using Microsoft::WRL::ComPtr;
    using Microsoft::WRL::Wrappers::HString;
    using Microsoft::WRL::Wrappers::HStringReference;

    const HWND handle = reinterpret_cast<HWND>(window->winId());
    ComPtr<IDataTransferManagerInterop> interop;
    HStringReference managerClass(RuntimeClass_Windows_ApplicationModel_DataTransfer_DataTransferManager);
    if (FAILED(RoGetActivationFactory(managerClass.Get(), IID_PPV_ARGS(&interop))) || !interop) return;
    ComPtr<IDataTransferManager> manager;
    if (FAILED(interop->GetForWindow(handle, IID_PPV_ARGS(&manager))) || !manager) return;

    // one share at a time: the last one's handler goes before this one's
    static ComPtr<IDataTransferManager> s_manager;
    static EventRegistrationToken s_token {};
    if (s_manager && s_token.value) {
        s_manager->remove_DataRequested(s_token);
    }
    s_manager = manager;
    s_token = {};

    const std::wstring wideTitle = title.toStdWString();
    const std::wstring wideUrl = url.toStdWString();
    manager->add_DataRequested(
        Callback<ITypedEventHandler<DataTransferManager *, DataRequestedEventArgs *>>(
            [wideTitle, wideUrl](IDataTransferManager *, IDataRequestedEventArgs *args) -> HRESULT {
                ComPtr<IDataRequest> request;
                ComPtr<IDataPackage> package;
                if (FAILED(args->get_Request(&request)) || FAILED(request->get_Data(&package))) return S_OK;
                ComPtr<IDataPackagePropertySet> properties;
                if (SUCCEEDED(package->get_Properties(&properties))) {
                    HString name;
                    name.Set(wideTitle.c_str(), UINT32(wideTitle.size()));
                    properties->put_Title(name.Get());
                }
                // the link, for apps that take one, and as text for the rest
                ComPtr<IUriRuntimeClassFactory> uriFactory;
                HStringReference uriClass(RuntimeClass_Windows_Foundation_Uri);
                ComPtr<IDataPackage2> package2;
                if (SUCCEEDED(RoGetActivationFactory(uriClass.Get(), IID_PPV_ARGS(&uriFactory))) && uriFactory
                    && SUCCEEDED(package.As(&package2))) {
                    HString link;
                    link.Set(wideUrl.c_str(), UINT32(wideUrl.size()));
                    ComPtr<IUriRuntimeClass> uri;
                    if (SUCCEEDED(uriFactory->CreateUri(link.Get(), &uri)) && uri) {
                        package2->SetWebLink(uri.Get());
                    }
                }
                HString text;
                text.Set(wideUrl.c_str(), UINT32(wideUrl.size()));
                package->SetText(text.Get());
                return S_OK;
            }).Get(),
        &s_token);
    interop->ShowShareUIForWindow(handle);
}

void WindowsIntegration::minimize(QWindow *window)
{
    if (!window) return;
    ShowWindow(reinterpret_cast<HWND>(window->winId()), SW_MINIMIZE);
}

void WindowsIntegration::initializeProcess()
{
    SetCurrentProcessExplicitAppUserModelID(L"dev.addenator.Swiftify.Qt");
}

void WindowsIntegration::setNativeTitleBar(QWindow *window, bool enabled)
{
    if (!window) return;
    const Qt::WindowFlags flags = enabled
        ? Qt::Window | Qt::WindowTitleHint | Qt::WindowSystemMenuHint | Qt::WindowMinMaxButtonsHint | Qt::WindowCloseButtonHint
        : Qt::Window | Qt::FramelessWindowHint;
    if (window->flags() == flags) return;
    if (!window->handle() || QGuiApplication::platformName() != QLatin1StringView("windows")) {
        window->setFlags(flags);
        return;
    }
    WINDOWPLACEMENT placement {sizeof(WINDOWPLACEMENT)};
    const bool placed = GetWindowPlacement(reinterpret_cast<HWND>(window->winId()), &placement);
    const auto visibility = window->visibility();
    const auto states = window->windowStates();
    const bool active = window->isActive();
    window->hide();
    window->destroy();
    window->setWindowStates(Qt::WindowNoState);
    window->setFlags(flags);
    window->create();
    if (placed) {
        placement.showCmd = SW_HIDE;
        SetWindowPlacement(reinterpret_cast<HWND>(window->winId()), &placement);
    }
    window->setWindowStates(states);
    window->setVisibility(visibility);
    if (active && window->isVisible()) window->requestActivate();
}

WindowsIntegration::WindowsIntegration(PlaybackController *player, Theme *theme, QObject *parent)
    : QObject(parent), m_player(player), m_theme(theme)
{
    if (QGuiApplication::platformName() != QLatin1StringView("windows")) {
        return;
    }
    m_native = std::make_unique<Native>();
    qApp->installNativeEventFilter(this);
    connect(m_theme, &Theme::schemeChanged, this, &WindowsIntegration::styleWindow);
    connect(m_player, &PlaybackController::playingChanged, this, &WindowsIntegration::updateButtons);
    connect(m_player, &PlaybackController::playingChanged, this, &WindowsIntegration::updateMediaControls);
    connect(m_player, &PlaybackController::queueChanged, this, &WindowsIntegration::updateButtons);
    connect(m_player, &PlaybackController::queueChanged, this, &WindowsIntegration::updateMediaControls);
    connect(m_player, &PlaybackController::currentSongChanged, this, &WindowsIntegration::updateButtons);
    connect(m_player, &PlaybackController::currentSongChanged, this, &WindowsIntegration::updateMediaControls);
    connect(m_player, &PlaybackController::currentSongChanged, this, &WindowsIntegration::updateMediaMetadata);
    connect(m_player, &PlaybackController::mediaStateChanged, this, &WindowsIntegration::updateMediaControls);
    connect(m_player, &PlaybackController::mediaStateChanged, this, &WindowsIntegration::updateMediaMetadata);
    connect(m_player, &PlaybackController::loadingChanged, this, &WindowsIntegration::updateProgress);
    connect(m_player, &PlaybackController::livePositionChanged, this, &WindowsIntegration::updateProgress);
    connect(m_player, &PlaybackController::durationChanged, this, &WindowsIntegration::updateProgress);
}

WindowsIntegration::~WindowsIntegration()
{
    if (m_native) {
        qApp->removeNativeEventFilter(this);
        m_native->cleanupMediaControls();
        if (m_window && m_native->taskbar) {
            m_native->taskbar->SetProgressState(reinterpret_cast<HWND>(m_window->winId()), TBPF_NOPROGRESS);
        }
    }
}

void WindowsIntegration::setWindow(QWindow *window)
{
    if (m_window == window || !m_native) {
        return;
    }
    if (m_window) {
        m_window->removeEventFilter(this);
        disconnect(m_window, nullptr, this, nullptr);
    }
    if (m_native->handle) {
        RemoveWindowSubclass(m_native->handle, &Native::windowProcedure, reinterpret_cast<UINT_PTR>(m_native.get()));
        m_native->cleanupMediaControls();
        m_native->handle = nullptr;
    }
    m_window = window;
    m_native->buttonsAdded = false;
    if (!m_window) return;
    m_window->installEventFilter(this);
    m_window->create();
    attachWindow();
    connect(m_window, &QWindow::visibleChanged, this, [this](bool visible) {
        if (visible) {
            styleWindow();
            QTimer::singleShot(0, this, &WindowsIntegration::initializeTaskbar);
            QTimer::singleShot(0, this, &WindowsIntegration::initializeMediaControls);
        }
    });
    if (auto *quick = qobject_cast<QQuickWindow *>(m_window.data())) {
        connect(quick, &QQuickWindow::colorChanged, this, &WindowsIntegration::styleWindow);
    }
    styleWindow();
    QTimer::singleShot(0, this, &WindowsIntegration::initializeTaskbar);
    QTimer::singleShot(0, this, &WindowsIntegration::initializeMediaControls);
}

void WindowsIntegration::attachWindow()
{
    if (!m_window || !m_native || !m_window->handle()) return;
    const HWND handle = reinterpret_cast<HWND>(m_window->winId());
    if (m_native->handle == handle) return;
    if (m_native->handle) {
        RemoveWindowSubclass(m_native->handle, &Native::windowProcedure, reinterpret_cast<UINT_PTR>(m_native.get()));
    }
    m_native->handle = nullptr;
    m_native->buttonsAdded = false;
    if (SetWindowSubclass(handle, &Native::windowProcedure, reinterpret_cast<UINT_PTR>(m_native.get()),
                          reinterpret_cast<DWORD_PTR>(this))) {
        m_native->handle = handle;
    }
}

bool WindowsIntegration::eventFilter(QObject *watched, QEvent *event)
{
    if (watched == m_window && event->type() == QEvent::PlatformSurface) {
        const auto *surface = static_cast<QPlatformSurfaceEvent *>(event);
        if (surface->surfaceEventType() == QPlatformSurfaceEvent::SurfaceCreated) {
            styleWindow();
            QTimer::singleShot(0, this, &WindowsIntegration::initializeTaskbar);
            QTimer::singleShot(0, this, &WindowsIntegration::initializeMediaControls);
        }
    }
    return QObject::eventFilter(watched, event);
}

void WindowsIntegration::styleWindow()
{
    if (!m_window || !m_native || !m_window->handle()) return;
    attachWindow();
    const HWND handle = reinterpret_cast<HWND>(m_window->winId());
    if (m_window->flags().testFlag(Qt::FramelessWindowHint) && m_window->visibility() != QWindow::FullScreen) {
        const LONG_PTR current = GetWindowLongPtrW(handle, GWL_STYLE);
        const LONG_PTR desired = (current | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SYSMENU) & ~WS_CAPTION;
        if (current != desired) {
            SetWindowLongPtrW(handle, GWL_STYLE, desired);
            SetWindowPos(handle, nullptr, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
        }
    }
    const auto *quick = qobject_cast<QQuickWindow *>(m_window.data());
    const QColor background = quick ? quick->color() : m_theme->colors()->layer0();
    const BOOL dark = background.lightnessF() < 0.5;
    const DWORD corners = 2;
    const COLORREF border = 0xfffffffe;
    const COLORREF caption = nativeColor(background);
    const COLORREF text = dark ? RGB(255, 255, 255) : RGB(0, 0, 0);
    DwmSetWindowAttribute(handle, kImmersiveDarkMode, &dark, sizeof(dark));
    DwmSetWindowAttribute(handle, kCornerPreference, &corners, sizeof(corners));
    DwmSetWindowAttribute(handle, kBorderColor, &border, sizeof(border));
    DwmSetWindowAttribute(handle, kCaptionColor, &caption, sizeof(caption));
    DwmSetWindowAttribute(handle, kTextColor, &text, sizeof(text));
}

void WindowsIntegration::initializeTaskbar()
{
    if (!m_window || !m_native || !m_window->isVisible()) return;
    if (!m_native->readyWindows.contains(quintptr(m_window->winId()))) return;
    if (!m_native->taskbar) {
        if (FAILED(CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER,
                                    IID_ITaskbarList3, reinterpret_cast<void **>(&m_native->taskbar)))) {
            return;
        }
        if (FAILED(m_native->taskbar->HrInit())) {
            m_native->taskbar->Release();
            m_native->taskbar = nullptr;
            return;
        }
    }
    updateButtons();
}

void WindowsIntegration::updateButtons()
{
    if (!m_window || !m_native || !m_native->taskbar || !m_window->isVisible()) return;
    const HWND handle = reinterpret_cast<HWND>(m_window->winId());
    std::array<THUMBBUTTON, 3> buttons {};
    const std::array<HICON, 3> icons {
        m_native->icons[0], m_native->icons[m_player->isPlaying() ? 2 : 1], m_native->icons[3]
    };
    const std::array<const wchar_t *, 3> tips {
        L"Previous", m_player->isPlaying() ? L"Pause" : L"Play", L"Next"
    };
    const std::array<bool, 3> enabled {
        m_player->hasSong(), m_player->hasSong(), m_player->canSkipForward()
    };
    for (size_t index = 0; index < buttons.size(); ++index) {
        buttons[index].dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
        buttons[index].iId = UINT(index) + 1;
        buttons[index].hIcon = icons[index];
        buttons[index].dwFlags = enabled[index] ? THBF_ENABLED : THBF_DISABLED;
        std::wcsncpy(buttons[index].szTip, tips[index], std::size(buttons[index].szTip) - 1);
    }
    if (!m_native->buttonsAdded) {
        m_native->buttonsAdded = SUCCEEDED(m_native->taskbar->ThumbBarAddButtons(handle, UINT(buttons.size()), buttons.data()));
    } else {
        m_native->taskbar->ThumbBarUpdateButtons(handle, UINT(buttons.size()), buttons.data());
    }
    const Song song = m_player->currentSong();
    const QString tooltip = m_player->hasSong() ? song.name + QStringLiteral(" — ") + song.artists : QStringLiteral("Swiftify");
    m_native->taskbar->SetThumbnailTooltip(handle, reinterpret_cast<LPCWSTR>(tooltip.utf16()));
    updateProgress();
}

void WindowsIntegration::updateProgress()
{
    if (!m_window || !m_native || !m_native->taskbar || !m_window->isVisible()) return;
    const HWND handle = reinterpret_cast<HWND>(m_window->winId());
    if (!m_player->hasSong()) {
        m_native->taskbar->SetProgressState(handle, TBPF_NOPROGRESS);
    } else if (m_player->isLoading()) {
        m_native->taskbar->SetProgressState(handle, TBPF_INDETERMINATE);
    } else if (m_player->durationMs() > 0) {
        m_native->taskbar->SetProgressState(handle, m_player->isPlaying() ? TBPF_NORMAL : TBPF_PAUSED);
        m_native->taskbar->SetProgressValue(handle,
            std::min<quint64>(m_player->livePositionMs(), m_player->durationMs()), m_player->durationMs());
    } else {
        m_native->taskbar->SetProgressState(handle, TBPF_NOPROGRESS);
    }
}

bool WindowsIntegration::nativeEventFilter(const QByteArray &eventType, void *message, qintptr *result)
{
    if (!m_native || (eventType != "windows_generic_MSG" && eventType != "windows_dispatcher_MSG")) return false;
    const auto *native = static_cast<MSG *>(message);
    if (m_native->taskbarCreated && native->message == m_native->taskbarCreated) {
        m_native->readyWindows.insert(reinterpret_cast<quintptr>(native->hwnd));
        if (!m_window || !m_window->handle() || native->hwnd != reinterpret_cast<HWND>(m_window->winId())) return false;
        m_native->buttonsAdded = false;
        if (m_native->taskbar) {
            m_native->taskbar->Release();
            m_native->taskbar = nullptr;
        }
        initializeTaskbar();
        return false;
    }
    if (!m_window || !m_window->handle() || native->hwnd != reinterpret_cast<HWND>(m_window->winId())) return false;
    if (native->message == WM_COMMAND && HIWORD(native->wParam) == THBN_CLICKED) {
        switch (LOWORD(native->wParam)) {
        case kPrevious: m_player->skipBackward(); break;
        case kPlayPause: m_player->togglePlayback(); break;
        case kNext: m_player->skipForward(); break;
        default: return false;
        }
        if (result) *result = 0;
        return true;
    }
    return false;
}

void WindowsIntegration::initializeMediaControls()
{
    if (!m_window || !m_native || !m_window->handle()) return;
    const HWND handle = reinterpret_cast<HWND>(m_window->winId());
    if (m_native->controls) return;

    using namespace ABI::Windows::Media;
    using namespace ABI::Windows::Foundation;
    using Microsoft::WRL::Callback;
    using Microsoft::WRL::ComPtr;
    using Microsoft::WRL::Wrappers::HStringReference;

    ComPtr<ISystemMediaTransportControlsInterop> interop;
    HStringReference smtcId(RuntimeClass_Windows_Media_SystemMediaTransportControls);
    if (FAILED(RoGetActivationFactory(smtcId.Get(), IID_PPV_ARGS(&interop))) || !interop) {
        return;
    }

    if (FAILED(interop->GetForWindow(handle, IID_PPV_ARGS(&m_native->controls))) || !m_native->controls) {
        return;
    }

    m_native->controls->put_IsEnabled(true);
    m_native->controls->put_IsPlayEnabled(true);
    m_native->controls->put_IsPauseEnabled(true);
    m_native->controls->put_IsStopEnabled(true);
    m_native->controls->put_IsNextEnabled(true);
    m_native->controls->put_IsPreviousEnabled(true);

    m_native->buttonToken.value = 0;
    m_native->controls->add_ButtonPressed(
        Callback<ITypedEventHandler<SystemMediaTransportControls*, SystemMediaTransportControlsButtonPressedEventArgs*>>(
            [this](ISystemMediaTransportControls *, ISystemMediaTransportControlsButtonPressedEventArgs *args) -> HRESULT {
                SystemMediaTransportControlsButton button;
                if (args && SUCCEEDED(args->get_Button(&button))) {
                    QMetaObject::invokeMethod(this, [this, button] {
                        handleMediaButton(int(button));
                    }, Qt::QueuedConnection);
                }
                return S_OK;
            }
        ).Get(),
        &m_native->buttonToken
    );

    updateMediaMetadata();
    updateMediaControls();
}

void WindowsIntegration::handleMediaButton(int button)
{
    using namespace ABI::Windows::Media;
    switch (button) {
    case SystemMediaTransportControlsButton_Play:
        m_player->resume();
        break;
    case SystemMediaTransportControlsButton_Pause:
    case SystemMediaTransportControlsButton_Stop:
        if (m_player->isPlaying() || m_player->isLoading()) {
            m_player->pause();
        }
        break;
    case SystemMediaTransportControlsButton_Next:
        m_player->skipForward();
        break;
    case SystemMediaTransportControlsButton_Previous:
        m_player->skipBackward();
        break;
    default:
        break;
    }
}

void WindowsIntegration::updateMediaControls()
{
    if (!m_native || !m_native->controls) return;
    using namespace ABI::Windows::Media;
    if (!m_player->hasSong()) {
        m_native->controls->put_PlaybackStatus(MediaPlaybackStatus_Closed);
        m_native->controls->put_IsPlayEnabled(false);
        m_native->controls->put_IsPauseEnabled(false);
        m_native->controls->put_IsNextEnabled(false);
        m_native->controls->put_IsPreviousEnabled(false);
    } else {
        m_native->controls->put_PlaybackStatus(m_player->isPlaying() ? MediaPlaybackStatus_Playing : MediaPlaybackStatus_Paused);
        m_native->controls->put_IsPlayEnabled(true);
        m_native->controls->put_IsPauseEnabled(true);
        m_native->controls->put_IsNextEnabled(m_player->canSkipForward());
        m_native->controls->put_IsPreviousEnabled(m_player->canSkipBackward());
    }
}

void WindowsIntegration::updateMediaMetadata()
{
    if (!m_native || !m_native->controls) return;
    using namespace ABI::Windows::Media;
    using namespace ABI::Windows::Foundation;
    using namespace ABI::Windows::Storage::Streams;
    using Microsoft::WRL::ComPtr;
    using Microsoft::WRL::Wrappers::HString;
    using Microsoft::WRL::Wrappers::HStringReference;

    ComPtr<ISystemMediaTransportControlsDisplayUpdater> updater;
    if (FAILED(m_native->controls->get_DisplayUpdater(&updater)) || !updater) {
        return;
    }

    if (!m_player->hasSong()) {
        updater->ClearAll();
        updater->Update();
        return;
    }

    const Song song = m_player->currentSong();
    updater->put_Type(MediaPlaybackType_Music);

    ComPtr<IMusicDisplayProperties> music;
    if (SUCCEEDED(updater->get_MusicProperties(&music)) && music) {
        HString title;
        title.Set(reinterpret_cast<const wchar_t *>(song.name.utf16()), UINT32(song.name.length()));
        music->put_Title(title.Get());

        HString artist;
        artist.Set(reinterpret_cast<const wchar_t *>(song.artists.utf16()), UINT32(song.artists.length()));
        music->put_Artist(artist.Get());

        if (!song.albumName.isEmpty()) {
            HString album;
            album.Set(reinterpret_cast<const wchar_t *>(song.albumName.utf16()), UINT32(song.albumName.length()));
            ComPtr<IMusicDisplayProperties2> music2;
            if (SUCCEEDED(music.As(&music2)) && music2) {
                music2->put_AlbumTitle(album.Get());
            }
        }
    }

    if (song.artworkUrl.isValid()) {
        ComPtr<IUriRuntimeClassFactory> uriFactory;
        HStringReference uriClassName(RuntimeClass_Windows_Foundation_Uri);
        if (SUCCEEDED(RoGetActivationFactory(uriClassName.Get(), IID_PPV_ARGS(&uriFactory))) && uriFactory) {
            const QString urlStr = song.artworkUrl.toString();
            HString uriHStr;
            uriHStr.Set(reinterpret_cast<const wchar_t *>(urlStr.utf16()), UINT32(urlStr.length()));
            ComPtr<IUriRuntimeClass> uri;
            if (SUCCEEDED(uriFactory->CreateUri(uriHStr.Get(), &uri)) && uri) {
                ComPtr<IRandomAccessStreamReferenceStatics> streamStatics;
                HStringReference streamClassName(RuntimeClass_Windows_Storage_Streams_RandomAccessStreamReference);
                if (SUCCEEDED(RoGetActivationFactory(streamClassName.Get(), IID_PPV_ARGS(&streamStatics))) && streamStatics) {
                    ComPtr<IRandomAccessStreamReference> thumbnail;
                    if (SUCCEEDED(streamStatics->CreateFromUri(uri.Get(), &thumbnail)) && thumbnail) {
                        updater->put_Thumbnail(thumbnail.Get());
                    }
                }
            }
        }
    }

    updater->Update();
}

} // namespace swiftify
