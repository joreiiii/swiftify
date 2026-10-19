//! spotify's dj: its session resolved as spotify's own apps resolve it, the
//! songs it picked and what the dj says before and after them. spotify
//! speaks the lines with a voice of its own; they come as text (ssml).

use http::Method;
use librespot::core::Session;
use serde::Serialize;
use serde_json::Value;

use crate::playlist::{TrackPayload, track_metadata};

pub const DJ_URI: &str = "spotify:playlist:37i9dQZF1EYkqdzj48dyYq";
/// the dj's segments read ahead: each is a few songs with its lines
const SEGMENTS: usize = 4;

/// where the dj got to: the next segment of its session not yet played.
/// spotify keeps a dj session for some hours, and opens it with the same
/// segment each time; its apps go on from where the dj left off, and so
/// does this, rather than starting over
static NEXT_SEGMENT: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

/// a line of the dj's: its words, and what spotify needs to speak it in the
/// dj's voice (narration.rs)
#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
struct Spoken {
    text: String,
    ssml: String,
    /// "VOICE81" is 81
    voice: i32,
    /// "SONANTIC_LARGE" is 8
    provider: i32,
    sample_rate: i32,
}

#[derive(Serialize)]
struct DjItem {
    item: TrackPayload,
    /// said as the song starts
    intro: Spoken,
    /// said once it is over, before the next one's intro
    outro: Spoken,
}

#[derive(Serialize)]
struct DjPayload {
    items: Vec<DjItem>,
    /// the language the lines are in, as "de-DE"
    language: String,
    /// where the next start goes on from, to be handed back then
    next: Option<String>,
}

async fn json_at(session: &Session, endpoint: &str) -> Result<Value, String> {
    let bytes = session
        .spclient()
        .request_as_json(&Method::GET, endpoint.trim_start_matches("hm:/"), None, None)
        .await
        .map_err(|error| format!("Spotify would not start the DJ: {error}"))?;
    serde_json::from_slice(&bytes).map_err(|error| format!("the DJ could not be read: {error}"))
}

/// a line's words without its markup, and the language it is in
fn spoken(ssml: &str) -> (String, Option<String>) {
    let language = ssml
        .split("xml:lang=\"")
        .nth(1)
        .and_then(|rest| rest.split('"').next())
        .map(str::to_owned);
    let mut text = String::new();
    let mut in_tag = false;
    for character in ssml.chars() {
        match character {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => text.push(character),
            _ => {}
        }
    }
    (text.split_whitespace().collect::<Vec<_>>().join(" "), language)
}

/// the dj's songs with its lines, a few segments of them, as a playlist page
pub async fn dj_json(session: &Session, from: &str) -> Result<String, String> {
    let continued = (!from.is_empty())
        .then(|| from.to_owned())
        .or_else(|| NEXT_SEGMENT.lock().ok().and_then(|next| next.clone()));
    let was_continued = continued.is_some();
    let mut url = match continued {
        Some(next) => next,
        None => json_at(session, &format!("/context-resolve/v1/{DJ_URI}"))
            .await?
            .pointer("/metadata/lexicon_context_url")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or("Spotify has no DJ for this account.")?,
    };

    // (uri, intro, outro), in order, over the segments
    let mut picks: Vec<(String, Spoken, Spoken)> = Vec::new();
    let mut language = String::new();
    let mut ended = true;
    for _ in 0..SEGMENTS {
        let segment = match json_at(session, &url).await {
            Ok(segment) => segment,
            Err(error) => {
                eprintln!("spotify-core: the dj's next segment: {error}");
                break;
            }
        };
        let mut next = None;
        // the session's first answer holds its pages; each later segment is
        // a page of its own
        let pages: Vec<&Value> = match segment.get("pages").and_then(Value::as_array) {
            Some(pages) => pages.iter().collect(),
            None => vec![&segment],
        };
        for page in pages {
            for track in page.get("tracks").and_then(Value::as_array).into_iter().flatten() {
                let Some(uri) = track.get("uri").and_then(Value::as_str).filter(|uri| uri.starts_with("spotify:track:")) else {
                    continue;
                };
                let mut line = |part: &str| {
                    let field = |name: &str| {
                        track.pointer(&format!("/metadata/narration.{part}.{name}")).and_then(Value::as_str).unwrap_or_default()
                    };
                    let ssml = field("ssml");
                    let (text, lang) = spoken(ssml);
                    if let Some(lang) = lang.filter(|_| language.is_empty()) {
                        language = lang;
                    }
                    Spoken {
                        text,
                        ssml: ssml.to_owned(),
                        voice: field("voice").trim_start_matches("VOICE").parse().unwrap_or_default(),
                        provider: crate::narration::provider_number(field("tts_provider")),
                        sample_rate: field("sample_rate").parse().unwrap_or(44100),
                    }
                };
                let intro = line("intro");
                let outro = line("outro");
                if !picks.iter().any(|(known, _, _)| known == uri) {
                    picks.push((uri.to_owned(), intro, outro));
                }
            }
            next = next.or_else(|| page.get("next_page_url").and_then(Value::as_str).map(str::to_owned));
        }
        match next {
            Some(next) if next != url => url = next,
            _ => break,
        }
        ended = false;
    }
    // the next start goes on from here; a session that ran out, or one
    // that would not answer, starts afresh
    let next = (!ended && !picks.is_empty()).then(|| url.clone());
    if let Ok(mut kept) = NEXT_SEGMENT.lock() {
        kept.clone_from(&next);
    }
    // a session gone stale since: once more, afresh
    if picks.is_empty() && was_continued {
        return Box::pin(dj_json(session, "")).await;
    }

    let uris: Vec<String> = picks.iter().map(|(uri, _, _)| uri.clone()).collect();
    let tracks = track_metadata(session, &uris).await?;
    let items = picks
        .into_iter()
        .filter_map(|(uri, intro, outro)| Some(DjItem { item: tracks.get(&uri)?.clone(), intro, outro }))
        .collect();
    serde_json::to_string(&DjPayload { items, language, next }).map_err(|error| format!("failed to encode the DJ: {error}"))
}

#[cfg(test)]
mod tests {
    use super::spoken;

    #[test]
    fn a_line_reads_without_its_markup() {
        let (text, language) = spoken(
            "<speak xml:lang=\"de-DE\">Wir starten mit <entity type=\"artist\" uri=\"x\">Good Kid</entity>.</speak>",
        );
        assert_eq!(text, "Wir starten mit Good Kid.");
        assert_eq!(language.as_deref(), Some("de-DE"));
    }
}
