//! Persistent TLS identity: one self-signed certificate per installation.
//! The LocalSend fingerprint is derived from the certificate DER, so the
//! certificate must be generated once and reused across restarts.

use crate::util::fingerprint_of_der;
use anyhow::{Context, Result};
use rustls_pki_types::{pem::PemObject, CertificateDer, PrivateKeyDer};
use std::path::{Path, PathBuf};

pub struct Identity {
    pub fingerprint: String,
    pub cert_der: Vec<u8>,
    pub cert_chain: Vec<CertificateDer<'static>>,
    pub key: PrivateKeyDer<'static>,
}

pub fn load_or_create(data_dir: &Path) -> Result<Identity> {
    let dir = data_dir.join("identity");
    std::fs::create_dir_all(&dir).with_context(|| format!("create {}", dir.display()))?;
    let cert_path: PathBuf = dir.join("cert.pem");
    let key_path: PathBuf = dir.join("key.pem");

    if cert_path.exists() && key_path.exists() {
        let cert_pem = std::fs::read(&cert_path).context("read cert.pem")?;
        let key_pem = std::fs::read(&key_path).context("read key.pem")?;
        let cert = CertificateDer::from_pem_slice(&cert_pem).context("parse cert.pem")?;
        let key = PrivateKeyDer::from_pem_slice(&key_pem).context("parse key.pem")?;
        let der = cert.as_ref().to_vec();
        let fingerprint = fingerprint_of_der(&der);
        return Ok(Identity {
            fingerprint,
            cert_der: der,
            cert_chain: vec![cert],
            key,
        });
    }

    // Generate a fresh RSA-2048 self-signed certificate, CN=LocalSend User,
    // mirroring the reference implementation's identity shape. rcgen cannot
    // generate RSA keys itself (ring has no RSA keygen), so the key comes
    // from the `rsa` crate and is handed to rcgen as PKCS#8 PEM.
    let mut params = rcgen::CertificateParams::new(vec!["localhost".to_string()])
        .context("certificate params")?;
    params
        .distinguished_name
        .push(rcgen::DnType::CommonName, "LocalSend User");
    let key_pair = {
        use rsa::pkcs8::EncodePrivateKey;
        let mut rng = rsa::rand_core::OsRng;
        let priv_key = rsa::RsaPrivateKey::new(&mut rng, 2048).context("generate RSA key")?;
        let pem = priv_key
            .to_pkcs8_pem(rsa::pkcs8::LineEnding::LF)
            .context("encode RSA key")?;
        rcgen::KeyPair::from_pem_and_sign_algo(&pem, &rcgen::PKCS_RSA_SHA256)
            .context("rcgen key pair from RSA key")?
    };
    let cert = params.self_signed(&key_pair).context("self-sign cert")?;
    let der = cert.der().as_ref().to_vec();

    std::fs::write(&cert_path, cert.pem()).context("write cert.pem")?;
    std::fs::write(&key_path, key_pair.serialize_pem()).context("write key.pem")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&key_path, std::fs::Permissions::from_mode(0o600));
    }

    let cert = CertificateDer::from_pem_slice(cert.pem().as_bytes()).context("re-parse cert")?;
    let key = PrivateKeyDer::from_pem_slice(key_pair.serialize_pem().as_bytes())
        .context("re-parse key")?;
    let fingerprint = fingerprint_of_der(&der);
    Ok(Identity {
        fingerprint,
        cert_der: der,
        cert_chain: vec![cert],
        key,
    })
}
