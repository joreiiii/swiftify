#pragma once

#include "library/SongListModel.h"
#include "spotify/SpotifyTypes.h"

#include <QHash>
#include <QObject>
#include <QPointer>
#include <QStringList>
#include <QTimer>
#include <QCoroTask>
#include <QtQml/qqmlregistration.h>

namespace swiftify {


/// the filter chips over a list of songs, as spotify's playlists have them:
/// the genres most of the songs' artists share, then the artists heard most,
/// and the songs of the chip picked. spotify's own moods ("chill", "upbeat")
/// come from a service of its own no other app can ask.
class SongFilter : public QObject {
    Q_OBJECT
    QML_ELEMENT

    /// the songs filtered
    Q_PROPERTY(swiftify::SongListModel *source READ source WRITE setSource NOTIFY sourceChanged FINAL)
    /// the chips, genres first
    Q_PROPERTY(QStringList chips READ chips NOTIFY chipsChanged FINAL)
    /// the chip picked, or empty for every song
    Q_PROPERTY(QString active READ active WRITE setActive NOTIFY activeChanged FINAL)
    /// the songs to show: the source's, or the picked chip's
    Q_PROPERTY(swiftify::SongListModel *songs READ songs CONSTANT FINAL)

public:
    explicit SongFilter(QObject *parent = nullptr);

    SongListModel *source() const { return m_source; }
    void setSource(SongListModel *source);
    QStringList chips() const { return m_chips; }
    QString active() const { return m_active; }
    void setActive(const QString &chip);
    SongListModel *songs() const { return m_songs; }

signals:
    void sourceChanged();
    void chipsChanged();
    void activeChanged();

private:
    void sourceSongsChanged();
    void rebuildChips();
    QCoro::Task<> runChips(quint64 generation, QList<Song> all, QStringList ids);
    void apply();
    bool matches(const Song &song) const;

    QPointer<SongListModel> m_source;
    SongListModel *m_songs;
    QStringList m_chips;
    QString m_active;
    /// each artist's genres, by id, as the library found them
    QHash<QString, QStringList> m_genres;
    QTimer m_settle;
    quint64 m_generation = 0;
};

} // namespace swiftify
