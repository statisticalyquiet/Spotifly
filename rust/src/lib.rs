use futures_util::StreamExt;
use librespot_connect::{ConnectConfig, LoadRequest, LoadRequestOptions, Spirc};
use librespot_core::cache::Cache;
use librespot_core::config::DeviceType;
use librespot_core::session::Session;
use librespot_core::SessionConfig;
use librespot_core::SpotifyUri;
use librespot_playback::audio_backend;
use librespot_playback::config::{AudioFormat, Bitrate, PlayerConfig};
use librespot_playback::mixer::softmixer::SoftMixer;
use librespot_playback::mixer::{Mixer, MixerConfig};
use librespot_playback::player::{Player, PlayerEvent};
use librespot_protocol::connect::ClusterUpdate;
use librespot_protocol::player::PlayerState;
use log::debug;
use once_cell::sync::Lazy;
use serde::Serialize;
use std::ffi::{c_char, CStr, CString};
use std::sync::atomic::{AtomicBool, AtomicU16, AtomicU32, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::runtime::Runtime;
use tokio::sync::mpsc;

// Global tokio runtime for async operations
static RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("Failed to create Tokio runtime")
});

// Player state
static PLAYER: Lazy<Mutex<Option<Arc<Player>>>> = Lazy::new(|| Mutex::new(None));
static SESSION: Lazy<Mutex<Option<Session>>> = Lazy::new(|| Mutex::new(None));
static MIXER: Lazy<Mutex<Option<Arc<SoftMixer>>>> = Lazy::new(|| Mutex::new(None));
static SPIRC: Lazy<Mutex<Option<Arc<Spirc>>>> = Lazy::new(|| Mutex::new(None));
static DEVICE_ID: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));
static IS_PLAYING: AtomicBool = AtomicBool::new(false);
static SPIRC_READY: AtomicBool = AtomicBool::new(false);
static IS_ACTIVE_DEVICE: AtomicBool = AtomicBool::new(false);
static PLAYER_EVENT_TX: Lazy<Mutex<Option<mpsc::UnboundedSender<()>>>> =
    Lazy::new(|| Mutex::new(None));
static QUEUE_CALLBACK: Lazy<Mutex<Option<extern "C" fn(*const c_char)>>> =
    Lazy::new(|| Mutex::new(None));
static PLAYBACK_STATE_CALLBACK: Lazy<Mutex<Option<extern "C" fn(*const c_char)>>> =
    Lazy::new(|| Mutex::new(None));
static STATE_UPDATE_CALLBACK: Lazy<Mutex<Option<extern "C" fn()>>> = Lazy::new(|| Mutex::new(None));
static VOLUME_CALLBACK: Lazy<Mutex<Option<extern "C" fn(u16)>>> = Lazy::new(|| Mutex::new(None));
static LOADING_CALLBACK: Lazy<Mutex<Option<extern "C" fn(*const c_char)>>> =
    Lazy::new(|| Mutex::new(None));
static QUEUE_CHANGED_CALLBACK: Lazy<Mutex<Option<extern "C" fn(*const c_char)>>> =
    Lazy::new(|| Mutex::new(None));
static SESSION_DISCONNECTED_CALLBACK: Lazy<Mutex<Option<extern "C" fn()>>> =
    Lazy::new(|| Mutex::new(None));
static SESSION_CONNECTED_CALLBACK: Lazy<Mutex<Option<extern "C" fn()>>> =
    Lazy::new(|| Mutex::new(None));
static LAST_VOLUME: AtomicU16 = AtomicU16::new(0);

// Session state tracking - guards playback commands until session is ready
struct SessionConnectionState {
    connection_id: Option<String>,
    is_connected: bool,
}

impl Default for SessionConnectionState {
    fn default() -> Self {
        Self {
            connection_id: None,
            is_connected: false,
        }
    }
}

static SESSION_CONNECTION_STATE: Lazy<Mutex<SessionConnectionState>> =
    Lazy::new(|| Mutex::new(SessionConnectionState::default()));

// Position tracking - updated from player events
static POSITION_MS: AtomicU32 = AtomicU32::new(0);
static POSITION_TIMESTAMP_MS: AtomicU64 = AtomicU64::new(0);

// Current track URI - for detecting same-track reconnects
static CURRENT_TRACK_URI: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));
// Flag to indicate soft reconnect mode (Player kept alive)
static SOFT_RECONNECT_MODE: AtomicBool = AtomicBool::new(false);
// Flag to skip transfer in SessionConnected (set during soft reconnect, cleared after use)
static SKIP_SESSION_CONNECTED_TRANSFER: AtomicBool = AtomicBool::new(false);

// Connection state tracking - for transparency dashboard
static RECONNECT_ATTEMPT: AtomicU32 = AtomicU32::new(0);
static CONNECTED_SINCE_MS: AtomicU64 = AtomicU64::new(0);
static LAST_ERROR: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));
static CONNECTION_STATE_CALLBACK: Lazy<Mutex<Option<extern "C" fn(*const c_char)>>> =
    Lazy::new(|| Mutex::new(None));

// Playback settings (applied on player init)
// Bitrate: 0 = 96kbps, 1 = 160kbps (default), 2 = 320kbps
static BITRATE_SETTING: AtomicU8 = AtomicU8::new(1);
// Gapless playback: true by default (matches librespot default)
static GAPLESS_SETTING: AtomicBool = AtomicBool::new(true);
// Initial volume (0-65535), default 50%
static INITIAL_VOLUME_SETTING: AtomicU16 = AtomicU16::new(65535 / 2);

#[derive(Serialize)]
struct QueueItem {
    uri: String,
    name: String,
    artist: String,
    image_url: String,
    duration_ms: u32,
    album_name: String,
    /// Track provider: "context", "queue", "autoplay", or "unavailable"
    provider: String,
}

#[derive(Serialize)]
struct QueueState {
    track: Option<QueueItem>,
    next_tracks: Vec<QueueItem>,
    prev_tracks: Vec<QueueItem>,
}

#[derive(Serialize)]
struct PlaybackStateUpdate {
    is_playing: bool,
    is_paused: bool,
    track_uri: String,
    position_ms: i64,
    duration_ms: i64,
    shuffle: bool,
    repeat_track: bool,
    repeat_context: bool,
}

#[derive(Serialize)]
struct LoadingNotification {
    track_uri: String,
    position_ms: u32,
}

#[derive(Serialize)]
struct QueueChangedNotification {
    track_uri: String,
}

#[derive(Serialize)]
struct ConnectionStateInfo {
    session_connected: bool,
    session_connection_id: Option<String>,
    spirc_ready: bool,
    device_id: Option<String>,
    device_name: String,
    reconnect_attempt: u32,
    last_error: Option<String>,
    connected_since_ms: Option<u64>,
}

/// Get current timestamp in milliseconds since UNIX epoch
fn current_timestamp_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_millis() as u64
}

/// Update position from player event
fn update_position(position_ms: u32) {
    POSITION_MS.store(position_ms, Ordering::SeqCst);
    POSITION_TIMESTAMP_MS.store(current_timestamp_ms(), Ordering::SeqCst);
}

// Helper function to convert URL to URI
fn url_to_uri(input: &str) -> String {
    // If already a URI, return as-is
    if input.starts_with("spotify:") {
        return input.to_string();
    }

    // If it's a URL, parse it
    if input.starts_with("http://") || input.starts_with("https://") {
        if let Some(marker_pos) = input.find("open.spotify.com/") {
            let after_marker = &input[marker_pos + "open.spotify.com/".len()..];
            let parts: Vec<&str> = after_marker.split('/').collect();

            // Filter out locale prefixes like "intl-de"
            let filtered: Vec<&str> = parts
                .iter()
                .filter(|p| !p.starts_with("intl-"))
                .copied()
                .collect();

            if filtered.len() >= 2 {
                let content_type = filtered[0];
                let mut id = filtered[1];

                // Remove query parameters
                if let Some(query_pos) = id.find('?') {
                    id = &id[..query_pos];
                }

                return format!("spotify:{}:{}", content_type, id);
            }
        }
    }

    // Return original if can't parse
    input.to_string()
}

// Helper function to parse Spotify URI from string
fn parse_spotify_uri(uri_str: &str) -> Result<SpotifyUri, String> {
    SpotifyUri::from_uri(uri_str).map_err(|e| format!("Invalid Spotify URI: {:?}", e))
}

/// Frees a C string allocated by this library.
#[no_mangle]
pub extern "C" fn spotifly_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            let _ = CString::from_raw(s);
        }
    }
}

/// Registers a callback to receive queue updates (as JSON string).
#[no_mangle]
pub extern "C" fn spotifly_register_queue_callback(callback: extern "C" fn(*const c_char)) {
    let mut cb = QUEUE_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

/// Registers a callback to receive playback state updates (as JSON string).
#[no_mangle]
pub extern "C" fn spotifly_register_playback_state_callback(
    callback: extern "C" fn(*const c_char),
) {
    let mut cb = PLAYBACK_STATE_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

/// Registers a callback to receive state update notifications.
/// This fires on track changes to signal Swift to fetch updated queue state.
#[no_mangle]
pub extern "C" fn spotifly_register_state_update_callback(callback: extern "C" fn()) {
    let mut cb = STATE_UPDATE_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

/// Registers a callback to receive volume change notifications.
/// Called when the volume is changed remotely (e.g., from another Spotify Connect device).
/// The callback receives the new volume (0-65535).
#[no_mangle]
pub extern "C" fn spotifly_register_volume_callback(callback: extern "C" fn(u16)) {
    let mut cb = VOLUME_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

/// Registers a callback to receive loading notifications.
/// Called when a new track starts loading (before metadata is fetched).
/// This fires earlier than TrackChanged (~180ms vs ~620ms after command).
/// The callback receives JSON with track_uri and position_ms.
#[no_mangle]
pub extern "C" fn spotifly_register_loading_callback(callback: extern "C" fn(*const c_char)) {
    let mut cb = LOADING_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

/// Registers a callback to receive queue change notifications.
/// Called when a remote device adds a track to the queue.
/// The callback receives JSON with track_uri.
#[no_mangle]
pub extern "C" fn spotifly_register_queue_changed_callback(callback: extern "C" fn(*const c_char)) {
    let mut cb = QUEUE_CHANGED_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

/// Registers a callback to receive session disconnection notifications.
/// Called when the Spotify session is disconnected (e.g., idle timeout).
/// When this fires, you should reinitialize the player with a fresh token.
#[no_mangle]
pub extern "C" fn spotifly_register_session_disconnected_callback(callback: extern "C" fn()) {
    let mut cb = SESSION_DISCONNECTED_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

/// Registers a callback to receive session connection notifications.
/// Called when the Spotify session is fully connected and ready for commands.
/// Wait for this callback before attempting playback operations after init/reinit.
#[no_mangle]
pub extern "C" fn spotifly_register_session_connected_callback(callback: extern "C" fn()) {
    let mut cb = SESSION_CONNECTED_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

/// Registers a callback to receive connection state change notifications.
/// Called whenever the connection state changes (connect, disconnect, error, etc.).
/// The callback receives JSON with full connection state.
#[no_mangle]
pub extern "C" fn spotifly_register_connection_state_callback(
    callback: extern "C" fn(*const c_char),
) {
    let mut cb = CONNECTION_STATE_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

/// Returns the current connection state as a JSON string.
/// Caller must free the returned string using spotifly_free_string().
#[no_mangle]
pub extern "C" fn spotifly_get_connection_state() -> *mut c_char {
    let state = build_connection_state_info();
    match serde_json::to_string(&state) {
        Ok(json) => CString::new(json).unwrap().into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Builds the current connection state info struct
fn build_connection_state_info() -> ConnectionStateInfo {
    let session_state = SESSION_CONNECTION_STATE.lock().unwrap();
    let device_id = DEVICE_ID.lock().unwrap().clone();
    let last_error = LAST_ERROR.lock().unwrap().clone();
    let connected_since = CONNECTED_SINCE_MS.load(Ordering::SeqCst);

    ConnectionStateInfo {
        session_connected: session_state.is_connected,
        session_connection_id: session_state.connection_id.clone(),
        spirc_ready: SPIRC_READY.load(Ordering::SeqCst),
        device_id,
        device_name: "Spotifly".to_string(),
        reconnect_attempt: RECONNECT_ATTEMPT.load(Ordering::SeqCst),
        last_error,
        connected_since_ms: if connected_since > 0 {
            Some(connected_since)
        } else {
            None
        },
    }
}

/// Sends connection state update to the registered callback
fn notify_connection_state_change() {
    let cb_guard = CONNECTION_STATE_CALLBACK.lock().unwrap();
    if let Some(callback) = *cb_guard {
        let cb = callback;
        drop(cb_guard);

        let state = build_connection_state_info();
        if let Ok(json) = serde_json::to_string(&state) {
            let c_str = CString::new(json).unwrap();
            cb(c_str.as_ptr());
        }
    }
}

/// Initializes the player with the given access token.
/// Must be called before play/pause operations.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_init_player(access_token: *const c_char) -> i32 {
    // Initialize env_logger to capture librespot's log output (only once)
    static LOGGER_INIT: std::sync::Once = std::sync::Once::new();
    LOGGER_INIT.call_once(|| {
        env_logger::Builder::from_env(env_logger::Env::default())
            .format_timestamp_millis()
            .init();
    });

    // Print RUST_LOG env var for debugging
    let rust_log = std::env::var("RUST_LOG").unwrap_or_else(|_| "(not set)".to_string());
    debug!("RUST_LOG={}", rust_log);

    if access_token.is_null() {
        debug!("Player init error: access_token is null");
        return -1;
    }

    let token_str = unsafe {
        match CStr::from_ptr(access_token).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                debug!("Player init error: invalid access_token string");
                return -1;
            }
        }
    };

    // Check if we already have a session
    {
        let session_guard = SESSION.lock().unwrap();
        if session_guard.is_some() {
            // Already initialized
            return 0;
        }
    }

    let result = RUNTIME.block_on(async { init_player_async(&token_str).await });

    match result {
        Ok(_) => 0,
        Err(_e) => {
            debug!("Player init error: {}", _e);
            -1
        }
    }
}

/// Helper function to create a new Player instance
fn create_new_player(session: &Session, mixer: &Arc<SoftMixer>) -> Result<Arc<Player>, String> {
    let bitrate_setting = BITRATE_SETTING.load(Ordering::SeqCst);
    let bitrate = match bitrate_setting {
        0 => Bitrate::Bitrate96,
        2 => Bitrate::Bitrate320,
        _ => Bitrate::Bitrate160,
    };
    let gapless = GAPLESS_SETTING.load(Ordering::SeqCst);

    let _bitrate_kbps = match bitrate_setting {
        0 => 96,
        2 => 320,
        _ => 160,
    };
    debug!(
        "Player initialized: bitrate={}kbps, gapless={}",
        _bitrate_kbps, gapless
    );

    let player_config = PlayerConfig {
        bitrate,
        gapless,
        position_update_interval: Some(Duration::from_millis(200)),
        ..PlayerConfig::default()
    };
    let audio_format = AudioFormat::default();

    let backend = audio_backend::find(None).ok_or("No audio backend found")?;

    let player = Player::new(
        player_config,
        session.clone(),
        mixer.get_soft_volume(),
        move || backend(None, audio_format),
    );

    // Store player globally
    {
        let mut player_guard = PLAYER.lock().unwrap();
        *player_guard = Some(Arc::clone(&player));
    }

    Ok(player)
}

async fn init_player_async(access_token: &str) -> Result<(), String> {
    // Check if we're in soft reconnect mode (Player kept alive)
    let is_soft_reconnect = SOFT_RECONNECT_MODE.load(Ordering::SeqCst);

    let device_id = format!("spotifly_{}", std::process::id());
    let session_config = SessionConfig {
        device_id: device_id.clone(),
        ..Default::default()
    };

    // Store device ID for later use in transfers
    {
        let mut device_id_guard = DEVICE_ID.lock().unwrap();
        *device_id_guard = Some(device_id);
    }

    // Create credentials - will be used by Spirc to connect
    let credentials = librespot_core::authentication::Credentials::with_access_token(access_token);

    let cache = Cache::new(None::<std::path::PathBuf>, None, None, None)
        .map_err(|e| format!("Cache error: {}", e))?;

    // Create session but DON'T connect yet - let Spirc handle the connection
    // This is important for Spirc to work properly with OAuth tokens
    let session = Session::new(session_config, Some(cache));

    // Get or create mixer
    let mixer: Arc<SoftMixer> = if is_soft_reconnect {
        // Reuse existing mixer in soft reconnect mode
        let mixer_guard = MIXER.lock().unwrap();
        if let Some(existing_mixer) = mixer_guard.as_ref() {
            debug!("Soft reconnect: reusing existing mixer");
            Arc::clone(existing_mixer)
        } else {
            drop(mixer_guard);
            let mixer_config = MixerConfig::default();
            let new_mixer = Arc::new(SoftMixer::open(mixer_config).map_err(|e| format!("Mixer error: {}", e))?);
            let mut mixer_guard = MIXER.lock().unwrap();
            *mixer_guard = Some(Arc::clone(&new_mixer));
            new_mixer
        }
    } else {
        // Create new mixer
        let mixer_config = MixerConfig::default();
        let new_mixer = Arc::new(SoftMixer::open(mixer_config).map_err(|e| format!("Mixer error: {}", e))?);
        let mut mixer_guard = MIXER.lock().unwrap();
        *mixer_guard = Some(Arc::clone(&new_mixer));
        new_mixer
    };

    // Get or create player
    let player: Arc<Player> = if is_soft_reconnect {
        // Try to reuse existing player in soft reconnect mode
        let player_guard = PLAYER.lock().unwrap();
        if let Some(existing_player) = player_guard.as_ref() {
            debug!("Soft reconnect: reusing existing player (audio continues uninterrupted)");
            Arc::clone(existing_player)
        } else {
            // No existing player, create new one
            drop(player_guard);
            debug!("Soft reconnect: no existing player, creating new one");
            create_new_player(&session, &mixer)?
        }
    } else {
        // Normal init: create new player
        create_new_player(&session, &mixer)?
    };

    // Get event channel from player
    let mut event_channel = player.get_player_event_channel();

    // Create channel for stopping event listener
    let (tx, mut rx) = mpsc::unbounded_channel::<()>();

    // Spawn event listener task
    let player_clone = Arc::clone(&player);
    RUNTIME.spawn(async move {
        loop {
            tokio::select! {
                _ = rx.recv() => {
                    // Shutdown signal received
                    break;
                }
                event = event_channel.recv() => {
                    match event {
                        Some(PlayerEvent::Playing { position_ms, .. }) => {
                            IS_PLAYING.store(true, Ordering::SeqCst);
                            IS_ACTIVE_DEVICE.store(true, Ordering::SeqCst);
                            update_position(position_ms);
                        }
                        Some(PlayerEvent::Paused { position_ms, .. }) => {
                            IS_PLAYING.store(false, Ordering::SeqCst);
                            // Still active when paused - just not playing
                            update_position(position_ms);
                        }
                        Some(PlayerEvent::PositionChanged { position_ms, .. }) => {
                            // Periodic position update (every 200ms)
                            update_position(position_ms);
                        }
                        Some(PlayerEvent::Seeked { position_ms, .. }) => {
                            update_position(position_ms);
                        }
                        Some(PlayerEvent::PositionCorrection { position_ms, .. }) => {
                            debug!("PositionCorrection event: {}ms", position_ms);
                            update_position(position_ms);
                        }
                        Some(PlayerEvent::Stopped { .. }) => {
                            IS_PLAYING.store(false, Ordering::SeqCst);
                            IS_ACTIVE_DEVICE.store(false, Ordering::SeqCst);
                            update_position(0);
                        }
                        Some(PlayerEvent::EndOfTrack { .. }) => {
                            // Spirc handles auto-advance to next track automatically
                            // We just update local state here
                            IS_PLAYING.store(false, Ordering::SeqCst);
                            update_position(0);
                        }
                        Some(PlayerEvent::TrackChanged { .. }) => {
                            // Notify Swift that track changed - it should fetch updated queue
                            debug!("TrackChanged event - triggering state update callback");
                            let cb_guard = STATE_UPDATE_CALLBACK.lock().unwrap();
                            if let Some(callback) = *cb_guard {
                                drop(cb_guard);
                                callback();
                            }
                        }
                        Some(PlayerEvent::VolumeChanged { volume }) => {
                            debug!("VolumeChanged event: {}", volume);
                            check_and_send_volume(volume as u32);
                        }
                        Some(PlayerEvent::Loading { track_id, position_ms, .. }) => {
                            let track_uri_str = track_id.to_string();
                            debug!("Loading event: {} at {}ms", track_uri_str, position_ms);

                            // Track current playing URI for soft reconnect detection
                            {
                                let mut uri_guard = CURRENT_TRACK_URI.lock().unwrap();
                                *uri_guard = Some(track_uri_str.clone());
                            }

                            let cb_guard = LOADING_CALLBACK.lock().unwrap();
                            if let Some(callback) = *cb_guard {
                                let cb = callback;
                                drop(cb_guard);
                                let notification = LoadingNotification {
                                    track_uri: track_uri_str,
                                    position_ms,
                                };
                                if let Ok(json) = serde_json::to_string(&notification) {
                                    let c_str = CString::new(json).unwrap();
                                    cb(c_str.as_ptr());
                                }
                            }
                        }
                        Some(PlayerEvent::QueueChanged { track_uri }) => {
                            debug!("QueueChanged event: {}", track_uri);
                            let cb_guard = QUEUE_CHANGED_CALLBACK.lock().unwrap();
                            if let Some(callback) = *cb_guard {
                                let cb = callback;
                                drop(cb_guard);
                                let notification = QueueChangedNotification { track_uri };
                                if let Ok(json) = serde_json::to_string(&notification) {
                                    let c_str = CString::new(json).unwrap();
                                    cb(c_str.as_ptr());
                                }
                            }
                        }
                        Some(PlayerEvent::SessionDisconnected { connection_id, user_name }) => {
                            debug!("SessionDisconnected event: connection_id={}, user={}", connection_id, user_name);
                            // Update session state
                            {
                                let mut state = SESSION_CONNECTION_STATE.lock().unwrap();
                                state.is_connected = false;
                                state.connection_id = None;
                            }
                            // Clear connected timestamp and increment reconnect counter
                            CONNECTED_SINCE_MS.store(0, Ordering::SeqCst);
                            RECONNECT_ATTEMPT.fetch_add(1, Ordering::SeqCst);
                            // Store disconnect as last error
                            {
                                let mut last_error = LAST_ERROR.lock().unwrap();
                                *last_error = Some("Session disconnected".to_string());
                            }
                            // Notify connection state change
                            notify_connection_state_change();
                            let cb_guard = SESSION_DISCONNECTED_CALLBACK.lock().unwrap();
                            if let Some(callback) = *cb_guard {
                                let cb = callback;
                                drop(cb_guard);
                                cb();
                            }
                        }
                        Some(PlayerEvent::SessionConnected { connection_id, user_name }) => {
                            debug!("SessionConnected event: connection_id={}, user={}, timestamp_ms={}", connection_id, user_name, current_timestamp_ms());
                            // Update session state
                            {
                                let mut state = SESSION_CONNECTION_STATE.lock().unwrap();
                                state.is_connected = true;
                                state.connection_id = Some(connection_id);
                            }
                            // Set connected timestamp and reset reconnect counter
                            CONNECTED_SINCE_MS.store(current_timestamp_ms(), Ordering::SeqCst);
                            RECONNECT_ATTEMPT.store(0, Ordering::SeqCst);
                            // Clear last error on successful connect
                            {
                                let mut last_error = LAST_ERROR.lock().unwrap();
                                *last_error = None;
                            }

                            // Check if we should skip transfer (soft reconnect mode)
                            if SKIP_SESSION_CONNECTED_TRANSFER.swap(false, Ordering::SeqCst) {
                                debug!("SessionConnected: skipping transfer(None) for soft reconnect - playback continues uninterrupted");
                            } else {
                                // Re-activate device on reconnect to trigger cluster state sync
                                // This tells Spotify "I'm available again, send me the current state"
                                let spirc_guard = SPIRC.lock().unwrap();
                                if let Some(spirc) = spirc_guard.as_ref() {
                                    if let Err(e) = spirc.transfer(None) {
                                        debug!("transfer(None) on reconnect failed (non-fatal): {:?}", e);
                                    } else {
                                        debug!("transfer(None) on reconnect succeeded - awaiting cluster state");
                                    }
                                }
                                drop(spirc_guard);
                            }

                            // Notify connection state change
                            notify_connection_state_change();
                            let cb_guard = SESSION_CONNECTED_CALLBACK.lock().unwrap();
                            if let Some(callback) = *cb_guard {
                                let cb = callback;
                                drop(cb_guard);
                                cb();
                            }
                        }
                        None => break,
                        _ => {}
                    }
                }
            }
        }
        drop(player_clone);
    });

    // Store session, player, mixer, and event channel first
    {
        let mut player_guard = PLAYER.lock().unwrap();
        *player_guard = Some(Arc::clone(&player));
    }
    {
        let mut session_guard = SESSION.lock().unwrap();
        *session_guard = Some(session.clone());
    }
    {
        let mut tx_guard = PLAYER_EVENT_TX.lock().unwrap();
        *tx_guard = Some(tx);
    }

    // Setup Mercury Queue Listener
    // Subscribe to cluster updates which contain player state (queue)
    let queue_stream = session
        .dealer()
        .listen_for(
            "hm://connect-state/v1/cluster",
            librespot_core::dealer::protocol::Message::from_raw::<ClusterUpdate>,
        )
        .map_err(|e| format!("Failed to subscribe to queue: {}", e))?;

    // Spawn task to process cluster updates (queue + playback state + volume)
    RUNTIME.spawn(async move {
        debug!("Cluster listener task started");
        let mut stream = queue_stream;
        while let Some(msg_result) = stream.next().await {
            debug!("Received cluster update message");
            match msg_result {
                Ok(cluster_update) => {
                    debug!("ClusterUpdate parsed successfully");
                    if let Some(cluster) = cluster_update.cluster.into_option() {
                        debug!("Cluster present");

                        if let Some(player_state) = cluster.player_state.into_option() {
                            debug!("ClusterUpdate: position_as_of_timestamp={}ms, is_playing={}",
                                   player_state.position_as_of_timestamp, player_state.is_playing);
                            // Send playback state update
                            send_playback_state(&player_state);
                            // Send queue update
                            process_and_send_queue(player_state);
                        } else {
                            debug!("No player_state in cluster");
                        }
                    } else {
                        debug!("No cluster in update");
                    }
                }
                Err(_e) => {
                    debug!("Failed to parse cluster update: {:?}", _e);
                }
            }
        }
        debug!("Cluster listener task ended");

        // When cluster listener ends, Spirc is dead. If we were connected,
        // trigger disconnect callback as fallback (in case SessionDisconnectedEvent wasn't emitted)
        let was_connected = {
            let state = SESSION_CONNECTION_STATE.lock().unwrap();
            state.is_connected
        };

        if was_connected {
            debug!("Cluster listener ended while session was connected - triggering fallback disconnect");
            // Update session state
            {
                let mut state = SESSION_CONNECTION_STATE.lock().unwrap();
                state.is_connected = false;
                state.connection_id = None;
            }
            CONNECTED_SINCE_MS.store(0, Ordering::SeqCst);
            RECONNECT_ATTEMPT.fetch_add(1, Ordering::SeqCst);
            {
                let mut last_error = LAST_ERROR.lock().unwrap();
                *last_error = Some("Cluster listener ended unexpectedly".to_string());
            }
            notify_connection_state_change();

            // Trigger session disconnected callback
            let cb_guard = SESSION_DISCONNECTED_CALLBACK.lock().unwrap();
            if let Some(callback) = *cb_guard {
                let cb = callback;
                drop(cb_guard);
                debug!("Calling session disconnected callback from cluster listener");
                cb();
            }
        }
    });

    // Create Spirc for Spotify Connect support (makes this app appear as a Connect device)
    // Spirc::new() will connect the session - this is the proper way per librespot examples
    let initial_volume = INITIAL_VOLUME_SETTING.load(Ordering::SeqCst);
    debug!("Using initial volume: {}", initial_volume);
    let connect_config = ConnectConfig {
        name: "Spotifly".to_string(),
        device_type: DeviceType::Computer,
        initial_volume,
        ..Default::default()
    };

    match Spirc::new(
        connect_config,
        session.clone(),
        credentials.clone(),
        player,
        mixer as Arc<dyn Mixer>,
    )
    .await
    {
        Ok((spirc, spirc_task)) => {
            // Spawn Spirc background task
            let spirc_arc = Arc::new(spirc);
            RUNTIME.spawn(spirc_task);

            let mut spirc_guard = SPIRC.lock().unwrap();
            *spirc_guard = Some(spirc_arc);
            SPIRC_READY.store(true, Ordering::SeqCst);
            debug!("SPIRC_READY set to true");

            // Mark session as connected immediately - Spirc is ready for commands
            // The SessionConnected event will update connection_id when it arrives
            {
                let mut state = SESSION_CONNECTION_STATE.lock().unwrap();
                state.is_connected = true;
                debug!("Session state: is_connected = true");
            }

            debug!("Spirc ready - connected to Spotify Connect");

            // In soft reconnect mode, skip transfer(None) to avoid interrupting current playback
            // The player is already playing the track - we don't want Spirc to reload it
            if is_soft_reconnect {
                debug!("Soft reconnect: skipping transfer(None) to preserve current playback");
                // Clear soft reconnect mode now that we're reconnected
                SOFT_RECONNECT_MODE.store(false, Ordering::SeqCst);
            } else {
                // Activate this device in Spotify Connect by calling transfer(None)
                // This makes us the active device so load() commands work immediately
                // We do this at init time, not at play time, to avoid delays when playing
                debug!("Activating device with transfer(None)");
                if let Some(spirc) = spirc_guard.as_ref() {
                    if let Err(_e) = spirc.transfer(None) {
                        debug!("Initial transfer failed (non-fatal, device may have no previous state): {:?}", _e);
                    }
                }
            }
            drop(spirc_guard);
            IS_ACTIVE_DEVICE.store(true, Ordering::SeqCst);
        }
        Err(_e) => {
            // Spirc failed - fall back to manual session connection for basic playback
            debug!("Spirc init failed: {:?}", _e);
            debug!("Falling back to basic playback (Connect won't be available)");

            // Connect session manually so basic playback works
            if let Err(connect_err) = session.connect(credentials, true).await {
                return Err(format!("Session connect error: {}", connect_err));
            }
        }
    }

    Ok(())
}

/// Checks if volume changed and sends callback if so
fn check_and_send_volume(volume: u32) {
    let volume_u16 = volume as u16;
    let last = LAST_VOLUME.load(Ordering::SeqCst);

    // Only send callback if volume actually changed
    if volume_u16 != last {
        LAST_VOLUME.store(volume_u16, Ordering::SeqCst);
        debug!("Volume changed: {} -> {}", last, volume_u16);

        let cb_guard = VOLUME_CALLBACK.lock().unwrap();
        if let Some(callback) = *cb_guard {
            drop(cb_guard);
            callback(volume_u16);
        }
    }
}

/// Checks if an error indicates the Spirc channel is closed (needs reinit)
fn is_channel_closed_error(err: &librespot_core::Error) -> bool {
    let err_string = format!("{:?}", err);
    err_string.contains("channel closed")
}

/// Error codes:
/// -1 = general error
/// -2 = channel closed, needs reinit (call spotifly_init_player again)
/// -3 = session not connected, wait for session_connected callback
const ERROR_GENERAL: i32 = -1;
const ERROR_NEEDS_REINIT: i32 = -2;
const ERROR_NOT_CONNECTED: i32 = -3;

/// Returns 1 if the session is connected and ready for commands, 0 otherwise.
#[no_mangle]
pub extern "C" fn spotifly_is_session_connected() -> i32 {
    let state = SESSION_CONNECTION_STATE.lock().unwrap();
    if state.is_connected { 1 } else { 0 }
}

/// Helper to check if session is connected. Returns ERROR_NOT_CONNECTED if not.
fn require_session_connected() -> Result<(), i32> {
    let state = SESSION_CONNECTION_STATE.lock().unwrap();
    if state.is_connected {
        Ok(())
    } else {
        debug!("Command rejected: session not connected");
        Err(ERROR_NOT_CONNECTED)
    }
}

fn send_playback_state(player_state: &PlayerState) {
    debug!("send_playback_state called");

    // Log context URI - this is the "active playlist/album/artist" being played from
    let context_uri = &player_state.context_uri;
    if !context_uri.is_empty() {
        debug!("Context URI: {}", context_uri);
    }

    let cb_guard = PLAYBACK_STATE_CALLBACK.lock().unwrap();
    if let Some(callback) = *cb_guard {
        let cb = callback;
        drop(cb_guard);

        // Extract track URI
        let track_uri = player_state
            .track
            .as_ref()
            .map(|t| t.uri.clone())
            .unwrap_or_default();

        // Extract playback options (shuffle, repeat)
        let options = player_state.options.as_ref();
        let shuffle = options.map(|o| o.shuffling_context).unwrap_or(false);
        let repeat_track = options.map(|o| o.repeating_track).unwrap_or(false);
        let repeat_context = options.map(|o| o.repeating_context).unwrap_or(false);

        let update = PlaybackStateUpdate {
            is_playing: player_state.is_playing,
            is_paused: player_state.is_paused,
            track_uri,
            position_ms: player_state.position_as_of_timestamp,
            duration_ms: player_state.duration,
            shuffle,
            repeat_track,
            repeat_context,
        };

        debug!(
            "PlaybackState: playing={}, paused={}, position={}ms, duration={}ms, shuffle={}, repeat_track={}, repeat_context={}",
            update.is_playing,
            update.is_paused,
            update.position_ms,
            update.duration_ms,
            update.shuffle,
            update.repeat_track,
            update.repeat_context
        );

        if let Ok(json) = serde_json::to_string(&update) {
            debug!(
                "Sending playback state JSON ({} bytes) to Swift callback",
                json.len()
            );
            let c_str = CString::new(json).unwrap();
            cb(c_str.as_ptr());
            debug!("Playback state callback returned");
        } else {
            debug!("Failed to serialize playback state to JSON");
        }
    } else {
        debug!("No playback state callback registered, skipping update");
    }
}

fn process_and_send_queue(player_state: PlayerState) {
    debug!("process_and_send_queue called");

    // Log context URI for queue processing too
    if !player_state.context_uri.is_empty() {
        debug!("Queue context URI: {}", player_state.context_uri);
    }

    let cb_guard = QUEUE_CALLBACK.lock().unwrap();
    if let Some(callback) = *cb_guard {
        debug!("Callback is registered, processing queue");
        let cb = callback;
        drop(cb_guard);

        // Helper to convert ProvidedTrack to QueueItem
        let to_queue_item = |t: &librespot_protocol::player::ProvidedTrack| -> QueueItem {
            QueueItem {
                uri: t.uri.clone(),
                name: String::new(),
                artist: String::new(),
                image_url: String::new(),
                duration_ms: 0,
                album_name: String::new(),
                provider: t.provider.clone(),
            }
        };

        // Process current track
        let current_track = player_state.track.into_option().and_then(|t| {
            debug!("current track[0] uri='{}' provider='{}'", t.uri, t.provider);
            if t.uri.starts_with("spotify:track:") {
                Some(to_queue_item(&t))
            } else {
                None
            }
        });

        // Process next_tracks - stop at first delimiter (autoplay boundary)
        let mut next_tracks: Vec<QueueItem> = Vec::new();
        for (i, t) in player_state.next_tracks.iter().enumerate() {
            if i < 3 || !t.uri.starts_with("spotify:track:") {
                debug!(
                    "next track[{}] uri='{}' provider='{}'",
                    i, t.uri, t.provider
                );
            }

            // Stop at first delimiter - everything after is autoplay content
            if t.uri == "spotify:delimiter" {
                debug!(
                    "Stopping at delimiter (index {}), hiding {} autoplay tracks",
                    i,
                    player_state.next_tracks.len() - i - 1
                );
                break;
            }

            if t.uri.starts_with("spotify:track:") {
                next_tracks.push(to_queue_item(t));
            }
        }

        // Process prev_tracks - also stop at delimiter (in reverse, it marks context boundary)
        let mut prev_tracks: Vec<QueueItem> = Vec::new();
        for (i, t) in player_state.prev_tracks.iter().enumerate() {
            if i < 3 || !t.uri.starts_with("spotify:track:") {
                debug!(
                    "prev track[{}] uri='{}' provider='{}'",
                    i, t.uri, t.provider
                );
            }

            // Stop at delimiter
            if t.uri == "spotify:delimiter" {
                debug!("Stopping prev at delimiter (index {})", i);
                break;
            }

            if t.uri.starts_with("spotify:track:") {
                prev_tracks.push(to_queue_item(t));
            }
        }

        debug!(
            "Queue counts: current={}, next={}, prev={}",
            if current_track.is_some() { 1 } else { 0 },
            next_tracks.len(),
            prev_tracks.len()
        );

        let queue_state = QueueState {
            track: current_track,
            next_tracks,
            prev_tracks,
        };

        if let Ok(json) = serde_json::to_string(&queue_state) {
            debug!(
                "Sending queue JSON ({} bytes) to Swift callback",
                json.len()
            );
            let c_str = CString::new(json).unwrap();
            cb(c_str.as_ptr());
            debug!("Swift callback returned");
        } else {
            debug!("Failed to serialize queue state to JSON");
        }
    } else {
        debug!("No callback registered, skipping queue update");
    }
}

/// Plays multiple tracks in sequence.
/// Returns 0 on success, -1 on error.
///
/// # Parameters
/// - track_uris_json: JSON array of track URIs as a C string (e.g., "[\"spotify:track:xxx\", \"spotify:track:yyy\"]")
#[no_mangle]
pub extern "C" fn spotifly_play_tracks(track_uris_json: *const c_char) -> i32 {
    debug!("spotifly_play_tracks called");
    if let Err(e) = require_session_connected() {
        return e;
    }
    if track_uris_json.is_null() {
        debug!("Play tracks error: track_uris_json is null");
        return -1;
    }

    let track_uris_str = unsafe {
        match CStr::from_ptr(track_uris_json).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                debug!("Play tracks error: invalid track_uris_json string");
                return -1;
            }
        }
    };

    // Parse JSON array of track URIs
    let track_uris: Vec<String> = match serde_json::from_str(&track_uris_str) {
        Ok(uris) => uris,
        Err(_e) => {
            debug!("Play tracks error: failed to parse JSON: {:?}", _e);
            return -1;
        }
    };

    if track_uris.is_empty() {
        debug!("Play tracks error: empty track URIs array");
        return -1;
    }

    // Use Spirc.load() for proper Connect state sync
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => {
            let load_request = LoadRequest::from_tracks(
                track_uris,
                LoadRequestOptions {
                    start_playing: true,
                    seek_to: 0,
                    ..Default::default()
                },
            );
            match spirc.load(load_request) {
                Ok(_) => {
                    debug!("Spirc.load(tracks) succeeded");
                    0
                }
                Err(_e) => {
                    debug!("Play tracks error: Spirc.load() failed: {:?}", _e);
                    -1
                }
            }
        }
        None => {
            debug!("Play tracks error: Spirc not initialized");
            -1
        }
    }
}

/// Plays content by its Spotify URI or URL.
/// Supports tracks, albums, playlists, and artists.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_play_uri(uri_or_url: *const c_char) -> i32 {
    if uri_or_url.is_null() {
        debug!("Play error: uri_or_url is null");
        return -1;
    }

    let input_str = unsafe {
        match CStr::from_ptr(uri_or_url).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                debug!("Play error: invalid uri_or_url string");
                return -1;
            }
        }
    };

    // Convert URL to URI if needed
    let uri_str = url_to_uri(&input_str);
    debug!("spotifly_play_uri called: {}", uri_str);

    if let Err(e) = require_session_connected() {
        return e;
    }

    // Use Spirc.load() with LoadRequest for proper Connect state sync
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => {
            // Create LoadRequest - use from_context_uri for albums/playlists/artists,
            // from_tracks for single tracks
            let load_request = if uri_str.starts_with("spotify:track:") {
                debug!("Spirc.load(LoadRequest::from_tracks([{}]))", uri_str);
                LoadRequest::from_tracks(
                    vec![uri_str.clone()],
                    LoadRequestOptions {
                        start_playing: true,
                        seek_to: 0,
                        ..Default::default()
                    },
                )
            } else {
                debug!("Spirc.load(LoadRequest::from_context_uri({}))", uri_str);
                LoadRequest::from_context_uri(
                    uri_str.clone(),
                    LoadRequestOptions {
                        start_playing: true,
                        seek_to: 0,
                        ..Default::default()
                    },
                )
            };

            match spirc.load(load_request) {
                Ok(_) => {
                    debug!("Spirc.load() succeeded");
                    IS_PLAYING.store(true, Ordering::SeqCst);
                    0
                }
                Err(_e) => {
                    debug!("Play error: Spirc.load() failed: {:?}", _e);
                    -1
                }
            }
        }
        None => {
            debug!("Play error: Spirc not initialized");
            -1
        }
    }
}

/// Pauses playback.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn spotifly_pause() -> i32 {
    debug!("spotifly_pause called");
    if let Err(e) = require_session_connected() {
        return e;
    }
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => match spirc.pause() {
            Ok(_) => {
                IS_PLAYING.store(false, Ordering::SeqCst);
                0
            }
            Err(e) => {
                debug!("Pause error: {:?}", e);
                if is_channel_closed_error(&e) {
                    ERROR_NEEDS_REINIT
                } else {
                    ERROR_GENERAL
                }
            }
        },
        None => {
            debug!("Pause error: Spirc not initialized");
            ERROR_GENERAL
        }
    }
}

/// Resumes playback.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn spotifly_resume() -> i32 {
    debug!("spotifly_resume called");
    if let Err(e) = require_session_connected() {
        return e;
    }
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => match spirc.play() {
            Ok(_) => {
                IS_PLAYING.store(true, Ordering::SeqCst);
                0
            }
            Err(e) => {
                debug!("Resume error: {:?}", e);
                if is_channel_closed_error(&e) {
                    ERROR_NEEDS_REINIT
                } else {
                    ERROR_GENERAL
                }
            }
        },
        None => {
            debug!("Resume error: Spirc not initialized");
            ERROR_GENERAL
        }
    }
}

/// Stops playback completely.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_stop() -> i32 {
    debug!("spotifly_stop called");
    let player_guard = PLAYER.lock().unwrap();
    match player_guard.as_ref() {
        Some(player) => {
            player.stop();
            IS_PLAYING.store(false, Ordering::SeqCst);
            0
        }
        None => {
            debug!("Stop error: player not initialized");
            -1
        }
    }
}

/// Shuts down the Spirc connection and sends goodbye to other devices.
/// Call this when the app is quitting to properly disconnect from Spotify Connect.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_shutdown() -> i32 {
    debug!("spotifly_shutdown called");
    let spirc_guard = SPIRC.lock().unwrap();
    if let Some(spirc) = spirc_guard.as_ref() {
        if spirc.shutdown().is_ok() {
            return 0;
        }
    }
    -1
}

/// Cleans up all player state, allowing a fresh reinitialization.
/// Call this before spotifly_init_player() when the session has disconnected.
/// This clears all static state (session, player, spirc, etc.)
#[no_mangle]
pub extern "C" fn spotifly_cleanup() {
    debug!("spotifly_cleanup called - clearing all state");

    // Signal event listener to stop
    {
        let mut tx_guard = PLAYER_EVENT_TX.lock().unwrap();
        if let Some(tx) = tx_guard.take() {
            let _ = tx.send(());
        }
    }

    // Clear Spirc first (it holds references to player and session)
    {
        let mut spirc_guard = SPIRC.lock().unwrap();
        *spirc_guard = None;
    }
    SPIRC_READY.store(false, Ordering::SeqCst);

    // Clear player
    {
        let mut player_guard = PLAYER.lock().unwrap();
        *player_guard = None;
    }

    // Clear mixer
    {
        let mut mixer_guard = MIXER.lock().unwrap();
        *mixer_guard = None;
    }

    // Clear session
    {
        let mut session_guard = SESSION.lock().unwrap();
        *session_guard = None;
    }

    // Clear device ID
    {
        let mut device_id_guard = DEVICE_ID.lock().unwrap();
        *device_id_guard = None;
    }

    // Reset state flags
    IS_PLAYING.store(false, Ordering::SeqCst);
    IS_ACTIVE_DEVICE.store(false, Ordering::SeqCst);
    POSITION_MS.store(0, Ordering::SeqCst);
    POSITION_TIMESTAMP_MS.store(0, Ordering::SeqCst);
    LAST_VOLUME.store(0, Ordering::SeqCst);

    // Reset session connection state
    {
        let mut state = SESSION_CONNECTION_STATE.lock().unwrap();
        state.is_connected = false;
        state.connection_id = None;
    }

    // Reset connection state tracking (but keep reconnect_attempt for backoff)
    CONNECTED_SINCE_MS.store(0, Ordering::SeqCst);
    // Note: We don't reset RECONNECT_ATTEMPT here - it's used for exponential backoff
    // and should only be reset on successful reconnect (in SessionConnected handler)

    // Notify connection state change
    notify_connection_state_change();

    debug!("spotifly_cleanup complete - ready for reinitialization");
}

/// Soft cleanup - preserves Player and Mixer for uninterrupted playback.
/// Only clears Session and Spirc, allowing reconnection without audio gap.
/// Call this instead of spotifly_cleanup when you want to preserve current playback.
#[no_mangle]
pub extern "C" fn spotifly_soft_cleanup() {
    debug!("spotifly_soft_cleanup called - preserving Player for uninterrupted playback");

    // Set soft reconnect mode - this tells init to skip transfer(None)
    SOFT_RECONNECT_MODE.store(true, Ordering::SeqCst);
    // Also skip transfer in SessionConnected handler
    SKIP_SESSION_CONNECTED_TRANSFER.store(true, Ordering::SeqCst);

    // Clear Spirc (but DON'T signal event listener to stop - Player needs it)
    {
        let mut spirc_guard = SPIRC.lock().unwrap();
        *spirc_guard = None;
    }
    SPIRC_READY.store(false, Ordering::SeqCst);

    // Clear session (Player will continue with buffered audio)
    {
        let mut session_guard = SESSION.lock().unwrap();
        *session_guard = None;
    }

    // Clear device ID (will be regenerated)
    {
        let mut device_id_guard = DEVICE_ID.lock().unwrap();
        *device_id_guard = None;
    }

    // DON'T clear Player or Mixer - keep audio playing!
    // DON'T reset IS_PLAYING, POSITION_MS, etc. - preserve playback state

    // Reset session connection state
    {
        let mut state = SESSION_CONNECTION_STATE.lock().unwrap();
        state.is_connected = false;
        state.connection_id = None;
    }

    CONNECTED_SINCE_MS.store(0, Ordering::SeqCst);

    // Notify connection state change
    notify_connection_state_change();

    debug!("spotifly_soft_cleanup complete - Player still running");
}

/// Returns 1 if currently playing, 0 otherwise.
#[no_mangle]
pub extern "C" fn spotifly_is_playing() -> i32 {
    if IS_PLAYING.load(Ordering::SeqCst) {
        1
    } else {
        0
    }
}

/// Returns the current playback position in milliseconds.
/// If playing, interpolates from last known position.
/// Returns 0 if not playing or no position available.
#[no_mangle]
pub extern "C" fn spotifly_get_position_ms() -> u32 {
    let stored_position = POSITION_MS.load(Ordering::SeqCst);
    let stored_timestamp = POSITION_TIMESTAMP_MS.load(Ordering::SeqCst);

    if stored_timestamp == 0 {
        return 0;
    }

    // If playing, interpolate position from last update
    if IS_PLAYING.load(Ordering::SeqCst) {
        let now = current_timestamp_ms();
        let elapsed_since_update = now.saturating_sub(stored_timestamp);
        // Cap interpolation at 5 seconds - librespot events can be delayed
        // but if we haven't heard anything in 5s, something is wrong
        let capped_elapsed = elapsed_since_update.min(5000) as u32;
        stored_position.saturating_add(capped_elapsed)
    } else {
        stored_position
    }
}

/// Skips to the next track in the queue.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn spotifly_next() -> i32 {
    debug!("spotifly_next called");
    if let Err(e) = require_session_connected() {
        return e;
    }
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => match spirc.next() {
            Ok(_) => 0,
            Err(e) => {
                debug!("Next error: {:?}", e);
                if is_channel_closed_error(&e) {
                    ERROR_NEEDS_REINIT
                } else {
                    ERROR_GENERAL
                }
            }
        },
        None => {
            debug!("Next error: Spirc not initialized");
            ERROR_GENERAL
        }
    }
}

/// Skips to the previous track in the queue.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn spotifly_previous() -> i32 {
    debug!("spotifly_previous called");
    if let Err(e) = require_session_connected() {
        return e;
    }
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => match spirc.prev() {
            Ok(_) => 0,
            Err(e) => {
                debug!("Previous error: {:?}", e);
                if is_channel_closed_error(&e) {
                    ERROR_NEEDS_REINIT
                } else {
                    ERROR_GENERAL
                }
            }
        },
        None => {
            debug!("Previous error: Spirc not initialized");
            ERROR_GENERAL
        }
    }
}

/// Seeks to the given position in milliseconds.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn spotifly_seek(position_ms: u32) -> i32 {
    debug!("spotifly_seek called: {}ms", position_ms);
    if let Err(e) = require_session_connected() {
        return e;
    }
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => match spirc.set_position_ms(position_ms) {
            Ok(_) => 0,
            Err(e) => {
                debug!("Seek error: {:?}", e);
                if is_channel_closed_error(&e) {
                    ERROR_NEEDS_REINIT
                } else {
                    ERROR_GENERAL
                }
            }
        },
        None => {
            debug!("Seek error: Spirc not initialized");
            ERROR_GENERAL
        }
    }
}

/// Plays radio for a seed track.
/// Gets the radio playlist URI and loads it directly via Spirc.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_play_radio(track_uri: *const c_char) -> i32 {
    if track_uri.is_null() {
        debug!("Play radio error: track_uri is null");
        return -1;
    }

    let uri_str = unsafe {
        match CStr::from_ptr(track_uri).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                debug!("Play radio error: invalid track_uri string");
                return -1;
            }
        }
    };

    debug!("spotifly_play_radio called: {}", uri_str);

    if let Err(e) = require_session_connected() {
        return e;
    }

    let session_guard = SESSION.lock().unwrap();
    let session = match session_guard.as_ref() {
        Some(s) => s.clone(),
        None => {
            debug!("Play radio error: session not initialized");
            return -1;
        }
    };
    drop(session_guard);

    // Get the radio playlist URI
    let playlist_uri: Result<String, String> = RUNTIME.block_on(async {
        let spotify_uri = parse_spotify_uri(&uri_str)?;

        let response = session
            .spclient()
            .get_radio_for_track(&spotify_uri)
            .await
            .map_err(|e| format!("Failed to get radio: {:?}", e))?;

        let json: serde_json::Value = serde_json::from_slice(&response)
            .map_err(|e| format!("Failed to parse radio response: {:?}", e))?;

        // The API returns a playlist URI in mediaItems
        // Format: { "mediaItems": [{ "uri": "spotify:playlist:xxx" }] }
        json.get("mediaItems")
            .and_then(|items| items.as_array())
            .and_then(|items| items.first())
            .and_then(|item| item.get("uri"))
            .and_then(|u| u.as_str())
            .filter(|uri| uri.starts_with("spotify:playlist:"))
            .map(|s| s.to_string())
            .ok_or_else(|| "No radio playlist found in response".to_string())
    });

    let playlist_uri = match playlist_uri {
        Ok(uri) => uri,
        Err(_e) => {
            debug!("Play radio error: {}", _e);
            return -1;
        }
    };

    debug!("Loading radio playlist: {}", playlist_uri);

    // Load the radio playlist via Spirc
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => {
            let load_request = LoadRequest::from_context_uri(
                playlist_uri,
                LoadRequestOptions {
                    start_playing: true,
                    seek_to: 0,
                    ..Default::default()
                },
            );
            match spirc.load(load_request) {
                Ok(_) => 0,
                Err(_e) => {
                    debug!("Play radio error: {:?}", _e);
                    -1
                }
            }
        }
        None => {
            debug!("Play radio error: Spirc not initialized");
            -1
        }
    }
}

/// Sets the playback volume (0-65535).
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn spotifly_set_volume(volume: u16) -> i32 {
    debug!("spotifly_set_volume called: {}", volume);
    if let Err(e) = require_session_connected() {
        return e;
    }
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => match spirc.set_volume(volume) {
            Ok(_) => 0,
            Err(e) => {
                debug!("Set volume error: {:?}", e);
                if is_channel_closed_error(&e) {
                    ERROR_NEEDS_REINIT
                } else {
                    ERROR_GENERAL
                }
            }
        },
        None => {
            debug!("Set volume error: Spirc not initialized");
            ERROR_GENERAL
        }
    }
}

/// Sets the streaming bitrate.
/// 0 = 96 kbps, 1 = 160 kbps (default), 2 = 320 kbps
/// Note: Takes effect on next player initialization (restart playback to apply).
#[no_mangle]
pub extern "C" fn spotifly_set_bitrate(bitrate: u8) {
    let value = bitrate.min(2); // Clamp to valid range
    let old_value = BITRATE_SETTING.swap(value, Ordering::SeqCst);
    if old_value != value {
        let _kbps = match value {
            0 => 96,
            2 => 320,
            _ => 160,
        };
        debug!(
            "Bitrate changed to {}kbps (restart playback to apply)",
            _kbps
        );
    }
}

/// Gets the current bitrate setting.
/// 0 = 96 kbps, 1 = 160 kbps, 2 = 320 kbps
#[no_mangle]
pub extern "C" fn spotifly_get_bitrate() -> u8 {
    BITRATE_SETTING.load(Ordering::SeqCst)
}

/// Sets gapless playback (true = enabled, false = disabled).
/// Enabled by default. Takes effect on next player initialization (restart playback to apply).
#[no_mangle]
pub extern "C" fn spotifly_set_gapless(enabled: bool) {
    let old_value = GAPLESS_SETTING.swap(enabled, Ordering::SeqCst);
    if old_value != enabled {
        debug!(
            "Gapless playback changed to {} (restart playback to apply)",
            enabled
        );
    }
}

/// Gets the current gapless playback setting.
#[no_mangle]
pub extern "C" fn spotifly_get_gapless() -> bool {
    GAPLESS_SETTING.load(Ordering::SeqCst)
}

/// Sets the initial volume (0-65535) used when registering with Spotify Connect.
/// Must be called before spotifly_init_player() to take effect.
#[no_mangle]
pub extern "C" fn spotifly_set_initial_volume(volume: u16) {
    INITIAL_VOLUME_SETTING.store(volume, Ordering::SeqCst);
}

/// Transfers playback from another device to this local player.
/// Uses the native Spotify Connect protocol via Spirc.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_transfer_to_local() -> i32 {
    debug!("spotifly_transfer_to_local called");
    if let Err(e) = require_session_connected() {
        return e;
    }
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => {
            // Pass None to transfer from whatever device is currently playing
            match spirc.transfer(None) {
                Ok(_) => 0,
                Err(_e) => {
                    debug!("Transfer error: {:?}", _e);
                    -1
                }
            }
        }
        None => {
            debug!("Transfer error: Spirc not initialized");
            -1
        }
    }
}

/// Transfers playback from this local player to another device.
/// Uses the native Spotify Connect protocol via SpClient.
/// Returns 0 on success, -1 on error.
///
/// # Parameters
/// - to_device_id: The target device ID to transfer playback to
#[no_mangle]
pub extern "C" fn spotifly_transfer_playback(to_device_id: *const c_char) -> i32 {
    if to_device_id.is_null() {
        debug!("Transfer playback error: to_device_id is null");
        return -1;
    }

    let to_device_str = unsafe {
        match CStr::from_ptr(to_device_id).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                debug!("Transfer playback error: invalid to_device_id string");
                return -1;
            }
        }
    };

    debug!("spotifly_transfer_playback called: {}", to_device_str);

    if let Err(e) = require_session_connected() {
        return e;
    }

    let session_guard = SESSION.lock().unwrap();
    let session = match session_guard.as_ref() {
        Some(s) => s.clone(),
        None => {
            debug!("Transfer playback error: session not initialized");
            return -1;
        }
    };
    drop(session_guard);

    let device_id_guard = DEVICE_ID.lock().unwrap();
    let from_device_id = match device_id_guard.as_ref() {
        Some(id) => id.clone(),
        None => {
            debug!("Transfer playback error: device ID not initialized");
            return -1;
        }
    };
    drop(device_id_guard);

    let result: Result<(), String> = RUNTIME.block_on(async {
        session
            .spclient()
            .transfer(&from_device_id, &to_device_str, None)
            .await
            .map_err(|e| format!("Transfer failed: {:?}", e))?;
        Ok(())
    });

    match result {
        Ok(_) => {
            // Pause local playback after successful transfer
            let player_guard = PLAYER.lock().unwrap();
            if let Some(player) = player_guard.as_ref() {
                player.pause();
            }
            IS_PLAYING.store(false, Ordering::SeqCst);
            IS_ACTIVE_DEVICE.store(false, Ordering::SeqCst);
            0
        }
        Err(_e) => {
            debug!("Transfer playback error: {}", _e);
            -1
        }
    }
}

/// Returns 1 if Spirc is initialized and connected to Spotify Connect, 0 otherwise.
#[no_mangle]
pub extern "C" fn spotifly_is_spirc_ready() -> i32 {
    if SPIRC_READY.load(Ordering::SeqCst) {
        1
    } else {
        0
    }
}

/// Adds a track to the queue.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_add_to_queue(track_uri: *const c_char) -> i32 {
    if track_uri.is_null() {
        debug!("Add to queue error: track_uri is null");
        return -1;
    }

    let uri_str = unsafe {
        match CStr::from_ptr(track_uri).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                debug!("Add to queue error: invalid track_uri string");
                return -1;
            }
        }
    };

    debug!("[Spotifly] spotifly_add_to_queue called: {}", uri_str);

    if let Err(e) = require_session_connected() {
        return e;
    }

    // Parse string to SpotifyUri
    let spotify_uri = match parse_spotify_uri(&uri_str) {
        Ok(uri) => uri,
        Err(e) => {
            debug!("Add to queue error: {}", e);
            return -1;
        }
    };

    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => {
            match spirc.add_to_queue(spotify_uri) {
                Ok(_) => {
                    debug!("[Spotifly] add_to_queue succeeded");
                    0
                }
                Err(e) => {
                    debug!("Add to queue error: {:?}", e);
                    -1
                }
            }
        }
        None => {
            debug!("Add to queue error: Spirc not initialized");
            -1
        }
    }
}
