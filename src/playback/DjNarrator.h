#pragma once

#include <QHash>
#include <QObject>
#include <QPointer>
#include <QTimer>
#include <QCoroTask>

#include <memory>

namespace swiftify {

class PlaybackController;
class PlaybackCore;

/// what spotify's dj says between its songs, said as they change: the last
/// song's outro and the next one's intro, in the dj's own voice, which
/// spotify makes from the lines' text as its apps have it made
/// (narration.rs), over the music turned down. when spotify will not give
/// the voice, the system's says the words. a song from outside the dj's set
/// ends it.
class DjNarrator : public QObject {
    Q_OBJECT

public:
    /// a line of the dj's, as the dj session gives it (dj.rs)
    struct Line {
        QString text;
        QString ssml;
        int voice = 0;
        int provider = 0;
        int sampleRate = 44100;

        bool isEmpty() const { return ssml.isEmpty() && text.isEmpty(); }
    };
    struct Lines {
        Line intro;
        Line outro;
    };

    DjNarrator(PlaybackController *player, PlaybackCore *core, QObject *parent = nullptr);
    ~DjNarrator() override;

    /// the dj's set, by song uri, and the language its lines are in ("de-DE")
    void start(QHash<QString, Lines> lines, QString language);

private:
    void songChanged();
    QCoro::Task<> speak(QList<Line> lines);
    void duck();
    void unduck();
    /// the system's voice, for when spotify's is not to be had
    void sayWithSystemVoice(const QString &text);

    QPointer<PlaybackController> m_player;
    PlaybackCore *m_core;
    QHash<QString, Lines> m_lines;
    QString m_language;
    QString m_previousUri;
    bool m_speaking = false;
    QTimer m_systemVoiceDone;

    struct Voice;
    std::unique_ptr<Voice> m_voice;
};

} // namespace swiftify
