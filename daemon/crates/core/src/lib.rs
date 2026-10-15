//! NotchSend core: LocalSend v2.2 transfer engine.
//!
//! The engine owns all protocol and transfer state. It knows nothing about
//! the notch UI or the IPC socket framing; it emits typed events on a
//! broadcast channel and exposes a snapshot for resynchronisation.

pub mod client;
pub mod discovery;
pub mod identity;
pub mod server;
pub mod tls;
pub mod util;

use identity::Identity;
use notchsend_protocol::{FileDto, RegisterDto, PROTOCOL_VERSION};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, HashMap};
use std::net::IpAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{broadcast, oneshot, Notify};

#[derive(Debug, Clone)]
pub struct CoreEvent {
    pub event: String,
    pub data: Value,
}

impl CoreEvent {
    pub fn new(event: &str, data: Value) -> Self {
        Self {
            event: event.to_string(),
            data,
        }
    }
}

#[derive(Debug, Clone)]
pub struct EngineConfig {
    pub alias: String,
    pub device_model: Option<String>,
    pub device_type: String,
    pub port: u16,
    pub download_dir: PathBuf,
    pub pin: String,
    pub approval_timeout: Duration,
    pub auto_accept: bool,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct PeerRecord {
    pub fingerprint: String,
    pub alias: String,
    pub device_model: Option<String>,
    pub device_type: Option<String>,
    pub ip: String,
    pub port: u16,
    pub protocol: String,
    pub last_seen: u64,
}

pub enum Decision {
    Accept(Option<Vec<String>>),
    Reject,
}

pub struct Pending {
    pub request_id: String,
    pub sender: RegisterDto,
    pub sender_ip: IpAddr,
    pub sender_fingerprint: String,
    pub files: BTreeMap<String, FileDto>,
    pub total_size: u64,
    pub decision_tx: Option<oneshot::Sender<Decision>>,
}

pub struct FileState {
    pub dto: FileDto,
    pub token: String,
    pub status: Mutex<String>, // queued | transferring | verifying | done | failed
    pub bytes_done: std::sync::atomic::AtomicU64,
    pub part_path: Mutex<Option<PathBuf>>,
    pub final_path: Mutex<Option<String>>,
}

pub struct InSession {
    pub session_id: String,
    pub sender_ip: IpAddr,
    pub sender_alias: String,
    pub files: HashMap<String, Arc<FileState>>,
    pub order: Vec<String>,
    pub total_size: u64,
    pub cancelled: Arc<AtomicBool>,
}

pub struct Inner {
    pub pending: Option<Pending>,
    pub session: Option<Arc<InSession>>,
}

pub struct Engine {
    pub cfg: EngineConfig,
    pub identity: Identity,
    events: broadcast::Sender<CoreEvent>,
    peers: std::sync::RwLock<HashMap<String, PeerRecord>>,
    pub inner: Mutex<Inner>,
    control_clients: AtomicUsize,
    outgoing: Mutex<HashMap<String, tokio::task::AbortHandle>>,
    pub rescan_notify: Notify,
}

impl Engine {
    pub fn new(cfg: EngineConfig, identity: Identity) -> Arc<Self> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let (events, _) = broadcast::channel(512);
        Arc::new(Self {
            cfg,
            identity,
            events,
            peers: std::sync::RwLock::new(HashMap::new()),
            inner: Mutex::new(Inner {
                pending: None,
                session: None,
            }),
            control_clients: AtomicUsize::new(0),
            outgoing: Mutex::new(HashMap::new()),
            rescan_notify: Notify::new(),
        })
    }

    // ------------------------------------------------------------ events ---

    pub fn subscribe(&self) -> broadcast::Receiver<CoreEvent> {
        self.events.subscribe()
    }

    pub fn emit(&self, event: &str, data: Value) {
        tracing::debug!(event, "core event");
        let _ = self.events.send(CoreEvent::new(event, data));
    }

    // ------------------------------------------------------ control link ---

    pub fn set_control_clients(&self, n: usize) {
        self.control_clients.store(n, Ordering::SeqCst);
    }

    pub fn control_clients(&self) -> usize {
        self.control_clients.load(Ordering::SeqCst)
    }

    // ------------------------------------------------------------ peers ----

    pub fn upsert_peer(&self, rec: PeerRecord) {
        let is_new = {
            let mut peers = self.peers.write().unwrap();
            let new = !peers.contains_key(&rec.fingerprint);
            peers.insert(rec.fingerprint.clone(), rec.clone());
            new
        };
        if is_new {
            self.emit(
                "peer_found",
                serde_json::to_value(&rec).unwrap_or(Value::Null),
            );
        }
    }

    pub fn peers_snapshot(&self) -> Vec<PeerRecord> {
        let mut v: Vec<PeerRecord> = self.peers.read().unwrap().values().cloned().collect();
        v.sort_by(|a, b| a.alias.cmp(&b.alias));
        v
    }

    // --------------------------------------------------------- identity ----

    pub fn self_register(&self) -> RegisterDto {
        RegisterDto {
            alias: self.cfg.alias.clone(),
            version: PROTOCOL_VERSION.to_string(),
            device_model: self.cfg.device_model.clone(),
            device_type: Some(self.cfg.device_type.clone()),
            fingerprint: self.identity.fingerprint.clone(),
            port: self.cfg.port,
            protocol: "https".to_string(),
            download: false,
        }
    }

    // ---------------------------------------------------------- snapshot ---

    pub fn snapshot(&self) -> Value {
        let inner = self.inner.lock().unwrap();
        let pending = inner.pending.as_ref().map(|p| {
            json!({
                "request_id": p.request_id,
                "sender": serde_json::to_value(&p.sender).unwrap_or(Value::Null),
                "sender_ip": p.sender_ip.to_string(),
                "files": files_json(&p.files),
                "total_size": p.total_size,
            })
        });
        let session = inner.session.as_ref().map(|s| {
            let files: Vec<Value> = s
                .order
                .iter()
                .filter_map(|id| s.files.get(id))
                .map(|f| {
                    json!({
                        "id": f.dto.id,
                        "name": f.dto.file_name,
                        "size": f.dto.size,
                        "bytes_done": f.bytes_done.load(Ordering::SeqCst),
                        "status": f.status.lock().unwrap().clone(),
                        "saved_path": f.final_path.lock().unwrap().clone(),
                    })
                })
                .collect();
            json!({
                "session_id": s.session_id,
                "direction": "receive",
                "peer_alias": s.sender_alias,
                "files": files,
                "total_size": s.total_size,
            })
        });
        json!({
            "peers": serde_json::to_value(self.peers_snapshot()).unwrap_or(Value::Null),
            "pending": pending,
            "session": session,
        })
    }

    // ------------------------------------------------------ approval gate --

    /// Resolve the pending approval request. Returns false if there is no
    /// matching pending request (e.g. it already timed out).
    pub fn resolve_pending(&self, request_id: &str, decision: Decision) -> bool {
        let tx = {
            let mut inner = self.inner.lock().unwrap();
            match inner.pending.as_mut() {
                Some(p) if p.request_id == request_id => p.decision_tx.take(),
                _ => None,
            }
        };
        match tx {
            Some(tx) => tx.send(decision).is_ok(),
            None => false,
        }
    }

    pub fn pending_request_id(&self) -> Option<String> {
        self.inner
            .lock()
            .unwrap()
            .pending
            .as_ref()
            .map(|p| p.request_id.clone())
    }

    // ------------------------------------------------------------ cancel ---

    /// Cancel an active incoming session: flags it cancelled (the in-flight
    /// upload loop notices and aborts) and deletes partial files.
    pub fn cancel_incoming(&self, session_id: &str) -> bool {
        let session = {
            let mut inner = self.inner.lock().unwrap();
            match inner.session.as_ref() {
                Some(s) if s.session_id == session_id => inner.session.take(),
                _ => None,
            }
        };
        match session {
            Some(s) => {
                s.cancelled.store(true, Ordering::SeqCst);
                for f in s.files.values() {
                    if let Some(p) = f.part_path.lock().unwrap().clone() {
                        let _ = std::fs::remove_file(p);
                    }
                }
                self.emit(
                    "session_cancelled",
                    json!({"session_id": session_id, "by": "user"}),
                );
                true
            }
            None => false,
        }
    }

    // ---------------------------------------------------------- outgoing ---

    pub fn register_outgoing(&self, session_id: &str, handle: tokio::task::AbortHandle) {
        self.outgoing
            .lock()
            .unwrap()
            .insert(session_id.to_string(), handle);
    }

    pub fn unregister_outgoing(&self, session_id: &str) {
        self.outgoing.lock().unwrap().remove(session_id);
    }

    pub fn abort_outgoing(&self, session_id: &str) -> bool {
        let handle = self.outgoing.lock().unwrap().remove(session_id);
        match handle {
            Some(h) => {
                h.abort();
                self.emit(
                    "session_cancelled",
                    json!({"session_id": session_id, "by": "user"}),
                );
                true
            }
            None => false,
        }
    }
}

pub fn files_json(files: &BTreeMap<String, FileDto>) -> Vec<Value> {
    files
        .values()
        .map(|f| {
            json!({
                "id": f.id,
                "name": f.file_name,
                "size": f.size,
                "file_type": f.file_type,
                "sha256": f.sha256,
            })
        })
        .collect()
}

pub fn map_of(data: Value) -> Map<String, Value> {
    match data {
        Value::Object(m) => m,
        _ => Map::new(),
    }
}
