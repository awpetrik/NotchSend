//! TLS configuration.
//!
//! Server: requests a client certificate but does not require one and does
//! not validate it against any CA (LocalSend peers are self-signed; the
//! certificate's SHA-256 *is* the identity). Signature verification still
//! runs normally, so a presented certificate is cryptographically bound to
//! the connection.
//!
//! Client: pins the server certificate to the fingerprint learned during
//! discovery; optionally accepts any self-signed certificate (TOFU) and
//! reports which one was presented.

use crate::identity::Identity;
use crate::util::fingerprint_of_der;
use anyhow::Result;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::WebPkiSupportedAlgorithms;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::{
    ClientConfig, DigitallySignedStruct, DistinguishedName, Error, ServerConfig, SignatureScheme,
};
use std::sync::{Arc, Mutex};

fn sig_algs() -> WebPkiSupportedAlgorithms {
    rustls::crypto::ring::default_provider().signature_verification_algorithms
}

// ---------------------------------------------------------------- server ---

#[derive(Debug)]
pub struct AcceptAnyClientCert {
    subjects: Vec<DistinguishedName>,
}

impl AcceptAnyClientCert {
    pub fn new() -> Self {
        Self { subjects: Vec::new() }
    }
}

impl ClientCertVerifier for AcceptAnyClientCert {
    fn offer_client_auth(&self) -> bool {
        true
    }
    fn client_auth_mandatory(&self) -> bool {
        false // request, never require
    }
    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        &self.subjects
    }
    fn verify_client_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _now: UnixTime,
    ) -> Result<ClientCertVerified, Error> {
        Ok(ClientCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        rustls::crypto::verify_tls12_signature(message, cert, dss, &sig_algs())
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &sig_algs())
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        sig_algs().supported_schemes()
    }
}

pub fn server_config(identity: &Identity) -> Result<Arc<ServerConfig>> {
    let cfg = ServerConfig::builder()
        .with_client_cert_verifier(Arc::new(AcceptAnyClientCert::new()))
        .with_single_cert(identity.cert_chain.clone(), identity.key.clone_key())?;
    Ok(Arc::new(cfg))
}

// ---------------------------------------------------------------- client ---

#[derive(Debug)]
pub struct PinnedServerCertVerifier {
    /// Expected uppercase-hex fingerprint; `None` = accept any self-signed
    /// certificate and record it in `captured` (trust on first use).
    pub expected: Option<String>,
    pub captured: Arc<Mutex<Option<Vec<u8>>>>,
}

impl ServerCertVerifier for PinnedServerCertVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, Error> {
        let fp = fingerprint_of_der(end_entity.as_ref());
        if let Ok(mut c) = self.captured.lock() {
            *c = Some(end_entity.as_ref().to_vec());
        }
        if let Some(expected) = &self.expected {
            if !expected.eq_ignore_ascii_case(&fp) {
                return Err(Error::General(format!(
                    "certificate fingerprint mismatch: expected {expected}, peer presented {fp}"
                )));
            }
        }
        Ok(ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        rustls::crypto::verify_tls12_signature(message, cert, dss, &sig_algs())
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &sig_algs())
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        sig_algs().supported_schemes()
    }
}

pub fn client_config(
    identity: &Identity,
    expected_fingerprint: Option<String>,
) -> Result<(Arc<ClientConfig>, Arc<Mutex<Option<Vec<u8>>>>)> {
    let captured = Arc::new(Mutex::new(None));
    let verifier = Arc::new(PinnedServerCertVerifier {
        expected: expected_fingerprint,
        captured: captured.clone(),
    });
    let cfg = ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_client_auth_cert(identity.cert_chain.clone(), identity.key.clone_key())?;
    Ok((Arc::new(cfg), captured))
}
