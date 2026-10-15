//! Send client: prepare-upload + per-file upload over HTTPS with the server
//! certificate pinned to the fingerprint learned during discovery.

use crate::util::fingerprint_of_der;
use crate::Engine;
use anyhow::{anyhow, Result};
use bytes::Bytes;
use futures_util::{stream, StreamExt, TryStreamExt};
use http_body_util::{BodyExt, Full, StreamBody};
use hyper::body::Frame;
use hyper::{Method, Request, StatusCode};
use hyper_util::rt::TokioIo;
use notchsend_protocol::{FileDto, PrepareUploadRequest, PrepareUploadResponse};
use rustls::pki_types::ServerName;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::io::AsyncReadExt;
use tokio::net::TcpStream;

#[derive(Debug, Clone)]
pub struct SendFailure {
    pub code: String,
    pub message: String,
}

impl SendFailure {
    fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.to_string(),
            message: message.into(),
        }
    }
}

type SendReq<B> = hyper::client::conn::http1::SendRequest<B>;

async fn connect<B>(
    engine: &Engine,
    target: SocketAddr,
    expected_fp: Option<String>,
) -> Result<(SendReq<B>, String), SendFailure>
where
    B: hyper::body::Body + Send + 'static,
    B::Data: Send,
    B::Error: Into<Box<dyn std::error::Error + Send + Sync>>,
{
    let (cfg, captured) = crate::tls::client_config(&engine.identity, expected_fp)
        .map_err(|e| SendFailure::new("tls", e.to_string()))?;
    let connector = tokio_rustls::TlsConnector::from(cfg);
    let tcp = TcpStream::connect(target)
        .await
        .map_err(|e| SendFailure::new("io_error", format!("connect {target}: {e}")))?;
    let server_name = ServerName::try_from("localsend")
        .map_err(|e| SendFailure::new("tls", e.to_string()))?;
    let tls = connector
        .connect(server_name, tcp)
        .await
        .map_err(|e| SendFailure::new("tls", format!("handshake with {target}: {e}")))?;
    let presented_fp = captured
        .lock()
        .unwrap()
        .as_ref()
        .map(|der| fingerprint_of_der(der))
        .unwrap_or_default();
    let io = TokioIo::new(tls);
    let (sender, conn) = hyper::client::conn::http1::handshake(io)
        .await
        .map_err(|e| SendFailure::new("io_error", format!("http handshake: {e}")))?;
    tokio::spawn(async move {
        let _ = conn.await;
    });
    Ok((sender, presented_fp))
}

async fn hash_file(path: &PathBuf) -> Result<(u64, String)> {
    let mut f = tokio::fs::File::open(path).await?;
    let mut hasher = Sha256::new();
    let mut total: u64 = 0;
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = f.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
        total += n as u64;
    }
    Ok((total, crate::util::hex_encode(&hasher.finalize(), false)))
}

/// POST /register to a peer (discovery callback). Best effort.
pub async fn post_register(engine: Arc<Engine>, target: SocketAddr, expected_fp: Option<String>) {
    let _ = post_register_inner(engine, target, expected_fp).await;
}

async fn post_register_inner(
    engine: Arc<Engine>,
    target: SocketAddr,
    expected_fp: Option<String>,
) -> Result<()> {
    let (mut sender, _) = connect::<Full<Bytes>>(&engine, target, expected_fp)
        .await
        .map_err(|e| anyhow!(e.message))?;
    let body = serde_json::to_string(&engine.self_register())?;
    let req = Request::builder()
        .method(Method::POST)
        .uri("/api/localsend/v2/register")
        .header("content-type", "application/json")
        .header("content-length", body.len().to_string())
        .body(Full::new(Bytes::from(body)))?;
    let resp = sender.send_request(req).await?;
    let bytes = resp.into_body().collect().await?.to_bytes();
    if let Ok(dto) = serde_json::from_slice::<notchsend_protocol::RegisterDto>(&bytes) {
        engine.upsert_peer(crate::PeerRecord {
            fingerprint: dto.fingerprint.clone(),
            alias: dto.alias.clone(),
            device_model: dto.device_model.clone(),
            device_type: dto.device_type.clone(),
            ip: target.ip().to_string(),
            port: dto.port,
            protocol: dto.protocol.clone(),
            last_seen: crate::util::now_secs(),
        });
    }
    Ok(())
}

/// Send files to a peer. `local_session_id` is the IPC-level session id used
/// in emitted events; the protocol session id is handled internally.
/// Runs to completion (or failure) in the caller's task; the daemon spawns it
/// so it can be aborted via `Engine::abort_outgoing`.
pub async fn send_files(
    engine: Arc<Engine>,
    local_session_id: String,
    target: SocketAddr,
    expected_fp: Option<String>,
    pin: Option<String>,
    paths: Vec<PathBuf>,
) -> Result<(), SendFailure> {
    let result = send_files_inner(
        engine.clone(),
        &local_session_id,
        target,
        expected_fp,
        pin,
        &paths,
    )
    .await;
    if let Err(f) = &result {
        engine.emit(
            "session_failed",
            json!({
                "session_id": local_session_id,
                "direction": "send",
                "error": f.code,
                "message": f.message,
            }),
        );
    }
    result
}

async fn send_files_inner(
    engine: Arc<Engine>,
    local_session_id: &str,
    target: SocketAddr,
    expected_fp: Option<String>,
    pin: Option<String>,
    paths: &[PathBuf],
) -> Result<(), SendFailure> {
    if paths.is_empty() {
        return Err(SendFailure::new("bad_request", "no files to send"));
    }
    engine.emit(
        "session_state",
        json!({"session_id": local_session_id, "direction": "send", "state": "preparing"}),
    );

    // Build metadata (one read pass per file for size + SHA-256).
    let mut files_map: BTreeMap<String, FileDto> = BTreeMap::new();
    let mut local_paths: BTreeMap<String, PathBuf> = BTreeMap::new();
    for path in paths {
        let (size, sha) = hash_file(path)
            .await
            .map_err(|e| SendFailure::new("io_error", format!("read {}: {e}", path.display())))?;
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .ok_or_else(|| SendFailure::new("bad_request", format!("bad path {}", path.display())))?;
        let id = uuid::Uuid::new_v4().to_string();
        let mime = mime_guess::from_path(path)
            .first_or_octet_stream()
            .to_string();
        files_map.insert(
            id.clone(),
            FileDto {
                id: id.clone(),
                file_name: name,
                size,
                file_type: mime,
                sha256: Some(sha),
                preview: None,
                metadata: None,
            },
        );
        local_paths.insert(id, path.clone());
    }
    let total_size: u64 = files_map.values().map(|f| f.size).sum();

    // prepare-upload (response is suspended at the receiver while it waits
    // for its user's approval).
    let (mut sender, presented_fp) = connect::<Full<Bytes>>(&engine, target, expected_fp).await?;
    let prep = PrepareUploadRequest {
        info: engine.self_register(),
        files: files_map.clone(),
    };
    let body = serde_json::to_string(&prep).unwrap();
    let uri = match &pin {
        Some(p) => format!("/api/localsend/v2/prepare-upload?pin={p}"),
        None => "/api/localsend/v2/prepare-upload".to_string(),
    };
    let req = Request::builder()
        .method(Method::POST)
        .uri(uri)
        .header("content-type", "application/json")
        .header("content-length", body.len().to_string())
        .body(Full::new(Bytes::from(body)))
        .map_err(|e| SendFailure::new("protocol", e.to_string()))?;
    let resp = sender
        .send_request(req)
        .await
        .map_err(|e| SendFailure::new("io_error", format!("prepare-upload: {e}")))?;
    let status = resp.status();
    let resp_bytes = resp
        .into_body()
        .collect()
        .await
        .map_err(|e| SendFailure::new("io_error", e.to_string()))?
        .to_bytes();
    match status {
        StatusCode::OK => {}
        StatusCode::UNAUTHORIZED => {
            return Err(SendFailure::new(
                "pin_required",
                "peer requires a PIN (or the PIN was wrong)",
            ))
        }
        StatusCode::FORBIDDEN => {
            return Err(SendFailure::new("declined", "peer declined the transfer"))
        }
        StatusCode::CONFLICT => {
            return Err(SendFailure::new("busy", "peer is busy with another session"))
        }
        StatusCode::NO_CONTENT => {
            engine.emit(
                "session_completed",
                json!({"session_id": local_session_id, "direction": "send", "saved_paths": []}),
            );
            return Ok(());
        }
        other => {
            return Err(SendFailure::new(
                "protocol",
                format!("prepare-upload returned {other}: {}", String::from_utf8_lossy(&resp_bytes)),
            ))
        }
    }
    let prep_resp: PrepareUploadResponse = serde_json::from_slice(&resp_bytes)
        .map_err(|e| SendFailure::new("protocol", format!("bad prepare response: {e}")))?;
    let remote_session = prep_resp.session_id.clone();

    engine.emit(
        "session_started",
        json!({
            "session_id": local_session_id,
            "remote_session_id": remote_session,
            "direction": "send",
            "peer": {"address": target.to_string(), "fingerprint": presented_fp},
            "files": crate::files_json(&files_map),
            "total_size": total_size,
        }),
    );

    // Upload each accepted file on its own connection, at most 2 in parallel.
    let aggregate_done = Arc::new(AtomicU64::new(0));
    let jobs: Vec<(String, String)> = prep_resp
        .files
        .iter()
        .map(|(fid, tok)| (fid.clone(), tok.clone()))
        .collect();
    let results: Vec<Result<(), SendFailure>> = stream::iter(jobs)
        .map(|(file_id, token)| {
            let engine = engine.clone();
            let local_paths = &local_paths;
            let files_map = &files_map;
            let aggregate_done = aggregate_done.clone();
            let remote_session = remote_session.clone();
            async move {
                let dto = files_map.get(&file_id).cloned().unwrap();
                let path = local_paths.get(&file_id).cloned().unwrap();
                upload_one(
                    engine,
                    target,
                    local_session_id,
                    &remote_session,
                    dto,
                    token,
                    path,
                    aggregate_done,
                    total_size,
                )
                .await
            }
        })
        .buffer_unordered(2)
        .collect()
        .await;

    if let Some(Err(f)) = results.into_iter().find(|r| r.is_err()) {
        // Best effort: tell the receiver we are abandoning the session.
        let _ = post_cancel(&engine, target, &remote_session).await;
        return Err(f);
    }

    engine.emit(
        "session_completed",
        json!({
            "session_id": local_session_id,
            "direction": "send",
            "remote_session_id": remote_session,
            "saved_paths": [],
        }),
    );
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn upload_one(
    engine: Arc<Engine>,
    target: SocketAddr,
    local_session_id: &str,
    remote_session: &str,
    dto: FileDto,
    token: String,
    path: PathBuf,
    aggregate_done: Arc<AtomicU64>,
    total_size: u64,
) -> Result<(), SendFailure> {
    type BoxBody = http_body_util::combinators::BoxBody<Bytes, std::io::Error>;
    let (mut sender, _) = connect::<BoxBody>(&engine, target, None).await?;

    let file = tokio::fs::File::open(&path)
        .await
        .map_err(|e| SendFailure::new("io_error", format!("open {}: {e}", path.display())))?;

    let engine_progress = engine.clone();
    let session_id_owned = local_session_id.to_string();
    let file_id_owned = dto.id.clone();
    let file_size = dto.size;
    let file_done = Arc::new(AtomicU64::new(0));
    let stream_state = (
        file,
        vec![0u8; 64 * 1024],
        false,
        std::time::Instant::now(),
        file_done.clone(),
    );
    let body_stream = stream::unfold(stream_state, move |mut st| {
        let engine_progress = engine_progress.clone();
        let session_id_owned = session_id_owned.clone();
        let file_id_owned = file_id_owned.clone();
        let aggregate_done = aggregate_done.clone();
        async move {
            if st.2 {
                return None;
            }
            match st.0.read(&mut st.1).await {
                Ok(0) => None,
                Ok(n) => {
                    let chunk = Bytes::copy_from_slice(&st.1[..n]);
                    let done = st.4.fetch_add(n as u64, Ordering::SeqCst) + n as u64;
                    let agg = aggregate_done.fetch_add(n as u64, Ordering::SeqCst) + n as u64;
                    if st.3.elapsed() >= std::time::Duration::from_millis(100) || done == file_size {
                        st.3 = std::time::Instant::now();
                        let pct = if total_size > 0 {
                            (agg as f64 / total_size as f64 * 100.0) as u32
                        } else {
                            100
                        };
                        engine_progress.emit(
                            "progress",
                            json!({
                                "session_id": session_id_owned,
                                "direction": "send",
                                "file_id": file_id_owned,
                                "bytes_done": done,
                                "bytes_total": file_size,
                                "aggregate_done": agg,
                                "aggregate_total": total_size,
                                "aggregate_pct": pct,
                            }),
                        );
                    }
                    Some((Ok::<Bytes, std::io::Error>(chunk), st))
                }
                Err(e) => {
                    st.2 = true;
                    Some((Err(e), st))
                }
            }
        }
    });
    let body: BoxBody = BodyExt::boxed(StreamBody::new(
        body_stream.map_ok(|c| Frame::data(c)),
    ));

    let uri = format!(
        "/api/localsend/v2/upload?sessionId={remote_session}&fileId={}&token={token}",
        dto.id
    );
    let req = Request::builder()
        .method(Method::POST)
        .uri(uri)
        .header("content-type", "application/octet-stream")
        .header("content-length", dto.size.to_string())
        .body(body)
        .map_err(|e| SendFailure::new("protocol", e.to_string()))?;
    let resp = sender
        .send_request(req)
        .await
        .map_err(|e| SendFailure::new("io_error", format!("upload {}: {e}", dto.file_name)))?;
    let status = resp.status();
    let _ = resp.into_body().collect().await;
    if status != StatusCode::OK {
        return Err(SendFailure::new(
            "upload_failed",
            format!("upload of {} returned {status}", dto.file_name),
        ));
    }
    engine.emit(
        "file_completed",
        json!({
            "session_id": local_session_id,
            "file_id": dto.id,
            "name": dto.file_name,
            "saved_path": Value::Null,
        }),
    );
    Ok(())
}

async fn post_cancel(engine: &Engine, target: SocketAddr, remote_session: &str) -> Result<()> {
    let (mut sender, _) = connect::<Full<Bytes>>(engine, target, None)
        .await
        .map_err(|e| anyhow!(e.message))?;
    let req = Request::builder()
        .method(Method::POST)
        .uri(format!("/api/localsend/v2/cancel?sessionId={remote_session}"))
        .header("content-length", "0")
        .body(Full::new(Bytes::new()))?;
    let _ = sender.send_request(req).await;
    Ok(())
}
