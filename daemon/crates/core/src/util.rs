use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub fn hex_encode(bytes: &[u8], upper: bool) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        if upper {
            s.push_str(&format!("{b:02X}"));
        } else {
            s.push_str(&format!("{b:02x}"));
        }
    }
    s
}

/// Uppercase hex SHA-256 of a DER certificate = LocalSend device fingerprint.
pub fn fingerprint_of_der(der: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(der);
    hex_encode(&h.finalize(), true)
}

pub fn sha256_hex(data: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(data);
    hex_encode(&h.finalize(), false)
}

pub fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Strip any directory components / traversal from a peer-supplied file name.
/// Never returns an empty string, "." or "..".
pub fn sanitise_filename(name: &str) -> String {
    let base = name
        .replace('\\', "/")
        .split('/')
        .filter(|c| !c.is_empty() && *c != "." && *c != "..")
        .last()
        .unwrap_or("file")
        .trim()
        .trim_matches('.')
        .to_string();
    let cleaned: String = base
        .chars()
        .filter(|c| !c.is_control() && *c != '/')
        .collect();
    if cleaned.is_empty() || cleaned == "." || cleaned == ".." {
        "file".to_string()
    } else {
        cleaned
    }
}

/// Pick a name inside `dir` that does not exist yet: `name`, `name (1).ext`, ...
pub fn collision_free_path(dir: &Path, name: &str) -> PathBuf {
    let candidate = dir.join(name);
    if !candidate.exists() {
        return candidate;
    }
    let (stem, ext) = match name.rfind('.') {
        Some(i) if i > 0 => (name[..i].to_string(), name[i..].to_string()),
        _ => (name.to_string(), String::new()),
    };
    for n in 1..10_000 {
        let c = dir.join(format!("{stem} ({n}){ext}"));
        if !c.exists() {
            return c;
        }
    }
    dir.join(format!("{stem}-{}", uuid::Uuid::new_v4()))
}

/// Parse a query string into (key, value) pairs (no percent-decoding needed
/// for the values this protocol uses here: uuids and hex tokens).
pub fn parse_query(q: Option<&str>) -> Vec<(String, String)> {
    let mut out = Vec::new();
    if let Some(q) = q {
        for pair in q.split('&') {
            if let Some((k, v)) = pair.split_once('=') {
                out.push((k.to_string(), v.to_string()));
            } else if !pair.is_empty() {
                out.push((pair.to_string(), String::new()));
            }
        }
    }
    out
}

pub fn query_get<'a>(pairs: &'a [(String, String)], key: &str) -> Option<&'a str> {
    pairs.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str())
}
