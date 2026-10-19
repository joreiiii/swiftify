#include "playback/DjNarrator.h"

#include "core/Async.h"
#include "core/PlaybackCore.h"
#include "playback/PlaybackController.h"
#include "spotify/SpotifyError.h"

#include <QJsonDocument>
#include <QJsonObject>

#include <QLocale>
#include <QLoggingCategory>

#ifdef Q_OS_WIN
#include <sapi.h>
#include <wrl/client.h>
#endif

namespace swiftify {

namespace {

Q_LOGGING_CATEGORY(lcDj, "swiftify.dj")

/// how loud the music plays under the dj's voice, of what it was
constexpr double kDucking = 0.3;

} // namespace

#ifdef Q_OS_WIN
// windows' speech engine (sapi), with a voice for the lines' language
struct DjNarrator::Voice {
    Microsoft::WRL::ComPtr<ISpVoice> voice;

    Voice()
    {
        if (FAILED(CoCreateInstance(__uuidof(SpVoice), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&voice)))) {
            voice.Reset();
        }
    }

    void useLanguage(const QString &language)
    {
        if (!voice || language.isEmpty()) {
            return;
        }
        // sapi names a language by its windows language id, in hex
        const QString attributes = QStringLiteral("Language=%1")
            .arg(QString::number(QLocale(language).language() == QLocale::German ? 0x407
                                 : QLocale(language).language() == QLocale::English ? 0x409 : 0, 16));
        Microsoft::WRL::ComPtr<ISpObjectTokenCategory> category;
        Microsoft::WRL::ComPtr<IEnumSpObjectTokens> tokens;
        Microsoft::WRL::ComPtr<ISpObjectToken> token;
        if (SUCCEEDED(CoCreateInstance(__uuidof(SpObjectTokenCategory), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&category)))
            && SUCCEEDED(category->SetId(SPCAT_VOICES, FALSE))
            && SUCCEEDED(category->EnumTokens(reinterpret_cast<LPCWSTR>(attributes.utf16()), nullptr, &tokens))
            && tokens->Next(1, &token, nullptr) == S_OK) {
            voice->SetVoice(token.Get());
        }
    }

    bool say(const QString &text)
    {
        return voice && SUCCEEDED(voice->Speak(reinterpret_cast<LPCWSTR>(text.utf16()),
                                               SPF_ASYNC | SPF_PURGEBEFORESPEAK | SPF_IS_NOT_XML, nullptr));
    }

    bool isSpeaking() const
    {
        SPVOICESTATUS status {};
        return voice && SUCCEEDED(voice->GetStatus(&status, nullptr)) && status.dwRunningState == SPRS_IS_SPEAKING;
    }

    void stop()
    {
        if (voice) {
            voice->Speak(nullptr, SPF_PURGEBEFORESPEAK, nullptr);
        }
    }
};
#else
// elsewhere the dj keeps quiet
struct DjNarrator::Voice {
    void useLanguage(const QString &) {}
    bool say(const QString &) { return false; }
    bool isSpeaking() const { return false; }
    void stop() {}
};
#endif

DjNarrator::DjNarrator(PlaybackController *player, PlaybackCore *core, QObject *parent)
    : QObject(parent)
    , m_player(player)
    , m_core(core)
    , m_voice(std::make_unique<Voice>())
{
    m_systemVoiceDone.setInterval(150);
    connect(&m_systemVoiceDone, &QTimer::timeout, this, [this] {
        if (!m_voice->isSpeaking()) {
            m_systemVoiceDone.stop();
            m_speaking = false;
            unduck();
        }
    });
    if (m_player) {
        connect(m_player, &PlaybackController::currentSongChanged, this, &DjNarrator::songChanged);
    }
}

DjNarrator::~DjNarrator()
{
    m_voice->stop();
    unduck();
}

void DjNarrator::start(QHash<QString, Lines> lines, QString language)
{
    m_lines = std::move(lines);
    m_language = std::move(language);
    m_previousUri.clear();
    m_voice->useLanguage(m_language);
}

void DjNarrator::songChanged()
{
    if (!m_player || m_lines.isEmpty()) {
        return;
    }
    const QString uri = m_player->currentSong().uri;
    const auto current = m_lines.constFind(uri);
    if (current == m_lines.cend()) {
        // something else plays now: the dj is done
        m_lines.clear();
        m_voice->stop();
        return;
    }
    QList<Line> lines;
    if (const auto previous = m_lines.constFind(m_previousUri); previous != m_lines.cend() && !previous->outro.isEmpty()) {
        lines << previous->outro;
    }
    if (!current->intro.isEmpty()) {
        lines << current->intro;
    }
    m_previousUri = uri;
    // one thing said at a time: a skip while the dj talks says nothing more
    if (!lines.isEmpty() && !m_speaking) {
        detach(speak(lines));
    }
}

QCoro::Task<> DjNarrator::speak(QList<Line> lines)
{
    QPointer<DjNarrator> self(this);
    m_speaking = true;
    duck();
    for (qsizetype index = 0; index < lines.size(); ++index) {
        const Line &line = lines.at(index);
        try {
            const QJsonObject request {{QStringLiteral("op"), QStringLiteral("djSay")},
                                       {QStringLiteral("ssml"), line.ssml},
                                       {QStringLiteral("language"), m_language},
                                       {QStringLiteral("voice"), line.voice},
                                       {QStringLiteral("provider"), line.provider},
                                       {QStringLiteral("sampleRate"), line.sampleRate}};
            co_await m_core->libraryJson(QJsonDocument(request).toJson(QJsonDocument::Compact));
            if (!self) {
                co_return;
            }
        } catch (const SpotifyError &error) {
            if (!self) {
                co_return;
            }
            // the rest in the system's voice, which keeps the music down
            // until it is done
            qCInfo(lcDj).noquote() << "the dj's own voice:" << error.message();
            QStringList words;
            for (qsizetype rest = index; rest < lines.size(); ++rest) {
                words << lines.at(rest).text;
            }
            words.removeAll(QString());
            sayWithSystemVoice(words.join(u' '));
            co_return;
        }
    }
    m_speaking = false;
    unduck();
}

void DjNarrator::sayWithSystemVoice(const QString &text)
{
    if (text.isEmpty() || !m_voice->say(text)) {
        m_speaking = false;
        unduck();
        return;
    }
    m_systemVoiceDone.start();
}

void DjNarrator::duck()
{
    // the music goes down under the voice; the volume itself, and what is
    // saved of it, stays as it is
    if (m_player) {
        m_player->setDucking(kDucking);
    }
}

void DjNarrator::unduck()
{
    if (m_player) {
        m_player->setDucking(1.0);
    }
}

} // namespace swiftify
