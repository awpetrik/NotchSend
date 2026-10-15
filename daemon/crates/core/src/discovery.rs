//! UDP multicast discovery: announce on 224.0.0.167:53317, answer
//! announcements, keep the peer registry fresh, and call back via
//! POST /register (best effort). Degrades gracefully if multicast is
//! unavailable (e.g. sandboxed network): explicit-address sends still work.

use crate::{Engine, PeerRecord};
use notchsend_protocol::{MulticastDto, MULTICAST_ADDR};
use socket2::{Domain, Protocol, Socket, Type};
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::Arc;
use tokio::net::UdpSocket;

const MULTICAST_PORT: u16 = 53317;

fn build_socket() -> std::io::Result<UdpSocket> {
    let socket = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
    socket.set_reuse_address(true)?;
    #[cfg(unix)]
    {
        let _ = socket.set_reuse_port(true);
    }
    socket.set_nonblocking(true)?;
    let bind: SocketAddr = (Ipv4Addr::UNSPECIFIED, MULTICAST_PORT).into();
    socket.bind(&bind.into())?;
    let group: Ipv4Addr = MULTICAST_ADDR.parse().unwrap();
    socket.join_multicast_v4(&group, &Ipv4Addr::UNSPECIFIED)?;
    let _ = socket.set_multicast_loop_v4(true);
    let _ = socket.set_multicast_ttl_v4(32);
    let std_sock: std::net::UdpSocket = socket.into();
    UdpSocket::from_std(std_sock)
}

async fn announce(socket: &UdpSocket, engine: &Engine, announce: bool) {
    let mut dto = MulticastDto::from(&engine.self_register());
    dto.announce = announce;
    dto.announcement = announce;
    if let Ok(payload) = serde_json::to_vec(&dto) {
        let dest: SocketAddr = (MULTICAST_ADDR.parse::<Ipv4Addr>().unwrap(), MULTICAST_PORT).into();
        let _ = socket.send_to(&payload, dest).await;
    }
}

pub async fn run_discovery(engine: Arc<Engine>) {
    let socket = match build_socket() {
        Ok(s) => Arc::new(s),
        Err(e) => {
            tracing::warn!(error = %e, "multicast unavailable; discovery degraded (explicit-address sends still work)");
            // Still honour rescan as a no-op so the task does not spin.
            loop {
                engine.rescan_notify.notified().await;
            }
        }
    };

    // Announce on start (a few times, like the reference implementation).
    {
        let socket = socket.clone();
        let engine = engine.clone();
        tokio::spawn(async move {
            for _ in 0..3 {
                announce(&socket, &engine, true).await;
                tokio::time::sleep(std::time::Duration::from_millis(400)).await;
            }
            loop {
                tokio::select! {
                    _ = tokio::time::sleep(std::time::Duration::from_secs(30)) => {
                        announce(&socket, &engine, true).await;
                    }
                    _ = engine.rescan_notify.notified() => {
                        announce(&socket, &engine, true).await;
                    }
                }
            }
        });
    }

    let mut buf = vec![0u8; 8192];
    loop {
        let (n, src) = match socket.recv_from(&mut buf).await {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!(error = %e, "multicast recv failed");
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                continue;
            }
        };
        let dto: MulticastDto = match serde_json::from_slice(&buf[..n]) {
            Ok(d) => d,
            Err(_) => continue,
        };
        if dto.fingerprint == engine.identity.fingerprint || dto.fingerprint.is_empty() {
            continue; // never discover ourselves
        }
        engine.upsert_peer(PeerRecord {
            fingerprint: dto.fingerprint.clone(),
            alias: dto.alias.clone(),
            device_model: dto.device_model.clone(),
            device_type: dto.device_type.clone(),
            ip: src.ip().to_string(),
            port: dto.port,
            protocol: dto.protocol.clone(),
            last_seen: crate::util::now_secs(),
        });
        if dto.announce {
            // Reply (unicast) with announce=false, and call the announcer's
            // /register endpoint so it learns about us directly too.
            let mut reply = MulticastDto::from(&engine.self_register());
            reply.announce = false;
            reply.announcement = false;
            if let Ok(payload) = serde_json::to_vec(&reply) {
                let _ = socket.send_to(&payload, src).await;
            }
            if let Ok(ip) = src.ip().to_string().parse::<std::net::IpAddr>() {
                let target = SocketAddr::new(ip, dto.port);
                let engine2 = engine.clone();
                let fp = dto.fingerprint.clone();
                tokio::spawn(async move {
                    crate::client::post_register(engine2, target, Some(fp)).await;
                });
            }
        }
    }
}
