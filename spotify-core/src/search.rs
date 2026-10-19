//! spotify's catalog search, as its web player searches: spotify's graphql
//! api ("pathfinder"), asked for its searchDesktop query by that query's id.
//!
//! the id changes as spotify ships new web players, so it is looked up in
//! the web player's own code once a run, with the one current when this
//! was written to fall back on. the answer is reshaped as the web api's
//! search, which the front end reads.

use std::sync::Mutex;

use bytes::Bytes;
use http::{
    Method, Request,
    header::{ACCEPT, AUTHORIZATION, CONTENT_TYPE, USER_AGENT},
};
use http_body_util::BodyExt;
use librespot::core::Session;
use serde_json::{Value, json};

const PATHFINDER: &str = "https://api-partner.spotify.com/pathfinder/v2/query";
const WEB_PLAYER: &str = "https://open.spotify.com/";
const WEB_PLAYER_CODE: &str = "https://open.spotifycdn.com/cdn/build/web-player/";
/// searchDesktop's id in the web player of october 2026
const KNOWN_SEARCH_ID: &str = "eef7cc54888d91bdd6802623477873caa3948ae173a0c34fd86827b267e94c03";
/// what the web player calls itself
const BROWSER: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36";
const LIMIT: usize = 10;

/// the search query's id, once looked up
static SEARCH_ID: Mutex<Option<String>> = Mutex::new(None);

async fn get_text(session: &Session, url: &str) -> Option<String> {
    let request = Request::builder()
        .method(Method::GET)
        .uri(url)
        .header(USER_AGENT, BROWSER)
        .body(Bytes::new())
        .ok()?;
    let body = session.http_client().request_body(request).await.ok()?;
    String::from_utf8(body.to_vec()).ok()
}

/// every match of `"name","query","<64 hex>"` for searchDesktop in `code`
fn search_id_in(code: &str) -> Option<String> {
    let marker = "\"searchDesktop\",\"query\",\"";
    let start = code.find(marker)? + marker.len();
    let id = code.get(start..start + 64)?;
    id.bytes().all(|byte| byte.is_ascii_hexdigit()).then(|| id.to_owned())
}

/// the web player's chunk names and file hashes: `1234:"name"` and `1234:"0a1b2c3d"`
fn chunk_files(code: &str, chunk: &str) -> Vec<String> {
    let Some(at) = code.find(&format!(":\"{chunk}\"")) else {
        return Vec::new();
    };
    let id: String = code[..at].chars().rev().take_while(char::is_ascii_digit).collect::<Vec<_>>().into_iter().rev().collect();
    let key = format!("{id}:\"");
    let mut hashes = Vec::new();
    let mut rest = code;
    while let Some(found) = rest.find(&key) {
        let after = &rest[found + key.len()..];
        if let Some(hash) = after.get(..8).filter(|hash| hash.bytes().all(|byte| byte.is_ascii_hexdigit())) {
            if after.as_bytes().get(8) == Some(&b'"') && !hashes.iter().any(|known| known == hash) {
                hashes.push(hash.to_owned());
            }
        }
        rest = after;
    }
    hashes
        .into_iter()
        .map(|hash| format!("{WEB_PLAYER_CODE}{chunk}.{hash}.js"))
        .collect()
}

/// searchDesktop's id, from the web player's search chunk
async fn look_up_search_id(session: &Session) -> Option<String> {
    let page = get_text(session, WEB_PLAYER).await?;
    let main = page
        .split('"')
        .find(|part| part.starts_with(WEB_PLAYER_CODE) && part.contains("/web-player.") && part.ends_with(".js"))?
        .to_owned();
    let code = get_text(session, &main).await?;
    if let Some(id) = search_id_in(&code) {
        return Some(id);
    }
    for file in chunk_files(&code, "xpui-routes-search") {
        if let Some(id) = get_text(session, &file).await.as_deref().and_then(search_id_in) {
            return Some(id);
        }
    }
    None
}

async fn search_id(session: &Session) -> String {
    if let Some(id) = SEARCH_ID.lock().ok().and_then(|id| id.clone()) {
        return id;
    }
    let id = look_up_search_id(session).await.unwrap_or_else(|| KNOWN_SEARCH_ID.to_owned());
    if let Ok(mut kept) = SEARCH_ID.lock() {
        *kept = Some(id.clone());
    }
    id
}

/// spotify's answer to a search, as its graphql gives it
async fn pathfinder(session: &Session, query: &str, id: &str) -> Result<Value, String> {
    let variables = json!({
            "searchTerm": query,
            "offset": 0,
            "limit": LIMIT,
            "numberOfTopResults": 5,
            "includeAudiobooks": false,
            "includeArtistHasConcertsField": false,
            "includePreReleases": false,
            "includeLocalConcertsField": false,
            "includeAuthors": false,
            "includeAlbumPreReleases": false,
            "includeEpisodeContentRatingsV2": false,
    });
    graphql(session, "searchDesktop", id, variables).await
}

/// one of the web player's graphql queries, by its name and id
pub(crate) async fn graphql(session: &Session, operation: &str, id: &str, variables: Value) -> Result<Value, String> {
    let failed = |error: &dyn std::fmt::Display| format!("Spotify would not answer: {error}");
    let body = json!({
        "operationName": operation,
        "variables": variables,
        "extensions": { "persistedQuery": { "version": 1, "sha256Hash": id } },
    });
    let token = session.login5().auth_token().await.map_err(|e| failed(&e))?;
    let mut request = Request::builder()
        .method(Method::POST)
        .uri(PATHFINDER)
        .header(AUTHORIZATION, format!("{} {}", token.token_type, token.access_token))
        .header(CONTENT_TYPE, "application/json;charset=UTF-8")
        .header(ACCEPT, "application/json")
        .header(USER_AGENT, BROWSER)
        .header("app-platform", "WebPlayer");
    if let Ok(client_token) = session.spclient().client_token().await {
        request = request.header("client-token", client_token);
    }
    let request = request.body(Bytes::from(body.to_string())).map_err(|e| failed(&e))?;
    let response = session
        .http_client()
        .request_fut(request)
        .map_err(|e| failed(&e))?
        .await
        .map_err(|e| failed(&e))?;
    let status = response.status();
    let bytes = response.into_body().collect().await.map_err(|e| failed(&e))?.to_bytes();
    if !status.is_success() {
        return Err(failed(&format!("{status}: {}", String::from_utf8_lossy(&bytes[..bytes.len().min(200)]))));
    }
    serde_json::from_slice(&bytes).map_err(|e| failed(&e))
}

// --- reshaped as the web api's search ------------------------------------------------

fn text<'a>(value: &'a Value, pointer: &str) -> &'a str {
    value.pointer(pointer).and_then(Value::as_str).unwrap_or_default()
}

fn id_of(uri: &str) -> &str {
    uri.rsplit(':').next().unwrap_or_default()
}

/// a graphql image set ({sources: [{url, width, height}]}) as the web api's images
fn images(set: Option<&Value>) -> Value {
    let sources = set.and_then(|set| set.get("sources")).and_then(Value::as_array).cloned().unwrap_or_default();
    Value::Array(
        sources
            .into_iter()
            .filter(|source| source.get("url").is_some())
            .map(|source| {
                json!({
                    "url": source["url"],
                    "width": source.get("width").cloned().unwrap_or(Value::Null),
                    "height": source.get("height").cloned().unwrap_or(Value::Null),
                })
            })
            .collect(),
    )
}

fn artists(set: Option<&Value>) -> Value {
    let items = set.and_then(|set| set.get("items")).and_then(Value::as_array).cloned().unwrap_or_default();
    Value::Array(
        items
            .iter()
            .map(|artist| {
                let uri = text(artist, "/uri");
                json!({ "id": id_of(uri), "uri": uri, "name": text(artist, "/profile/name") })
            })
            .collect(),
    )
}

fn track(data: &Value) -> Option<Value> {
    let uri = text(data, "/uri");
    if !uri.starts_with("spotify:track:") {
        return None;
    }
    let album = data.get("albumOfTrack")?;
    let album_uri = text(album, "/uri");
    Some(json!({
        "type": "track",
        "id": id_of(uri),
        "uri": uri,
        "name": text(data, "/name"),
        "duration_ms": data.pointer("/duration/totalMilliseconds").and_then(Value::as_i64).unwrap_or_default(),
        "explicit": text(data, "/contentRating/label") == "EXPLICIT",
        "artists": artists(data.get("artists")),
        "album": {
            "id": id_of(album_uri),
            "uri": album_uri,
            "name": text(album, "/name"),
            "artists": artists(album.get("artists")),
            "images": images(album.get("coverArt")),
        },
    }))
}

fn album(data: &Value) -> Option<Value> {
    let uri = text(data, "/uri");
    uri.starts_with("spotify:album:").then(|| {
        json!({
            "id": id_of(uri),
            "uri": uri,
            "name": text(data, "/name"),
            "artists": artists(data.get("artists")),
            "images": images(data.get("coverArt")),
            "release_date": data.pointer("/date/year").map(|year| year.to_string()).unwrap_or_default(),
        })
    })
}

fn artist(data: &Value) -> Option<Value> {
    let uri = text(data, "/uri");
    uri.starts_with("spotify:artist:").then(|| {
        json!({
            "id": id_of(uri),
            "uri": uri,
            "name": text(data, "/profile/name"),
            "images": images(data.pointer("/visuals/avatarImage")),
        })
    })
}

fn playlist(data: &Value) -> Option<Value> {
    let uri = text(data, "/uri");
    uri.starts_with("spotify:playlist:").then(|| {
        let owner = text(data, "/ownerV2/data/uri");
        json!({
            "id": id_of(uri),
            "uri": uri,
            "name": text(data, "/name"),
            "description": text(data, "/description"),
            "images": data.pointer("/images/items/0").map(|first| images(Some(first))).unwrap_or(Value::Array(Vec::new())),
            "owner": { "id": id_of(owner), "display_name": text(data, "/ownerV2/data/name") },
        })
    })
}

/// a section's items' data, whichever of spotify's shapes it comes in
fn section<'a>(search: &'a Value, key: &str) -> Vec<&'a Value> {
    search
        .pointer(&format!("/{key}/items"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|item| item.pointer("/item/data").or_else(|| item.get("data")))
        .collect()
}

/// the answer as the web api's search, with spotify's top result: `top`
/// names its kind ("tracks", "artists", "albums", "playlists") and uri
fn reshaped(answer: &Value) -> Value {
    let search = answer.pointer("/data/searchV2").cloned().unwrap_or_default();
    let tracks: Vec<Value> = section(&search, "tracksV2").into_iter().filter_map(track).collect();
    let albums: Vec<Value> = section(&search, "albumsV2").into_iter().filter_map(album).collect();
    let artists: Vec<Value> = section(&search, "artists").into_iter().filter_map(artist).collect();
    let playlists: Vec<Value> = section(&search, "playlists").into_iter().filter_map(playlist).collect();
    let top = search
        .pointer("/topResultsV2/itemsV2")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|item| item.pointer("/item/data"))
        .find_map(|data| {
            let uri = text(data, "/uri");
            let kind = match uri.split(':').nth(1)? {
                "track" => "tracks",
                "artist" => "artists",
                "album" => "albums",
                "playlist" => "playlists",
                _ => return None,
            };
            Some(json!({ "kind": kind, "uri": uri }))
        });
    json!({
        "tracks": { "items": tracks },
        "albums": { "items": albums },
        "artists": { "items": artists },
        "playlists": { "items": playlists },
        "top": top,
    })
}

/// spotify's catalog search for `query`, as the web api's search's json
pub async fn search_json(session: &Session, query: &str) -> Result<String, String> {
    let id = search_id(session).await;
    let answer = match pathfinder(session, query, &id).await {
        Ok(answer) => answer,
        // a query id spotify no longer knows: looked up afresh, once
        Err(error) if id != KNOWN_SEARCH_ID || error.contains("PersistedQueryNotFound") => {
            if let Ok(mut kept) = SEARCH_ID.lock() {
                *kept = None;
            }
            let fresh = look_up_search_id(session).await.unwrap_or_else(|| KNOWN_SEARCH_ID.to_owned());
            if let Ok(mut kept) = SEARCH_ID.lock() {
                *kept = Some(fresh.clone());
            }
            pathfinder(session, query, &fresh).await?
        }
        Err(error) => return Err(error),
    };
    if let Some(errors) = answer.get("errors").filter(|errors| answer.get("data").is_none() && !errors.is_null()) {
        return Err(format!("Spotify would not search: {errors}"));
    }
    serde_json::to_string(&reshaped(&answer)).map_err(|error| format!("failed to encode the search: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_search_id_is_found_in_the_web_players_code() {
        let code = r#"x=new l("searchDesktop","query","eef7cc54888d91bdd6802623477873caa3948ae173a0c34fd86827b267e94c03",null)"#;
        assert_eq!(search_id_in(code).as_deref(), Some(KNOWN_SEARCH_ID));
    }

    #[test]
    fn the_search_chunk_is_found_by_its_name() {
        let code = r#"{4406:"xpui-routes-search",12:"x"}[e]...{4406:"26863a01",12:"aaaaaaaa"}...{4406:"a0a5ee13"}"#;
        let files = chunk_files(code, "xpui-routes-search");
        assert_eq!(files[0], format!("{WEB_PLAYER_CODE}xpui-routes-search.26863a01.js"));
        assert_eq!(files.len(), 2);
    }

    #[test]
    fn an_answer_reads_as_the_web_apis_search() {
        let answer = json!({ "data": { "searchV2": {
            "tracksV2": { "items": [{ "item": { "data": {
                "uri": "spotify:track:t", "name": "Decode", "duration": { "totalMilliseconds": 261000 },
                "artists": { "items": [{ "uri": "spotify:artist:p", "profile": { "name": "Paramore" } }] },
                "albumOfTrack": { "uri": "spotify:album:a", "name": "Decode", "coverArt": { "sources": [{ "url": "u", "width": 640, "height": 640 }] } }
            } } }] },
            "artists": { "items": [{ "data": { "uri": "spotify:artist:p", "profile": { "name": "Paramore" } } }] },
            "topResultsV2": { "itemsV2": [{ "item": { "data": { "uri": "spotify:artist:p" } } }] }
        } } });
        let shaped = reshaped(&answer);
        assert_eq!(shaped["tracks"]["items"][0]["artists"][0]["name"], "Paramore");
        assert_eq!(shaped["tracks"]["items"][0]["album"]["images"][0]["url"], "u");
        assert_eq!(shaped["artists"]["items"][0]["name"], "Paramore");
        assert_eq!(shaped["top"]["kind"], "artists");
    }
}
