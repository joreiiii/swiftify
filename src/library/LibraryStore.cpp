#include "library/LibraryStore.h"

#include "app/ErrorCenter.h"
#include "app/Settings.h"
#include "core/PlaybackCore.h"
#include "library/LocalLibrary.h"
#include "playback/DjNarrator.h"
#include "playback/PlaybackController.h"
#include "spotify/SpotifyJson.h"
#include "spotify/SpotifySession.h"

#include <QCollator>
#include <QDate>
#include <QDateTime>
#include <QJsonObject>
#include <QVariantMap>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLoggingCategory>
#include <QQmlEngine>
#include <QScopeGuard>
#include <QCoroTimer>

#include <algorithm>
#include <chrono>

namespace swiftify {

Q_LOGGING_CATEGORY(lcLibrary, "swiftify.library")

namespace {
/// what's new, as last found, and when (Settings)
const QString kWhatsNewKey = QStringLiteral("whatsNew");
const QString kWhatsNewFetchedKey = QStringLiteral("whatsNewFetchedAt");
constexpr qint64 kWhatsNewRefreshSeconds = 12 * 60 * 60;
} // namespace

namespace {

LibraryStore *s_instance = nullptr;

const QString kPinnedKey = QStringLiteral("pinnedPlaylistIDs");
const QString kSearchHistoryKey = QStringLiteral("searchPlaybackHistory");
/// the saved songs' file in the song list cache: no playlist id looks like it
const QString kSavedSongsCacheKey = QStringLiteral("saved-songs");
const QString kCatchphrase = QStringLiteral("swiftify (modded) by jorei_");
const QString kReconnectToEdit = QStringLiteral("Reconnect your library once to create and edit playlists.");
constexpr int kSearchHistoryLimit = 20;

/// a playlist made on this computer (LocalLibrary)
bool isLocalId(const QString &id)
{
    return id.startsWith(QLatin1StringView("local:"));
}

/// `next`, with each occurrence `previous` already had kept as it was, in
/// order: the rows stay where they are and the song playing stays marked
QList<Song> keepingInstances(const QList<Song> &previous, QList<Song> next)
{
    QHash<QString, QList<quint64>> held;
    for (const Song &song : previous) {
        held[song.uri].append(song.instanceId);
    }
    for (Song &song : next) {
        const auto found = held.find(song.uri);
        if (found != held.end() && !found->isEmpty()) {
            song.instanceId = found->takeFirst();
        }
    }
    return next;
}

bool sameSongs(const QList<Song> &left, const QList<Song> &right)
{
    return std::equal(left.begin(), left.end(), right.begin(), right.end(), [](const Song &a, const Song &b) {
        return a.uri == b.uri && a.name == b.name && a.artists == b.artists && a.albumName == b.albumName
            && a.artworkUrl == b.artworkUrl && a.durationMs == b.durationMs;
    });
}

/// the items page PlaybackCore::playlistJson completes with
QList<Song> songsFromItems(const QString &payload)
{
    QList<Song> songs;
    const QJsonObject page = QJsonDocument::fromJson(payload.toUtf8()).object();
    for (const QJsonValue &value : page.value(QStringLiteral("items")).toArray()) {
        if (const auto song = json::wrappedTrack(value.toObject())) {
            songs.append(*song);
        }
    }
    return songs;
}

} // namespace

bool LibraryStore::Destination::operator==(const Destination &other) const
{
    if (page != other.page) {
        return false;
    }
    switch (page) {
    case Page::Playlist: return playlistId == other.playlistId;
    case Page::Album: return album.id == other.album.id;
    case Page::Artist: return artist.id == other.artist.id;
    case Page::Radio: return radioSeed.uri == other.radioSeed.uri;
    case Page::Genre: return genreUri == other.genreUri;
    default: return true;
    }
}

LibraryStore::LibraryStore(SpotifySession *session, Settings *settings, ErrorCenter *errors, QObject *parent)
    : QObject(parent)
    , m_session(session)
    , m_settings(settings)
    , m_errors(errors)
    , m_playlists(new PlaylistListModel(this))
    , m_pinnedPlaylists(new PlaylistListModel(this))
    , m_playlistSongs(new SongListModel(this))
    , m_displayedPlaylistSongs(new SongListModel(this))
    , m_savedSongs(new SongListModel(this))
    , m_recentlyPlayed(new SongListModel(this))
    , m_recommendedArtists(new ArtistListModel(this))
    , m_recommendedAlbums(new AlbumListModel(this))
    , m_followedArtists(new ArtistListModel(this))
    , m_radioSongs(new SongListModel(this))
    , m_newReleases(new AlbumListModel(this))
    , m_albumSongs(new SongListModel(this))
    , m_artistTopSongs(new SongListModel(this))
    , m_artistAlbums(new AlbumListModel(this))
    , m_searchSongs(new SongListModel(this))
    , m_searchAlbums(new AlbumListModel(this))
    , m_searchArtists(new ArtistListModel(this))
    , m_searchPlaylists(new PlaylistListModel(this))
    , m_searchHistory(new SongListModel(this))
    , m_searchHistoryPreview(new SongListModel(this))
{
    if (!s_instance) {
        s_instance = this;
    }

    const QStringList pinned = m_settings->value(kPinnedKey).toStringList();
    m_pinnedIds = QSet<QString>(pinned.begin(), pinned.end());

    QList<Song> history;
    for (const QJsonValue &value : QJsonDocument::fromJson(m_settings->value(kSearchHistoryKey).toByteArray()).array()) {
        const Song song = Song::fromJson(value.toObject());
        if (song.isValid()) {
            history.append(song);
        }
    }
    setSearchHistory(history);

    connect(m_savedSongs, &SongListModel::countChanged, this, &LibraryStore::savedSongTotalChanged);
    m_session->setInitialLibraryLoader([this] { return loadInitialLibrary(); });
    connect(m_session, &SpotifySession::loggedOut, this, &LibraryStore::reset);
}

LibraryStore::~LibraryStore()
{
    m_songLoad.cancel();
    m_artistLoad.cancel();
    m_search.cancel();
    if (s_instance == this) {
        s_instance = nullptr;
    }
}

LibraryStore *LibraryStore::instance()
{
    return s_instance;
}

LibraryStore *LibraryStore::create(QQmlEngine *, QJSEngine *)
{
    QJSEngine::setObjectOwnership(s_instance, QJSEngine::CppOwnership);
    return s_instance;
}

void LibraryStore::attachPlayer(PlaybackController *player)
{
    m_player = player;
    connect(player, &PlaybackController::playedFromSearch, this, &LibraryStore::recordSearchPlayback);
}

void LibraryStore::loadArtistCard(const QString &artistId)
{
    if (artistId.isEmpty() || m_artistCard.value(QStringLiteral("id")).toString() == artistId) {
        return;
    }
    if (const auto cached = m_artistCards.constFind(artistId); cached != m_artistCards.cend()) {
        m_artistCard = *cached;
        emit artistCardChanged();
        return;
    }
    detach(runArtistCard(artistId));
}

QCoro::Task<> LibraryStore::runArtistCard(QString artistId)
{
    try {
        co_await m_session->ensureFreshPlaybackConnection();
        const QJsonObject page = QJsonDocument::fromJson(
            (co_await m_session->core()->artistJson(QStringLiteral("spotify:artist:") + artistId)).toUtf8()).object();
        // the largest picture is the last
        const QJsonArray images = page.value(QStringLiteral("images")).toArray();
        QVariantMap card {
            {QStringLiteral("id"), artistId},
            {QStringLiteral("name"), page.value(QStringLiteral("name")).toString()},
            {QStringLiteral("imageUrl"), images.isEmpty() ? QString() : images.last().toObject().value(QStringLiteral("url")).toString()},
            {QStringLiteral("biography"), page.value(QStringLiteral("biography")).toString()},
        };
        m_artistCards.insert(artistId, card);
        m_artistCard = card;
        emit artistCardChanged();
    } catch (const Cancelled &) {
    } catch (const SpotifyError &error) {
        qCWarning(lcLibrary).noquote() << "artist card:" << error.message();
    }
}

void LibraryStore::loadSongExtras(const QString &trackUri, const QString &artistId)
{
    if (!trackUri.startsWith(QLatin1StringView("spotify:track:")) || trackUri == m_songExtrasUri) {
        return;
    }
    m_songExtrasUri = trackUri;
    m_songExtras.clear();
    emit songExtrasChanged();
    detach([](LibraryStore *self, QString uri, QString artist) -> QCoro::Task<> {
        try {
            const QJsonObject request {{QStringLiteral("op"), QStringLiteral("extras")},
                                       {QStringLiteral("uri"), uri},
                                       {QStringLiteral("artist"), QStringLiteral("spotify:artist:") + artist}};
            const QString answer = co_await self->m_session->core()->libraryJson(QJsonDocument(request).toJson(QJsonDocument::Compact));
            // a later song's extras win
            if (self->m_songExtrasUri == uri) {
                self->m_songExtras = QJsonDocument::fromJson(answer.toUtf8()).object().toVariantMap();
                emit self->songExtrasChanged();
            }
        } catch (const SpotifyError &error) {
            qCWarning(lcLibrary).noquote() << "song extras:" << error.message();
        }
    }(this, trackUri, artistId));
}

// --- browse: spotify's categories and their pages (browse.rs) ---------------------------

void LibraryStore::loadBrowse()
{
    if (!m_genres.isEmpty()) {
        return;
    }
    detach([](LibraryStore *self) -> QCoro::Task<> {
        try {
            co_await self->m_session->ensureFreshPlaybackConnection();
            const QJsonObject answer = QJsonDocument::fromJson(
                (co_await self->m_session->core()->libraryJson(QByteArrayLiteral(R"({"op":"browseAll"})"))).toUtf8()).object();
            QVariantList genres;
            for (const QJsonValue &value : answer.value(QStringLiteral("categories")).toArray()) {
                genres.append(value.toObject().toVariantMap());
            }
            self->m_genres = genres;
            emit self->genresChanged();
        } catch (const SpotifyError &error) {
            qCWarning(lcLibrary).noquote() << "browse:" << error.message();
        }
    }(this));
}

void LibraryStore::showGenre(const QString &uri, const QString &title, const QString &color)
{
    if (uri.isEmpty()) {
        return;
    }
    cancelDetailLoads();
    Destination destination {Page::Genre};
    destination.genreUri = uri;
    navigate(destination);
    m_genre = {{QStringLiteral("uri"), uri}, {QStringLiteral("title"), title}, {QStringLiteral("color"), color},
               {QStringLiteral("sections"), QVariantList {}}};
    m_loadingGenre = true;
    emit genreChanged();
    detach(runGenreLoad(uri));
}

QCoro::Task<> LibraryStore::runGenreLoad(QString uri)
{
    QVariantList sections;
    QString title;
    QString color;
    try {
        co_await m_session->ensureFreshPlaybackConnection();
        const QJsonObject request {{QStringLiteral("op"), QStringLiteral("browsePage")}, {QStringLiteral("uri"), uri}};
        const QJsonObject page = QJsonDocument::fromJson(
            (co_await m_session->core()->libraryJson(QJsonDocument(request).toJson(QJsonDocument::Compact))).toUtf8()).object();
        title = page.value(QStringLiteral("title")).toString();
        color = page.value(QStringLiteral("color")).toString();
        for (const QJsonValue &sectionValue : page.value(QStringLiteral("sections")).toArray()) {
            const QJsonObject section = sectionValue.toObject();
            QVariantList items;
            for (const QJsonValue &value : section.value(QStringLiteral("items")).toArray()) {
                const QJsonObject card = value.toObject();
                const QString type = card.value(QStringLiteral("type")).toString();
                const QJsonObject item = card.value(QStringLiteral("item")).toObject();
                if (type == QLatin1StringView("playlist")) {
                    const Playlist playlist = json::playlist(item);
                    if (playlist.isValid()) {
                        items.append(QVariantMap {{QStringLiteral("kind"), type}, {QStringLiteral("name"), playlist.name},
                                                  {QStringLiteral("subtitle"), playlist.description.isEmpty() ? playlist.ownerDisplayName() : playlist.description},
                                                  {QStringLiteral("artworkUrl"), playlist.artworkUrl},
                                                  {QStringLiteral("playlist"), QVariant::fromValue(playlist)}});
                    }
                } else if (type == QLatin1StringView("album")) {
                    if (const auto album = json::album(item)) {
                        items.append(QVariantMap {{QStringLiteral("kind"), type}, {QStringLiteral("name"), album->name},
                                                  {QStringLiteral("subtitle"), album->artists},
                                                  {QStringLiteral("artworkUrl"), album->artworkUrl},
                                                  {QStringLiteral("album"), QVariant::fromValue(*album)}});
                    }
                } else if (type == QLatin1StringView("artist")) {
                    if (const auto artist = json::artist(item)) {
                        items.append(QVariantMap {{QStringLiteral("kind"), type}, {QStringLiteral("name"), artist->name},
                                                  {QStringLiteral("subtitle"), QStringLiteral("Artist")},
                                                  {QStringLiteral("artworkUrl"), artist->artworkUrl},
                                                  {QStringLiteral("artist"), QVariant::fromValue(*artist)}});
                    }
                } else if (type == QLatin1StringView("category")) {
                    items.append(QVariantMap {{QStringLiteral("kind"), type},
                                              {QStringLiteral("name"), item.value(QStringLiteral("title")).toString()},
                                              {QStringLiteral("uri"), item.value(QStringLiteral("uri")).toString()},
                                              {QStringLiteral("color"), item.value(QStringLiteral("color")).toString()},
                                              {QStringLiteral("artworkUrl"), item.value(QStringLiteral("image")).toString()}});
                } else if (type == QLatin1StringView("show") || type == QLatin1StringView("episode")) {
                    items.append(QVariantMap {{QStringLiteral("kind"), type},
                                              {QStringLiteral("name"), item.value(QStringLiteral("name")).toString()},
                                              {QStringLiteral("subtitle"), item.value(QStringLiteral("subtitle")).toString()},
                                              {QStringLiteral("uri"), item.value(QStringLiteral("uri")).toString()},
                                              {QStringLiteral("artworkUrl"), item.value(QStringLiteral("image")).toString()}});
                }
            }
            if (!items.isEmpty()) {
                sections.append(QVariantMap {{QStringLiteral("title"), section.value(QStringLiteral("title")).toString()},
                                             {QStringLiteral("items"), items}});
            }
        }
    } catch (const SpotifyError &error) {
        qCWarning(lcLibrary).noquote() << "genre page:" << error.message();
    }
    // a page left meanwhile keeps what the newer one has
    if (m_destination.page != Page::Genre || m_destination.genreUri != uri) {
        co_return;
    }
    if (!title.isEmpty()) {
        m_genre.insert(QStringLiteral("title"), title);
    }
    if (!color.isEmpty()) {
        m_genre.insert(QStringLiteral("color"), color);
    }
    m_genre.insert(QStringLiteral("sections"), sections);
    m_loadingGenre = false;
    emit genreChanged();
}

void LibraryStore::playTrackUri(const QString &uri)
{
    if (uri.startsWith(QLatin1StringView("spotify:track:"))) {
        detach(runPlayTrackUri(uri));
    }
}

QCoro::Task<> LibraryStore::runPlayTrackUri(QString uri)
{
    try {
        const QString id = uri.section(u':', 2);
        const Song song = co_await m_session->withLibraryAccessToken<Song>(
            [this, id](QString accessToken) { return m_session->webApi().song(id, accessToken); });
        if (m_player) {
            m_player->playSong(song);
        }
    } catch (const Cancelled &) {
    } catch (const SpotifyError &error) {
        reportError(QStringLiteral("Playing the song"), error.message());
    }
}

void LibraryStore::playPlaylist(const Playlist &playlist)
{
    if (playlist.isValid()) {
        detach(runPlayPlaylist(playlist));
    }
}

void LibraryStore::playArtist(const Artist &artist)
{
    if (artist.isValid()) {
        detach(runPlayArtist(artist));
    }
}

QCoro::Task<> LibraryStore::runPlayPlaylist(Playlist playlist)
{
    try {
        QList<Song> songs;
        if (playlist.isDj) {
            // the dj is no list of songs: spotify picks them as it starts,
            // with what the dj says around them (DjNarrator)
            co_await m_session->ensureFreshPlaybackConnection();
            // it goes on from where it got to last time, as spotify's does
            const QString djNext = QStringLiteral("djNextSegment");
            const QJsonObject request {{QStringLiteral("op"), QStringLiteral("dj")},
                                       {QStringLiteral("from"), m_settings->value(djNext).toString()}};
            const QJsonObject set = QJsonDocument::fromJson(
                (co_await m_session->core()->libraryJson(QJsonDocument(request).toJson(QJsonDocument::Compact))).toUtf8()).object();
            m_settings->setValue(djNext, set.value(QStringLiteral("next")).toString());
            QHash<QString, DjNarrator::Lines> lines;
            for (const QJsonValue &value : set.value(QStringLiteral("items")).toArray()) {
                const QJsonObject entry = value.toObject();
                if (const auto song = json::wrappedTrack(entry)) {
                    songs.append(*song);
                    const auto line = [&entry](const char *part) {
                        const QJsonObject spoken = entry.value(QLatin1StringView(part)).toObject();
                        return DjNarrator::Line {spoken.value(QStringLiteral("text")).toString(),
                                                 spoken.value(QStringLiteral("ssml")).toString(),
                                                 spoken.value(QStringLiteral("voice")).toInt(),
                                                 spoken.value(QStringLiteral("provider")).toInt(),
                                                 spoken.value(QStringLiteral("sampleRate")).toInt(44100)};
                    };
                    lines.insert(song->uri, {line("intro"), line("outro")});
                }
            }
            if (m_player && !songs.isEmpty()) {
                if (!m_dj) {
                    m_dj = new DjNarrator(m_player, m_session->core(), this);
                }
                m_dj->start(std::move(lines), set.value(QStringLiteral("language")).toString());
            }
        } else {
            songs = co_await m_session->withLibraryAccessToken<QList<Song>>(
                [this, id = playlist.id](QString accessToken) { return m_session->webApi().playlistSongs(id, accessToken); });
        }
        if (songs.isEmpty()) {
            throw SpotifyError::requestFailed(QStringLiteral("There is nothing in it to play."));
        }
        m_quickPlaySongs->setSongs(songs);
        if (m_player) {
            m_player->playFromModel(m_quickPlaySongs, 0);
        }
    } catch (const Cancelled &) {
    } catch (const SpotifyError &error) {
        reportError(QStringLiteral("Playing the playlist"), error.message());
    }
}

QCoro::Task<> LibraryStore::runPlayArtist(Artist artist)
{
    try {
        co_await m_session->ensureFreshPlaybackConnection();
        const QString uri = artist.uri.isEmpty() ? QStringLiteral("spotify:artist:") + artist.id : artist.uri;
        const QJsonObject page = QJsonDocument::fromJson((co_await m_session->core()->artistJson(uri)).toUtf8()).object();
        QList<Song> songs;
        for (const QJsonValue &value : page.value(QStringLiteral("topTracks")).toObject().value(QStringLiteral("items")).toArray()) {
            if (const auto song = json::wrappedTrack(value.toObject())) {
                songs.append(*song);
            }
        }
        if (songs.isEmpty()) {
            throw SpotifyError::requestFailed(QStringLiteral("There is nothing of theirs to play."));
        }
        m_quickPlaySongs->setSongs(songs);
        if (m_player) {
            m_player->playFromModel(m_quickPlaySongs, 0);
        }
    } catch (const Cancelled &) {
    } catch (const SpotifyError &error) {
        reportError(QStringLiteral("Playing the artist"), error.message());
    }
}

void LibraryStore::attachLocalFiles(LocalLibrary *localFiles)
{
    m_localFiles = localFiles;
    connect(localFiles, &LocalLibrary::playlistsChanged, this, [this] {
        refreshPinnedPlaylists();
        refreshLocalPlaylist();
    });
    refreshPinnedPlaylists();
}

void LibraryStore::refreshLocalPlaylist()
{
    const QString id = selectedPlaylistId();
    if (!isLocalId(id) || !m_localFiles) {
        return;
    }
    // its name, cover or count may be what changed
    emit selectedPlaylistChanged();
    const QList<Song> next = m_localFiles->songsOf(id);
    if (!sameSongs(next, m_songs)) {
        setSongs(keepingInstances(m_songs, next));
    }
}

void LibraryStore::reportError(const QString &context, const QString &message)
{
    qCWarning(lcLibrary).noquote() << context << ':' << message;
    m_errors->show(message);
}

void LibraryStore::setLoading(bool &flag, bool value)
{
    if (flag != value) {
        flag = value;
        emit loadingChanged();
    }
}

// --- state -----------------------------------------------------------------------------

Playlist LibraryStore::selectedPlaylist() const
{
    if (m_destination.page != Page::Playlist) {
        return {};
    }
    if (isLocalId(m_destination.playlistId)) {
        const Playlist local = m_localFiles ? m_localFiles->playlist(m_destination.playlistId) : Playlist {};
        return local.isValid() ? local : m_destination.playlist;
    }
    for (const Playlist &playlist : m_playlistList) {
        if (playlist.id == m_destination.playlistId) {
            return playlist;
        }
    }
    // opened from search without being in the library
    return m_destination.playlist;
}

bool LibraryStore::isSelectedPlaylistEditable() const
{
    const Playlist playlist = selectedPlaylist();
    return playlist.isValid() && (playlist.isLocal() || playlist.canModify(m_profile.id));
}

QList<Playlist> LibraryStore::editablePlaylistList() const
{
    QList<Playlist> result;
    for (const Playlist &playlist : m_playlistList) {
        if (playlist.canModify(m_profile.id)) {
            result.append(playlist);
        }
    }
    return result;
}

QVariantList LibraryStore::editablePlaylists() const
{
    QVariantList result;
    for (const Playlist &playlist : editablePlaylistList()) {
        result.append(QVariant::fromValue(playlist));
    }
    return result;
}

void LibraryStore::setProfile(const Profile &profile)
{
    m_profile = profile;
    emit profileChanged();
    emit selectedPlaylistChanged();
}

void LibraryStore::setPlaylistList(const QList<Playlist> &playlists)
{
    m_playlistList = playlists;
    m_playlists->setItems(playlists);
    refreshPinnedPlaylists();
    emit selectedPlaylistChanged();
}

// every playlist's songs, read once in the background, so the search finds
// a song in any of them and not only in the one open. a few at a time
QCoro::Task<> LibraryStore::indexPlaylistsForSearch(QList<Playlist> playlists)
{
    constexpr qsizetype kAtOnce = 4;
    const quint64 generation = m_session->generation();
    QList<Song> index;
    QSet<QString> seen;
    for (qsizetype start = 0; start < playlists.size(); start += kAtOnce) {
        std::vector<QCoro::Task<QString>> batch;
        for (qsizetype at = start; at < std::min(playlists.size(), start + kAtOnce); ++at) {
            if (!playlists.at(at).isDj && !playlists.at(at).isLocal()) {
                batch.push_back(m_session->core()->playlistJson(playlists.at(at).uri));
            }
        }
        for (auto &task : batch) {
            try {
                for (const Song &song : songsFromItems(co_await std::move(task))) {
                    if (!seen.contains(song.uri)) {
                        seen.insert(song.uri);
                        index.append(song);
                    }
                }
            } catch (const SpotifyError &error) {
                qCInfo(lcLibrary).noquote() << "indexing a playlist for search:" << error.message();
            }
        }
        if (generation != m_session->generation()) {
            co_return;
        }
    }
    m_searchIndex = index;
}

void LibraryStore::refreshPinnedPlaylists()
{
    QList<Playlist> pinned;
    for (const Playlist &playlist : m_playlistList) {
        if (m_pinnedIds.contains(playlist.id)) {
            pinned.append(playlist);
        }
    }
    if (m_localFiles) {
        for (const Playlist &playlist : m_localFiles->playlists()->items()) {
            if (m_pinnedIds.contains(playlist.id)) {
                pinned.append(playlist);
            }
        }
    }
    m_pinnedPlaylists->setItems(pinned);
}

void LibraryStore::persistPins()
{
    QStringList ids(m_pinnedIds.begin(), m_pinnedIds.end());
    ids.sort();
    m_settings->setValue(kPinnedKey, ids);
}

void LibraryStore::setSongs(const QList<Song> &songs)
{
    m_songs = songs;
    // written through, so a reorder or a removal is what the page shows when it
    // is opened again, rather than the order the server last sent.
    if (m_destination.page == Page::Playlist) {
        m_openedPlaylists.insert(m_destination.playlistId, songs);
    }
    m_playlistSongs->setSongs(songs);
    refreshDisplayedSongs();
}

void LibraryStore::refreshDisplayedSongs()
{
    const QString query = m_playlistFilterQuery.trimmed();
    QList<Song> shown;
    if (query.isEmpty()) {
        shown = m_songs;
    } else {
        for (const Song &song : m_songs) {
            if (song.name.contains(query, Qt::CaseInsensitive) || song.artists.contains(query, Qt::CaseInsensitive)
                || song.albumName.contains(query, Qt::CaseInsensitive)) {
                shown.append(song);
            }
        }
    }

    QCollator collator;
    collator.setCaseSensitivity(Qt::CaseInsensitive);
    collator.setNumericMode(true);
    const auto byText = [&collator](auto field) {
        return [&collator, field](const Song &left, const Song &right) {
            return collator.compare(field(left), field(right)) < 0;
        };
    };
    switch (m_sortOrder) {
    case SortOrder::Playlist:
        break;
    case SortOrder::Title:
        std::stable_sort(shown.begin(), shown.end(), byText([](const Song &song) { return song.name; }));
        break;
    case SortOrder::Artist:
        std::stable_sort(shown.begin(), shown.end(), byText([](const Song &song) { return song.artists; }));
        break;
    case SortOrder::Album:
        std::stable_sort(shown.begin(), shown.end(), byText([](const Song &song) { return song.albumName; }));
        break;
    case SortOrder::Duration:
        std::stable_sort(shown.begin(), shown.end(), [](const Song &left, const Song &right) {
            const int a = left.durationMs > 0 ? left.durationMs : std::numeric_limits<int>::max();
            const int b = right.durationMs > 0 ? right.durationMs : std::numeric_limits<int>::max();
            return a < b;
        });
        break;
    }
    m_displayedPlaylistSongs->setSongs(shown);
}

void LibraryStore::setPlaylistFilterQuery(const QString &query)
{
    if (m_playlistFilterQuery == query) {
        return;
    }
    m_playlistFilterQuery = query;
    refreshDisplayedSongs();
    emit playlistViewChanged();
}

void LibraryStore::setPlaylistSortOrder(SortOrder order)
{
    if (m_sortOrder == order) {
        return;
    }
    m_sortOrder = order;
    refreshDisplayedSongs();
    emit playlistViewChanged();
}

bool LibraryStore::canReorderPlaylist() const
{
    // dragging is offered only where it means something: on a playlist this
    // account may edit, showing every song, in the playlist's own order.
    return isSelectedPlaylistEditable() && m_sortOrder == SortOrder::Playlist && m_playlistFilterQuery.trimmed().isEmpty();
}

void LibraryStore::refreshRecommendations()
{
    QList<Artist> artists;
    QList<Album> albums;
    QSet<QString> seenArtists;
    QSet<QString> seenAlbums;
    for (const Song &song : m_recentlyPlayed->songs()) {
        Artist artist = song.primaryArtist();
        if (artist.isValid() && !seenArtists.contains(artist.id)) {
            seenArtists.insert(artist.id);
            if (artist.artworkUrl.isEmpty()) {
                artist.artworkUrl = song.artworkUrl;
            }
            artists.append(artist);
        }
        const Album album = song.albumDestination();
        if (album.isValid() && !seenAlbums.contains(album.id)) {
            seenAlbums.insert(album.id);
            albums.append(album);
        }
    }
    m_recommendedArtists->setItems(artists);
    m_recommendedAlbums->setItems(albums);
}

// --- navigation ---------------------------------------------------------------------

void LibraryStore::navigate(const Destination &destination)
{
    const Destination previous = m_destination;
    m_destination = destination;

    // going back must not record the screen it came from, or back would
    // bounce between the last two destinations forever.
    bool record = true;
    if (m_restoreTarget) {
        const Destination target = *m_restoreTarget;
        m_restoreTarget.reset();
        if (target == destination) {
            record = false;
        }
    }
    if (record && !(previous == destination) && (m_history.isEmpty() || !(m_history.last() == previous))) {
        m_history.append(previous);
    }
    emit destinationChanged();
    emit currentArtistChanged();
    emit selectedPlaylistChanged();
    emit playlistViewChanged();
}

void LibraryStore::goBack()
{
    if (m_history.isEmpty()) {
        return;
    }
    const Destination destination = m_history.takeLast();
    m_restoreTarget = destination;
    switch (destination.page) {
    case Page::Home: showHome(); break;
    case Page::Search: showSearch(); break;
    case Page::Settings: showSettings(); break;
    case Page::Songs: showSavedSongs(); break;
    case Page::Playlists: showPlaylists(); break;
    case Page::PinnedPlaylists: showPinnedPlaylists(); break;
    case Page::Radio: showRadio(destination.radioSeed); break;
    case Page::Profile: showProfile(); break;
    case Page::Genre: showGenre(destination.genreUri, m_genre.value(QStringLiteral("title")).toString(),
                                m_genre.value(QStringLiteral("color")).toString()); break;
    case Page::LocalFiles: showLocalFiles(); break;
    case Page::LocalTracks: showLocalTracks(); break;
    case Page::Playlist: {
        if (isLocalId(destination.playlistId)) {
            const Playlist local = m_localFiles ? m_localFiles->playlist(destination.playlistId) : Playlist {};
            if (local.isValid()) {
                selectPlaylist(local);
            } else {
                showLocalFiles();
            }
            break;
        }
        const auto found = std::find_if(m_playlistList.begin(), m_playlistList.end(),
                                        [&](const Playlist &playlist) { return playlist.id == destination.playlistId; });
        if (found != m_playlistList.end()) {
            selectPlaylist(*found);
        } else {
            showPlaylists();
        }
        break;
    }
    case Page::Album: selectAlbum(destination.album); break;
    case Page::Artist: selectArtist(destination.artist); break;
    }
}

void LibraryStore::cancelDetailLoads()
{
    m_songLoad.cancel();
    m_artistLoad.cancel();
    setLoading(m_loadingSongs, false);
    setLoading(m_loadingArtist, false);
}

void LibraryStore::showHome()
{
    cancelDetailLoads();
    navigate({Page::Home});
    if (!m_hasLoadedHome) {
        detach(loadHome());
    }
}

void LibraryStore::showSearch()
{
    cancelDetailLoads();
    navigate({Page::Search});
}

void LibraryStore::showSettings()
{
    cancelDetailLoads();
    navigate({Page::Settings});
}

void LibraryStore::showSavedSongs()
{
    cancelDetailLoads();
    navigate({Page::Songs});
    if (!m_hasLoadedSavedSongs) {
        // what was loaded last time shows while the list is fetched again
        if (m_savedSongs->count() == 0) {
            if (const std::optional<QList<Song>> stored = m_songListCache.load(kSavedSongsCacheKey)) {
                m_savedSongs->setSongs(*stored);
            }
        }
        detach(loadSavedSongs());
    }
}

void LibraryStore::showPlaylists()
{
    cancelDetailLoads();
    navigate({Page::Playlists});
}

void LibraryStore::showPinnedPlaylists()
{
    cancelDetailLoads();
    navigate({Page::PinnedPlaylists});
}

void LibraryStore::showProfile()
{
    cancelDetailLoads();
    navigate({Page::Profile});
    // its recently played shelf is home's
    if (!m_hasLoadedHome) {
        detach(loadHome());
    }
}

void LibraryStore::showRadio(const Song &seed)
{
    if (seed.isLocalFile()) {
        return;
    }
    cancelDetailLoads();
    Destination destination {Page::Radio};
    destination.radioSeed = seed;
    navigate(destination);
    m_radioSongs->setSongs({seed});
    setLoading(m_loadingSongs, true);
    detach(runRadioLoad(seed, m_songLoad.renew()));
}

QCoro::Task<> LibraryStore::runRadioLoad(Song seed, CancelToken token)
{
    Destination target {Page::Radio};
    target.radioSeed = seed;
    try {
        co_await m_session->ensureFreshPlaybackConnection();
        throwIfCancelled(token);
        QList<Song> songs = songsFromItems(co_await m_session->core()->stationJson(seed.uri, {}, false));
        throwIfCancelled(token);
        if (!(m_destination == target)) {
            co_return;
        }
        // like spotify's, the radio starts with the song it is made from
        songs.prepend(seed);
        m_radioSongs->setSongs(songs);
        setLoading(m_loadingSongs, false);
        m_songLoad.finish(token);
        co_await loadSavedStatuses(songs);
    } catch (const Cancelled &) {
    } catch (const SpotifyError &error) {
        if (m_destination == target && !isCancelled(token)) {
            setLoading(m_loadingSongs, false);
            reportError(QStringLiteral("Loading the song radio"), error.message());
        }
    }
    m_songLoad.finish(token);
}

void LibraryStore::loadNewReleases()
{
    // what was found last time shows at once, even from an earlier run
    if (m_newReleases->count() == 0) {
        QList<Album> stored;
        const QJsonArray cached = QJsonDocument::fromJson(m_settings->value(kWhatsNewKey).toByteArray()).array();
        for (const QJsonValue &value : cached) {
            const QJsonObject object = value.toObject();
            Album album;
            album.id = object.value(QStringLiteral("id")).toString();
            album.name = object.value(QStringLiteral("name")).toString();
            album.artists = object.value(QStringLiteral("artists")).toString();
            album.artworkUrl = QUrl(object.value(QStringLiteral("artworkUrl")).toString());
            album.releaseDate = object.value(QStringLiteral("releaseDate")).toString();
            album.songCount = object.value(QStringLiteral("songCount")).toInt();
            album.uri = object.value(QStringLiteral("uri")).toString();
            stored.append(album);
        }
        m_newReleases->setItems(stored);
    }
    // one request per followed artist: asked at most twice a day, as
    // spotify shuts a client out for a day once it asks too often
    const QDateTime fetched = QDateTime::fromString(m_settings->value(kWhatsNewFetchedKey).toString(), Qt::ISODate);
    if (fetched.isValid() && fetched.secsTo(QDateTime::currentDateTimeUtc()) < kWhatsNewRefreshSeconds) {
        return;
    }
    if (!m_loadingNewReleases) {
        detach(runNewReleases());
    }
}

QCoro::Task<> LibraryStore::runNewReleases()
{
    if (!m_session->hasLibraryToken()) {
        co_return;
    }
    setLoading(m_loadingNewReleases, true);
    const quint64 generation = m_session->generation();
    // what spotify's bell shows: the last four weeks of the followed artists
    const QString since = QDate::currentDate().addDays(-28).toString(Qt::ISODate);
    QList<Album> fresh;
    QSet<QString> seen;
    QString message;
    const QList<Artist> artists = m_followedArtists->items();
    // read through the session, as the artist pages are: the web api's
    // album pages are rate limited hard
    try {
        co_await m_session->ensureFreshPlaybackConnection();
    } catch (const Cancelled &) {
        setLoading(m_loadingNewReleases, false);
        co_return;
    } catch (const SpotifyError &error) {
        qCWarning(lcLibrary).noquote() << "what's new:" << error.message();
        setLoading(m_loadingNewReleases, false);
        co_return;
    }
    const auto releasesOf = [this](Artist artist) -> QCoro::Task<QList<Album>> {
        const QString uri = artist.uri.isEmpty() ? QStringLiteral("spotify:artist:") + artist.id : artist.uri;
        const QJsonObject page = QJsonDocument::fromJson((co_await m_session->core()->artistJson(uri)).toUtf8()).object();
        QList<Album> albums;
        for (const QJsonValue &value : page.value(QStringLiteral("albums")).toArray()) {
            if (const auto album = json::album(value.toObject())) {
                albums.append(*album);
            }
        }
        co_return albums;
    };
    // a few at once, so as not to burst past spotify's rate limit
    constexpr qsizetype kAtOnce = 4;
    for (qsizetype start = 0; start < artists.size() && message.isEmpty(); start += kAtOnce) {
        std::vector<QCoro::Task<QList<Album>>> batch;
        for (qsizetype index = start; index < std::min(artists.size(), start + kAtOnce); ++index) {
            batch.push_back(releasesOf(artists.at(index)));
        }
        // each started is awaited to its end, even after one fails
        for (auto &task : batch) {
            try {
                for (const Album &album : co_await std::move(task)) {
                    // a release date of only a year or month reads as before `since`
                    if (album.releaseDate.size() == 10 && album.releaseDate >= since && !seen.contains(album.id)) {
                        seen.insert(album.id);
                        fresh.append(album);
                    }
                }
            } catch (const Cancelled &) {
            } catch (const SpotifyError &error) {
                qCWarning(lcLibrary).noquote() << "what's new:" << error.message();
                // spotify wants a pause: the rest are not asked for
                if (error.kind() == SpotifyError::Kind::RateLimited) {
                    message = QStringLiteral("Spotify asked Swiftify to slow down. What's New will update later.");
                    // nothing is asked again before spotify's wait is over
                    const qint64 wait = std::max<qint64>(error.retryAfterSeconds(), 60);
                    m_settings->setValue(kWhatsNewFetchedKey, QDateTime::currentDateTimeUtc()
                        .addSecs(wait - kWhatsNewRefreshSeconds).toString(Qt::ISODate));
                }
            }
        }
        if (generation != m_session->generation()) {
            setLoading(m_loadingNewReleases, false);
            co_return;
        }
    }
    if (message.isEmpty()) {
        std::stable_sort(fresh.begin(), fresh.end(),
                         [](const Album &a, const Album &b) { return a.releaseDate > b.releaseDate; });
        m_newReleases->setItems(fresh);
        QJsonArray cached;
        for (const Album &album : fresh) {
            cached.append(QJsonObject {
                {QStringLiteral("id"), album.id},
                {QStringLiteral("name"), album.name},
                {QStringLiteral("artists"), album.artists},
                {QStringLiteral("artworkUrl"), album.artworkUrl.toString()},
                {QStringLiteral("releaseDate"), album.releaseDate},
                {QStringLiteral("songCount"), album.songCount},
                {QStringLiteral("uri"), album.uri},
            });
        }
        m_settings->setValue(kWhatsNewKey, QJsonDocument(cached).toJson(QJsonDocument::Compact));
        m_settings->setValue(kWhatsNewFetchedKey, QDateTime::currentDateTimeUtc().toString(Qt::ISODate));
    }
    if (m_newReleasesMessage != message) {
        m_newReleasesMessage = message;
        emit newReleasesMessageChanged();
    }
    setLoading(m_loadingNewReleases, false);
}

void LibraryStore::loadFriendActivity()
{
    if (!m_loadingFriendActivity) {
        detach(runFriendActivity());
    }
}

QCoro::Task<> LibraryStore::runFriendActivity()
{
    setLoading(m_loadingFriendActivity, true);
    const quint64 generation = m_session->generation();
    QVariantList friends;
    QString message;
    try {
        co_await m_session->ensureFreshPlaybackConnection();
        const QJsonObject list = QJsonDocument::fromJson((co_await m_session->core()->friendsJson()).toUtf8()).object();
        for (const QJsonValue &value : list.value(QStringLiteral("friends")).toArray()) {
            const QJsonObject entry = value.toObject();
            const QJsonObject user = entry.value(QStringLiteral("user")).toObject();
            const QJsonObject track = entry.value(QStringLiteral("track")).toObject();
            friends.append(QVariantMap {
                {QStringLiteral("name"), user.value(QStringLiteral("name")).toString()},
                {QStringLiteral("imageUrl"), user.value(QStringLiteral("imageUrl")).toString()},
                {QStringLiteral("track"), track.value(QStringLiteral("name")).toString()},
                {QStringLiteral("trackUri"), track.value(QStringLiteral("uri")).toString()},
                {QStringLiteral("artist"), track.value(QStringLiteral("artist")).toObject().value(QStringLiteral("name")).toString()},
                {QStringLiteral("timestamp"), entry.value(QStringLiteral("timestamp")).toDouble()},
            });
        }
        // the most recent first, as spotify lists them
        std::stable_sort(friends.begin(), friends.end(), [](const QVariant &a, const QVariant &b) {
            return a.toMap().value(QStringLiteral("timestamp")).toDouble() > b.toMap().value(QStringLiteral("timestamp")).toDouble();
        });
    } catch (const Cancelled &) {
        co_return;
    } catch (const SpotifyError &error) {
        message = QStringLiteral("Spotify won't share friend activity with this app right now.");
        qCWarning(lcLibrary) << "friend activity:" << error.message();
    }
    if (generation != m_session->generation()) {
        co_return;
    }
    m_friendActivity = friends;
    m_friendActivityMessage = message;
    emit friendActivityChanged();
    setLoading(m_loadingFriendActivity, false);
}

QCoro::Task<> LibraryStore::loadFollowedArtists()
{
    // however it goes, the start no longer waits on it
    const auto done = qScopeGuard([this] { markReady(m_followedLoadedOnce); });
    if (!m_session->hasLibraryToken() || m_session->libraryNeedsAuthorizationUpgrade()) {
        co_return;
    }
    const quint64 generation = m_session->generation();
    try {
        const QList<Artist> artists = co_await m_session->withLibraryAccessToken<QList<Artist>>(
            [this](QString accessToken) { return m_session->webApi().followedArtists(accessToken); });
        if (generation == m_session->generation()) {
            m_followedArtists->setItems(artists);
            // their pages open with their listeners
            detach(prefetchListeners(artists));
        }
    } catch (const Cancelled &) {
    } catch (const SpotifyError &error) {
        reportError(QStringLiteral("Loading followed artists"), error.message());
    }
}

void LibraryStore::showLocalFiles()
{
    cancelDetailLoads();
    navigate({Page::LocalFiles});
}

void LibraryStore::showLocalTracks()
{
    cancelDetailLoads();
    navigate({Page::LocalTracks});
}

void LibraryStore::selectPlaylistById(const QString &id)
{
    if (isLocalId(id)) {
        const Playlist local = m_localFiles ? m_localFiles->playlist(id) : Playlist {};
        if (local.isValid()) {
            selectPlaylist(local);
        }
        return;
    }
    for (const Playlist &playlist : m_playlistList) {
        if (playlist.id == id) {
            selectPlaylist(playlist);
            return;
        }
    }
}

void LibraryStore::selectPlaylist(const Playlist &playlist)
{
    // the dj has no page of its own, as in spotify: it plays
    if (playlist.isDj) {
        playPlaylist(playlist);
        return;
    }
    cancelDetailLoads();
    m_playlistFilterQuery.clear();
    m_sortOrder = SortOrder::Playlist;
    m_errors->clear();
    // shown at once when it is already known, and refreshed underneath: a
    // playlist can be edited from anywhere.
    const QList<Song> *opened = m_openedPlaylists.find(playlist.id);
    // not opened since the app started: what was loaded last time, if any
    if (!opened && !playlist.isLocal()) {
        if (const std::optional<QList<Song>> stored = m_songListCache.load(playlist.id)) {
            m_openedPlaylists.insert(playlist.id, *stored);
            opened = m_openedPlaylists.find(playlist.id);
        }
    }
    const QList<Song> openedSongs = opened ? *opened : QList<Song> {};
    navigate({Page::Playlist, playlist.id, {}, {}, playlist});
    if (playlist.isLocal()) {
        // nothing to load: the files are already known
        setSongs(keepingInstances(openedSongs, m_localFiles ? m_localFiles->songsOf(playlist.id) : QList<Song> {}));
        return;
    }
    setSongs(openedSongs);
    if (!m_session->hasLibraryToken()) {
        return;
    }
    setLoading(m_loadingSongs, opened == nullptr);
    detach(runPlaylistLoad(playlist, m_songLoad.renew()));
}

QCoro::Task<> LibraryStore::runPlaylistLoad(Playlist playlist, CancelToken token)
{
    const Destination target {Page::Playlist, playlist.id};
    try {
        QList<Song> loaded;
        if (playlist.canModify(m_profile.id)) {
            loaded = co_await m_session->withLibraryAccessToken<QList<Song>>(
                [this, id = playlist.id](QString accessToken) { return m_session->webApi().playlistSongs(id, accessToken); });
        } else {
            // the web api only gives the name and cover of a playlist someone
            // else made, the session still reads its songs
            co_await m_session->ensureFreshPlaybackConnection();
            throwIfCancelled(token);
            loaded = songsFromItems(co_await m_session->core()->playlistJson(playlist.uri));
        }
        throwIfCancelled(token);
        m_songListCache.save(playlist.id, loaded);
        if (!(m_destination == target)) {
            co_return;
        }
        setSongs(loaded);
        setLoading(m_loadingSongs, false);
        m_songLoad.finish(token);
        co_await loadSavedStatuses(loaded);
    } catch (const Cancelled &) {
    } catch (const SpotifyError &error) {
        if (m_destination == target && !isCancelled(token)) {
            setLoading(m_loadingSongs, false);
            reportError(QStringLiteral("Loading songs from \"%1\"").arg(playlist.name), error.message());
        }
    }
    m_songLoad.finish(token);
}

void LibraryStore::selectAlbum(const Album &album)
{
    cancelDetailLoads();
    const QList<Song> *opened = m_openedAlbums.find(album.id);
    navigate({Page::Album, {}, album});
    m_albumSongs->setSongs(opened ? *opened : QList<Song> {});
    if (!m_session->hasLibraryToken()) {
        return;
    }
    setLoading(m_loadingSongs, opened == nullptr);
    detach(runAlbumLoad(album, m_songLoad.renew()));
}

QCoro::Task<> LibraryStore::runAlbumLoad(Album album, CancelToken token)
{
    const Destination target {Page::Album, {}, album};
    try {
        const QList<Song> loaded = co_await m_session->withLibraryAccessToken<QList<Song>>(
            [this, album](QString accessToken) { return m_session->webApi().albumSongs(album, accessToken); });
        throwIfCancelled(token);
        if (!(m_destination == target)) {
            co_return;
        }
        m_albumSongs->setSongs(loaded);
        m_openedAlbums.insert(album.id, loaded);
        setLoading(m_loadingSongs, false);
        m_songLoad.finish(token);
        co_await loadSavedStatuses(loaded);
    } catch (const Cancelled &) {
    } catch (const SpotifyError &error) {
        if (m_destination == target && !isCancelled(token)) {
            setLoading(m_loadingSongs, false);
            reportError(QStringLiteral("Loading \"%1\"").arg(album.name), error.message());
        }
    }
    m_songLoad.finish(token);
}

void LibraryStore::selectArtist(const Artist &artist)
{
    cancelDetailLoads();
    const ArtistDetail *opened = m_openedArtists.find(artist.id);
    navigate({Page::Artist, {}, {}, artist});
    m_artistAlbums->setItems(opened ? opened->albums : QList<Album> {});
    m_artistTopSongs->setSongs(opened ? opened->topSongs : QList<Song> {});
    m_errors->clear();
    if (!m_session->hasLibraryToken()) {
        return;
    }
    setLoading(m_loadingArtist, opened == nullptr);
    detach(runArtistLoad(artist, m_artistLoad.renew()));
    // known from before, it opens with the page; else it comes once spotify says
    m_artistListeners = m_listenerCache.value(artist.id, 0);
    emit artistListenersChanged();
    detach(runArtistListeners(artist.id, artist.uri.isEmpty() ? QStringLiteral("spotify:artist:") + artist.id : artist.uri));
}

QCoro::Task<qint64> LibraryStore::fetchListeners(QString uri)
{
    co_await m_session->ensureFreshPlaybackConnection();
    const QJsonObject request {{QStringLiteral("op"), QStringLiteral("listeners")}, {QStringLiteral("artist"), uri}};
    const QJsonObject answer = QJsonDocument::fromJson(
        (co_await m_session->core()->libraryJson(QJsonDocument(request).toJson(QJsonDocument::Compact))).toUtf8()).object();
    co_return answer.value(QStringLiteral("monthlyListeners")).toInteger();
}

QCoro::Task<> LibraryStore::prefetchListeners(QList<Artist> artists)
{
    for (const Artist &artist : artists) {
        if (artist.id.isEmpty() || m_listenerCache.contains(artist.id)) {
            continue;
        }
        try {
            const qint64 listeners = co_await fetchListeners(artist.uri.isEmpty() ? QStringLiteral("spotify:artist:") + artist.id : artist.uri);
            if (listeners > 0) {
                m_listenerCache.insert(artist.id, listeners);
            }
        } catch (const SpotifyError &) {
            co_return;
        }
    }
}

QCoro::Task<> LibraryStore::runArtistListeners(QString artistId, QString uri)
{
    try {
        const qint64 listeners = co_await fetchListeners(uri);
        if (listeners > 0) {
            m_listenerCache.insert(artistId, listeners);
        }
        // an artist left meanwhile keeps the newer one's
        if (m_destination.page != Page::Artist || m_destination.artist.id != artistId || listeners == m_artistListeners) {
            co_return;
        }
        m_artistListeners = listeners;
        emit artistListenersChanged();
    } catch (const SpotifyError &error) {
        qCWarning(lcLibrary).noquote() << "listeners:" << error.message();
    }
}

bool LibraryStore::isFollowing(const QString &artistId) const
{
    const QList<Artist> &followed = m_followedArtists->items();
    return std::any_of(followed.begin(), followed.end(), [&](const Artist &item) { return item.id == artistId; });
}

void LibraryStore::toggleFollow(const Artist &artist)
{
    if (artist.id.isEmpty()) {
        return;
    }
    const bool follow = !isFollowing(artist.id);
    QList<Artist> followed = m_followedArtists->items();
    if (follow) {
        Artist added = artist;
        // the newest in the library's recents
        added.recency = QDateTime::currentMSecsSinceEpoch();
        followed.prepend(added);
    } else {
        followed.removeIf([&](const Artist &item) { return item.id == artist.id; });
    }
    m_followedArtists->setItems(followed);
    ++m_followRevision;
    emit followedChanged();
    detach(runToggleFollow(artist, follow));
}

QCoro::Task<> LibraryStore::runToggleFollow(Artist artist, bool follow)
{
    try {
        co_await m_session->ensureFreshPlaybackConnection();
        const QString uri = artist.uri.isEmpty() ? QStringLiteral("spotify:artist:") + artist.id : artist.uri;
        const QJsonObject request {{QStringLiteral("op"), follow ? QStringLiteral("follow") : QStringLiteral("unfollow")},
                                   {QStringLiteral("uris"), QJsonArray {uri}}};
        co_await m_session->core()->libraryJson(QJsonDocument(request).toJson(QJsonDocument::Compact));
    } catch (const SpotifyError &error) {
        // spotify said no: the button goes back to what is true
        QList<Artist> followed = m_followedArtists->items();
        if (follow) {
            followed.removeIf([&](const Artist &item) { return item.id == artist.id; });
        } else {
            followed.prepend(artist);
        }
        m_followedArtists->setItems(followed);
        ++m_followRevision;
        emit followedChanged();
        reportError(follow ? QStringLiteral("Following ") + artist.name : QStringLiteral("Unfollowing ") + artist.name, error.message());
    }
}

QCoro::Task<> LibraryStore::runArtistLoad(Artist artist, CancelToken token)
{
    const Destination target {Page::Artist, {}, {}, artist};
    try {
        // read through the session, as spotify's apps read it: the web api
        // gives development apps no top songs, and its album pages are
        // rate limited hard
        co_await m_session->ensureFreshPlaybackConnection();
        throwIfCancelled(token);
        const QString uri = artist.uri.isEmpty() ? QStringLiteral("spotify:artist:") + artist.id : artist.uri;
        const QJsonObject page = QJsonDocument::fromJson((co_await m_session->core()->artistJson(uri)).toUtf8()).object();
        throwIfCancelled(token);
        if (!(m_destination == target)) {
            co_return;
        }
        QList<Song> topSongs;
        for (const QJsonValue &value : page.value(QStringLiteral("topTracks")).toObject().value(QStringLiteral("items")).toArray()) {
            if (const auto song = json::wrappedTrack(value.toObject())) {
                topSongs.append(*song);
            }
        }
        QList<Album> albums;
        for (const QJsonValue &value : page.value(QStringLiteral("albums")).toArray()) {
            if (const auto album = json::album(value.toObject())) {
                albums.append(*album);
            }
        }
        // an artist reached from a song comes without a picture: theirs, the largest
        const QJsonArray images = page.value(QStringLiteral("images")).toArray();
        if (m_destination.artist.artworkUrl.isEmpty() && !images.isEmpty()) {
            m_destination.artist.artworkUrl = QUrl(images.last().toObject().value(QStringLiteral("url")).toString());
            // the picture alone: the page stays, rather than being made anew
            emit currentArtistChanged();
        }
        m_artistTopSongs->setSongs(topSongs);
        m_artistAlbums->setItems(albums);
        m_openedArtists.insert(artist.id, {topSongs, albums});
        setLoading(m_loadingArtist, false);
        co_await loadSavedStatuses(topSongs);
    } catch (const Cancelled &) {
    } catch (const SpotifyError &error) {
        if (m_destination == target && !isCancelled(token)) {
            setLoading(m_loadingArtist, false);
            reportError(QStringLiteral("Loading %1").arg(artist.name), error.message());
        }
    }
    m_artistLoad.finish(token);
}

void LibraryStore::goToAlbum(const Song &song)
{
    detach(runSongNavigation(song, true));
}

void LibraryStore::goToArtist(const Song &song)
{
    detach(runSongNavigation(song, false));
}

QCoro::Task<> LibraryStore::runSongNavigation(Song song, bool toAlbum)
{
    try {
        if (toAlbum) {
            Album album = song.albumDestination();
            if (!album.isValid()) {
                const Song resolved = co_await m_session->withLibraryAccessToken<Song>(
                    [this, id = song.spotifyId()](QString accessToken) { return m_session->webApi().song(id, accessToken); });
                album = resolved.albumDestination();
                if (!album.isValid()) {
                    throw SpotifyError::invalidData(QStringLiteral("Spotify did not return an album for this track."));
                }
            }
            selectAlbum(album);
        } else {
            Artist artist = song.primaryArtist();
            if (!artist.isValid()) {
                const Song resolved = co_await m_session->withLibraryAccessToken<Song>(
                    [this, id = song.spotifyId()](QString accessToken) { return m_session->webApi().song(id, accessToken); });
                artist = resolved.primaryArtist();
                if (!artist.isValid()) {
                    throw SpotifyError::invalidData(QStringLiteral("Spotify did not return an artist for this track."));
                }
            }
            selectArtist(artist);
        }
    } catch (const Cancelled &) {
    } catch (const SpotifyError &error) {
        reportError(QStringLiteral("Opening %1 for %2").arg(toAlbum ? QStringLiteral("album") : QStringLiteral("artist"), song.uri),
                    error.message());
    }
}

// --- search ------------------------------------------------------------------------

bool LibraryStore::searchIsCatchphrase() const
{
    return m_searchQuery.trimmed().toLower() == kCatchphrase;
}

bool LibraryStore::hasSearchResults() const
{
    return m_searchSongs->count() > 0 || m_searchAlbums->count() > 0 || m_searchArtists->count() > 0
        || m_searchPlaylists->count() > 0;
}

void LibraryStore::setSearchQuery(const QString &query)
{
    if (m_searchQuery == query) {
        return;
    }
    m_searchQuery = query;
    m_search.cancel();

    const QString trimmed = query.trimmed();
    const auto clearResults = [this] {
        m_searchSongs->clear();
        m_searchAlbums->setItems({});
        m_searchArtists->setItems({});
        m_searchPlaylists->setItems({});
        m_searchOrder.clear();
        m_searchTop.clear();
        setLoading(m_searching, false);
    };
    if (trimmed.isEmpty() || searchIsCatchphrase()) {
        clearResults();
    } else if (!m_session->hasLibraryToken()) {
        m_errors->show(QStringLiteral("Connect your Spotify library to search the catalog."));
    } else {
        setLoading(m_searching, true);
        detach(runSearch(trimmed, m_search.renew()));
    }
    emit searchChanged();
}

// spotify's catalog search is out of reach of the one login, so the search
// looks through what the person has: their saved and recent songs, the
// playlist open, their playlists and the artists they follow, and the
// albums of those songs. every word typed has to match. as spotify's, the
// results are ranked: a name that is what was typed beats one that starts
// with it, which beats one with a word that does, which beats one that only
// has it somewhere; an artist edges ahead of the rest, and what was played or
// added lately ahead of what was not. the best is the top result, and the
// kinds come in the order of their best.
LibraryStore::RankedResults LibraryStore::searchLibrary(const QString &query) const
{
    constexpr qsizetype kSongs = 20;
    constexpr qsizetype kOthers = 10;
    const QString typed = query.simplified();
    const QStringList words = typed.split(u' ', Qt::SkipEmptyParts);
    const auto matches = [&words](const QString &text) {
        for (const QString &word : words) {
            if (!text.contains(word, Qt::CaseInsensitive)) {
                return false;
            }
        }
        return !words.isEmpty();
    };
    // how well a name answers what was typed; `rest` is what else may match
    const auto score = [&](const QString &name, const QString &rest) -> double {
        if (name.compare(typed, Qt::CaseInsensitive) == 0) {
            return 100;
        }
        if (name.startsWith(typed, Qt::CaseInsensitive)) {
            return 80;
        }
        const QStringList nameWords = name.split(u' ', Qt::SkipEmptyParts);
        for (const QString &word : nameWords) {
            if (word.startsWith(words.value(0), Qt::CaseInsensitive) && matches(name)) {
                return 60;
            }
        }
        if (matches(name)) {
            return 40;
        }
        return matches(name + u' ' + rest) ? 20 : -1;
    };
    // up to 10 more for what was played or added in the last month
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    const auto lately = [now](qint64 recency) -> double {
        constexpr double kMonth = 30.0 * 24 * 3600 * 1000;
        return recency > 0 ? std::max(0.0, 10.0 * (1.0 - double(now - recency) / kMonth)) : 0;
    };

    QList<std::pair<double, Song>> songs;
    QList<std::pair<double, Album>> albums;
    QList<std::pair<double, Artist>> artists;
    QList<std::pair<double, Playlist>> playlists;

    QSet<QString> seenSongs;
    QSet<QString> seenAlbums;
    QSet<QString> saved;
    for (const Song &song : m_savedSongs->songs()) {
        saved.insert(song.uri);
    }
    for (const QList<Song> *list : {&m_savedSongs->songs(), &m_recentlyPlayed->songs(), &m_songs, &m_searchIndex}) {
        for (const Song &song : *list) {
            if (!seenSongs.contains(song.uri)) {
                seenSongs.insert(song.uri);
                if (const double value = score(song.name, song.artists + u' ' + song.albumName); value >= 0) {
                    songs.append({value + 2 + (saved.contains(song.uri) ? 4 : 0), song});
                }
            }
            if (!song.albumId.isEmpty() && !seenAlbums.contains(song.albumId)) {
                seenAlbums.insert(song.albumId);
                if (const double value = score(song.albumName, song.artists); value >= 0) {
                    Album album;
                    album.id = song.albumId;
                    album.uri = song.albumUri;
                    album.name = song.albumName;
                    album.artists = song.artists;
                    album.artworkUrl = song.artworkUrl;
                    albums.append({value, album});
                }
            }
        }
    }
    for (const Artist &artist : m_followedArtists->items()) {
        if (const double value = score(artist.name, {}); value >= 0) {
            artists.append({value + 6 + lately(artist.recency), artist});
        }
    }
    for (const Playlist &playlist : m_playlistList) {
        if (const double value = score(playlist.name, playlist.description); value >= 0) {
            playlists.append({value + 3 + lately(playlist.recency), playlist});
        }
    }

    const auto best = [](auto &list) {
        std::stable_sort(list.begin(), list.end(), [](const auto &a, const auto &b) { return a.first > b.first; });
        return list.isEmpty() ? -1.0 : list.first().first;
    };
    const double bestSong = best(songs);
    const double bestAlbum = best(albums);
    const double bestArtist = best(artists);
    const double bestPlaylist = best(playlists);

    RankedResults results;
    for (const auto &[value, song] : songs.mid(0, kSongs)) results.songs.append(song);
    for (const auto &[value, album] : albums.mid(0, kOthers)) results.albums.append(album);
    for (const auto &[value, artist] : artists.mid(0, kOthers)) results.artists.append(artist);
    for (const auto &[value, playlist] : playlists.mid(0, kOthers)) results.playlists.append(playlist);

    QList<std::pair<double, QString>> kinds {{bestSong, QStringLiteral("songs")},
                                             {bestArtist, QStringLiteral("artists")},
                                             {bestAlbum, QStringLiteral("albums")},
                                             {bestPlaylist, QStringLiteral("playlists")}};
    std::stable_sort(kinds.begin(), kinds.end(), [](const auto &a, const auto &b) { return a.first > b.first; });
    for (const auto &[value, kind] : kinds) {
        if (value >= 0) {
            results.order.append(kind);
        }
    }

    // the top result, the best of the best
    if (!results.order.isEmpty()) {
        const QString kind = results.order.first();
        if (kind == QLatin1StringView("songs")) {
            const Song &song = results.songs.first();
            results.top = {{QStringLiteral("kind"), kind}, {QStringLiteral("name"), song.name},
                           {QStringLiteral("subtitle"), song.artists}, {QStringLiteral("artworkUrl"), song.artworkUrl},
                           {QStringLiteral("song"), QVariant::fromValue(song)}};
        } else if (kind == QLatin1StringView("artists")) {
            const Artist &artist = results.artists.first();
            results.top = {{QStringLiteral("kind"), kind}, {QStringLiteral("name"), artist.name},
                           {QStringLiteral("subtitle"), QStringLiteral("Artist")}, {QStringLiteral("artworkUrl"), artist.artworkUrl},
                           {QStringLiteral("artist"), QVariant::fromValue(artist)}};
        } else if (kind == QLatin1StringView("albums")) {
            const Album &album = results.albums.first();
            results.top = {{QStringLiteral("kind"), kind}, {QStringLiteral("name"), album.name},
                           {QStringLiteral("subtitle"), QStringLiteral("Album  •  ") + album.artists},
                           {QStringLiteral("artworkUrl"), album.artworkUrl},
                           {QStringLiteral("album"), QVariant::fromValue(album)}};
        } else {
            const Playlist &playlist = results.playlists.first();
            results.top = {{QStringLiteral("kind"), kind}, {QStringLiteral("name"), playlist.name},
                           {QStringLiteral("subtitle"), QStringLiteral("Playlist  •  ") + playlist.ownerDisplayName()},
                           {QStringLiteral("artworkUrl"), playlist.artworkUrl},
                           {QStringLiteral("playlist"), QVariant::fromValue(playlist)}};
        }
    }
    return results;
}

// spotify's catalog search (search.rs), as its web player searches: its own
// top result first, then songs, artists, albums and playlists
LibraryStore::RankedResults LibraryStore::catalogResults(const QJsonObject &answer) const
{
    const auto items = [&answer](const char *key) {
        return answer.value(QLatin1StringView(key)).toObject().value(QStringLiteral("items")).toArray();
    };
    RankedResults results;
    for (const QJsonValue &value : items("tracks")) {
        if (const auto song = json::track(value.toObject())) results.songs.append(*song);
    }
    for (const QJsonValue &value : items("albums")) {
        if (const auto album = json::album(value.toObject())) results.albums.append(*album);
    }
    for (const QJsonValue &value : items("artists")) {
        if (const auto artist = json::artist(value.toObject())) results.artists.append(*artist);
    }
    for (const QJsonValue &value : items("playlists")) {
        const Playlist playlist = json::playlist(value.toObject());
        if (playlist.isValid()) results.playlists.append(playlist);
    }

    const QJsonObject top = answer.value(QStringLiteral("top")).toObject();
    const QString topKind = top.value(QStringLiteral("kind")).toString();
    const QString topUri = top.value(QStringLiteral("uri")).toString();
    if (!results.songs.isEmpty()) results.order.append(QStringLiteral("songs"));
    if (!results.artists.isEmpty()) results.order.append(QStringLiteral("artists"));
    if (!results.albums.isEmpty()) results.order.append(QStringLiteral("albums"));
    if (!results.playlists.isEmpty()) results.order.append(QStringLiteral("playlists"));

    // spotify's top result, found among the results, and its kind first
    const auto first = [&](auto &list, const QString &kind) -> bool {
        for (qsizetype index = 0; index < list.size(); ++index) {
            if (list.at(index).uri == topUri) {
                list.move(index, 0);
                results.order.removeAll(kind);
                results.order.prepend(kind);
                return true;
            }
        }
        return false;
    };
    if (topKind == QLatin1StringView("tracks") && first(results.songs, QStringLiteral("songs"))) {
        const Song &song = results.songs.first();
        results.top = {{QStringLiteral("kind"), QStringLiteral("songs")}, {QStringLiteral("name"), song.name},
                       {QStringLiteral("subtitle"), QStringLiteral("Song  •  ") + song.artists},
                       {QStringLiteral("artworkUrl"), song.artworkUrl}, {QStringLiteral("song"), QVariant::fromValue(song)}};
    } else if (topKind == QLatin1StringView("artists") && first(results.artists, QStringLiteral("artists"))) {
        const Artist &artist = results.artists.first();
        results.top = {{QStringLiteral("kind"), QStringLiteral("artists")}, {QStringLiteral("name"), artist.name},
                       {QStringLiteral("subtitle"), QStringLiteral("Artist")}, {QStringLiteral("artworkUrl"), artist.artworkUrl},
                       {QStringLiteral("artist"), QVariant::fromValue(artist)}};
    } else if (topKind == QLatin1StringView("albums") && first(results.albums, QStringLiteral("albums"))) {
        const Album &album = results.albums.first();
        results.top = {{QStringLiteral("kind"), QStringLiteral("albums")}, {QStringLiteral("name"), album.name},
                       {QStringLiteral("subtitle"), QStringLiteral("Album  •  ") + album.artists},
                       {QStringLiteral("artworkUrl"), album.artworkUrl}, {QStringLiteral("album"), QVariant::fromValue(album)}};
    } else if (topKind == QLatin1StringView("playlists") && first(results.playlists, QStringLiteral("playlists"))) {
        const Playlist &playlist = results.playlists.first();
        results.top = {{QStringLiteral("kind"), QStringLiteral("playlists")}, {QStringLiteral("name"), playlist.name},
                       {QStringLiteral("subtitle"), QStringLiteral("Playlist  •  ") + playlist.ownerDisplayName()},
                       {QStringLiteral("artworkUrl"), playlist.artworkUrl}, {QStringLiteral("playlist"), QVariant::fromValue(playlist)}};
    }
    return results;
}

QCoro::Task<> LibraryStore::runSearch(QString query, CancelToken token)
{
    try {
        co_await QCoro::sleepFor(std::chrono::milliseconds(350));
        throwIfCancelled(token);
        // all of spotify, as its own apps search; the person's library if
        // spotify will not answer
        RankedResults results;
        try {
            co_await m_session->ensureFreshPlaybackConnection();
            const QJsonObject request {{QStringLiteral("op"), QStringLiteral("search")}, {QStringLiteral("query"), query}};
            results = catalogResults(QJsonDocument::fromJson(
                (co_await m_session->core()->libraryJson(QJsonDocument(request).toJson(QJsonDocument::Compact))).toUtf8()).object());
        } catch (const SpotifyError &error) {
            qCWarning(lcLibrary).noquote() << "searching spotify:" << error.message();
            results = searchLibrary(query);
        }
        throwIfCancelled(token);
        if (m_searchQuery.trimmed() != query) {
            co_return;
        }
        m_searchSongs->setSongs(results.songs);
        m_searchAlbums->setItems(results.albums);
        m_searchArtists->setItems(results.artists);
        m_searchPlaylists->setItems(results.playlists);
        m_searchOrder = results.order;
        m_searchTop = results.top;
        setLoading(m_searching, false);
        emit searchChanged();
        m_search.finish(token);
        co_await loadSavedStatuses(results.songs);
    } catch (const Cancelled &) {
    } catch (const SpotifyError &error) {
        if (!isCancelled(token)) {
            setLoading(m_searching, false);
            reportError(QStringLiteral("Searching for \"%1\"").arg(query), error.message());
        }
    }
    m_search.finish(token);
}

void LibraryStore::recordSearchPlayback(const Song &song)
{
    QList<Song> history = m_searchHistory->songs();
    history.removeIf([&](const Song &item) { return item.uri == song.uri; });
    history.prepend(song);
    if (history.size() > kSearchHistoryLimit) {
        history.resize(kSearchHistoryLimit);
    }
    setSearchHistory(history);
    persistSearchHistory();
}

void LibraryStore::clearSearchHistory()
{
    setSearchHistory({});
    persistSearchHistory();
}

void LibraryStore::setSearchHistory(const QList<Song> &songs)
{
    m_searchHistory->setSongs(songs);
    m_searchHistoryPreview->setSongs(songs.mid(0, 8));
}

void LibraryStore::persistSearchHistory()
{
    QJsonArray array;
    for (const Song &song : m_searchHistory->songs()) {
        array.append(song.toJson());
    }
    m_settings->setValue(kSearchHistoryKey, QJsonDocument(array).toJson(QJsonDocument::Compact));
}

// --- saved songs and pins ------------------------------------------------------------

void LibraryStore::togglePinned(const Playlist &playlist)
{
    if (m_pinnedIds.contains(playlist.id)) {
        m_pinnedIds.remove(playlist.id);
    } else {
        m_pinnedIds.insert(playlist.id);
    }
    persistPins();
    refreshPinnedPlaylists();
    ++m_pinsRevision;
    emit pinsChanged();
}

void LibraryStore::toggleSaved(const Song &song)
{
    if (!m_session->hasFullLibraryAccess()) {
        m_errors->show(QStringLiteral("Reconnect your library once to enable saved songs and playlist editing."));
        return;
    }
    if (!m_session->hasLibraryToken()) {
        m_errors->show(QStringLiteral("Connect your Spotify library to save songs."));
        return;
    }
    // never send contradictory save and remove requests for the same song.
    if (m_pendingSavedUris.contains(song.uri)) {
        return;
    }
    m_pendingSavedUris.insert(song.uri);
    ++m_savedStatusRevision;

    const bool shouldSave = !m_savedUris.contains(song.uri);
    if (shouldSave) {
        m_savedUris.insert(song.uri);
        const QList<Song> &saved = m_savedSongs->songs();
        if (std::none_of(saved.begin(), saved.end(), [&](const Song &item) { return item.uri == song.uri; })) {
            QList<Song> updated = saved;
            updated.prepend(song);
            m_savedSongs->setSongs(updated);
        }
    } else {
        m_savedUris.remove(song.uri);
        m_savedSongs->removeAll([&](const Song &item) { return item.uri == song.uri; });
    }
    adjustSavedSongTotal(shouldSave ? 1 : -1);
    ++m_savedRevision;
    emit savedChanged();
    detach(runToggleSaved(song, shouldSave, m_session->generation()));
}

QCoro::Task<> LibraryStore::runToggleSaved(Song song, bool shouldSave, quint64 generation)
{
    try {
        co_await m_session->withLibraryAccessToken<void>([this, shouldSave, uri = song.uri](QString accessToken) {
            return m_session->webApi().setSaved(shouldSave, uri, accessToken);
        });
    } catch (const Cancelled &) {
    } catch (const SpotifyError &error) {
        if (shouldSave) {
            m_savedUris.remove(song.uri);
            m_savedSongs->removeAll([&](const Song &item) { return item.uri == song.uri; });
        } else {
            m_savedUris.insert(song.uri);
            QList<Song> updated = m_savedSongs->songs();
            updated.prepend(song);
            m_savedSongs->setSongs(updated);
        }
        adjustSavedSongTotal(shouldSave ? -1 : 1);
        ++m_savedRevision;
        emit savedChanged();
        reportError(QStringLiteral("Updating saved songs"), error.message());
    }
    if (generation == m_session->generation()) {
        m_pendingSavedUris.remove(song.uri);
    }
}

QCoro::Task<> LibraryStore::loadSavedStatuses(QList<Song> songs)
{
    if (m_session->libraryNeedsAuthorizationUpgrade() || !m_session->hasLibraryToken() || songs.isEmpty()) {
        co_return;
    }
    const int revision = m_savedStatusRevision;
    const QSet<QString> pendingAtRequest = m_pendingSavedUris;
    QStringList uris;
    for (const Song &song : songs) {
        uris.append(song.uri);
    }
    try {
        const QHash<QString, bool> statuses = co_await m_session->withLibraryAccessToken<QHash<QString, bool>>(
            [this, uris](QString accessToken) { return m_session->webApi().savedStatuses(uris, accessToken); });
        if (revision != m_savedStatusRevision) {
            co_return;
        }
        bool changed = false;
        for (auto status = statuses.cbegin(); status != statuses.cend(); ++status) {
            if (m_pendingSavedUris.contains(status.key()) || pendingAtRequest.contains(status.key())) {
                continue;
            }
            if (status.value() && !m_savedUris.contains(status.key())) {
                m_savedUris.insert(status.key());
                changed = true;
            } else if (!status.value() && m_savedUris.remove(status.key())) {
                changed = true;
            }
        }
        if (changed) {
            ++m_savedRevision;
            emit savedChanged();
        }
    } catch (const Cancelled &) {
    } catch (const SpotifyError &error) {
        qCInfo(lcLibrary).noquote() << "checking saved songs:" << error.message();
    }
}

// --- loading ---------------------------------------------------------------------------

void LibraryStore::markReady(bool &part)
{
    const bool was = isLibraryReady();
    part = true;
    if (isLibraryReady() != was) {
        emit libraryReadyChanged();
    }
}

QCoro::Task<> LibraryStore::loadInitialLibrary()
{
    if (!m_session->hasLibraryToken()) {
        m_followedLoadedOnce = true;
        markReady(m_initialLoadDone);
        co_return;
    }
    if (!m_session->libraryNeedsAuthorizationUpgrade()) {
        try {
            const Profile profile = co_await m_session->withLibraryAccessToken<Profile>(
                [this](QString accessToken) { return m_session->webApi().profile(accessToken); });
            setProfile(profile);
        } catch (const Cancelled &) {
            co_return;
        } catch (const SpotifyError &error) {
            qCWarning(lcLibrary).noquote() << "loading spotify profile:" << error.message();
        }
    }
    co_await loadPlaylists();
    if (!m_session->libraryNeedsAuthorizationUpgrade()) {
        co_await loadHome();
    }
    markReady(m_initialLoadDone);
    // search's browse all, ready before search is opened
    loadBrowse();
}

QCoro::Task<> LibraryStore::loadPlaylists()
{
    if (!m_session->hasLibraryToken() || m_loadingPlaylists) {
        co_return;
    }
    setLoading(m_loadingPlaylists, true);
    const quint64 generation = m_session->generation();
    try {
        const QList<Playlist> playlists = co_await m_session->withLibraryAccessToken<QList<Playlist>>(
            [this](QString accessToken) { return m_session->webApi().playlists(accessToken); });
        setPlaylistList(playlists);
        m_session->setLibraryStatus(QStringLiteral("Connected"));
        detach(loadFollowedArtists());
        detach(indexPlaylistsForSearch(playlists));
    } catch (const Cancelled &) {
    } catch (const SpotifyError &error) {
        reportError(QStringLiteral("Loading playlists"), error.message());
    }
    if (generation == m_session->generation()) {
        setLoading(m_loadingPlaylists, false);
    }
}

void LibraryStore::retryLoadingPlaylists()
{
    detach(loadPlaylists());
}

QCoro::Task<> LibraryStore::loadHome()
{
    if (m_session->libraryNeedsAuthorizationUpgrade() || !m_session->hasLibraryToken() || m_loadingHome) {
        co_return;
    }
    setLoading(m_loadingHome, true);
    const quint64 generation = m_session->generation();
    // the favourite songs' card counts them, long before their list is opened
    detach(loadSavedSongTotal());
    try {
        const QList<Song> recent = co_await m_session->withLibraryAccessToken<QList<Song>>(
            [this](QString accessToken) { return m_session->webApi().recentlyPlayed(accessToken); });
        m_recentlyPlayed->setSongs(recent);
        refreshRecommendations();
        m_hasLoadedHome = true;
        co_await loadSavedStatuses(recent);
    } catch (const Cancelled &) {
    } catch (const SpotifyError &error) {
        qCWarning(lcLibrary).noquote() << "loading recently played songs:" << error.message();
    }
    if (generation == m_session->generation()) {
        setLoading(m_loadingHome, false);
    }
}

QCoro::Task<> LibraryStore::loadSavedSongs()
{
    if (m_session->libraryNeedsAuthorizationUpgrade()) {
        m_errors->show(QStringLiteral("Reconnect your library once to enable saved songs and playlist editing."));
        co_return;
    }
    if (!m_session->hasLibraryToken() || m_loadingSavedSongs) {
        co_return;
    }
    setLoading(m_loadingSavedSongs, true);
    const quint64 generation = m_session->generation();
    const int revision = m_savedStatusRevision;
    try {
        const QList<Song> loaded = co_await m_session->withLibraryAccessToken<QList<Song>>(
            [this](QString accessToken) { return m_session->webApi().savedSongs(accessToken); });
        if (revision == m_savedStatusRevision) {
            QList<Song> merged;
            for (const Song &song : m_savedSongs->songs()) {
                if (m_pendingSavedUris.contains(song.uri)) {
                    merged.append(song);
                }
            }
            for (const Song &song : loaded) {
                if (!m_pendingSavedUris.contains(song.uri)) {
                    merged.append(song);
                }
            }
            m_savedSongs->setSongs(merged);
            m_songListCache.save(kSavedSongsCacheKey, loaded);
            for (const Song &song : merged) {
                m_savedUris.insert(song.uri);
            }
            m_hasLoadedSavedSongs = true;
            ++m_savedRevision;
            emit savedChanged();
            emit savedSongTotalChanged();
        }
    } catch (const Cancelled &) {
    } catch (const SpotifyError &error) {
        reportError(QStringLiteral("Loading saved songs"), error.message());
    }
    if (generation == m_session->generation()) {
        setLoading(m_loadingSavedSongs, false);
    }
}

QCoro::Task<> LibraryStore::loadSavedSongTotal()
{
    if (m_hasLoadedSavedSongs) {
        co_return;
    }
    const int revision = m_savedStatusRevision;
    try {
        const int total = co_await m_session->withLibraryAccessToken<int>(
            [this](QString accessToken) { return m_session->webApi().savedSongTotal(accessToken); });
        // a song saved or removed meanwhile may or may not be counted in it
        if (revision == m_savedStatusRevision && !m_hasLoadedSavedSongs) {
            m_savedSongTotal = total;
            emit savedSongTotalChanged();
        }
    } catch (const Cancelled &) {
    } catch (const SpotifyError &error) {
        qCWarning(lcLibrary).noquote() << "counting saved songs:" << error.message();
    }
}

void LibraryStore::adjustSavedSongTotal(int delta)
{
    if (!m_hasLoadedSavedSongs && m_savedSongTotal >= 0) {
        m_savedSongTotal = std::max(0, m_savedSongTotal + delta);
        emit savedSongTotalChanged();
    }
}

// --- editing -------------------------------------------------------------------------------

void LibraryStore::adjustPlaylistSongCount(const QString &id, int delta)
{
    QList<Playlist> playlists = m_playlistList;
    for (Playlist &playlist : playlists) {
        if (playlist.id == id) {
            playlist.songCount = std::max(playlist.songCount + delta, 0);
            setPlaylistList(playlists);
            return;
        }
    }
}

void LibraryStore::addToPlaylist(const Song &song, const Playlist &playlist)
{
    if (playlist.isLocal()) {
        // what changes shows once the library says so (refreshLocalPlaylist)
        if (!song.isLocalFile()) {
            m_errors->show(QStringLiteral("Only music files on this computer can go in “%1”.").arg(playlist.name));
        } else if (m_localFiles) {
            m_localFiles->addSongs(playlist.id, {song});
        }
        return;
    }
    detach(runAdd(song, playlist));
}

QCoro::Task<> LibraryStore::runAdd(Song song, Playlist playlist)
{
    if (!m_session->hasFullLibraryAccess()) {
        m_errors->show(kReconnectToEdit);
        co_return;
    }
    if (!m_session->hasLibraryToken()) {
        m_errors->show(QStringLiteral("Connect your Spotify library to edit playlists."));
        co_return;
    }
    try {
        co_await m_session->withLibraryAccessToken<void>([this, uri = song.uri, id = playlist.id](QString accessToken) {
            return m_session->webApi().addToPlaylist(uri, id, accessToken);
        });
        if (selectedPlaylistId() == playlist.id) {
            QList<Song> songs = m_songs;
            songs.append(song.freshInstance());
            setSongs(songs);
        }
        adjustPlaylistSongCount(playlist.id, 1);
    } catch (const Cancelled &) {
    } catch (const SpotifyError &error) {
        reportError(QStringLiteral("Adding to \"%1\"").arg(playlist.name), error.message());
    }
}

void LibraryStore::removeFromSelectedPlaylist(const Song &song)
{
    const Playlist playlist = selectedPlaylist();
    if (playlist.isLocal()) {
        removeFromLocalPlaylist(song, playlist);
    } else if (playlist.isValid()) {
        detach(runRemove(song, playlist));
    }
}

void LibraryStore::removeFromPlaylist(const Song &song, const Playlist &playlist)
{
    if (playlist.isLocal()) {
        removeFromLocalPlaylist(song, playlist);
        return;
    }
    detach(runRemove(song, playlist));
}

void LibraryStore::removeFromLocalPlaylist(const Song &song, const Playlist &playlist)
{
    if (m_localFiles) {
        m_localFiles->removeSong(playlist.id, song.uri);
    }
}

QCoro::Task<> LibraryStore::runRemove(Song song, Playlist playlist)
{
    if (!m_session->hasFullLibraryAccess()) {
        m_errors->show(kReconnectToEdit);
        co_return;
    }
    if (!playlist.canModify(m_profile.id) || !m_session->hasLibraryToken()) {
        co_return;
    }
    try {
        co_await m_session->withLibraryAccessToken<void>([this, uri = song.uri, id = playlist.id](QString accessToken) {
            return m_session->webApi().removeFromPlaylist(uri, id, accessToken);
        });
        // navigation can change while the request is in flight. never remove
        // matching songs from a newly selected playlist.
        if (selectedPlaylistId() == playlist.id) {
            QList<Song> songs = m_songs;
            const qsizetype before = songs.size();
            songs.removeIf([&](const Song &item) { return item.uri == song.uri; });
            const int removed = int(before - songs.size());
            setSongs(songs);
            adjustPlaylistSongCount(playlist.id, -removed);
        } else {
            co_await loadPlaylists();
        }
    } catch (const Cancelled &) {
    } catch (const SpotifyError &error) {
        reportError(QStringLiteral("Removing from \"%1\"").arg(playlist.name), error.message());
    }
}

QString LibraryStore::reorderFailureMessage(const QString &message, bool forbidden, const Playlist &playlist) const
{
    // spotify answers a refused reorder with the bare word "forbidden".
    if (!forbidden) {
        return message;
    }
    if (playlist.ownerId != m_profile.id) {
        return QStringLiteral("Only the owner can reorder “%1”. You can still add and remove songs.").arg(playlist.name);
    }
    return QStringLiteral("Spotify would not reorder “%1”. Reconnect your library in Settings and try again.").arg(playlist.name);
}

void LibraryStore::moveSongs(int from, int count, int to)
{
    // a playlist made here is the person's own, and spotify has no say in it
    const Playlist playlist = selectedPlaylist();
    const bool local = playlist.isLocal();
    if (!local && !m_session->hasFullLibraryAccess()) {
        m_errors->show(kReconnectToEdit);
        return;
    }
    // every refusal below used to be silent, which looked exactly like a
    // broken drag: the row sprang back and nothing else happened.
    if (!playlist.isValid()) {
        m_errors->show(QStringLiteral("Open the playlist once before reordering it."));
        return;
    }
    if (!local && !playlist.canModify(m_profile.id)) {
        m_errors->show(QStringLiteral("“%1” belongs to someone else, so its order cannot be changed.").arg(playlist.name));
        return;
    }
    if (!local && !m_session->hasLibraryRefreshToken()) {
        m_errors->show(kReconnectToEdit);
        return;
    }
    if (count <= 0 || from < 0 || from + count > m_songs.size() || to < 0 || to > m_songs.size()) {
        return;
    }

    QList<Song> reordered = m_songs;
    const QList<Song> moving = reordered.mid(from, count);
    reordered.remove(from, count);
    const int insertAt = to > from ? to - count : to;
    for (int offset = 0; offset < count; ++offset) {
        reordered.insert(insertAt + offset, moving.at(offset));
    }
    const auto uris = [](const QList<Song> &songs) {
        QStringList result;
        for (const Song &song : songs) {
            result.append(song.uri);
        }
        return result;
    };
    if (uris(reordered) == uris(m_songs)) {
        return;
    }

    const QList<Song> previous = m_songs;
    // the rows move in place, so the drag lands without the list resetting.
    m_songs = reordered;
    m_openedPlaylists.insert(playlist.id, reordered);
    m_playlistSongs->moveRows(from, count, to);
    m_displayedPlaylistSongs->moveRows(from, count, to);
    if (local) {
        if (m_localFiles) {
            m_localFiles->reorder(playlist.id, uris(reordered));
        }
        return;
    }
    detach(runMove(playlist, from, count, to, previous, reordered));
}

QCoro::Task<> LibraryStore::runMove(Playlist playlist, int from, int count, int to, QList<Song> previous, QList<Song> reordered)
{
    QString failure;
    bool forbidden = false;
    try {
        co_await m_session->withLibraryAccessToken<void>([this, id = playlist.id, from, to, count](QString accessToken) {
            return m_session->webApi().reorderPlaylist(id, from, to, count, accessToken);
        });
        co_return;
    } catch (const Cancelled &) {
        co_return;
    } catch (const SpotifyError &error) {
        failure = error.message();
        forbidden = error.kind() == SpotifyError::Kind::Forbidden;
    }
    reportError(QStringLiteral("Reordering \"%1\" (owner %2, collaborative %3)")
                    .arg(playlist.name, playlist.ownerId.isEmpty() ? QStringLiteral("unknown") : playlist.ownerId)
                    .arg(playlist.isCollaborative),
                reorderFailureMessage(failure, forbidden, playlist));
    // put the order back rather than refetching the playlist: the move did not
    // happen, and a full reload throws away the rest of the page's state.
    const bool stillShown = selectedPlaylistId() == playlist.id && m_songs.size() == reordered.size()
        && std::equal(m_songs.begin(), m_songs.end(), reordered.begin(),
                      [](const Song &a, const Song &b) { return a.uri == b.uri; });
    if (stillShown) {
        setSongs(previous);
    }
}

void LibraryStore::deletePlaylist(const Playlist &playlist)
{
    if (playlist.isLocal()) {
        deleteLocalPlaylist(playlist);
        return;
    }
    detach(runDelete(playlist));
}

void LibraryStore::deleteLocalPlaylist(const Playlist &playlist)
{
    if (!m_localFiles || !m_localFiles->deletePlaylist(playlist.id)) {
        return;
    }
    if (m_pinnedIds.remove(playlist.id)) {
        persistPins();
        refreshPinnedPlaylists();
        ++m_pinsRevision;
        emit pinsChanged();
    }
    m_openedPlaylists.remove(playlist.id);
    m_songListCache.remove(playlist.id);
    if (selectedPlaylistId() == playlist.id) {
        setSongs({});
        m_playlistFilterQuery.clear();
        navigate({Page::LocalFiles});
    }
    emit playlistDeleted(playlist.id);
}

QCoro::Task<> LibraryStore::runDelete(Playlist playlist)
{
    if (!m_session->hasFullLibraryAccess()) {
        m_errors->show(kReconnectToEdit);
        co_return;
    }
    if (!m_session->hasLibraryToken()) {
        m_errors->show(QStringLiteral("Connect your Spotify library to delete playlists."));
        co_return;
    }
    try {
        co_await m_session->withLibraryAccessToken<void>(
            [this, id = playlist.id](QString accessToken) { return m_session->webApi().deletePlaylist(id, accessToken); });
    } catch (const Cancelled &) {
        co_return;
    } catch (const SpotifyError &error) {
        reportError(QStringLiteral("Deleting \"%1\"").arg(playlist.name), error.message());
        co_return;
    }

    QList<Playlist> playlists = m_playlistList;
    playlists.removeIf([&](const Playlist &item) { return item.id == playlist.id; });
    if (m_pinnedIds.remove(playlist.id)) {
        persistPins();
        ++m_pinsRevision;
        emit pinsChanged();
    }
    m_openedPlaylists.remove(playlist.id);
    m_songListCache.remove(playlist.id);
    setPlaylistList(playlists);
    if (selectedPlaylistId() == playlist.id) {
        setSongs({});
        m_playlistFilterQuery.clear();
        navigate({Page::Playlists});
    }
    emit playlistDeleted(playlist.id);
}

void LibraryStore::savePlaylist(bool isNew, const QString &name, const QString &description, bool isPublic,
                                const QByteArray &coverJpeg)
{
    detach(runSave(isNew, name, description, isPublic, coverJpeg));
}

void LibraryStore::saveLocalPlaylist(bool isNew, const QString &name, const QString &description,
                                     const QByteArray &coverJpeg, const QVariant &firstSong)
{
    const Song song = firstSong.value<Song>();
    bool ok = false;
    if (name.trimmed().isEmpty()) {
        m_errors->show(QStringLiteral("Enter a playlist name."));
    } else if (m_localFiles && isNew) {
        const Playlist created = m_localFiles->createPlaylist(
            name, description, coverJpeg, song.isLocalFile() ? QList<Song> {song} : QList<Song> {});
        ok = created.isValid();
        // opened, as a new spotify playlist is
        if (ok) {
            selectPlaylist(created);
        }
    } else if (m_localFiles) {
        const Playlist target = selectedPlaylist();
        ok = target.isLocal() && m_localFiles->updatePlaylist(target.id, name, description, coverJpeg);
    }
    emit playlistSaveFinished(ok);
}

QCoro::Task<> LibraryStore::runSave(bool isNew, QString name, QString description, bool isPublic, QByteArray coverJpeg)
{
    const auto finish = [this](bool ok) {
        setLoading(m_savingPlaylist, false);
        emit playlistSaveFinished(ok);
    };
    if (!m_session->hasFullLibraryAccess()) {
        m_errors->show(kReconnectToEdit);
        finish(false);
        co_return;
    }
    if (!m_session->hasLibraryToken()) {
        m_errors->show(isNew ? QStringLiteral("Connect your Spotify library to create playlists.") : QString());
        finish(false);
        co_return;
    }
    name = name.trimmed();
    description = description.trimmed();
    if (name.isEmpty()) {
        m_errors->show(QStringLiteral("Enter a playlist name."));
        finish(false);
        co_return;
    }

    setLoading(m_savingPlaylist, true);
    Playlist target;
    try {
        if (isNew) {
            target = co_await m_session->withLibraryAccessToken<Playlist>([this, name, description, isPublic](QString accessToken) {
                return m_session->webApi().createPlaylist(name, description, isPublic, accessToken);
            });
            QList<Playlist> playlists = m_playlistList;
            playlists.prepend(target);
            setPlaylistList(playlists);
            navigate({Page::Playlist, target.id});
            setSongs({});
        } else {
            target = selectedPlaylist();
            if (!target.isValid()) {
                finish(false);
                co_return;
            }
            co_await m_session->withLibraryAccessToken<void>([this, id = target.id, name, description, isPublic](QString accessToken) {
                return m_session->webApi().updatePlaylist(id, name, description, isPublic, accessToken);
            });
            QList<Playlist> playlists = m_playlistList;
            for (Playlist &playlist : playlists) {
                if (playlist.id == target.id) {
                    playlist.name = name;
                    playlist.description = description;
                    playlist.isPublic = isPublic;
                    target = playlist;
                }
            }
            setPlaylistList(playlists);
        }
    } catch (const Cancelled &) {
        finish(false);
        co_return;
    } catch (const SpotifyError &error) {
        reportError(isNew ? QStringLiteral("Creating playlist") : QStringLiteral("Updating playlist"), error.message());
        finish(false);
        co_return;
    }

    // the macos app only uploaded a chosen cover when editing; a new playlist
    // gets its cover too.
    bool ok = true;
    if (!coverJpeg.isEmpty()) {
        ok = co_await uploadCover(target, coverJpeg);
    }
    finish(ok);
}

QCoro::Task<bool> LibraryStore::uploadCover(Playlist playlist, QByteArray jpeg)
{
    if (!playlist.canModify(m_profile.id) || !m_session->hasLibraryToken()) {
        co_return false;
    }
    try {
        co_await m_session->withLibraryAccessToken<void>([this, id = playlist.id, jpeg](QString accessToken) {
            return m_session->webApi().setPlaylistImage(id, jpeg, accessToken);
        });
    } catch (const Cancelled &) {
        co_return false;
    } catch (const SpotifyError &error) {
        reportError(QStringLiteral("Setting the cover for \"%1\"").arg(playlist.name), error.message());
        co_return false;
    }
    detach(refreshCover(playlist));
    co_return true;
}

QCoro::Task<> LibraryStore::refreshCover(Playlist playlist)
{
    // spotify mints a new image url for an uploaded cover once it has processed
    // it, and the old url keeps serving the old picture until then.
    const QUrl staleUrl = playlist.artworkUrl;
    co_await loadPlaylists();
    const auto currentUrl = [&] {
        for (const Playlist &item : m_playlistList) {
            if (item.id == playlist.id) {
                return item.artworkUrl;
            }
        }
        return QUrl();
    };
    if (currentUrl() != staleUrl) {
        co_return;
    }
    co_await QCoro::sleepFor(std::chrono::seconds(4));
    co_await loadPlaylists();
}

// --- logout ------------------------------------------------------------------------------

void LibraryStore::reset()
{
    m_pendingSavedUris.clear();
    ++m_savedStatusRevision;
    m_songLoad.cancel();
    m_artistLoad.cancel();
    m_search.cancel();
    m_hasLoadedHome = false;
    m_hasLoadedSavedSongs = false;
    m_savedSongTotal = -1;
    emit savedSongTotalChanged();

    setProfile({});
    setPlaylistList({});
    m_songs.clear();
    m_playlistSongs->clear();
    m_displayedPlaylistSongs->clear();
    m_openedPlaylists.clear();
    m_songListCache.clear();
    m_openedAlbums.clear();
    m_openedArtists.clear();
    m_savedSongs->clear();
    m_recentlyPlayed->clear();
    m_recommendedAlbums->setItems({});
    m_recommendedArtists->setItems({});
    m_followedArtists->setItems({});
    m_radioSongs->clear();
    m_newReleases->setItems({});
    m_friendActivity.clear();
    m_friendActivityMessage.clear();
    emit friendActivityChanged();
    m_albumSongs->clear();
    m_artistAlbums->setItems({});
    m_artistTopSongs->clear();
    m_searchSongs->clear();
    m_searchAlbums->setItems({});
    m_searchArtists->setItems({});
    m_searchPlaylists->setItems({});
    m_savedUris.clear();
    ++m_savedRevision;

    m_history.clear();
    m_restoreTarget.reset();
    m_destination = {Page::Home};
    m_searchQuery.clear();
    m_playlistFilterQuery.clear();
    m_sortOrder = SortOrder::Playlist;

    m_loadingPlaylists = m_loadingSongs = m_loadingHome = m_loadingSavedSongs = false;
    m_searching = m_loadingArtist = m_savingPlaylist = false;
    emit loadingChanged();
    emit destinationChanged();
    emit currentArtistChanged();
    emit selectedPlaylistChanged();
    emit searchChanged();
    emit savedChanged();
    emit playlistViewChanged();
}

} // namespace swiftify
