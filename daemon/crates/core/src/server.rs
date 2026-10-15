//! HTTPS receive server: info, register, prepare-upload (with the approval
//! gate), upload (streamed to disk), cancel.

use crate::util::{
    collision_free_path, fingerprint_of_der, parse_query, query_get, sanitise_filename,
};
use crate::{Decision, Engine, FileState, InSession, Pending};
use anyhow::Result;
use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::body::Incoming;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use notchsend_protocol::{
    FileDto, PrepareUploadRequest, PrepareUploadResponse, RegisterDto,
};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::convert::Infallible;
use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use tokio::io::AsyncWriteExt;
use tokio::net::TcpListener;
use tokio::sync::oneshot;

type Resp = Response<Full<Bytes>>;

fn resp(status: StatusCode, body: &str) -> Resp {
    Response::builder()
        .status(status)
        .header("content-type", "text/plain")
        .body(Full::new(Bytes::from(body.to_string())))
        .unwrap()
}

fn json_resp(status: StatusCode, v: &Value) -> Resp {
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(Full::new(Bytes::from(v.to_string())))
        .unwrap()
}

fn json_resp_obj<T: serde::Serialize>(status: StatusCode, v: &T) -> Resp {
    json_resp(status, &serde_json::to_value(v).unwrap_or(Value::Null))
}

pub async fn run_server(engine: Arc<Engine>) -> Result<()> {
    let tls_cfg = crate::tls::server_config(&engine.identity)?;
    let acceptor = tokio_rustls::TlsAcceptor::from(tls_cfg);
    let addr = SocketAddr::from(([0, 0, 0, 0], engine.cfg.port));
    let listener = TcpListener::bind(addr).await?;
    tracing::info!(%addr, alias = %engine.cfg.alias, fingerprint = %engine.identity.fingerprint, "https server listening");
    loop {
        let (tcp, remote) = match listener.accept().await {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!(error = %e, "tcp accept failed");
                continue;
            }
        };
        let acceptor = acceptor.clone();
        let engine = engine.clone();
        tokio::spawn(async move {
            let tls = match acceptor.accept(tcp).await {
                Ok(t) => t,
                Err(e) => {
                    tracing::debug!(error = %e, %remote, "tls accept failed");
                    return;
                }
            };
            // Sender fingerprint from the presented client certificate, if any.
            let peer_fp = {
                let (_, conn) = tls.get_ref();
                conn.peer_certificates()
                    .and_then(|certs| certs.first())
                    .map(|c| fingerprint_of_der(c.as_ref()))
            };
            let io = TokioIo::new(tls);
            let svc = service_fn(move |req: Request<Incoming>| {
                let engine = engine.clone();
                let peer_fp = peer_fp.clone();
                async move {
                    Ok::<Resp, Infallible>(
                        handle(engine, req, remote.ip(), peer_fp).await,
                    )
                }
            });
            if let Err(e) = hyper::server::conn::http1::Builder::new()
                .serve_connection(io, svc)
                .await
            {
                tracing::debug!(error = %e, %remote, "connection ended");
            }
        });
    }
}

async fn handle(
    engine: Arc<Engine>,
    req: Request<Incoming>,
    remote_ip: IpAddr,
    peer_fp: Option<String>,
) -> Resp {
    let method = req.method().clone();
    let path = req.uri().path().to_string();
    let query = parse_query(req.uri().query());
    match (method, path.as_str()) {
        (Method::GET, "/api/localsend/v2/info") => {
            json_resp_obj(StatusCode::OK, &engine.self_register().to_info())
        }
        (Method::POST, "/api/localsend/v2/register") => {
            handle_register(engine, req, remote_ip, peer_fp).await
        }
        (Method::POST, "/api/localsend/v2/prepare-upload") => {
            handle_prepare_upload(engine, req, remote_ip, peer_fp, &query).await
        }
        (Method::POST, "/api/localsend/v2/upload") => {
            handle_upload(engine, req, remote_ip, &query).await
        }
        (Method::POST, "/api/localsend/v2/cancel") => {
            handle_cancel(engine, &query).await
        }
        _ => resp(StatusCode::NOT_FOUND, "not found"),
    }
}

async fn collect_json<T: serde::de::DeserializeOwned>(req: Request<Incoming>) -> Option<T> {
    let bytes = req.into_body().collect().await.ok()?.to_bytes();
    serde_json::from_slice(&bytes).ok()
}

async fn handle_register(
    engine: Arc<Engine>,
    req: Request<Incoming>,
    remote_ip: IpAddr,
    peer_fp: Option<String>,
) -> Resp {
    let dto: RegisterDto = match collect_json(req).await {
        Some(d) => d,
        None => return resp(StatusCode::BAD_REQUEST, "invalid body"),
    };
    let fingerprint = peer_fp.unwrap_or_else(|| dto.fingerprint.clone());
    engine.upsert_peer(crate::PeerRecord {
        fingerprint,
        alias: dto.alias.clone(),
        device_model: dto.device_model.clone(),
        device_type: dto.device_type.clone(),
        ip: remote_ip.to_string(),
        port: dto.port,
        protocol: dto.protocol.clone(),
        last_seen: crate::util::now_secs(),
    });
    json_resp_obj(StatusCode::OK, &engine.self_register())
}

async fn handle_prepare_upload(
    engine: Arc<Engine>,
    req: Request<Incoming>,
    remote_ip: IpAddr,
    peer_fp: Option<String>,
    query: &[(String, String)],
) -> Resp {
    // PIN gate first (401 before anything else, like the reference).
    if !engine.cfg.pin.is_empty() {
        match query_get(query, "pin") {
            Some(p) if p == engine.cfg.pin => {}
            _ => return resp(StatusCode::UNAUTHORIZED, "PIN required or invalid"),
        }
    }
    let body: PrepareUploadRequest = match collect_json(req).await {
        Some(b) => b,
        None => return resp(StatusCode::BAD_REQUEST, "invalid body"),
    };
    if body.files.is_empty() {
        return resp(StatusCode::NO_CONTENT, "no files");
    }
    let sender_fp = peer_fp.unwrap_or_else(|| body.info.fingerprint.clone());
    let total_size: u64 = body.files.values().map(|f| f.size).sum();

    // Session slot: one pending or active session at a time.
    {
        let inner = engine.inner.lock().unwrap();
        if inner.pending.is_some() || inner.session.is_some() {
            return resp(StatusCode::CONFLICT, "blocked by another session");
        }
    }

    // Decide: auto-accept, immediate decline (nobody can answer), or suspend.
    let decision = if engine.cfg.auto_accept {
        Decision::Accept(None)
    } else if engine.control_clients() == 0 {
        tracing::info!("prepare-upload declined immediately: no control client connected");
        return resp(StatusCode::FORBIDDEN, "rejected");
    } else {
        let request_id = uuid::Uuid::new_v4().to_string();
        let (tx, rx) = oneshot::channel::<Decision>();
        {
            let mut inner = engine.inner.lock().unwrap();
            // Re-check the slot inside the lock.
            if inner.pending.is_some() || inner.session.is_some() {
                return resp(StatusCode::CONFLICT, "blocked by another session");
            }
            inner.pending = Some(Pending {
                request_id: request_id.clone(),
                sender: body.info.clone(),
                sender_ip: remote_ip,
                sender_fingerprint: sender_fp.clone(),
                files: body.files.clone(),
                total_size,
                decision_tx: Some(tx),
            });
        }
        engine.emit(
            "incoming_request",
            json!({
                "request_id": request_id,
                "sender": serde_json::to_value(&body.info).unwrap_or(Value::Null),
                "sender_ip": remote_ip.to_string(),
                "sender_fingerprint": sender_fp,
                "files": crate::files_json(&body.files),
                "total_size": total_size,
            }),
        );
        let timeout = engine.cfg.approval_timeout;
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(d)) => d,
            _ => {
                // Timeout or the UI went away: clear pending, notify, decline.
                let mut inner = engine.inner.lock().unwrap();
                if let Some(p) = &inner.pending {
                    if p.request_id == request_id {
                        inner.pending = None;
                    }
                }
                drop(inner);
                engine.emit("request_expired", json!({"request_id": request_id}));
                return resp(StatusCode::FORBIDDEN, "rejected (timeout)");
            }
        }
    };

    match decision {
        Decision::Reject => {
            let mut inner = engine.inner.lock().unwrap();
            inner.pending = None;
            resp(StatusCode::FORBIDDEN, "rejected")
        }
        Decision::Accept(file_ids) => {
            let accepted: Vec<&FileDto> = body
                .files
                .values()
                .filter(|f| file_ids.as_ref().map(|ids| ids.contains(&f.id)).unwrap_or(true))
                .collect();
            {
                let mut inner = engine.inner.lock().unwrap();
                inner.pending = None;
            }
            if accepted.is_empty() {
                return resp(StatusCode::NO_CONTENT, "no files accepted");
            }
            let session_id = uuid::Uuid::new_v4().to_string();
            let mut tokens: BTreeMap<String, String> = BTreeMap::new();
            let mut files: HashMap<String, Arc<FileState>> = HashMap::new();
            let mut order: Vec<String> = Vec::new();
            for f in &accepted {
                let token = uuid::Uuid::new_v4().to_string();
                tokens.insert(f.id.clone(), token.clone());
                order.push(f.id.clone());
                files.insert(
                    f.id.clone(),
                    Arc::new(FileState {
                        dto: (*f).clone(),
                        token,
                        status: std::sync::Mutex::new("queued".to_string()),
                        bytes_done: AtomicU64::new(0),
                        part_path: std::sync::Mutex::new(None),
                        final_path: std::sync::Mutex::new(None),
                    }),
                );
            }
            let accepted_total: u64 = accepted.iter().map(|f| f.size).sum();
            let session = Arc::new(InSession {
                session_id: session_id.clone(),
                sender_ip: remote_ip,
                sender_alias: body.info.alias.clone(),
                files,
                order: order.clone(),
                total_size: accepted_total,
                cancelled: Arc::new(AtomicBool::new(false)),
            });
            {
                let mut inner = engine.inner.lock().unwrap();
                if inner.session.is_some() {
                    return resp(StatusCode::CONFLICT, "blocked by another session");
                }
                inner.session = Some(session);
            }
            engine.emit(
                "session_started",
                json!({
                    "session_id": session_id,
                    "direction": "receive",
                    "peer": serde_json::to_value(&body.info).unwrap_or(Value::Null),
                    "files": crate::files_json(&body.files),
                    "total_size": accepted_total,
                }),
            );
            json_resp_obj(
                StatusCode::OK,
                &PrepareUploadResponse {
                    session_id,
                    files: tokens,
                },
            )
        }
    }
}

async fn handle_upload(
    engine: Arc<Engine>,
    req: Request<Incoming>,
    remote_ip: IpAddr,
    query: &[(String, String)],
) -> Resp {
    let (session_id, file_id, token) = match (
        query_get(query, "sessionId"),
        query_get(query, "fileId"),
        query_get(query, "token"),
    ) {
        (Some(s), Some(f), Some(t)) => (s.to_string(), f.to_string(), t.to_string()),
        _ => return resp(StatusCode::BAD_REQUEST, "missing parameters"),
    };
    let session = {
        let inner = engine.inner.lock().unwrap();
        inner.session.clone()
    };
    let session = match session {
        Some(s) if s.session_id == session_id => s,
        _ => return resp(StatusCode::CONFLICT, "no such session"),
    };
    if session.sender_ip != remote_ip {
        return resp(StatusCode::FORBIDDEN, "source IP mismatch");
    }
    let file = match session.files.get(&file_id) {
        Some(f) => f.clone(),
        None => return resp(StatusCode::FORBIDDEN, "unknown file"),
    };
    if file.token != token {
        return resp(StatusCode::FORBIDDEN, "invalid token");
    }
    {
        let mut st = file.status.lock().unwrap();
        if *st != "queued" {
            return resp(StatusCode::CONFLICT, "file already transferred");
        }
        *st = "transferring".to_string();
    }

    // Stream the body to <download_dir>/<sanitised>.part
    let safe_name = sanitise_filename(&file.dto.file_name);
    let part_path = engine.cfg.download_dir.join(format!("{safe_name}.part"));
    {
        let mut pp = file.part_path.lock().unwrap();
        *pp = Some(part_path.clone());
    }
    if let Some(parent) = part_path.parent() {
        let _ = tokio::fs::create_dir_all(parent).await;
    }
    let mut out = match tokio::fs::File::create(&part_path).await {
        Ok(f) => f,
        Err(e) => {
            fail_file(&engine, &session, &file, "io_error", &format!("create .part: {e}"));
            return resp(StatusCode::INTERNAL_SERVER_ERROR, "cannot write file");
        }
    };

    let mut hasher = Sha256::new();
    let mut received: u64 = 0;
    let mut last_emit = std::time::Instant::now();
    let session_done_before: u64 = session
        .files
        .values()
        .map(|f| f.bytes_done.load(Ordering::SeqCst))
        .sum();
    let mut body = req.into_body();
    let mut stream_error: Option<String> = None;
    while let Some(frame) = body.frame().await {
        if session.cancelled.load(Ordering::SeqCst) {
            stream_error = Some("cancelled".to_string());
            break;
        }
        match frame {
            Ok(frame) => {
                if let Ok(data) = frame.into_data() {
                    if let Err(e) = out.write_all(&data).await {
                        stream_error = Some(format!("write: {e}"));
                        break;
                    }
                    hasher.update(&data);
                    received += data.len() as u64;
                    file.bytes_done.store(received, Ordering::SeqCst);
                    if received > file.dto.size {
                        stream_error = Some("size exceeded declared size".to_string());
                        break;
                    }
                    if last_emit.elapsed() >= std::time::Duration::from_millis(100) {
                        last_emit = std::time::Instant::now();
                        emit_progress(&engine, &session, &file, session_done_before);
                    }
                }
            }
            Err(e) => {
                stream_error = Some(format!("body: {e}"));
                break;
            }
        }
    }
    let _ = out.flush().await;
    drop(out);
    emit_progress(&engine, &session, &file, session_done_before);

    if let Some(err) = stream_error {
        let code = if err == "cancelled" { "cancelled" } else { "io_error" };
        fail_file(&engine, &session, &file, code, &err);
        let _ = tokio::fs::remove_file(&part_path).await;
        return resp(StatusCode::INTERNAL_SERVER_ERROR, "transfer failed");
    }
    if received != file.dto.size {
        fail_file(
            &engine,
            &session,
            &file,
            "size_mismatch",
            &format!("expected {} bytes, got {received}", file.dto.size),
        );
        let _ = tokio::fs::remove_file(&part_path).await;
        return resp(StatusCode::INTERNAL_SERVER_ERROR, "size mismatch");
    }

    // Verify SHA-256 when the sender provided one.
    {
        let mut st = file.status.lock().unwrap();
        *st = "verifying".to_string();
    }
    if let Some(expected) = &file.dto.sha256 {
        let actual = crate::util::hex_encode(&hasher.finalize(), false);
        if !actual.eq_ignore_ascii_case(expected) {
            fail_file(
                &engine,
                &session,
                &file,
                "checksum_mismatch",
                "sha256 mismatch",
            );
            let _ = tokio::fs::remove_file(&part_path).await;
            return resp(StatusCode::UNPROCESSABLE_ENTITY, "checksum mismatch");
        }
    }

    // Atomic rename to a collision-safe final name.
    let final_path = collision_free_path(&engine.cfg.download_dir, &safe_name);
    if let Err(e) = tokio::fs::rename(&part_path, &final_path).await {
        fail_file(&engine, &session, &file, "io_error", &format!("rename: {e}"));
        return resp(StatusCode::INTERNAL_SERVER_ERROR, "rename failed");
    }
    {
        let mut st = file.status.lock().unwrap();
        *st = "done".to_string();
        let mut fp = file.final_path.lock().unwrap();
        *fp = Some(final_path.display().to_string());
    }
    engine.emit(
        "file_completed",
        json!({
            "session_id": session.session_id,
            "file_id": file.dto.id,
            "name": file.dto.file_name,
            "saved_path": final_path.display().to_string(),
        }),
    );
    maybe_complete_session(&engine, &session);
    resp(StatusCode::OK, "ok")
}

fn emit_progress(engine: &Engine, session: &InSession, file: &FileState, done_before: u64) {
    let total_done: u64 = session
        .files
        .values()
        .map(|f| f.bytes_done.load(Ordering::SeqCst))
        .sum::<u64>()
        .max(done_before);
    let pct = if session.total_size > 0 {
        (total_done as f64 / session.total_size as f64 * 100.0) as u32
    } else {
        100
    };
    engine.emit(
        "progress",
        json!({
            "session_id": session.session_id,
            "direction": "receive",
            "file_id": file.dto.id,
            "bytes_done": file.bytes_done.load(Ordering::SeqCst),
            "bytes_total": file.dto.size,
            "aggregate_done": total_done,
            "aggregate_total": session.total_size,
            "aggregate_pct": pct,
        }),
    );
}

fn fail_file(engine: &Engine, session: &InSession, file: &FileState, code: &str, message: &str) {
    {
        let mut st = file.status.lock().unwrap();
        *st = "failed".to_string();
    }
    engine.emit(
        "session_failed",
        json!({
            "session_id": session.session_id,
            "direction": "receive",
            "file_id": file.dto.id,
            "error": code,
            "message": message,
        }),
    );
    let mut inner = engine.inner.lock().unwrap();
    if let Some(s) = &inner.session {
        if s.session_id == session.session_id {
            inner.session = None;
        }
    }
}

fn maybe_complete_session(engine: &Engine, session: &InSession) {
    let all_done = session
        .files
        .values()
        .all(|f| *f.status.lock().unwrap() == "done");
    if !all_done {
        return;
    }
    let saved: Vec<String> = session
        .order
        .iter()
        .filter_map(|id| session.files.get(id))
        .filter_map(|f| f.final_path.lock().unwrap().clone())
        .collect();
    {
        let mut inner = engine.inner.lock().unwrap();
        if let Some(s) = &inner.session {
            if s.session_id == session.session_id {
                inner.session = None;
            }
        }
    }
    engine.emit(
        "session_completed",
        json!({
            "session_id": session.session_id,
            "direction": "receive",
            "saved_paths": saved,
        }),
    );
}

async fn handle_cancel(engine: Arc<Engine>, query: &[(String, String)]) -> Resp {
    let session_id = query_get(query, "sessionId").unwrap_or("");
    let mut cancelled = false;
    let session = {
        let mut inner = engine.inner.lock().unwrap();
        match inner.session.as_ref() {
            Some(s) if s.session_id == session_id => inner.session.take(),
            _ => None,
        }
    };
    if let Some(s) = session {
        s.cancelled.store(true, Ordering::SeqCst);
        for f in s.files.values() {
            if *f.status.lock().unwrap() != "done" {
                let part = f.part_path.lock().unwrap().clone();
                if let Some(p) = part {
                    let _ = tokio::fs::remove_file(p).await;
                }
            }
        }
        cancelled = true;
    }
    if cancelled {
        engine.emit(
            "session_cancelled",
            json!({"session_id": session_id, "by": "peer"}),
        );
    }
    resp(StatusCode::OK, "ok")
}
