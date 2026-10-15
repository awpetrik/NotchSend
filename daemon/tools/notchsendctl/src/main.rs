//! notchsendctl - debug/CLI client for the notchsendd control socket.
//!
//! Usage:
//!   notchsendctl [--socket PATH] status
//!   notchsendctl [--socket PATH] peers
//!   notchsendctl [--socket PATH] watch
//!   notchsendctl [--socket PATH] accept <request_id> [file_id ...]
//!   notchsendctl [--socket PATH] reject <request_id>
//!   notchsendctl [--socket PATH] cancel <session_id>
//!   notchsendctl [--socket PATH] rescan
//!   notchsendctl [--socket PATH] send --to <ip:port> [--fingerprint HEX] [--pin PIN] <paths...>
//!
//! `send` exits 0 on completion, 3 if the peer declined / the transfer
//! failed, 2 on usage or command errors.

use anyhow::{Context, Result};
use serde_json::{json, Value};
use std::path::PathBuf;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::mpsc;

struct Client {
    tx: tokio::sync::Mutex<tokio::net::unix::OwnedWriteHalf>,
    rx: mpsc::Receiver<Value>,
    counter: std::sync::atomic::AtomicU64,
}

impl Client {
    async fn connect(socket: &PathBuf) -> Result<Self> {
        let stream = UnixStream::connect(socket)
            .await
            .with_context(|| format!("connect {}", socket.display()))?;
        let (read_half, write_half) = stream.into_split();
        let (tx, rx) = mpsc::channel::<Value>(256);
        tokio::spawn(async move {
            let mut lines = BufReader::new(read_half).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                if let Ok(v) = serde_json::from_str::<Value>(&line) {
                    if tx.send(v).await.is_err() {
                        break;
                    }
                }
            }
        });
        let client = Self {
            tx: tokio::sync::Mutex::new(write_half),
            rx,
            counter: std::sync::atomic::AtomicU64::new(0),
        };
        client
            .send_raw(json!({"type": "hello", "client": "notchsendctl", "ipc_version": 1}))
            .await?;
        Ok(client)
    }

    async fn send_raw(&self, v: Value) -> Result<()> {
        let mut w = self.tx.lock().await;
        w.write_all(v.to_string().as_bytes()).await?;
        w.write_all(b"\n").await?;
        Ok(())
    }

    async fn send_command(&self, v: Value) -> Result<String> {
        let id = format!(
            "ctl-{}",
            self.counter
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst)
        );
        let mut obj = v;
        obj["id"] = json!(id);
        self.send_raw(obj).await?;
        Ok(id)
    }

    async fn next(&mut self) -> Option<Value> {
        self.rx.recv().await
    }

    /// Read until the result for `id` arrives; returns (result, messages seen meanwhile).
    async fn wait_result(&mut self, id: &str) -> Result<(Value, Vec<Value>)> {
        let mut seen = Vec::new();
        while let Some(m) = self.next().await {
            if m.get("type").and_then(|v| v.as_str()) == Some("result")
                && m.get("id").and_then(|v| v.as_str()) == Some(id)
            {
                return Ok((m, seen));
            }
            seen.push(m);
        }
        anyhow::bail!("connection closed while waiting for result {id}")
    }
}

fn default_socket() -> PathBuf {
    if let Ok(p) = std::env::var("NOTCHSEND_SOCKET") {
        return PathBuf::from(p);
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home).join(".notchsend/daemon.sock")
}

fn print_event(m: &Value) {
    if m.get("type").and_then(|v| v.as_str()) == Some("event") {
        let event = m.get("event").and_then(|v| v.as_str()).unwrap_or("?");
        match event {
            "progress" => {
                println!(
                    "progress {} {}% ({}/{})",
                    m.get("session_id").and_then(|v| v.as_str()).unwrap_or(""),
                    m.get("aggregate_pct").and_then(|v| v.as_u64()).unwrap_or(0),
                    m.get("aggregate_done").and_then(|v| v.as_u64()).unwrap_or(0),
                    m.get("aggregate_total").and_then(|v| v.as_u64()).unwrap_or(0),
                );
            }
            _ => println!("{}", m),
        }
    } else {
        println!("{}", m);
    }
}

#[tokio::main]
async fn main() {
    std::process::exit(match run().await {
        Ok(code) => code,
        Err(e) => {
            eprintln!("error: {e:#}");
            2
        }
    });
}

async fn run() -> Result<i32> {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let mut socket = default_socket();
    let mut args: Vec<String> = Vec::new();
    let mut i = 0;
    while i < argv.len() {
        if argv[i] == "--socket" && i + 1 < argv.len() {
            socket = PathBuf::from(&argv[i + 1]);
            i += 2;
        } else {
            args.push(argv[i].clone());
            i += 1;
        }
    }
    if args.is_empty() {
        eprintln!("usage: notchsendctl [--socket PATH] <status|peers|watch|accept|reject|cancel|rescan|send> ...");
        return Ok(2);
    }
    let mut client = Client::connect(&socket).await?;
    // Drain welcome + snapshot.
    let welcome = client.next().await;
    let snapshot = client.next().await;

    match args[0].as_str() {
        "status" => {
            if let Some(w) = &welcome {
                println!("daemon: {} alias={} fingerprint={} port={}",
                    w.get("daemon_version").and_then(|v| v.as_str()).unwrap_or("?"),
                    w.get("alias").and_then(|v| v.as_str()).unwrap_or("?"),
                    w.get("fingerprint").and_then(|v| v.as_str()).unwrap_or("?"),
                    w.get("port").and_then(|v| v.as_u64()).unwrap_or(0));
            }
            let id = client.send_command(json!({"type": "status"})).await?;
            let (res, _) = client.wait_result(&id).await?;
            println!("{}", serde_json::to_string_pretty(&res["status"]).unwrap_or_default());
            Ok(0)
        }
        "peers" => {
            let id = client.send_command(json!({"type": "peers"})).await?;
            let (res, _) = client.wait_result(&id).await?;
            println!("{}", serde_json::to_string_pretty(&res["peers"]).unwrap_or_default());
            Ok(0)
        }
        "watch" => {
            if let Some(s) = &snapshot {
                println!("{}", s);
            }
            while let Some(m) = client.next().await {
                print_event(&m);
            }
            Ok(0)
        }
        "accept" | "reject" => {
            if args.len() < 2 {
                eprintln!("usage: notchsendctl {} <request_id> [file_id ...]", args[0]);
                return Ok(2);
            }
            let mut cmd = json!({"type": args[0], "request_id": args[1]});
            if args[0] == "accept" && args.len() > 2 {
                cmd["file_ids"] = json!(args[2..]);
            }
            let id = client.send_command(cmd).await?;
            let (res, _) = client.wait_result(&id).await?;
            println!("{}", res);
            Ok(if res["ok"].as_bool().unwrap_or(false) { 0 } else { 2 })
        }
        "cancel" => {
            if args.len() < 2 {
                eprintln!("usage: notchsendctl cancel <session_id>");
                return Ok(2);
            }
            let id = client
                .send_command(json!({"type": "cancel", "session_id": args[1]}))
                .await?;
            let (res, _) = client.wait_result(&id).await?;
            println!("{}", res);
            Ok(if res["ok"].as_bool().unwrap_or(false) { 0 } else { 2 })
        }
        "rescan" => {
            let id = client.send_command(json!({"type": "rescan"})).await?;
            let (res, _) = client.wait_result(&id).await?;
            println!("{}", res);
            Ok(0)
        }
        "send" => {
            let mut to: Option<String> = None;
            let mut fingerprint: Option<String> = None;
            let mut pin: Option<String> = None;
            let mut paths: Vec<String> = Vec::new();
            let mut j = 1;
            while j < args.len() {
                match args[j].as_str() {
                    "--to" => {
                        to = args.get(j + 1).cloned();
                        j += 2;
                    }
                    "--fingerprint" => {
                        fingerprint = args.get(j + 1).cloned();
                        j += 2;
                    }
                    "--pin" => {
                        pin = args.get(j + 1).cloned();
                        j += 2;
                    }
                    other => {
                        paths.push(other.to_string());
                        j += 1;
                    }
                }
            }
            let to = match to {
                Some(t) => t,
                None => {
                    eprintln!("usage: notchsendctl send --to <ip:port> [--fingerprint HEX] [--pin PIN] <paths...>");
                    return Ok(2);
                }
            };
            let mut cmd = json!({"type": "send", "address": to, "paths": paths});
            if let Some(f) = fingerprint {
                cmd["fingerprint"] = json!(f);
            }
            if let Some(p) = pin {
                cmd["pin"] = json!(p);
            }
            let id = client.send_command(cmd).await?;
            let (res, _) = client.wait_result(&id).await?;
            if !res["ok"].as_bool().unwrap_or(false) {
                eprintln!("send command rejected: {res}");
                return Ok(2);
            }
            let session_id = res["session_id"].as_str().unwrap_or("").to_string();
            println!("session {session_id} started, waiting for completion...");
            while let Some(m) = client.next().await {
                let is_event = m.get("type").and_then(|v| v.as_str()) == Some("event");
                if !is_event {
                    continue;
                }
                print_event(&m);
                if m.get("session_id").and_then(|v| v.as_str()) != Some(session_id.as_str()) {
                    continue;
                }
                match m.get("event").and_then(|v| v.as_str()) {
                    Some("session_completed") => {
                        println!("SEND OK");
                        return Ok(0);
                    }
                    Some("session_failed") => {
                        eprintln!(
                            "SEND FAILED: {} {}",
                            m.get("error").and_then(|v| v.as_str()).unwrap_or("error"),
                            m.get("message").and_then(|v| v.as_str()).unwrap_or("")
                        );
                        return Ok(3);
                    }
                    Some("session_cancelled") => {
                        eprintln!("SEND CANCELLED");
                        return Ok(3);
                    }
                    _ => {}
                }
            }
            eprintln!("connection closed before send completed");
            Ok(3)
        }
        other => {
            eprintln!("unknown subcommand: {other}");
            Ok(2)
        }
    }
}
