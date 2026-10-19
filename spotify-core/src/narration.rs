//! the dj's voice: its lines, as the dj session gives them (ssml with the
//! voice that speaks them), made into speech by spotify's own text to speech
//! as spotify's apps have it made, and played over the music.
//!
//! spotify answers a line with a redirect to a short, signed audio file
//! (mp3, whatever format was asked for), good for a few minutes.

use std::io::Cursor;

use bytes::Bytes;
use http::{
    Method, Request, StatusCode,
    header::{ACCEPT, AUTHORIZATION, CONTENT_TYPE, LOCATION},
};
use librespot::core::Session;
use protobuf::CodedOutputStream;

/// TtsRequest's audio_format: mp3
const MP3: i32 = 5;

/// a line, as the dj session describes it
pub struct Line<'a> {
    pub ssml: &'a str,
    pub language: &'a str,
    /// the voice's number: "VOICE81" is 81
    pub voice: i32,
    /// the speech provider's number: SONANTIC_LARGE is 8
    pub provider: i32,
    pub sample_rate: i32,
}

/// a provider's number by its name, as the dj session names it
pub fn provider_number(name: &str) -> i32 {
    match name {
        "CLOUD_TTS" => 1,
        "READSPEAKER" => 2,
        "POLLY" => 3,
        "WELL_SAID" => 4,
        "SONANTIC_DEPRECATED" => 5,
        "SONANTIC_FAST" => 6,
        "OPENAI" => 7,
        "SONANTIC_LARGE" => 8,
        "ELEVEN_LABS_DEPRECATED" => 9,
        "ADS_PUBLIC" => 10,
        _ => 0,
    }
}

/// a TtsRequest, as /client-tts/v1/fulfill takes it
fn request_body(line: &Line) -> Vec<u8> {
    let mut body = Vec::new();
    {
        let mut out = CodedOutputStream::vec(&mut body);
        let _ = out.write_string(2, line.ssml);
        let _ = out.write_int32(3, MP3);
        if !line.language.is_empty() {
            let _ = out.write_string(4, line.language);
        }
        let _ = out.write_int32(5, line.voice);
        let _ = out.write_int32(6, line.provider);
        let _ = out.write_int32(7, line.sample_rate);
        let _ = out.flush();
    }
    body
}

/// the spoken line, as audio
async fn speech(session: &Session, line: &Line<'_>) -> Result<Bytes, String> {
    let failed = |error: &dyn std::fmt::Display| format!("Spotify would not give the DJ its voice: {error}");
    let spclient = session.spclient();
    let url = format!("{}/client-tts/v1/fulfill", spclient.base_url().await.map_err(|e| failed(&e))?);
    let token = session.login5().auth_token().await.map_err(|e| failed(&e))?;
    let mut request = Request::builder()
        .method(Method::POST)
        .uri(url)
        .header(AUTHORIZATION, format!("{} {}", token.token_type, token.access_token))
        .header(CONTENT_TYPE, "application/x-protobuf")
        .header(ACCEPT, "*/*");
    if let Ok(client_token) = spclient.client_token().await {
        request = request.header("client-token", client_token);
    }
    let request = request.body(Bytes::from(request_body(line))).map_err(|e| failed(&e))?;
    // the answer is a redirect to the audio: its location is wanted, not
    // followed with the session's credentials
    let response = session
        .http_client()
        .request_fut(request)
        .map_err(|e| failed(&e))?
        .await
        .map_err(|e| failed(&e))?;
    let status = response.status();
    let location = response
        .headers()
        .get(LOCATION)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned);
    let audio_url = match (status, location) {
        (status, Some(location)) if status.is_redirection() => location,
        (StatusCode::OK, _) => {
            // a TtsResponse with the url in field 1
            use http_body_util::BodyExt;
            let body = response.into_body().collect().await.map_err(|e| failed(&e))?.to_bytes();
            let mut input = protobuf::CodedInputStream::from_bytes(&body);
            let mut url = String::new();
            while let Ok(Some(tag)) = input.read_raw_tag_or_eof() {
                if tag >> 3 == 1 {
                    url = input.read_string().unwrap_or_default();
                    break;
                }
                let Some(wire) = protobuf::rt::WireType::new(tag & 7) else { break };
                if input.skip_field(wire).is_err() {
                    break;
                }
            }
            if url.is_empty() {
                return Err(failed(&"no audio was given"));
            }
            url
        }
        (status, _) => return Err(failed(&status)),
    };
    // a signed url of its own: no credentials go with it
    let download = Request::builder()
        .method(Method::GET)
        .uri(audio_url)
        .body(Bytes::new())
        .map_err(|e| failed(&e))?;
    session.http_client().request_body(download).await.map_err(|e| failed(&e))
}

/// speaks a line in the dj's voice over whatever plays, and completes once
/// it has been said
pub async fn say(session: &Session, line: &Line<'_>) -> Result<(), String> {
    let audio = speech(session, line).await?;
    tokio::task::spawn_blocking(move || -> Result<(), String> {
        // an output of its own, mixed with the music's by the system
        let mut stream = rodio::OutputStreamBuilder::open_default_stream()
            .map_err(|error| format!("no audio output for the DJ: {error}"))?;
        stream.log_on_drop(false);
        let sink = rodio::Sink::connect_new(stream.mixer());
        let decoder = rodio::Decoder::new(Cursor::new(audio)).map_err(|error| format!("the DJ's voice could not be read: {error}"))?;
        sink.append(decoder);
        sink.sleep_until_end();
        Ok(())
    })
    .await
    .map_err(|error| format!("the DJ's voice stopped: {error}"))?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_line_is_asked_for_with_its_voice() {
        let body = request_body(&Line { ssml: "<speak/>", language: "de-DE", voice: 81, provider: 8, sample_rate: 44100 });
        let mut input = protobuf::CodedInputStream::from_bytes(&body);
        let mut fields = Vec::new();
        while let Ok(Some(tag)) = input.read_raw_tag_or_eof() {
            fields.push(tag >> 3);
            if tag & 7 == 2 {
                input.read_bytes().unwrap();
            } else {
                input.read_int64().unwrap();
            }
        }
        assert_eq!(fields, vec![2, 3, 4, 5, 6, 7]);
        assert_eq!(provider_number("SONANTIC_LARGE"), 8);
    }
}
