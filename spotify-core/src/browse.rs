//! spotify's browse: every category ("browse all"), and a category's own
//! page, as its web player has them (spotify's graphql, as search.rs asks it).
//!
//! spotify's answers nest deep and change shape between its kinds of card,
//! so what is wanted is found by what it is rather than by where it sits: a
//! category is anything with a `spotify:page:` uri, a section anything with
//! `sectionItems`, and a card's name, colour and picture the first of each
//! under it.

use librespot::core::Session;
use serde_json::{Map, Value, json};

use crate::search::graphql;

/// the queries' ids in the web player of october 2026
const BROWSE_ALL_ID: &str = "dbd8b55e09a58afc52eab438bc228ba28fd72ac2f2148c6c26354980e4579001";
const BROWSE_PAGE_ID: &str = "f5c4e6d668f5716464a231c1cc8b22c1cbf6ad68b09929fd7de813a30581298b";
const INTEGRATION: &str = "INTEGRATION_WEB_PLAYER";

/// the first string under `value` at any of `keys`, depth first
fn first_string(value: &Value, keys: &[&str]) -> Option<String> {
    match value {
        Value::Object(map) => {
            for key in keys {
                if let Some(Value::String(text)) = map.get(*key) {
                    if !text.is_empty() {
                        return Some(text.clone());
                    }
                }
            }
            map.values().find_map(|inner| first_string(inner, keys))
        }
        Value::Array(items) => items.iter().find_map(|inner| first_string(inner, keys)),
        _ => None,
    }
}

/// every object under `value` that `wanted` picks, outermost first; what
/// it picks is not looked into further
fn objects<'a>(value: &'a Value, wanted: &dyn Fn(&Map<String, Value>) -> bool, found: &mut Vec<&'a Map<String, Value>>) {
    match value {
        Value::Object(map) if wanted(map) => found.push(map),
        Value::Object(map) => map.values().for_each(|inner| objects(inner, wanted, found)),
        Value::Array(items) => items.iter().for_each(|inner| objects(inner, wanted, found)),
        _ => {}
    }
}

fn label(value: &Value) -> String {
    first_string(value, &["transformedLabel", "title", "name"]).unwrap_or_default()
}

fn colour(value: &Value) -> String {
    first_string(value, &["hex"]).unwrap_or_default()
}

/// the sharpest of the first set of pictures under `value`
fn picture(value: &Value) -> String {
    let mut found = Vec::new();
    objects(value, &|map| map.get("sources").is_some_and(Value::is_array), &mut found);
    found
        .first()
        .and_then(|map| map["sources"].as_array())
        .and_then(|sources| sources.iter().max_by_key(|source| source.get("width").and_then(Value::as_u64).unwrap_or(0)))
        .and_then(|source| source.get("url").and_then(Value::as_str))
        .map(str::to_owned)
        .or_else(|| first_string(value, &["url"]))
        .unwrap_or_default()
}

/// every category, as `{categories: [{title, uri, color, image}]}`
fn categories(answer: &Value) -> Value {
    let mut found = Vec::new();
    objects(
        answer,
        // a card, not the browse page around them, which has a page uri too
        &|map| {
            map.contains_key("content")
                && map.get("uri").and_then(Value::as_str).is_some_and(|uri| uri.starts_with("spotify:page:"))
        },
        &mut found,
    );
    let mut categories: Vec<Value> = Vec::new();
    for map in found {
        let card = Value::Object(map.clone());
        let uri = map.get("uri").and_then(Value::as_str).unwrap_or_default();
        let title = label(&card);
        if title.is_empty() || categories.iter().any(|known| known["uri"] == uri) {
            continue;
        }
        categories.push(json!({ "title": title, "uri": uri, "color": colour(&card), "image": picture(&card) }));
    }
    json!({ "categories": categories })
}

fn id_of(uri: &str) -> &str {
    uri.rsplit(':').next().unwrap_or_default()
}

/// a card of a section as the web api's playlist, album or artist, by kind;
/// a category of its own, a podcast or an episode as just what shows it
fn card(item: &Value) -> Option<Value> {
    let uri = first_string(item, &["uri"])?;
    let kind = uri.split(':').nth(1)?.to_owned();
    let content = item.get("content").unwrap_or(item);
    if kind == "page" {
        let title = label(content);
        return (!title.is_empty()).then(|| json!({
            "type": "category",
            "item": { "uri": uri, "title": title, "color": colour(content), "image": picture(content) },
        }));
    }
    if kind == "show" || kind == "episode" {
        let data = content.get("data").unwrap_or(content);
        let name = data.get("name").and_then(Value::as_str).filter(|name| !name.is_empty())?;
        let subtitle = if kind == "show" {
            data.pointer("/publisher/name").and_then(Value::as_str).unwrap_or("Podcast").to_owned()
        } else {
            data.pointer("/podcastV2/data/name").and_then(Value::as_str).unwrap_or("Episode").to_owned()
        };
        return Some(json!({
            "type": kind,
            "item": { "uri": uri, "name": name, "subtitle": subtitle, "image": picture(data) },
        }));
    }
    let name = first_string(content, &["name"]).or_else(|| first_string(content, &["transformedLabel"]))?;
    let image = picture(content);
    let images = if image.is_empty() { json!([]) } else { json!([{ "url": image }]) };
    let (id, uri) = (id_of(&uri).to_owned(), uri.clone());
    Some(match kind.as_str() {
        "playlist" => json!({
            "type": "playlist",
            "item": {
                "id": id, "uri": uri, "name": name, "images": images,
                "description": first_string(content, &["description"]).unwrap_or_default(),
                "owner": { "id": "", "display_name": content.pointer("/data/ownerV2/data/name").and_then(Value::as_str).unwrap_or("Spotify") },
            },
        }),
        "album" => json!({
            "type": "album",
            "item": {
                "id": id, "uri": uri, "name": name, "images": images,
                "artists": content.pointer("/data/artists/items").and_then(Value::as_array).map(|artists| {
                    artists.iter().map(|artist| json!({
                        "id": id_of(artist.get("uri").and_then(Value::as_str).unwrap_or_default()),
                        "uri": artist.get("uri").cloned().unwrap_or_default(),
                        "name": artist.pointer("/profile/name").cloned().unwrap_or_default(),
                    })).collect::<Vec<_>>()
                }).unwrap_or_default(),
            },
        }),
        "artist" => json!({ "type": "artist", "item": { "id": id, "uri": uri, "name": name, "images": images } }),
        _ => return None,
    })
}

/// a category's page, as `{title, color, sections: [{title, items: [{type, item}]}]}`
fn page(answer: &Value) -> Value {
    let browse = answer.pointer("/data/browse").unwrap_or(answer);
    let header = browse.get("header").unwrap_or(&Value::Null);
    let mut found = Vec::new();
    objects(browse, &|map| map.contains_key("sectionItems"), &mut found);
    let sections: Vec<Value> = found
        .into_iter()
        .filter_map(|section| {
            let title = section.get("data").map(label).unwrap_or_default();
            let items: Vec<Value> = section
                .get("sectionItems")
                .and_then(|items| items.get("items"))
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(card)
                .collect();
            (!items.is_empty()).then(|| json!({ "title": title, "items": items }))
        })
        .collect();
    json!({ "title": label(header), "color": colour(header), "sections": sections })
}

pub async fn browse_all_json(session: &Session) -> Result<String, String> {
    let answer = graphql(
        session,
        "browseAll",
        BROWSE_ALL_ID,
        json!({
            "pagePagination": { "offset": 0, "limit": 10 },
            "sectionPagination": { "offset": 0, "limit": 99 },
            "browseEndUserIntegration": INTEGRATION,
        }),
    )
    .await?;
    Ok(categories(&answer).to_string())
}

pub async fn browse_page_json(session: &Session, uri: &str) -> Result<String, String> {
    let answer = graphql(
        session,
        "browsePage",
        BROWSE_PAGE_ID,
        json!({
            "uri": uri,
            "pagePagination": { "offset": 0, "limit": 10 },
            "sectionPagination": { "offset": 0, "limit": 10 },
            "browseEndUserIntegration": INTEGRATION,
            "includeEpisodeContentRatingsV2": false,
        }),
    )
    .await?;
    Ok(page(&answer).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn categories_are_found_wherever_they_sit() {
        let answer = json!({ "data": { "browseStart": { "sections": { "items": [{ "sectionItems": { "items": [
            { "uri": "spotify:page:abc", "content": { "data": { "data": { "cardRepresentation": {
                "title": { "transformedLabel": "Rock" }, "backgroundColor": { "hex": "#E91429" },
                "artwork": { "sources": [{ "url": "https://i.scdn.co/image/x" }] } } } } } }
        ] } }] } } } });
        let shaped = categories(&answer);
        assert_eq!(shaped["categories"][0]["title"], "Rock");
        assert_eq!(shaped["categories"][0]["color"], "#E91429");
        assert_eq!(shaped["categories"][0]["image"], "https://i.scdn.co/image/x");
    }

    #[test]
    fn a_page_reads_as_sections_of_cards() {
        let answer = json!({ "data": { "browse": {
            "header": { "title": { "transformedLabel": "Rock" }, "color": { "hex": "#E91429" } },
            "sections": { "items": [{ "data": { "title": { "transformedLabel": "Popular" } }, "sectionItems": { "items": [
                { "uri": "spotify:playlist:p", "content": { "data": { "name": "Rock Classics",
                    "images": { "items": [{ "sources": [{ "url": "u" }] }] }, "ownerV2": { "data": { "name": "Spotify" } } } } }
            ] } }] }
        } } });
        let shaped = page(&answer);
        assert_eq!(shaped["title"], "Rock");
        assert_eq!(shaped["sections"][0]["title"], "Popular");
        assert_eq!(shaped["sections"][0]["items"][0]["type"], "playlist");
        assert_eq!(shaped["sections"][0]["items"][0]["item"]["name"], "Rock Classics");
        assert_eq!(shaped["sections"][0]["items"][0]["item"]["images"][0]["url"], "u");
    }

    #[test]
    fn categories_and_podcasts_are_cards_too() {
        let category = card(&json!({ "uri": "spotify:page:c", "content": { "data": { "data": { "cardRepresentation": {
            "title": { "transformedLabel": "Comedy" }, "backgroundColor": { "hex": "#8e66ac" },
            "artwork": { "sources": [{ "url": "small", "width": 64 }, { "url": "big", "width": 640 }] } } } } } })).unwrap();
        assert_eq!(category["type"], "category");
        assert_eq!(category["item"]["title"], "Comedy");
        assert_eq!(category["item"]["image"], "big");
        let show = card(&json!({ "uri": "spotify:show:s", "content": { "data": { "name": "Sleepover Sessions",
            "publisher": { "name": "funk" }, "coverArt": { "sources": [{ "url": "c", "width": 300 }] } } } })).unwrap();
        assert_eq!(show["type"], "show");
        assert_eq!(show["item"]["subtitle"], "funk");
        assert_eq!(show["item"]["image"], "c");
    }
}
