//! the person's library through the one spotify login, as spotify's own
//! apps reach it: the profile, the playlists (the rootlist), the saved songs
//! and followed artists (the collection), what played last, albums and
//! songs, and changes to all of them. the web api would need a developer
//! app of the person's own, and with spotify's client it is rate limited
//! for everyone at once.
//!
//! each answer is json shaped as the web api's, so the front end reads both
//! the same way.

use std::{
    collections::HashMap,
    time::{SystemTime, UNIX_EPOCH},
};

use http::{HeaderMap, HeaderValue, Method, header::CONTENT_TYPE};
use librespot::{
    core::{Session, SpotifyId, SpotifyUri},
    protocol::{
        extended_metadata::{BatchedEntityRequest, EntityRequest, ExtensionQuery},
        extension_kind::ExtensionKind,
        metadata,
        playlist4_external::{
            Add, CreateListReply, Delta, Item, ListAttributes, ListAttributesPartialState, ListChanges,
            ListUpdateRequest, Mov, Op, Rem, SelectedListContent, UpdateListAttributes, op,
        },
    },
};
use protobuf::{CodedInputStream, CodedOutputStream, EnumOrUnknown, Message, MessageField, rt::WireType};
use serde::Serialize;
use tokio::task::JoinSet;
use serde_json::{Value, json};

use crate::playlist::{ArtistPayload, ImagePayload, ItemPayload, PagePayload, track_metadata};

/// items asked for per rootlist or collection page
const PAGE_LENGTH: usize = 500;
/// a playlist's first items read for its mosaic: enough for four albums
const MOSAIC_ITEMS: usize = 30;
/// spotify's dj, listed among the playlists
const DJ_PLAYLIST: &str = "37i9dQZF1EYkqdzj48dyYq";
const COLLECTION_TYPE: &str = "application/vnd.collection-v2.spotify.proto";

fn now_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs() as i64)
        .unwrap_or_default()
}

fn encoded<T: Serialize>(value: &T, what: &str) -> Result<String, String> {
    serde_json::to_string(value).map_err(|error| format!("failed to encode {what}: {error}"))
}

fn image_url(file_id: &[u8]) -> Option<String> {
    (!file_id.is_empty()).then(|| {
        let hex: String = file_id.iter().map(|byte| format!("{byte:02x}")).collect();
        format!("https://i.scdn.co/image/{hex}")
    })
}

fn base62(uri: &str) -> Result<String, String> {
    let parsed = SpotifyUri::from_uri(uri).map_err(|error| format!("not a spotify uri: {uri}: {error}"))?;
    SpotifyId::try_from(&parsed)
        .and_then(|id| id.to_base62())
        .map_err(|error| format!("not a spotify uri: {uri}: {error}"))
}

// --- the profile ---------------------------------------------------------------------

pub async fn profile_json(session: &Session) -> Result<String, String> {
    let user = session.username();
    let endpoint = format!("/user-profile-view/v3/profile/{user}?playlist_limit=0&artist_limit=0&episode_limit=0");
    let bytes = session
        .spclient()
        .request_as_json(&Method::GET, &endpoint, None, None)
        .await
        .map_err(|error| format!("Spotify would not send your profile: {error}"))?;
    let profile: Value = serde_json::from_slice(&bytes).unwrap_or_default();
    let image = profile.get("image_url").and_then(Value::as_str).unwrap_or_default();
    encoded(
        &json!({
            "id": user,
            "display_name": profile.get("name").and_then(Value::as_str).unwrap_or(&user),
            "images": if image.is_empty() { json!([]) } else { json!([{"url": image}]) },
        }),
        "your profile",
    )
}

// --- recency, for the library's recents --------------------------------------------------

/// when each context (playlist, artist, album) last played, in milliseconds
async fn played_contexts(session: &Session) -> HashMap<String, i64> {
    let endpoint = format!(
        "/recently-played/v3/user/{}/recently-played?format=json&limit=50&filter=default",
        session.username()
    );
    let Ok(bytes) = session.spclient().request_as_json(&Method::GET, &endpoint, None, None).await else {
        return HashMap::new();
    };
    let recent: Value = serde_json::from_slice(&bytes).unwrap_or_default();
    recent
        .get("playContexts")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|context| {
            let uri = context.get("uri")?.as_str()?;
            let time = context.get("lastPlayedTime")?;
            let time = time.as_i64().or_else(|| time.as_str()?.parse().ok())?;
            Some((uri.to_owned(), time))
        })
        .collect()
}

/// the later of when it last played and when it was added or changed, in
/// milliseconds; a time in seconds is taken as one
fn recency(played: Option<i64>, changed: i64) -> i64 {
    let changed = if changed > 0 && changed < 100_000_000_000 { changed * 1000 } else { changed };
    played.unwrap_or_default().max(changed)
}

// --- the playlists ---------------------------------------------------------------------

/// the person's playlists, in their order, as the web api's /me/playlists page
pub async fn playlists_json(session: &Session) -> Result<String, String> {
    let user = session.username();
    let own_name = serde_json::from_str::<Value>(&profile_json(session).await.unwrap_or_default())
        .ok()
        .and_then(|profile| profile.get("display_name").and_then(Value::as_str).map(str::to_owned))
        .unwrap_or_else(|| user.clone());
    let played = played_contexts(session).await;
    let mut playlists = Vec::new();
    let mut from = 0;
    loop {
        let endpoint = format!(
            "/playlist/v2/user/{user}/rootlist?decorate=revision,length,attributes,timestamp,owner&from={from}&length={PAGE_LENGTH}"
        );
        let bytes = session
            .spclient()
            .request(&Method::GET, &endpoint, None, None)
            .await
            .map_err(|error| format!("Spotify would not send your playlists: {error}"))?;
        let list = SelectedListContent::parse_from_bytes(&bytes)
            .map_err(|error| format!("your playlists could not be read: {error}"))?;
        let contents = list.contents.get_or_default();
        for (index, item) in contents.items.iter().enumerate() {
            // folders show as start and end markers: their playlists are kept
            let Ok(SpotifyUri::Playlist { .. }) = SpotifyUri::from_uri(item.uri()) else {
                continue;
            };
            let Some(meta) = contents.meta_items.get(index) else {
                continue;
            };
            let attributes = meta.attributes.get_or_default();
            let mut playlist = playlist_value(item.uri(), attributes, meta.length(), meta.owner_username(), &user, &own_name);
            // spotify's dj: it plays at once rather than opening (dj.rs)
            playlist["dj"] = json!(item.uri().ends_with(DJ_PLAYLIST) || attributes.format() == "lexicon");
            // for the library's recents: when it last played, or changed
            // spotify's recents: when it last played, when it was added to
            // the library, and for the person's own, when they changed it.
            // spotify remakes its own mixes and radios daily, which counts
            // for nothing
            let added = item.attributes.as_ref().map(|attributes| attributes.timestamp()).unwrap_or_default();
            let own = meta.owner_username().is_empty() || meta.owner_username() == user;
            let changed = if own { added.max(meta.timestamp()) } else { added };
            playlist["recency"] = json!(recency(played.get(item.uri()).copied(), changed));
            playlists.push(playlist);
        }
        let fetched = contents.items.len();
        from += fetched;
        if fetched == 0 || from >= usize::try_from(list.length()).unwrap_or(0) {
            break;
        }
    }
    add_mosaics(session, &mut playlists).await;
    name_owners(session, &mut playlists, &user).await;
    encoded(&json!({ "items": playlists }), "your playlists")
}

/// the names other people's playlists are shown under, as spotify shows
/// them: their display names, asked once each, rather than their usernames
async fn name_owners(session: &Session, playlists: &mut [Value], user: &str) {
    let mut owners: Vec<String> = playlists
        .iter()
        .filter_map(|playlist| playlist.pointer("/owner/id")?.as_str().map(str::to_owned))
        .filter(|owner| owner != user && owner != "spotify")
        .collect();
    owners.sort_unstable();
    owners.dedup();
    let mut lookups = JoinSet::new();
    for owner in owners {
        let session = session.clone();
        lookups.spawn(async move {
            let endpoint = format!("/user-profile-view/v3/profile/{owner}?playlist_limit=0&artist_limit=0&episode_limit=0");
            let bytes = session.spclient().request_as_json(&Method::GET, &endpoint, None, None).await.ok()?;
            let profile: Value = serde_json::from_slice(&bytes).ok()?;
            let name = profile.get("name")?.as_str()?.to_owned();
            Some((owner, name))
        });
    }
    let mut names = HashMap::new();
    while let Some(joined) = lookups.join_next().await {
        if let Ok(Some((owner, name))) = joined {
            names.insert(owner, name);
        }
    }
    for playlist in playlists.iter_mut() {
        let owner = playlist.pointer("/owner/id").and_then(Value::as_str).unwrap_or_default().to_owned();
        if owner == "spotify" {
            playlist["owner"]["display_name"] = json!("Spotify");
        } else if let Some(name) = names.get(&owner) {
            playlist["owner"]["display_name"] = json!(name);
        }
    }
}

/// the cover spotify draws for a playlist without a picture of its own: its
/// first four albums' covers in a square, or the first one's when it has
/// fewer. a playlist that cannot be read keeps no cover
async fn add_mosaics(session: &Session, playlists: &mut [Value]) {
    let mut reads = JoinSet::new();
    for (index, playlist) in playlists.iter().enumerate() {
        let bare = playlist.get("images").and_then(Value::as_array).is_none_or(Vec::is_empty);
        let Some(id) = playlist.get("id").and_then(Value::as_str).filter(|_| bare) else {
            continue;
        };
        let (session, endpoint) = (session.clone(), format!("/playlist/v2/playlist/{id}?from=0&length={MOSAIC_ITEMS}"));
        reads.spawn(async move {
            let bytes = session.spclient().request(&Method::GET, &endpoint, None, None).await.ok()?;
            let list = SelectedListContent::parse_from_bytes(&bytes).ok()?;
            let uris: Vec<String> = list.contents.get_or_default().items.iter().map(|item| item.uri().to_owned()).collect();
            Some((index, uris))
        });
    }
    let mut firsts = Vec::new();
    while let Some(joined) = reads.join_next().await {
        if let Ok(Some(read)) = joined {
            firsts.push(read);
        }
    }
    let all: Vec<String> = firsts.iter().flat_map(|(_, uris)| uris.iter().cloned()).collect();
    let Ok(tracks) = track_metadata(session, &all).await else {
        return;
    };
    for (index, uris) in firsts {
        let mut albums: Vec<String> = Vec::new();
        let mut covers: Vec<String> = Vec::new();
        for (album, cover) in uris.iter().filter_map(|uri| tracks.get(uri)?.album_cover()) {
            if covers.len() < 4 && !albums.contains(&album) {
                albums.push(album);
                covers.push(cover);
            }
        }
        let url = match covers.len() {
            0 => continue,
            4 => format!("https://mosaic.scdn.co/640/{}", covers.concat()),
            _ => format!("https://i.scdn.co/image/{}", covers[0]),
        };
        playlists[index]["images"] = json!([{ "url": url, "width": 640, "height": 640 }]);
    }
}

fn playlist_value(uri: &str, attributes: &ListAttributes, length: i32, owner: &str, user: &str, own_name: &str) -> Value {
    // its own picture, or the mosaic spotify makes of its first covers
    let mut images: Vec<Value> = Vec::new();
    if let Some(url) = image_url(attributes.picture()) {
        images.push(json!({ "url": url, "width": 640, "height": 640 }));
    }
    for size in &attributes.picture_size {
        if !size.url().is_empty() {
            let side = match size.target_name() {
                "large" | "xlarge" => 640,
                "small" => 60,
                _ => 300,
            };
            images.push(json!({ "url": size.url(), "width": side, "height": side }));
        }
    }
    for attribute in &attributes.format_attributes {
        if attribute.key() == "image_url" && !attribute.value().is_empty() {
            images.push(json!({ "url": attribute.value(), "width": 640, "height": 640 }));
        }
    }
    let owner = if owner.is_empty() { user } else { owner };
    json!({
        "id": uri.rsplit(':').next().unwrap_or_default(),
        "uri": uri,
        "name": attributes.name(),
        "description": attributes.description(),
        "images": images,
        "owner": { "id": owner, "display_name": if owner == user { own_name } else { owner } },
        "tracks": { "total": length },
        "collaborative": attributes.collaborative(),
        "public": false,
    })
}

// --- the collection: saved songs, followed artists ------------------------------------------------

/// a collection's items, newest first: their uris and when they were added
async fn collection_items(session: &Session, set: &str) -> Result<Vec<(String, i64)>, String> {
    let user = session.username();
    let mut items = Vec::new();
    let mut token = String::new();
    loop {
        let mut body = Vec::new();
        {
            let mut out = CodedOutputStream::vec(&mut body);
            let _ = out.write_string(1, &user);
            let _ = out.write_string(2, set);
            if !token.is_empty() {
                let _ = out.write_string(3, &token);
            }
            let _ = out.write_int32(4, PAGE_LENGTH as i32);
            let _ = out.flush();
        }
        let bytes = session
            .spclient()
            .request(&Method::POST, "/collection/v2/paging", Some(collection_headers()), Some(&body))
            .await
            .map_err(|error| format!("Spotify would not send your {set}: {error}"))?;
        let (page, next) = parse_page(&bytes);
        items.extend(page);
        if next.is_empty() || next == token {
            break;
        }
        token = next;
    }
    items.sort_by(|a, b| b.1.cmp(&a.1));
    Ok(items)
}

fn collection_headers() -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static(COLLECTION_TYPE));
    headers
}

/// a PageResponse: its items' uris and added times, and the next page's token
fn parse_page(bytes: &[u8]) -> (Vec<(String, i64)>, String) {
    let mut items = Vec::new();
    let mut next = String::new();
    let mut input = CodedInputStream::from_bytes(bytes);
    while let Ok(Some(tag)) = input.read_raw_tag_or_eof() {
        match tag >> 3 {
            1 => {
                let Ok(item) = input.read_bytes() else { break };
                let mut inner = CodedInputStream::from_bytes(&item);
                let (mut uri, mut added, mut removed) = (String::new(), 0i64, false);
                while let Ok(Some(field)) = inner.read_raw_tag_or_eof() {
                    match field >> 3 {
                        1 => uri = inner.read_string().unwrap_or_default(),
                        2 => added = i64::from(inner.read_int32().unwrap_or_default()),
                        3 => removed = inner.read_bool().unwrap_or_default(),
                        _ => {
                            if skip(&mut inner, field).is_err() {
                                break;
                            }
                        }
                    }
                }
                if !removed && !uri.is_empty() {
                    items.push((uri, added));
                }
            }
            2 => next = input.read_string().unwrap_or_default(),
            _ => {
                if skip(&mut input, tag).is_err() {
                    break;
                }
            }
        }
    }
    (items, next)
}

fn skip(input: &mut CodedInputStream, tag: u32) -> Result<(), ()> {
    let wire = WireType::new(tag & 7).ok_or(())?;
    input.skip_field(wire).map_err(|_| ())
}

/// the saved songs, newest first, as the web api's /me/tracks page
pub async fn saved_tracks_json(session: &Session) -> Result<String, String> {
    let uris: Vec<String> = collection_items(session, "collection")
        .await?
        .into_iter()
        .map(|(uri, _)| uri)
        .filter(|uri| uri.starts_with("spotify:track:"))
        .collect();
    let tracks = track_metadata(session, &uris).await?;
    let items = uris
        .iter()
        .filter_map(|uri| tracks.get(uri))
        .map(|track| ItemPayload { item: track.clone() })
        .collect();
    encoded(&PagePayload { items }, "your saved songs")
}

/// whether each of `uris` is saved, as a json array of booleans: read from
/// the collection itself, which spotify's contains endpoint would not answer
pub async fn saved_contains_json(session: &Session, uris: &[String]) -> Result<String, String> {
    let saved: std::collections::HashSet<String> =
        collection_items(session, "collection").await?.into_iter().map(|(uri, _)| uri).collect();
    let found: Vec<bool> = uris.iter().map(|uri| saved.contains(uri)).collect();
    encoded(&found, "what is saved")
}

/// saves `uris` to the collection, or takes them out of it
pub async fn write_collection(session: &Session, set: &str, uris: &[String], saved: bool) -> Result<(), String> {
    let added = now_seconds() as i32;
    let mut body = Vec::new();
    {
        let mut out = CodedOutputStream::vec(&mut body);
        let _ = out.write_string(1, &session.username());
        let _ = out.write_string(2, set);
        for uri in uris {
            let mut item = Vec::new();
            {
                let mut inner = CodedOutputStream::vec(&mut item);
                let _ = inner.write_string(1, uri);
                let _ = inner.write_int32(2, added);
                let _ = inner.write_bool(3, !saved);
                let _ = inner.flush();
            }
            let _ = out.write_bytes(3, &item);
        }
        let _ = out.write_string(4, &format!("swiftify-{added}"));
        let _ = out.flush();
    }
    session
        .spclient()
        .request(&Method::POST, "/collection/v2/write", Some(collection_headers()), Some(&body))
        .await
        .map(|_| ())
        .map_err(|error| format!("Spotify would not save that: {error}"))
}

#[derive(Serialize)]
struct ArtistItem {
    id: String,
    uri: String,
    name: String,
    images: Vec<ImagePayload>,
    recency: i64,
}

/// the followed artists, newest first, as the web api's followed artists
pub async fn followed_artists_json(session: &Session) -> Result<String, String> {
    let followed: Vec<(String, i64)> = collection_items(session, "artist")
        .await?
        .into_iter()
        .filter(|(uri, _)| uri.starts_with("spotify:artist:"))
        .collect();
    let added: HashMap<String, i64> = followed.iter().cloned().collect();
    let uris: Vec<String> = followed.into_iter().map(|(uri, _)| uri).collect();
    let played = played_contexts(session).await;
    let mut artists = Vec::new();
    for batch in uris.chunks(100) {
        let response = session
            .spclient()
            .get_extended_metadata(entity_request(batch, ExtensionKind::ARTIST_V4))
            .await
            .map_err(|error| format!("Spotify would not describe the artists you follow: {error}"))?;
        let mut found = HashMap::new();
        for array in &response.extended_metadata {
            for data in &array.extension_data {
                let Some(any) = data.extension_data.as_ref() else { continue };
                let Ok(artist) = metadata::Artist::parse_from_bytes(&any.value) else { continue };
                let Some(payload) = ArtistPayload::new(&artist) else { continue };
                let portraits = match artist.portrait_group.as_ref() {
                    Some(group) if !group.image.is_empty() => &group.image,
                    _ => &artist.portrait,
                };
                found.insert(data.entity_uri.clone(), ArtistItem {
                    id: payload.id,
                    uri: payload.uri,
                    name: payload.name,
                    images: portraits.iter().rev().filter_map(ImagePayload::new).collect(),
                    recency: recency(played.get(&data.entity_uri).copied(),
                                     added.get(&data.entity_uri).copied().unwrap_or_default()),
                });
            }
        }
        artists.extend(batch.iter().filter_map(|uri| found.remove(uri)));
    }
    encoded(&json!({ "items": artists }), "the artists you follow")
}

fn entity_request(uris: &[String], kind: ExtensionKind) -> BatchedEntityRequest {
    BatchedEntityRequest {
        entity_request: uris
            .iter()
            .map(|uri| EntityRequest {
                entity_uri: uri.clone(),
                query: vec![ExtensionQuery {
                    extension_kind: EnumOrUnknown::new(kind),
                    ..Default::default()
                }],
                ..Default::default()
            })
            .collect(),
        ..Default::default()
    }
}

// --- what played last, albums, songs -----------------------------------------------------

/// the songs last played, newest first, as the web api's recently played
pub async fn recent_json(session: &Session) -> Result<String, String> {
    let endpoint = format!(
        "/recently-played/v3/user/{}/recently-played?format=json&limit=50&filter=default",
        session.username()
    );
    let bytes = session
        .spclient()
        .request_as_json(&Method::GET, &endpoint, None, None)
        .await
        .map_err(|error| format!("Spotify would not say what played last: {error}"))?;
    let recent: Value = serde_json::from_slice(&bytes).unwrap_or_default();
    let mut uris: Vec<String> = Vec::new();
    for context in recent.get("playContexts").and_then(Value::as_array).into_iter().flatten() {
        if let Some(uri) = context.get("lastPlayedTrackUri").and_then(Value::as_str) {
            if uri.starts_with("spotify:track:") && !uris.iter().any(|known| known == uri) {
                uris.push(uri.to_owned());
            }
        }
    }
    let tracks = track_metadata(session, &uris).await?;
    let items = uris
        .iter()
        .filter_map(|uri| tracks.get(uri))
        .map(|track| ItemPayload { item: track.clone() })
        .collect();
    encoded(&PagePayload { items }, "what played last")
}

/// an album's songs in order, as a playlist page
pub async fn album_json(session: &Session, album_uri: &str) -> Result<String, String> {
    let uri = SpotifyUri::from_uri(album_uri).map_err(|error| format!("not a spotify album: {error}"))?;
    let bytes = session
        .spclient()
        .get_album_metadata(&uri)
        .await
        .map_err(|error| format!("Spotify would not describe the album: {error}"))?;
    let album = metadata::Album::parse_from_bytes(&bytes).map_err(|error| format!("the album could not be read: {error}"))?;
    let uris: Vec<String> = album
        .disc
        .iter()
        .flat_map(|disc| disc.track.iter())
        .filter_map(|track| SpotifyUri::try_from(track).ok()?.to_uri().ok())
        .collect();
    let tracks = track_metadata(session, &uris).await?;
    let items = uris
        .iter()
        .filter_map(|uri| tracks.get(uri))
        .map(|track| ItemPayload { item: track.clone() })
        .collect();
    encoded(&PagePayload { items }, "the album")
}

/// one song, as a playlist page of one
pub async fn track_json(session: &Session, track_uri: &str) -> Result<String, String> {
    let uris = vec![track_uri.to_owned()];
    let tracks = track_metadata(session, &uris).await?;
    let items = tracks.get(track_uri).map(|track| ItemPayload { item: track.clone() }).into_iter().collect();
    encoded(&PagePayload { items }, "the song")
}

// --- changes to playlists -----------------------------------------------------------------

async fn revision(session: &Session, endpoint_base: &str) -> Result<Vec<u8>, String> {
    let bytes = session
        .spclient()
        .request(&Method::GET, &format!("{endpoint_base}?from=0&length=0"), None, None)
        .await
        .map_err(|error| format!("Spotify would not send the playlist: {error}"))?;
    let list = SelectedListContent::parse_from_bytes(&bytes).map_err(|error| format!("the playlist could not be read: {error}"))?;
    Ok(list.revision().to_vec())
}

/// applies `ops` to the list at `endpoint_base` (a playlist, or the rootlist)
async fn change(session: &Session, endpoint_base: &str, ops: Vec<Op>) -> Result<(), String> {
    let base = revision(session, endpoint_base).await?;
    let changes = ListChanges {
        base_revision: Some(base.clone()),
        deltas: vec![Delta {
            base_version: Some(base),
            ops,
            ..Default::default()
        }],
        want_resulting_revisions: Some(false),
        want_sync_result: Some(false),
        ..Default::default()
    };
    let body = changes.write_to_bytes().map_err(|error| format!("the change could not be written: {error}"))?;
    let mut headers = HeaderMap::new();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/x-protobuf"));
    session
        .spclient()
        .request(&Method::POST, &format!("{endpoint_base}/changes"), Some(headers), Some(&body))
        .await
        .map(|_| ())
        .map_err(|error| format!("Spotify would not change the playlist: {error}"))
}

fn playlist_base(playlist_uri: &str) -> Result<String, String> {
    Ok(format!("/playlist/v2/playlist/{}", base62(playlist_uri)?))
}

fn items(uris: &[String]) -> Vec<Item> {
    uris.iter().map(|uri| Item { uri: Some(uri.clone()), ..Default::default() }).collect()
}

fn op_of(kind: op::Kind) -> Op {
    Op { kind: Some(EnumOrUnknown::new(kind)), ..Default::default() }
}

pub async fn playlist_add(session: &Session, playlist_uri: &str, uris: &[String]) -> Result<(), String> {
    let mut add = op_of(op::Kind::ADD);
    add.add = MessageField::some(Add { items: items(uris), add_last: Some(true), ..Default::default() });
    change(session, &playlist_base(playlist_uri)?, vec![add]).await
}

pub async fn playlist_remove(session: &Session, playlist_uri: &str, uris: &[String]) -> Result<(), String> {
    let mut rem = op_of(op::Kind::REM);
    rem.rem = MessageField::some(Rem { items: items(uris), items_as_key: Some(true), ..Default::default() });
    change(session, &playlist_base(playlist_uri)?, vec![rem]).await
}

pub async fn playlist_move(session: &Session, playlist_uri: &str, from: i32, length: i32, to: i32) -> Result<(), String> {
    let mut mov = op_of(op::Kind::MOV);
    mov.mov = MessageField::some(Mov {
        from_index: Some(from),
        length: Some(length),
        to_index: Some(to),
        ..Default::default()
    });
    change(session, &playlist_base(playlist_uri)?, vec![mov]).await
}

pub async fn playlist_rename(session: &Session, playlist_uri: &str, name: &str, description: &str) -> Result<(), String> {
    let mut update = op_of(op::Kind::UPDATE_LIST_ATTRIBUTES);
    update.update_list_attributes = MessageField::some(UpdateListAttributes {
        new_attributes: MessageField::some(ListAttributesPartialState {
            values: MessageField::some(ListAttributes {
                name: Some(name.to_owned()),
                description: Some(description.to_owned()),
                ..Default::default()
            }),
            ..Default::default()
        }),
        ..Default::default()
    });
    change(session, &playlist_base(playlist_uri)?, vec![update]).await
}

/// a new playlist, first in the person's list; json of the playlist made
pub async fn playlist_create(session: &Session, name: &str, description: &str) -> Result<String, String> {
    let request = ListUpdateRequest {
        attributes: MessageField::some(ListAttributes {
            name: Some(name.to_owned()),
            description: Some(description.to_owned()),
            ..Default::default()
        }),
        ..Default::default()
    };
    let body = request.write_to_bytes().map_err(|error| format!("the playlist could not be written: {error}"))?;
    let mut headers = HeaderMap::new();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/x-protobuf"));
    let bytes = session
        .spclient()
        .request(&Method::POST, "/playlist/v2/playlist", Some(headers), Some(&body))
        .await
        .map_err(|error| format!("Spotify would not make the playlist: {error}"))?;
    let reply = CreateListReply::parse_from_bytes(&bytes).map_err(|error| format!("the new playlist could not be read: {error}"))?;
    let uri = reply.uri().to_owned();
    let mut add = op_of(op::Kind::ADD);
    add.add = MessageField::some(Add { items: items(std::slice::from_ref(&uri)), add_first: Some(true), ..Default::default() });
    change(session, &format!("/playlist/v2/user/{}/rootlist", session.username()), vec![add]).await?;
    let user = session.username();
    encoded(
        &playlist_value(&uri, &ListAttributes { name: Some(name.to_owned()), description: Some(description.to_owned()), ..Default::default() },
                        0, &user, &user, &user),
        "the new playlist",
    )
}

/// takes a playlist out of the person's list, as spotify's delete does
pub async fn playlist_delete(session: &Session, playlist_uri: &str) -> Result<(), String> {
    let mut rem = op_of(op::Kind::REM);
    rem.rem = MessageField::some(Rem {
        items: items(&[playlist_uri.to_owned()]),
        items_as_key: Some(true),
        ..Default::default()
    });
    change(session, &format!("/playlist/v2/user/{}/rootlist", session.username()), vec![rem]).await
}

// --- one entry for the front end --------------------------------------------------

/// answers a request of the front end's, `{"op": ..., ...}`, with json: what
/// was asked for, or `null` for a change made
pub async fn request_json(session: &Session, request: &str) -> Result<String, String> {
    let request: Value = serde_json::from_str(request).map_err(|error| format!("not a library request: {error}"))?;
    let text = |key: &str| request.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();
    let number = |key: &str| request.get(key).and_then(Value::as_i64).unwrap_or_default() as i32;
    let uris = || -> Vec<String> {
        request
            .get("uris")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|uri| uri.as_str().map(str::to_owned))
            .collect()
    };
    let done = |result: Result<(), String>| result.map(|()| "null".to_owned());
    match text("op").as_str() {
        "profile" => profile_json(session).await,
        "playlists" => playlists_json(session).await,
        "savedSongs" => saved_tracks_json(session).await,
        "savedCount" => Ok(collection_items(session, "collection")
            .await?
            .iter()
            .filter(|(uri, _)| uri.starts_with("spotify:track:"))
            .count()
            .to_string()),
        "savedContains" => saved_contains_json(session, &uris()).await,
        "save" => done(write_collection(session, "collection", &uris(), true).await),
        "unsave" => done(write_collection(session, "collection", &uris(), false).await),
        "follow" => done(write_collection(session, "artist", &uris(), true).await),
        "unfollow" => done(write_collection(session, "artist", &uris(), false).await),
        "listeners" => crate::extras::listeners_json(session, &text("artist")).await,
        "followedArtists" => followed_artists_json(session).await,
        "recent" => recent_json(session).await,
        "dj" => crate::dj::dj_json(session, &text("from")).await,
        "search" => crate::search::search_json(session, &text("query")).await,
        "browseAll" => crate::browse::browse_all_json(session).await,
        "browsePage" => crate::browse::browse_page_json(session, &text("uri")).await,
        "djSay" => done(
            crate::narration::say(
                session,
                &crate::narration::Line {
                    ssml: &text("ssml"),
                    language: &text("language"),
                    voice: number("voice"),
                    provider: number("provider"),
                    sample_rate: number("sampleRate"),
                },
            )
            .await,
        ),
        "extras" => crate::extras::extras_json(session, &text("uri"), &text("artist")).await,
        "album" => album_json(session, &text("uri")).await,
        "track" => track_json(session, &text("uri")).await,
        "playlistAdd" => done(playlist_add(session, &text("uri"), &uris()).await),
        "playlistRemove" => done(playlist_remove(session, &text("uri"), &uris()).await),
        "playlistMove" => done(playlist_move(session, &text("uri"), number("from"), number("length"), number("to")).await),
        "playlistRename" => done(playlist_rename(session, &text("uri"), &text("name"), &text("description")).await),
        "playlistCreate" => playlist_create(session, &text("name"), &text("description")).await,
        "playlistDelete" => done(playlist_delete(session, &text("uri")).await),
        other => Err(format!("not a library request: {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::parse_page;
    use protobuf::CodedOutputStream;

    #[test]
    fn a_collection_page_reads_its_items_and_token() {
        let mut item = Vec::new();
        {
            let mut out = CodedOutputStream::vec(&mut item);
            out.write_string(1, "spotify:track:a").unwrap();
            out.write_int32(2, 42).unwrap();
            out.flush().unwrap();
        }
        let mut page = Vec::new();
        {
            let mut out = CodedOutputStream::vec(&mut page);
            out.write_bytes(1, &item).unwrap();
            out.write_string(2, "next").unwrap();
            out.flush().unwrap();
        }
        let (items, next) = parse_page(&page);
        assert_eq!(items, vec![("spotify:track:a".to_owned(), 42)]);
        assert_eq!(next, "next");
    }
}
