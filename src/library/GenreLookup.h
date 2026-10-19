#pragma once

#include "spotify/SpotifyTypes.h"

#include <QDateTime>
#include <QHash>
#include <QNetworkAccessManager>
#include <QObject>
#include <QStringList>
#include <QCoroTask>

namespace swiftify {

/// an artist's genres, from MusicBrainz: spotify gives development apps no
/// genres at all. each artist is asked about once, ever: the answers are
/// kept in the cache folder. MusicBrainz takes a request a second, so the
/// requests are spaced out, whoever asks.
class GenreLookup : public QObject {
    Q_OBJECT

public:
    static GenreLookup *instance();

    /// the artist's genres, lower case, most voted first; none when
    /// MusicBrainz does not know them or cannot be reached
    QCoro::Task<QStringList> genresOf(Artist artist);
    /// what is known already, without asking
    bool knows(const QString &artistId) const { return m_genres.contains(artistId); }

private:
    explicit GenreLookup(QObject *parent = nullptr);

    QCoro::Task<QByteArray> get(QUrl url);
    void load();
    void save() const;

    QNetworkAccessManager m_network;
    /// by spotify artist id
    QHash<QString, QStringList> m_genres;
    /// when the next request may go out
    QDateTime m_nextSlot;
};

} // namespace swiftify
