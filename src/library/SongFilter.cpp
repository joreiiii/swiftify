#include "library/SongFilter.h"

#include "core/Async.h"
#include "library/GenreLookup.h"
#include "library/SongListModel.h"

#include <QPointer>
#include <QSet>

#include <algorithm>

namespace swiftify {

namespace {

/// chips of each kind shown, at most
constexpr int kGenreChips = 12;
/// the artists most heard whose genres are looked up
constexpr int kLookedUp = 40;

/// the keys of `counts`, most counted first, of at least `least` and fewer
/// than `most`: a chip every song has filters nothing
QStringList ranked(const QHash<QString, int> &counts, int least, int most, int limit)
{
    QList<QPair<QString, int>> entries;
    for (auto it = counts.cbegin(); it != counts.cend(); ++it) {
        if (it.value() >= least && it.value() < most) {
            entries.append({it.key(), it.value()});
        }
    }
    std::sort(entries.begin(), entries.end(), [](const auto &a, const auto &b) {
        return a.second != b.second ? a.second > b.second : a.first < b.first;
    });
    QStringList result;
    for (const auto &entry : entries.mid(0, limit)) {
        result.append(entry.first);
    }
    return result;
}

/// "alternative rock" reads as spotify writes its chips: "Alternative Rock"
QString titled(const QString &genre)
{
    QStringList words = genre.split(u' ', Qt::SkipEmptyParts);
    for (QString &word : words) {
        word[0] = word[0].toUpper();
    }
    return words.join(u' ');
}

} // namespace

SongFilter::SongFilter(QObject *parent)
    : QObject(parent)
    , m_songs(new SongListModel(this))
{
    // a list loads in steps: the chips are worked out once it settles
    m_settle.setSingleShot(true);
    m_settle.setInterval(60);
    connect(&m_settle, &QTimer::timeout, this, &SongFilter::rebuildChips);
}

void SongFilter::setSource(SongListModel *source)
{
    if (m_source == source) {
        return;
    }
    if (m_source) {
        disconnect(m_source, nullptr, this, nullptr);
    }
    m_source = source;
    if (m_source) {
        connect(m_source, &SongListModel::modelReset, this, &SongFilter::sourceSongsChanged);
        connect(m_source, &SongListModel::rowsInserted, this, &SongFilter::sourceSongsChanged);
        connect(m_source, &SongListModel::rowsRemoved, this, &SongFilter::sourceSongsChanged);
        connect(m_source, &SongListModel::dataChanged, this, &SongFilter::sourceSongsChanged);
    }
    m_active.clear();
    emit activeChanged();
    emit sourceChanged();
    sourceSongsChanged();
}

void SongFilter::setActive(const QString &chip)
{
    const QString next = chip == m_active ? QString() : chip;
    if (next == m_active) {
        return;
    }
    m_active = next;
    emit activeChanged();
    apply();
}

void SongFilter::sourceSongsChanged()
{
    apply();
    m_settle.start();
}

bool SongFilter::matches(const Song &song) const
{
    for (const Artist &artist : song.artistItems) {
        for (const QString &genre : m_genres.value(artist.id)) {
            if (titled(genre) == m_active) {
                return true;
            }
        }
    }
    return false;
}

void SongFilter::apply()
{
    const QList<Song> all = m_source ? m_source->songs() : QList<Song> {};
    if (m_active.isEmpty()) {
        m_songs->setSongs(all);
        return;
    }
    QList<Song> kept;
    for (const Song &song : all) {
        if (matches(song)) {
            kept.append(song);
        }
    }
    m_songs->setSongs(kept);
}

void SongFilter::rebuildChips()
{
    const QList<Song> all = m_source ? m_source->songs() : QList<Song> {};
    // the artists, most heard first: their genres are looked up in that order
    QHash<QString, int> heard;
    QHash<QString, Artist> byId;
    for (const Song &song : all) {
        for (const Artist &artist : song.artistItems) {
            if (!artist.id.isEmpty()) {
                heard[artist.id] += 1;
                byId.insert(artist.id, artist);
            }
        }
    }
    QList<Artist> artists = byId.values();
    std::stable_sort(artists.begin(), artists.end(),
                     [&heard](const Artist &a, const Artist &b) { return heard.value(a.id) > heard.value(b.id); });
    // the chips show at once with what is known; genres join as they come
    const quint64 generation = ++m_generation;
    showChips(all);
    detach(runChips(generation, all, artists.mid(0, kLookedUp)));
}

void SongFilter::showChips(const QList<Song> &all)
{
    QHash<QString, int> genreCounts;
    for (const Song &song : all) {
        QSet<QString> songGenres;
        for (const Artist &artist : song.artistItems) {
            for (const QString &genre : m_genres.value(artist.id)) {
                songGenres.insert(titled(genre));
            }
        }
        for (const QString &genre : songGenres) {
            genreCounts[genre] += 1;
        }
    }
    const int total = int(all.size());
    const QStringList chips = ranked(genreCounts, std::max(2, total / 50), total, kGenreChips);
    if (chips != m_chips) {
        m_chips = chips;
        emit chipsChanged();
    }
    if (!m_active.isEmpty() && !chips.contains(m_active)) {
        m_active.clear();
        emit activeChanged();
    }
    apply();
}

QCoro::Task<> SongFilter::runChips(quint64 generation, QList<Song> all, QList<Artist> artists)
{
    QPointer<SongFilter> self(this);
    GenreLookup *lookup = GenreLookup::instance();
    int fresh = 0;
    for (const Artist &artist : artists) {
        const bool asked = !lookup->knows(artist.id);
        const QStringList genres = co_await lookup->genresOf(artist);
        // gone, or a newer list came while MusicBrainz answered
        if (!self || generation != m_generation) {
            co_return;
        }
        m_genres.insert(artist.id, genres);
        // the row is brought up to date every few artists looked up, not
        // with every one, and at once for what was known already
        if (asked && ++fresh % 8 == 0) {
            showChips(all);
        }
    }
    showChips(all);
}

} // namespace swiftify
