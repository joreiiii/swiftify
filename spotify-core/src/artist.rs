//! an artist's page read through the session, as spotify's own apps read it:
//! their top songs and their albums and singles. the web api gives top
//! songs to no app in development mode, and limits its album pages hard.
//!
//! the result is json: the artist's `name`, `images` and `biography`,
//! `topTracks`, a page shaped like the web api's playlist items, and
//! `albums`, shaped like the web api's simplified albums.

use std::collections::HashMap;

use librespot::{
    core::{Session, SpotifyUri},
    protocol::{
        extended_metadata::{BatchedEntityRequest, EntityRequest, ExtensionQuery},
        extension_kind::ExtensionKind,
        metadata,
    },
};
use protobuf::{EnumOrUnknown, Message};
use serde::Serialize;

use crate::playlist::{ArtistPayload, ImagePayload, ItemPayload, PagePayload, track_metadata};

/// the albums and singles listed, newest first, at most
const ALBUM_LIMIT: usize = 30;

pub async fn artist_json(session: &Session, artist_uri: &str) -> Result<String, String> {
    let uri = match SpotifyUri::from_uri(artist_uri) {
        Ok(uri @ SpotifyUri::Artist { .. }) => uri,
        _ => return Err(format!("not a spotify artist: {artist_uri}")),
    };
    let bytes = session
        .spclient()
        .get_artist_metadata(&uri)
        .await
        .map_err(|error| format!("Spotify would not describe the artist: {error}"))?;
    let artist = metadata::Artist::parse_from_bytes(&bytes)
        .map_err(|error| format!("the artist could not be read: {error}"))?;

    // the top songs of the person's own country, or the first list there is
    let country = session.country();
    let top = artist
        .top_track
        .iter()
        .find(|list| list.country() == country)
        .or_else(|| artist.top_track.first());
    let top_uris: Vec<String> = top
        .map(|list| list.track.iter().filter_map(uri_of).collect())
        .unwrap_or_default();
    let tracks = track_metadata(session, &top_uris).await?;
    let items = top_uris
        .iter()
        .filter_map(|uri| tracks.get(uri))
        .map(|track| ItemPayload { item: track.clone() })
        .collect();

    // one album of each group (a group holds the same release in its
    // editions), albums before singles
    let album_uris: Vec<String> = artist
        .album_group
        .iter()
        .chain(artist.single_group.iter())
        .filter_map(|group| group.album.first())
        .filter_map(uri_of)
        .collect();
    let mut albums = album_metadata(session, &album_uris).await?;
    albums.sort_by(|a, b| b.release_date.cmp(&a.release_date));
    albums.truncate(ALBUM_LIMIT);

    // the artist's pictures, largest last, and their story in plain text
    let portraits = match artist.portrait_group.as_ref() {
        Some(group) if !group.image.is_empty() => &group.image,
        _ => &artist.portrait,
    };
    let biography = artist
        .biography
        .first()
        .map(|biography| plain_text(biography.text()))
        .unwrap_or_default();

    serde_json::to_string(&ArtistPagePayload {
        name: artist.name().to_owned(),
        images: portraits.iter().filter_map(ImagePayload::new).collect(),
        biography,
        top_tracks: PagePayload { items },
        albums,
    })
    .map_err(|error| format!("failed to encode the artist: {error}"))
}

/// a track's or album's uri from the id the artist lists it by
fn uri_of<T>(entity: &T) -> Option<String>
where
    for<'a> SpotifyUri: TryFrom<&'a T>,
{
    SpotifyUri::try_from(entity).ok()?.to_uri().ok()
}

/// each album's details, in no particular order
async fn album_metadata(session: &Session, uris: &[String]) -> Result<Vec<AlbumPagePayload>, String> {
    if uris.is_empty() {
        return Ok(Vec::new());
    }
    let request = BatchedEntityRequest {
        entity_request: uris
            .iter()
            .map(|uri| EntityRequest {
                entity_uri: uri.clone(),
                query: vec![ExtensionQuery {
                    extension_kind: EnumOrUnknown::new(ExtensionKind::ALBUM_V4),
                    ..Default::default()
                }],
                ..Default::default()
            })
            .collect(),
        ..Default::default()
    };
    let response = session
        .spclient()
        .get_extended_metadata(request)
        .await
        .map_err(|error| format!("Spotify would not describe the artist's albums: {error}"))?;
    let mut albums: HashMap<String, AlbumPagePayload> = HashMap::new();
    for array in &response.extended_metadata {
        for data in &array.extension_data {
            let Some(any) = data.extension_data.as_ref() else {
                continue;
            };
            let Ok(album) = metadata::Album::parse_from_bytes(&any.value) else {
                continue;
            };
            if let Some(payload) = AlbumPagePayload::new(&data.entity_uri, &album) {
                albums.insert(data.entity_uri.clone(), payload);
            }
        }
    }
    Ok(albums.into_values().collect())
}

/// spotify's biographies are html: their text, with links reduced to their words
fn plain_text(html: &str) -> String {
    let mut text = String::with_capacity(html.len());
    let mut in_tag = false;
    for character in html.chars() {
        match character {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => text.push(character),
            _ => {}
        }
    }
    text.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .trim()
        .to_owned()
}

#[derive(Serialize)]
struct ArtistPagePayload {
    name: String,
    images: Vec<ImagePayload>,
    biography: String,
    #[serde(rename = "topTracks")]
    top_tracks: PagePayload,
    albums: Vec<AlbumPagePayload>,
}

/// an album as the web api's simplified album has it
#[derive(Serialize)]
struct AlbumPagePayload {
    id: String,
    uri: String,
    name: String,
    artists: Vec<ArtistPayload>,
    images: Vec<ImagePayload>,
    release_date: String,
    total_tracks: usize,
}

impl AlbumPagePayload {
    fn new(uri: &str, album: &metadata::Album) -> Option<Self> {
        if album.name().is_empty() {
            return None;
        }
        let parsed = SpotifyUri::from_uri(uri).ok()?;
        let covers = match album.cover_group.as_ref() {
            Some(group) if !group.image.is_empty() => &group.image,
            _ => &album.cover,
        };
        // the web api's precision: a year, a month or a whole day
        let release_date = album
            .date
            .as_ref()
            .map(|date| match (date.month, date.day) {
                (Some(month), Some(day)) => format!("{:04}-{month:02}-{day:02}", date.year()),
                (Some(month), None) => format!("{:04}-{month:02}", date.year()),
                _ => format!("{:04}", date.year()),
            })
            .unwrap_or_default();
        Some(Self {
            id: parsed.to_id().ok()?,
            uri: uri.to_owned(),
            name: album.name().to_owned(),
            artists: album.artist.iter().filter_map(ArtistPayload::new).collect(),
            images: covers.iter().filter_map(ImagePayload::new).collect(),
            release_date,
            total_tracks: album.disc.iter().map(|disc| disc.track.len()).sum(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::plain_text;

    #[test]
    fn a_biography_reads_as_plain_text() {
        assert_eq!(
            plain_text("Formed in <a href=\"spotify:artist:x\">Leeds</a> &amp; London. "),
            "Formed in Leeds & London."
        );
    }
}
