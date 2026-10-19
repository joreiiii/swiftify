#pragma once

#include "spotify/SpotifyTypes.h"

#include <QByteArray>
#include <QHash>
#include <QJsonDocument>
#include <QJsonObject>
#include <QCoroTask>

namespace swiftify {

class PlaybackCore;

/// the library calls, answered as spotify's own apps answer them: through
/// the playback session's internal endpoints (spotify-core's library.rs),
/// so one login covers everything and no developer app is needed. the
/// access tokens are left over from the web api and go unused. every call
/// throws SpotifyError on failure.
class WebApi {
public:
    static constexpr int kMaximumCoverBytes = 256'000;

    explicit WebApi(PlaybackCore *core);

    QCoro::Task<Profile> profile(QString accessToken);
    QCoro::Task<QList<Playlist>> playlists(QString accessToken);
    QCoro::Task<QList<Song>> playlistSongs(QString playlistId, QString accessToken);
    QCoro::Task<QList<Song>> savedSongs(QString accessToken);
    /// how many songs are saved, without their details
    QCoro::Task<int> savedSongTotal(QString accessToken);
    QCoro::Task<QList<Song>> recentlyPlayed(QString accessToken);
    QCoro::Task<QList<Artist>> followedArtists(QString accessToken);
    QCoro::Task<Song> song(QString trackId, QString accessToken);
    QCoro::Task<QList<Song>> albumSongs(Album album, QString accessToken);

    /// the new playlist is private, as spotify's own apps make them
    QCoro::Task<Playlist> createPlaylist(QString name, QString description, bool isPublic, QString accessToken);
    QCoro::Task<> updatePlaylist(QString id, QString name, QString description, bool isPublic, QString accessToken);
    QCoro::Task<> addToPlaylist(QString songUri, QString playlistId, QString accessToken);
    QCoro::Task<> removeFromPlaylist(QString songUri, QString playlistId, QString accessToken);
    /// moves a range, in spotify's indexes
    QCoro::Task<> reorderPlaylist(QString playlistId, int rangeStart, int insertBefore, int length,
                                  QString accessToken);
    /// not offered by the internal endpoints: throws
    QCoro::Task<> setPlaylistImage(QString playlistId, QByteArray jpeg, QString accessToken);
    /// takes the playlist out of the person's list, as spotify's delete does
    QCoro::Task<> deletePlaylist(QString id, QString accessToken);
    QCoro::Task<> setSaved(bool saved, QString songUri, QString accessToken);
    QCoro::Task<QHash<QString, bool>> savedStatuses(QStringList uris, QString accessToken);

private:
    QCoro::Task<QJsonDocument> ask(QJsonObject request);

    PlaybackCore *m_core;
};

} // namespace swiftify
