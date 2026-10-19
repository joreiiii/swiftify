//! what spotify's now playing view shows besides the song: its credits, and
//! the artist's monthly listeners and concerts, read as spotify's own apps
//! read them. each part is left empty when spotify will not give it.

use http::Method;
use librespot::core::Session;
use serde_json::{Value, json};

/// the credits and concerts shown, at most; spotify shows the rest on asking
const CREDITS: usize = 5;
const CONCERTS: usize = 3;

/// a json answer of spotify's, or none
async fn answer(session: &Session, endpoint: &str) -> Option<Value> {
    let bytes = session.spclient().request_as_json(&Method::GET, endpoint, None, None).await.ok()?;
    serde_json::from_slice(&bytes).ok()
}

fn id_of(uri: &str) -> &str {
    uri.rsplit(':').next().unwrap_or_default()
}

fn text(value: &Value, key: &str) -> String {
    value.get(key).and_then(Value::as_str).unwrap_or_default().to_owned()
}

/// each person credited, in spotify's order, with what they did: "Composer, Lyricist"
fn credits(answer: &Value) -> Vec<Value> {
    let mut people: Vec<Value> = Vec::new();
    for role in answer.get("roleCredits").and_then(Value::as_array).into_iter().flatten() {
        for artist in role.get("artists").and_then(Value::as_array).into_iter().flatten() {
            let name = text(artist, "name");
            if name.is_empty() || people.iter().any(|known| known["name"] == name) {
                continue;
            }
            let roles: Vec<String> = artist
                .get("subroles")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(|role| {
                    let mut letters = role.chars();
                    letters.next().map(|first| first.to_uppercase().chain(letters).collect()).unwrap_or_default()
                })
                .collect();
            people.push(json!({ "name": name, "uri": text(artist, "uri"), "roles": roles.join(", ") }));
        }
    }
    people
}

/// the artist's coming concerts, those near the person first, then by date
fn concerts(answer: &Value) -> Vec<Value> {
    let mut found: Vec<(bool, String, Value)> = answer
        .get("concerts")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|entry| {
            let concert = entry.get("concert")?;
            let date = text(concert, "date");
            Some((
                entry.get("nearUser").and_then(Value::as_bool).unwrap_or_default(),
                date.clone(),
                json!({
                    // the local date and time, as "2026-11-01T19:00:00+0100"
                    "date": date,
                    "city": text(concert, "location"),
                    "venue": text(concert, "venue"),
                    "title": text(concert, "title"),
                    "festival": concert.get("festival").and_then(Value::as_bool).unwrap_or_default(),
                }),
            ))
        })
        .collect();
    found.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
    found.into_iter().map(|(_, _, concert)| concert).collect()
}

/// `{monthlyListeners}` for an artist, as their page shows it
pub async fn listeners_json(session: &Session, artist_uri: &str) -> Result<String, String> {
    let endpoint = format!("/concerts/v2/concerts/artist/{}?filterByLoc=false", id_of(artist_uri));
    let answer = answer(session, &endpoint).await.unwrap_or_default();
    Ok(json!({ "monthlyListeners": answer.pointer("/artist/monthlyListeners").and_then(Value::as_i64).unwrap_or_default() })
        .to_string())
}

/// `{monthlyListeners, credits, moreCredits, concerts, moreConcerts}` for a
/// track and its first artist
pub async fn extras_json(session: &Session, track_uri: &str, artist_uri: &str) -> Result<String, String> {
    let credits_endpoint = format!("/track-credits-view/v0/experimental/{}/credits", id_of(track_uri));
    let concerts_endpoint = format!("/concerts/v2/concerts/artist/{}?filterByLoc=false", id_of(artist_uri));
    let (credit_answer, concert_answer) =
        tokio::join!(answer(session, &credits_endpoint), answer(session, &concerts_endpoint));
    let credit_answer = credit_answer.unwrap_or_default();
    let concert_answer = concert_answer.unwrap_or_default();
    let people = credits(&credit_answer);
    let shows = concerts(&concert_answer);
    serde_json::to_string(&json!({
        "monthlyListeners": concert_answer.pointer("/artist/monthlyListeners").and_then(Value::as_i64).unwrap_or_default(),
        "moreCredits": people.len().saturating_sub(CREDITS),
        "credits": people.into_iter().take(CREDITS).collect::<Vec<_>>(),
        "moreConcerts": shows.len().saturating_sub(CONCERTS),
        "concerts": shows.into_iter().take(CONCERTS).collect::<Vec<_>>(),
    }))
    .map_err(|error| format!("failed to encode the song's details: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn credits_read_each_person_once_with_their_roles() {
        let answer = json!({ "roleCredits": [
            { "roleTitle": "Performers", "artists": [{ "name": "Good Kid", "uri": "u", "subroles": ["main artist"] }] },
            { "roleTitle": "Writers", "artists": [{ "name": "Good Kid", "subroles": ["composer"] },
                                                  { "name": "Crispin Day", "subroles": ["composer", "lyricist"] }] }
        ]});
        let people = credits(&answer);
        assert_eq!(people.len(), 2);
        assert_eq!(people[0]["roles"], "Main artist");
        assert_eq!(people[1]["roles"], "Composer, Lyricist");
    }

    #[test]
    fn concerts_near_the_person_come_first() {
        let answer = json!({ "concerts": [
            { "nearUser": false, "concert": { "date": "2026-11-01", "location": "Brugge" } },
            { "nearUser": true, "concert": { "date": "2026-12-01", "location": "Munich" } }
        ]});
        let shows = concerts(&answer);
        assert_eq!(shows[0]["city"], "Munich");
        assert_eq!(shows[1]["city"], "Brugge");
    }
}
