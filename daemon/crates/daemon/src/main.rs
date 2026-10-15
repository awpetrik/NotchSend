//! notchsendd - LocalSend daemon with a Unix-socket control interface
//! (NDJSON, BLUEPRINT §5). The daemon owns all protocol state; control
//! clients (the notch UI, notchsendctl) are projectors/command senders.

use anyhow::{Context, Result};
use notchsend_core::{Decision, Engine, EngineConfig};
use serde_json::{json, Value};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::broadcast;

struct Args {
    alias: String,
    port: u16,
    download_dir: PathBuf,
    data_dir: PathBuf,
    socket_path: Option<PathBuf>,
    pin: String,
    approval_timeout_secs: u64,
    auto_accept: bool,
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string()))
}

fn parse_args() -> Args {
    let mut a = Args {
        alias: "NotchSend".to_string(),
        port: 53317,
        download_dir: home().join("Downloads"),
        data_dir: home().join(".notchsend"),
        socket_path: None,
        pin: String::new(),
        approval_timeout_secs: 60,
        auto_accept: false,
    };
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    while i < argv.len() {
        let next = |i: &mut usize| -> String {
            *i += 1;
            argv.get(*i).cloned().unwrap_or_default()
        };
        match argv[i].as_str() {
            "--alias" => a.alias = next(&mut i),
            "--port" => a.port = next(&mut i).parse().unwrap_or(53317),
            "--download-dir" => a.download_dir = PathBuf::from(next(&mut i)),
            "--data-dir" => a.data_dir = PathBuf::from(next(&mut i)),
            "--socket-path" => a.socket_path = Some(PathBuf::from(next(&mut i))),
            "--pin" => a.pin = next(&mut i),
            "--approval-timeout-secs" => {
                a.approval_timeout_secs = next(&mut i).parse().unwrap_or(60)
            }
            "--auto-accept" => a.auto_accept = true,
            "--help" | "-h" => {
                println!(
                    "notchsendd [--alias NAME] [--port N] [--download-dir DIR] [--data-dir DIR]\n           [--socket-path PATH] [--pin PIN] [--approval-timeout-secs N] [--auto-accept]"
                );
                std::process::exit(0);
            }
            other => eprintln!("ignoring unknown argument: {other}"),
        }
        i += 1;
    }
    a
}

type Sink = Arc<tokio::sync::Mutex<tokio::net::unix::OwnedWriteHalf>>;

struct IpcState {
    engine: Arc<Engine>,
    clients: Mutex<Vec<Sink>>,
    seq: AtomicU64,
}

impl IpcState {
    async fn add_client(&self, sink: Sink) {
        let n = {
            let mut c = self.clients.lock().unwrap();
            c.push(sink);
            c.len()
        };
        self.engine.set_control_clients(n);
    }

    async fn remove_client(&self, sink: &Sink) {
        let n = {
            let mut c = self.clients.lock().unwrap();
            c.retain(|s| !Arc::ptr_eq(s, sink));
            c.len()
        };
        self.engine.set_control_clients(n);
    }

    async fn broadcast_line(&self, line: String) {
        let sinks: Vec<Sink> = self.clients.lock().unwrap().clone();
        let mut dead: Vec<Sink> = Vec::new();
        for sink in sinks {
            let mut w = sink.lock().await;
            if w.write_all(line.as_bytes()).await.is_err()
                || w.write_all(b"\n").await.is_err()
            {
                dead.push(sink.clone());
            }
        }
        for d in dead {
            self.remove_client(&d).await;
        }
    }

    fn snapshot_msg(&self) -> Value {
        let mut snap = self.engine.snapshot();
        snap["type"] = json!("snapshot");
        snap["seq"] = json!(self.seq.load(Ordering::SeqCst));
        snap
    }
}

async fn write_line(sink: &Sink, v: &Value) {
    let mut w = sink.lock().await;
    let _ = w.write_all(v.to_string().as_bytes()).await;
    let _ = w.write_all(b"\n").await;
}

fn result(id: &Value, ok: bool, extra: Value) -> Value {
    let mut m = json!({"type": "result", "id": id, "ok": ok});
    if let (Value::Object(dst), Value::Object(src)) = (&mut m, extra) {
        for (k, v) in src {
            dst.insert(k, v);
        }
    }
    m
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info,notchsend_core=info".into()),
        )
        .init();
    let args = parse_args();
    std::fs::create_dir_all(&args.data_dir).context("create data dir")?;
    std::fs::create_dir_all(&args.download_dir).context("create download dir")?;
    let socket_path = args
        .socket_path
        .clone()
        .unwrap_or_else(|| args.data_dir.join("daemon.sock"));

    let identity = notchsend_core::identity::load_or_create(&args.data_dir)?;
    tracing::info!(fingerprint = %identity.fingerprint, "identity ready");
    let engine = Engine::new(
        EngineConfig {
            alias: args.alias.clone(),
            device_model: None,
            device_type: "desktop".to_string(),
            port: args.port,
            download_dir: args.download_dir.clone(),
            pin: args.pin.clone(),
            approval_timeout: std::time::Duration::from_secs(args.approval_timeout_secs),
            auto_accept: args.auto_accept,
        },
        identity,
    );

    // Protocol server + discovery.
    {
        let e = engine.clone();
        tokio::spawn(async move {
            if let Err(err) = notchsend_core::server::run_server(e).await {
                tracing::error!(error = %err, "https server failed");
            }
        });
        let e = engine.clone();
        tokio::spawn(async move {
            notchsend_core::discovery::run_discovery(e).await;
        });
    }

    // Control socket.
    if socket_path.exists() {
        let _ = std::fs::remove_file(&socket_path);
    }
    if let Some(parent) = socket_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let listener = UnixListener::bind(&socket_path)
        .with_context(|| format!("bind {}", socket_path.display()))?;
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(
            &socket_path,
            std::fs::Permissions::from_mode(0o600),
        );
    }
    tracing::info!(socket = %socket_path.display(), "control socket listening");

    let ipc = Arc::new(IpcState {
        engine: engine.clone(),
        clients: Mutex::new(Vec::new()),
        seq: AtomicU64::new(0),
    });

    // Event fanout: core broadcast -> all IPC clients, with daemon seq.
    {
        let ipc = ipc.clone();
        let mut rx = engine.subscribe();
        tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(ev) => {
                        let seq = ipc.seq.fetch_add(1, Ordering::SeqCst) + 1;
                        let mut msg = json!({"type": "event", "event": ev.event, "seq": seq});
                        if let (Value::Object(dst), Value::Object(src)) =
                            (&mut msg, ev.data)
                        {
                            for (k, v) in src {
                                dst.insert(k, v);
                            }
                        }
                        ipc.broadcast_line(msg.to_string()).await;
                    }
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        tracing::warn!(skipped = n, "ipc fanout lagged");
                    }
                    Err(_) => break,
                }
            }
        });
    }

    loop {
        tokio::select! {
            accept = listener.accept() => {
                match accept {
                    Ok((stream, _)) => {
                        let ipc = ipc.clone();
                        tokio::spawn(async move {
                            if let Err(e) = handle_client(ipc, stream).await {
                                tracing::debug!(error = %e, "control client ended");
                            }
                        });
                    }
                    Err(e) => tracing::warn!(error = %e, "control accept failed"),
                }
            }
            _ = tokio::signal::ctrl_c() => {
                tracing::info!("shutting down");
                let _ = std::fs::remove_file(&socket_path);
                break;
            }
        }
    }
    Ok(())
}

async fn handle_client(ipc: Arc<IpcState>, stream: UnixStream) -> Result<()> {
    let (read_half, write_half) = stream.into_split();
    let sink: Sink = Arc::new(tokio::sync::Mutex::new(write_half));
    ipc.add_client(sink.clone()).await;
    let mut lines = BufReader::new(read_half).lines();
    let engine = ipc.engine.clone();

    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        let msg: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let ty = msg.get("type").and_then(|v| v.as_str()).unwrap_or("");
        let id = msg.get("id").cloned().unwrap_or(Value::Null);
        match ty {
            "hello" => {
                let welcome = json!({
                    "type": "welcome",
                    "ipc_version": 1,
                    "daemon_version": env!("CARGO_PKG_VERSION"),
                    "alias": engine.cfg.alias,
                    "fingerprint": engine.identity.fingerprint,
                    "port": engine.cfg.port,
                });
                write_line(&sink, &welcome).await;
                write_line(&sink, &ipc.snapshot_msg()).await;
            }
            "accept" | "reject" => {
                let request_id = msg
                    .get("request_id")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let ok = if ty == "accept" {
                    let file_ids: Option<Vec<String>> = msg
                        .get("file_ids")
                        .and_then(|v| serde_json::from_value(v.clone()).ok());
                    engine.resolve_pending(&request_id, Decision::Accept(file_ids))
                } else {
                    engine.resolve_pending(&request_id, Decision::Reject)
                };
                write_line(&sink, &result(&id, ok, json!({"request_id": request_id}))).await;
            }
            "send" => {
                let address = msg.get("address").and_then(|v| v.as_str()).unwrap_or("");
                let paths: Vec<PathBuf> = msg
                    .get("paths")
                    .and_then(|v| serde_json::from_value(v.clone()).ok())
                    .unwrap_or_default();
                match address.parse::<SocketAddr>() {
                    Ok(target) if !paths.is_empty() => {
                        let fingerprint = msg
                            .get("fingerprint")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string());
                        let pin = msg
                            .get("pin")
                            .and_then(|v| v.as_str())
                            .map(|s| s.to_string());
                        let session_id = uuid::Uuid::new_v4().to_string();
                        let eng = engine.clone();
                        let sid = session_id.clone();
                        let handle = tokio::spawn(async move {
                            let _ = notchsend_core::client::send_files(
                                eng.clone(),
                                sid.clone(),
                                target,
                                fingerprint,
                                pin,
                                paths,
                            )
                            .await;
                            eng.unregister_outgoing(&sid);
                        });
                        engine.register_outgoing(&session_id, handle.abort_handle());
                        write_line(
                            &sink,
                            &result(&id, true, json!({"session_id": session_id})),
                        )
                        .await;
                    }
                    _ => {
                        write_line(
                            &sink,
                            &result(
                                &id,
                                false,
                                json!({"error": "bad_request", "message": "need address (ip:port) and non-empty paths"}),
                            ),
                        )
                        .await;
                    }
                }
            }
            "cancel" => {
                let session_id = msg
                    .get("session_id")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let ok = engine.cancel_incoming(&session_id)
                    || engine.abort_outgoing(&session_id);
                write_line(&sink, &result(&id, ok, json!({"session_id": session_id}))).await;
            }
            "rescan" => {
                engine.rescan_notify.notify_one();
                write_line(&sink, &result(&id, true, json!({}))).await;
            }
            "status" => {
                let st = json!({
                    "alias": engine.cfg.alias,
                    "fingerprint": engine.identity.fingerprint,
                    "port": engine.cfg.port,
                    "control_clients": engine.control_clients(),
                    "peers": engine.peers_snapshot().len(),
                    "pending_request": engine.pending_request_id(),
                    "download_dir": engine.cfg.download_dir.display().to_string(),
                    "auto_accept": engine.cfg.auto_accept,
                });
                write_line(&sink, &result(&id, true, json!({"status": st}))).await;
            }
            "peers" => {
                let peers = serde_json::to_value(engine.peers_snapshot())
                    .unwrap_or(Value::Null);
                write_line(&sink, &result(&id, true, json!({"peers": peers}))).await;
            }
            "set_config" | "shutdown" => {
                write_line(
                    &sink,
                    &result(
                        &id,
                        false,
                        json!({"error": "unsupported", "message": "not in Phase 0 spike"}),
                    ),
                )
                .await;
            }
            other => {
                write_line(
                    &sink,
                    &result(
                        &id,
                        false,
                        json!({"error": "unknown_type", "message": format!("unknown message type: {other}")}),
                    ),
                )
                .await;
            }
        }
    }
    ipc.remove_client(&sink).await;
    Ok(())
}
