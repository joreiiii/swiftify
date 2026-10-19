#include "spotify/WebApi.h"

#include "core/PlaybackCore.h"
#include "spotify/SpotifyError.h"
#include "spotify/SpotifyJson.h"

#include <QJsonArray>
#include <QJsonObject>

namespace swiftify {

namespace {

QString playlistUri(const QString &id)
{
    return QStringLiteral("spotify:playlist:") + id;
}

QList<Song> wrappedTracks(const QJsonObject &page)
{
    QList<Song> songs;
    for (const QJsonValue &value : page.value(QStringLiteral("items")).toArray()) {
        if (const auto song = json::wrappedTrack(value.toObject())) {
            songs.append(*song);
        }
    }
    return songs;
}

} // namespace

WebApi::WebApi(PlaybackCore *core)
    : m_core(core)
{
}

QCoro::Task<QJsonDocument> WebApi::ask(QJsonObject request)
{
    const QString answer = co_await m_core->libraryJson(QJsonDocument(request).toJson(QJsonDocument::Compact));
    QJsonParseError error;
    const QJsonDocument document = QJsonDocument::fromJson(answer.toUtf8(), &error);
    if (error.error != QJsonParseError::NoError && answer != QLatin1StringView("null")) {
        throw SpotifyError::invalidData(QStringLiteral("Spotify sent something that could not be read."));
    }
    co_return document;
}

QCoro::Task<Profile> WebApi::profile(QString)
{
    const QJsonDocument document = co_await ask({{QStringLiteral("op"), QStringLiteral("profile")}});
    const Profile result = json::profile(document.object());
    if (!result.isValid()) {
        throw SpotifyError::invalidData(QStringLiteral("the profile had no id."));
    }
    co_return result;
}

QCoro::Task<QList<Playlist>> WebApi::playlists(QString)
{
    const QJsonDocument document = co_await ask({{QStringLiteral("op"), QStringLiteral("playlists")}});
    QList<Playlist> result;
    for (const QJsonValue &value : document.object().value(QStringLiteral("items")).toArray()) {
        const Playlist playlist = json::playlist(value.toObject());
        if (playlist.isValid()) {
            result.append(playlist);
        }
    }
    co_return result;
}

QCoro::Task<QList<Song>> WebApi::playlistSongs(QString playlistId, QString)
{
    const QString answer = co_await m_core->playlistJson(playlistUri(playlistId));
    co_return wrappedTracks(QJsonDocument::fromJson(answer.toUtf8()).object());
}

QCoro::Task<QList<Song>> WebApi::savedSongs(QString)
{
    co_return wrappedTracks((co_await ask({{QStringLiteral("op"), QStringLiteral("savedSongs")}})).object());
}

QCoro::Task<int> WebApi::savedSongTotal(QString)
{
    const QString answer = co_await m_core->libraryJson(QByteArrayLiteral(R"({"op":"savedCount"})"));
    co_return answer.toInt();
}

QCoro::Task<QList<Artist>> WebApi::followedArtists(QString)
{
    const QJsonDocument document = co_await ask({{QStringLiteral("op"), QStringLiteral("followedArtists")}});
    QList<Artist> result;
    for (const QJsonValue &value : document.object().value(QStringLiteral("items")).toArray()) {
        if (const auto artist = json::artist(value.toObject())) {
            result.append(*artist);
        }
    }
    co_return result;
}

QCoro::Task<QList<Song>> WebApi::recentlyPlayed(QString)
{
    co_return wrappedTracks((co_await ask({{QStringLiteral("op"), QStringLiteral("recent")}})).object());
}

QCoro::Task<Song> WebApi::song(QString trackId, QString)
{
    const QJsonDocument document = co_await ask({{QStringLiteral("op"), QStringLiteral("track")},
                                                 {QStringLiteral("uri"), QStringLiteral("spotify:track:") + trackId}});
    const QList<Song> songs = wrappedTracks(document.object());
    if (songs.isEmpty()) {
        throw SpotifyError::invalidData(QStringLiteral("Spotify returned an unsupported track."));
    }
    co_return songs.first();
}

QCoro::Task<QList<Song>> WebApi::albumSongs(Album album, QString)
{
    const QString uri = album.uri.isEmpty() ? QStringLiteral("spotify:album:") + album.id : album.uri;
    co_return wrappedTracks((co_await ask({{QStringLiteral("op"), QStringLiteral("album")}, {QStringLiteral("uri"), uri}})).object());
}

QCoro::Task<Playlist> WebApi::createPlaylist(QString name, QString description, bool, QString)
{
    const QJsonDocument document = co_await ask({{QStringLiteral("op"), QStringLiteral("playlistCreate")},
                                                 {QStringLiteral("name"), name},
                                                 {QStringLiteral("description"), description}});
    const Playlist playlist = json::playlist(document.object());
    if (!playlist.isValid()) {
        throw SpotifyError::invalidData(QStringLiteral("the new playlist had no id."));
    }
    co_return playlist;
}

QCoro::Task<> WebApi::updatePlaylist(QString id, QString name, QString description, bool, QString)
{
    co_await ask({{QStringLiteral("op"), QStringLiteral("playlistRename")},
                  {QStringLiteral("uri"), playlistUri(id)},
                  {QStringLiteral("name"), name},
                  {QStringLiteral("description"), description}});
}

QCoro::Task<> WebApi::addToPlaylist(QString songUri, QString playlistId, QString)
{
    co_await ask({{QStringLiteral("op"), QStringLiteral("playlistAdd")},
                  {QStringLiteral("uri"), playlistUri(playlistId)},
                  {QStringLiteral("uris"), QJsonArray {songUri}}});
}

QCoro::Task<> WebApi::removeFromPlaylist(QString songUri, QString playlistId, QString)
{
    co_await ask({{QStringLiteral("op"), QStringLiteral("playlistRemove")},
                  {QStringLiteral("uri"), playlistUri(playlistId)},
                  {QStringLiteral("uris"), QJsonArray {songUri}}});
}

QCoro::Task<> WebApi::reorderPlaylist(QString playlistId, int rangeStart, int insertBefore, int length, QString)
{
    co_await ask({{QStringLiteral("op"), QStringLiteral("playlistMove")},
                  {QStringLiteral("uri"), playlistUri(playlistId)},
                  {QStringLiteral("from"), rangeStart},
                  {QStringLiteral("length"), length},
                  {QStringLiteral("to"), insertBefore}});
}

QCoro::Task<> WebApi::setPlaylistImage(QString, QByteArray, QString)
{
    if (m_core) {
        throw SpotifyError::requestFailed(QStringLiteral("Changing a playlist's cover is not available yet."));
    }
    co_return;
}

QCoro::Task<> WebApi::deletePlaylist(QString id, QString)
{
    co_await ask({{QStringLiteral("op"), QStringLiteral("playlistDelete")}, {QStringLiteral("uri"), playlistUri(id)}});
}

QCoro::Task<> WebApi::setSaved(bool saved, QString songUri, QString)
{
    co_await ask({{QStringLiteral("op"), saved ? QStringLiteral("save") : QStringLiteral("unsave")},
                  {QStringLiteral("uris"), QJsonArray {songUri}}});
}

QCoro::Task<QHash<QString, bool>> WebApi::savedStatuses(QStringList uris, QString)
{
    uris.removeDuplicates();
    QHash<QString, bool> result;
    if (uris.isEmpty()) {
        co_return result;
    }
    const QJsonDocument document = co_await ask({{QStringLiteral("op"), QStringLiteral("savedContains")},
                                                 {QStringLiteral("uris"), QJsonArray::fromStringList(uris)}});
    const QJsonArray statuses = document.array();
    for (qsizetype index = 0; index < uris.size() && index < statuses.size(); ++index) {
        result.insert(uris[index], statuses[index].toBool());
    }
    co_return result;
}

} // namespace swiftify
