//! swiftify as a spotify connect device: it shows in the person's devices as
//! "Swiftify" and tells spotify what it plays, as any connect speaker does.
//! spotify then has the song as the account's playing one, which is what
//! discord's spotify connection shows ("Listening to Spotify"), and what the
//! person's other spotify apps show playing elsewhere.
//!
//! only what plays is reported: the app's own queue stays its own, and the
//! device takes no commands from other devices.

use std::time::{SystemTime, UNIX_EPOCH};

use futures_util::StreamExt;
use librespot::{
    core::{Error, Session, config::DeviceType, dealer::protocol::Message, version},
    protocol::{
        connect::{Capabilities, Device, DeviceInfo, MemberType, PutStateReason, PutStateRequest},
        media::AudioQuality,
        player::{ContextPlayerOptions, PlayOrigin, PlayerState, ProvidedTrack, Suppressions},
    },
};
use protobuf::{EnumOrUnknown, MessageField};
use tokio::{sync::watch, task::JoinHandle, time::Duration};

/// what the app plays, as it reports it
#[derive(Clone, Debug, Default, PartialEq)]
pub struct NowPlaying {
    /// a spotify track uri; empty while nothing of spotify's plays
    pub uri: String,
    pub playing: bool,
    pub position_ms: u32,
    pub duration_ms: u32,
}

const DEVICE_NAME: &str = "Swiftify";
/// how often the state is sent again while nothing changes, so spotify keeps
/// the device as the one playing
const HEARTBEAT: Duration = Duration::from_secs(60);

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or_default()
}

/// reports `now` for `session` until the session ends or the task is aborted
pub fn start(session: Session, now: watch::Receiver<NowPlaying>) -> JoinHandle<()> {
    tokio::spawn(async move {
        if let Err(error) = run(session, now).await {
            eprintln!("spotify-core: spotify connect presence stopped: {error}");
        }
    })
}

async fn run(session: Session, mut now: watch::Receiver<NowPlaying>) -> Result<(), Error> {
    let mut connection_ids = session
        .dealer()
        .listen_for("hm://pusher/v1/connections/", |message: Message| {
            message
                .headers
                .get("Spotify-Connection-Id")
                .cloned()
                .ok_or_else(|| Error::invalid_argument("the dealer sent no connection id"))
        })?;
    session.dealer().start().await?;

    let mut device = Presence::new(&session);
    let mut connected = false;
    let mut heartbeat = tokio::time::interval(HEARTBEAT);
    loop {
        tokio::select! {
            id = connection_ids.next() => {
                let Some(id) = id else { break };
                // a new connection, at the start and after each reconnect:
                // the device is announced on it, then what plays
                session.set_connection_id(&id?);
                connected = true;
                device.update(&now.borrow());
                device.send(&session, PutStateReason::NEW_DEVICE).await;
                device.send(&session, PutStateReason::PLAYER_STATE_CHANGED).await;
            }
            changed = now.changed() => {
                if changed.is_err() {
                    break;
                }
                let playing = now.borrow_and_update().clone();
                if connected && device.update(&playing) {
                    device.send(&session, PutStateReason::PLAYER_STATE_CHANGED).await;
                }
            }
            _ = heartbeat.tick() => {
                if connected && device.request.is_active {
                    device.update(&now.borrow());
                    device.send(&session, PutStateReason::PLAYER_STATE_CHANGED).await;
                }
            }
        }
        if session.is_invalid() {
            break;
        }
    }
    session.dealer().close().await;
    Ok(())
}

struct Presence {
    request: PutStateRequest,
    reported: NowPlaying,
}

impl Presence {
    fn new(session: &Session) -> Self {
        let device_info = DeviceInfo {
            can_play: true,
            volume: u32::from(u16::MAX),
            name: DEVICE_NAME.to_owned(),
            device_id: session.device_id().to_owned(),
            device_type: EnumOrUnknown::new(DeviceType::Computer.into()),
            device_software_version: version::SEMVER.to_owned(),
            spirc_version: version::SPOTIFY_SPIRC_VERSION.to_owned(),
            client_id: session.client_id(),
            capabilities: MessageField::some(Capabilities {
                volume_steps: 64,
                // it plays, and others see what, but it is driven from
                // swiftify alone: no transfers or remote commands
                can_be_player: true,
                gaia_eq_connect_id: true,
                is_observable: true,
                is_controllable: false,
                needs_full_player_state: false,
                disable_volume: true,
                supports_gzip_pushes: true,
                supported_types: vec!["audio/track".into()],
                supported_audio_quality: EnumOrUnknown::new(AudioQuality::VERY_HIGH),
                ..Default::default()
            }),
            ..Default::default()
        };
        Self {
            request: PutStateRequest {
                member_type: EnumOrUnknown::new(MemberType::CONNECT_STATE),
                put_state_reason: EnumOrUnknown::new(PutStateReason::NEW_DEVICE),
                device: MessageField::some(Device {
                    device_info: MessageField::some(device_info),
                    player_state: MessageField::some(PlayerState {
                        session_id: session.session_id(),
                        ..Default::default()
                    }),
                    ..Default::default()
                }),
                ..Default::default()
            },
            reported: NowPlaying::default(),
        }
    }

    /// takes in what plays; says whether that changed what spotify was told
    fn update(&mut self, playing: &NowPlaying) -> bool {
        let changed = playing.uri != self.reported.uri
            || playing.playing != self.reported.playing
            || playing.duration_ms != self.reported.duration_ms
            // a seek: the position is off from where playing on would have it
            || self.drift(playing) > 2_000;
        self.reported = playing.clone();

        let now = now_ms();
        let active = playing.uri.starts_with("spotify:track:");
        if active && !self.request.is_active {
            self.request.started_playing_at = now as u64;
        }
        self.request.is_active = active;
        self.request.client_side_timestamp = now as u64;

        let device = self.request.device.as_mut().expect("the device is always set");
        let player = device.player_state.as_mut().expect("the player state is always set");
        let session_id = std::mem::take(&mut player.session_id);
        *player = if active {
            PlayerState {
                session_id,
                timestamp: now,
                position_as_of_timestamp: playing.position_ms.into(),
                duration: playing.duration_ms.into(),
                playback_speed: if playing.playing { 1. } else { 0. },
                // paused, all three are set, as spotify's own apps want them
                is_playing: true,
                is_paused: !playing.playing,
                is_buffering: !playing.playing,
                is_system_initiated: true,
                context_uri: playing.uri.clone(),
                track: MessageField::some(ProvidedTrack {
                    uri: playing.uri.clone(),
                    provider: "context".into(),
                    ..Default::default()
                }),
                play_origin: MessageField::some(PlayOrigin {
                    feature_identifier: "swiftify".into(),
                    ..Default::default()
                }),
                options: MessageField::some(ContextPlayerOptions::new()),
                suppressions: MessageField::some(Suppressions::new()),
                ..Default::default()
            }
        } else {
            PlayerState {
                session_id,
                ..Default::default()
            }
        };
        changed
    }

    /// how far `playing`'s position is from where the one reported would be now
    fn drift(&self, playing: &NowPlaying) -> u64 {
        let Some(player) = self.request.device.player_state.as_ref() else {
            return 0;
        };
        if self.reported.uri.is_empty() || !self.reported.playing {
            return u64::from(playing.position_ms.abs_diff(self.reported.position_ms));
        }
        let expected = player.position_as_of_timestamp + (now_ms() - player.timestamp);
        (i64::from(playing.position_ms) - expected).unsigned_abs()
    }

    async fn send(&mut self, session: &Session, reason: PutStateReason) {
        self.request.put_state_reason = EnumOrUnknown::new(reason);
        let result = if self.request.is_active || reason == PutStateReason::NEW_DEVICE {
            session.spclient().put_connect_state_request(&self.request).await
        } else {
            session.spclient().put_connect_state_inactive(false).await
        };
        if let Err(error) = result {
            eprintln!("spotify-core: spotify connect state was not taken: {error}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn presence() -> Presence {
        Presence {
            request: PutStateRequest {
                device: MessageField::some(Device {
                    player_state: MessageField::some(PlayerState::default()),
                    ..Default::default()
                }),
                ..Default::default()
            },
            reported: NowPlaying::default(),
        }
    }

    fn track(playing: bool, position_ms: u32) -> NowPlaying {
        NowPlaying {
            uri: "spotify:track:4uLU6hMCjMI75M1A2tKUQC".into(),
            playing,
            position_ms,
            duration_ms: 213_000,
        }
    }

    #[test]
    fn a_track_makes_the_device_active_and_nothing_inactive() {
        let mut presence = presence();
        assert!(presence.update(&track(true, 0)));
        assert!(presence.request.is_active);
        let player = presence.request.device.player_state.as_ref().unwrap();
        assert_eq!(player.track.uri, "spotify:track:4uLU6hMCjMI75M1A2tKUQC");
        assert!(player.is_playing && !player.is_paused);
        assert_eq!(player.playback_speed, 1.);

        assert!(presence.update(&NowPlaying::default()));
        assert!(!presence.request.is_active);
    }

    #[test]
    fn playing_on_is_no_change_but_a_pause_or_seek_is() {
        let mut presence = presence();
        presence.update(&track(true, 10_000));
        assert!(!presence.update(&track(true, 10_000)));
        assert!(presence.update(&track(false, 10_000)));
        assert!(presence.update(&track(false, 90_000)));
        let player = presence.request.device.player_state.as_ref().unwrap();
        assert!(player.is_playing && player.is_paused && player.is_buffering);
    }
}
