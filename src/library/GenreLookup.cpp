#include "library/GenreLookup.h"

#include "app/Paths.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLoggingCategory>
#include <QNetworkReply>
#include <QPointer>
#include <QSaveFile>
#include <QUrlQuery>
#include <QCoroNetworkReply>
#include <QCoroTimer>

#include <algorithm>
#include <chrono>
#include <memory>

Q_LOGGING_CATEGORY(lcGenres, "swiftify.genres")

namespace swiftify {

namespace {

/// MusicBrainz asks for no more than one request a second
constexpr qint64 kSpacingMs = 1500;
/// a 503 (MusicBrainz turning a request away) is tried again this often,
/// further apart each time
constexpr int kRetries = 3;
/// a name search below this score is somebody else of that name
constexpr int kLeastScore = 90;

QString cachePath()
{
    return paths::cacheDirectory() + QStringLiteral("/artist-genres.json");
}

} // namespace

GenreLookup *GenreLookup::instance()
{
    static GenreLookup *lookup = new GenreLookup(QCoreApplication::instance());
    return lookup;
}

GenreLookup::GenreLookup(QObject *parent)
    : QObject(parent)
{
    load();
}

void GenreLookup::load()
{
    QFile file(cachePath());
    if (!file.open(QIODevice::ReadOnly)) {
        return;
    }
    const QJsonObject stored = QJsonDocument::fromJson(file.readAll()).object();
    for (auto it = stored.constBegin(); it != stored.constEnd(); ++it) {
        QStringList genres;
        for (const QJsonValue &genre : it.value().toArray()) {
            genres.append(genre.toString());
        }
        m_genres.insert(it.key(), genres);
    }
}

void GenreLookup::save() const
{
    QJsonObject stored;
    for (auto it = m_genres.constBegin(); it != m_genres.constEnd(); ++it) {
        stored.insert(it.key(), QJsonArray::fromStringList(it.value()));
    }
    QDir().mkpath(paths::cacheDirectory());
    QSaveFile file(cachePath());
    if (file.open(QIODevice::WriteOnly)) {
        file.write(QJsonDocument(stored).toJson(QJsonDocument::Compact));
        file.commit();
    }
}

QCoro::Task<QByteArray> GenreLookup::get(QUrl url)
{
    for (int attempt = 0; attempt <= kRetries; ++attempt) {
        // a slot of its own, taken before waiting, so callers asking at once
        // line up rather than going out together; a retry waits longer
        const QDateTime now = QDateTime::currentDateTimeUtc();
        const QDateTime slot = m_nextSlot.isValid() && m_nextSlot > now ? m_nextSlot : now;
        m_nextSlot = slot.addMSecs(kSpacingMs * (1 + attempt));
        if (const qint64 wait = now.msecsTo(slot); wait > 0) {
            co_await QCoro::sleepFor(std::chrono::milliseconds(wait));
        }

        QNetworkRequest request(url);
        // MusicBrainz turns away requests that do not say who is asking
        request.setHeader(QNetworkRequest::UserAgentHeader,
                          QStringLiteral("Swiftify/%1 ( https://github.com/joreiiii/swiftify )").arg(QStringLiteral(SWIFTIFY_VERSION)));
        request.setRawHeader("Accept", "application/json");
        request.setTransferTimeout(15'000);
        std::unique_ptr<QNetworkReply> reply(m_network.get(request));
        co_await qCoro(reply.get()).waitForFinished();
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (status == 200) {
            co_return reply->readAll();
        }
        if (status != 503) {
            qCInfo(lcGenres).noquote() << "MusicBrainz answered" << status << "for" << url.path();
            co_return QByteArray();
        }
    }
    qCInfo(lcGenres).noquote() << "MusicBrainz kept turning away" << url.path();
    co_return QByteArray();
}

QCoro::Task<QStringList> GenreLookup::genresOf(Artist artist)
{
    if (const auto known = m_genres.constFind(artist.id); known != m_genres.cend()) {
        co_return *known;
    }
    if (artist.name.isEmpty()) {
        co_return QStringList();
    }
    QPointer<GenreLookup> self(this);

    // the artist by name: the best match, if it is good enough
    QUrl search(QStringLiteral("https://musicbrainz.org/ws/2/artist/"));
    QString escaped = artist.name;
    escaped.replace(u'"', QStringLiteral("\\\""));
    search.setQuery(QUrlQuery {{QStringLiteral("query"), QStringLiteral("artist:\"%1\"").arg(escaped)},
                               {QStringLiteral("limit"), QStringLiteral("1")},
                               {QStringLiteral("fmt"), QStringLiteral("json")}});
    const QByteArray found = co_await get(search);
    if (!self) {
        co_return QStringList();
    }
    if (found.isEmpty()) {
        // unreachable: asked again another time
        co_return QStringList();
    }
    const QJsonObject best = QJsonDocument::fromJson(found).object()
                                 .value(QStringLiteral("artists")).toArray().first().toObject();
    QStringList genres;
    const QString id = best.value(QStringLiteral("id")).toString();
    if (!id.isEmpty() && best.value(QStringLiteral("score")).toInt() >= kLeastScore) {
        // its genres, as MusicBrainz's editors voted them
        QUrl lookup(QStringLiteral("https://musicbrainz.org/ws/2/artist/") + id);
        lookup.setQuery(QUrlQuery {{QStringLiteral("inc"), QStringLiteral("genres")},
                                   {QStringLiteral("fmt"), QStringLiteral("json")}});
        const QByteArray details = co_await get(lookup);
        if (!self) {
            co_return QStringList();
        }
        if (details.isEmpty()) {
            co_return QStringList();
        }
        QList<QPair<int, QString>> voted;
        for (const QJsonValue &value : QJsonDocument::fromJson(details).object().value(QStringLiteral("genres")).toArray()) {
            const QJsonObject genre = value.toObject();
            voted.append({genre.value(QStringLiteral("count")).toInt(), genre.value(QStringLiteral("name")).toString()});
        }
        std::stable_sort(voted.begin(), voted.end(), [](const auto &a, const auto &b) { return a.first > b.first; });
        for (const auto &entry : voted.mid(0, 4)) {
            genres.append(entry.second);
        }
    }
    m_genres.insert(artist.id, genres);
    save();
    co_return genres;
}

} // namespace swiftify
