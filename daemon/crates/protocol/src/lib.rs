//! LocalSend protocol v2 DTOs (serde only, no I/O).
//!
//! Field names follow the official protocol README (`localsend/protocol`):
//! camelCase on the wire, `sessionId` on the prepare-upload response.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Protocol version string this implementation announces (`major.minor` of v2).
pub const PROTOCOL_VERSION: &str = "2.0";
/// Default LocalSend TCP/UDP port.
pub const DEFAULT_PORT: u16 = 53317;
/// Discovery multicast group.
pub const MULTICAST_ADDR: &str = "224.0.0.167";

pub const API_PREFIX: &str = "/api/localsend/v2";

/// Device information as returned by `GET /info`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InfoDto {
    pub alias: String,
    pub version: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_type: Option<String>,
    pub fingerprint: String,
    #[serde(default)]
    pub download: bool,
}

/// Device information exchanged via `POST /register` and embedded as `info`
/// in prepare-upload / prepare-download requests.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterDto {
    pub alias: String,
    pub version: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_type: Option<String>,
    pub fingerprint: String,
    pub port: u16,
    pub protocol: String,
    #[serde(default)]
    pub download: bool,
}

impl RegisterDto {
    pub fn to_info(&self) -> InfoDto {
        InfoDto {
            alias: self.alias.clone(),
            version: self.version.clone(),
            device_model: self.device_model.clone(),
            device_type: self.device_type.clone(),
            fingerprint: self.fingerprint.clone(),
            download: self.download,
        }
    }
}

impl From<&RegisterDto> for InfoDto {
    fn from(r: &RegisterDto) -> Self {
        r.to_info()
    }
}

/// UDP multicast announcement payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MulticastDto {
    pub alias: String,
    pub version: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_type: Option<String>,
    pub fingerprint: String,
    pub port: u16,
    pub protocol: String,
    #[serde(default)]
    pub download: bool,
    /// `true` in the initial broadcast (requests a response), `false` in replies.
    #[serde(default)]
    pub announce: bool,
    /// Mirrors `announce` in the reference Dart DTO (both fields are sent).
    #[serde(default)]
    pub announcement: bool,
}

impl From<&RegisterDto> for MulticastDto {
    fn from(r: &RegisterDto) -> Self {
        MulticastDto {
            alias: r.alias.clone(),
            version: r.version.clone(),
            device_model: r.device_model.clone(),
            device_type: r.device_type.clone(),
            fingerprint: r.fingerprint.clone(),
            port: r.port,
            protocol: r.protocol.clone(),
            download: r.download,
            announce: true,
            announcement: true,
        }
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct FileMetadata {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub modified: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub accessed: Option<String>,
}

/// One file entry in a prepare-upload request.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileDto {
    pub id: String,
    pub file_name: String,
    pub size: u64,
    pub file_type: String,
    /// Lowercase hex SHA-256 of the file contents, if the sender computed one.
    /// The reference Dart model historically calls this field `hash`; accept both.
    #[serde(default, alias = "hash", skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preview: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub metadata: Option<FileMetadata>,
}

/// `POST /prepare-upload` request body.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrepareUploadRequest {
    pub info: RegisterDto,
    /// Map of file id -> file metadata.
    pub files: BTreeMap<String, FileDto>,
}

/// `POST /prepare-upload` success response body.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrepareUploadResponse {
    pub session_id: String,
    /// Map of file id -> per-file upload token (accepted files only).
    pub files: BTreeMap<String, String>,
}
