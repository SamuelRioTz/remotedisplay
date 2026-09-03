#[cfg(not(target_os = "ios"))]
use hbb_common::whoami;
use hbb_common::{
    allow_err,
    anyhow::bail,
    config::Config,
    config::{self, RENDEZVOUS_PORT},
    log,
    protobuf::Message as _,
    rendezvous_proto::*,
    tokio::{
        self,
        sync::mpsc::{unbounded_channel, UnboundedReceiver, UnboundedSender},
    },
    ResultType,
};

use std::{
    collections::{HashMap, HashSet},
    net::{IpAddr, Ipv4Addr, SocketAddr, ToSocketAddrs, UdpSocket},
    time::Instant,
};

type Message = RendezvousMessage;

#[cfg(not(target_os = "ios"))]
pub(super) fn start_listening() -> ResultType<()> {
    let addr = SocketAddr::from(([0, 0, 0, 0], get_broadcast_port()));
    let socket = std::net::UdpSocket::bind(addr)?;
    socket.set_read_timeout(Some(std::time::Duration::from_millis(1000)))?;
    log::info!("lan discovery listener started");
    loop {
        let mut buf = [0; 2048];
        if let Ok((len, addr)) = socket.recv_from(&mut buf) {
            if let Ok(msg_in) = Message::parse_from_bytes(&buf[0..len]) {
                match msg_in.union {
                    Some(rendezvous_message::Union::PeerDiscovery(p)) => {
                        if p.cmd == "ping"
                            && config::option2bool(
                                "enable-lan-discovery",
                                &Config::get_option("enable-lan-discovery"),
                            )
                        {
                            let id = Config::get_id();
                            if p.id == id {
                                continue;
                            }
                            if let Some(self_addr) = get_ipaddr_by_peer(&addr) {
                                let mut msg_out = Message::new();
                                let mut hostname = crate::whoami_hostname();
                                // The default hostname is "localhost" which is a bit confusing
                                if hostname == "localhost" {
                                    hostname = "unknown".to_owned();
                                }
                                let peer = PeerDiscovery {
                                    cmd: "pong".to_owned(),
                                    mac: get_mac(&self_addr),
                                    id,
                                    hostname,
                                    username: crate::platform::get_active_username(),
                                    platform: whoami::platform().to_string(),
                                    ..Default::default()
                                };
                                msg_out.set_peer_discovery(peer);
                                socket.send_to(&msg_out.write_to_bytes()?, addr).ok();
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
    }
}

#[tokio::main(flavor = "current_thread")]
pub async fn discover() -> ResultType<()> {
    let sockets = send_query()?;
    let rx = spawn_wait_responses(sockets);
    handle_received_peers(rx).await?;

    log::info!("discover ping done");
    Ok(())
}

pub fn send_wol(id: String) {
    let interfaces = default_net::get_interfaces();
    for peer in &config::LanPeers::load().peers {
        if peer.id == id {
            for (_, mac) in peer.ip_mac.iter() {
                if let Ok(mac_addr) = mac.parse() {
                    for interface in &interfaces {
                        for ipv4 in &interface.ipv4 {
                            // remove below mask check to avoid unexpected bug
                            // if (u32::from(ipv4.addr) & u32::from(ipv4.netmask)) == (u32::from(peer_ip) & u32::from(ipv4.netmask))
                            log::info!("Send wol to {mac_addr} of {}", ipv4.addr);
                            allow_err!(wol::send_wol(mac_addr, None, Some(IpAddr::V4(ipv4.addr))));
                        }
                    }
                }
            }
            break;
        }
    }
}

#[inline]
fn get_broadcast_port() -> u16 {
    (RENDEZVOUS_PORT + 3) as _
}

fn get_mac(_ip: &IpAddr) -> String {
    #[cfg(not(target_os = "ios"))]
    if let Ok(mac) = get_mac_by_ip(_ip) {
        mac.to_string()
    } else {
        "".to_owned()
    }
    #[cfg(target_os = "ios")]
    "".to_owned()
}

#[cfg(not(target_os = "ios"))]
fn get_mac_by_ip(ip: &IpAddr) -> ResultType<String> {
    for interface in default_net::get_interfaces() {
        match ip {
            IpAddr::V4(local_ipv4) => {
                if interface.ipv4.iter().any(|x| x.addr == *local_ipv4) {
                    if let Some(mac_addr) = interface.mac_addr {
                        return Ok(mac_addr.address());
                    }
                }
            }
            IpAddr::V6(local_ipv6) => {
                if interface.ipv6.iter().any(|x| x.addr == *local_ipv6) {
                    if let Some(mac_addr) = interface.mac_addr {
                        return Ok(mac_addr.address());
                    }
                }
            }
        }
    }
    bail!("No interface found for ip: {:?}", ip);
}

// Mainly from https://github.com/shellrow/default-net/blob/cf7ca24e7e6e8e566ed32346c9cfddab3f47e2d6/src/interface/shared.rs#L4
fn get_ipaddr_by_peer<A: ToSocketAddrs>(peer: A) -> Option<IpAddr> {
    let socket = match UdpSocket::bind("0.0.0.0:0") {
        Ok(s) => s,
        Err(_) => return None,
    };

    match socket.connect(peer) {
        Ok(()) => (),
        Err(_) => return None,
    };

    match socket.local_addr() {
        Ok(addr) => return Some(addr.ip()),
        Err(_) => return None,
    };
}

fn create_broadcast_sockets() -> Vec<UdpSocket> {
    let mut ipv4s = Vec::new();
    // TODO: maybe we should use a better way to get ipv4 addresses.
    // But currently, it's ok to use `[Ipv4Addr::UNSPECIFIED]` for discovery.
    // `default_net::get_interfaces()` causes undefined symbols error when `flutter build` on iOS simulator x86_64
    #[cfg(not(any(target_os = "ios")))]
    for interface in default_net::get_interfaces() {
        for ipv4 in &interface.ipv4 {
            ipv4s.push(ipv4.addr.clone());
        }
    }
    ipv4s.push(Ipv4Addr::UNSPECIFIED); // for robustness
    let mut sockets = Vec::new();
    for v4_addr in ipv4s {
        // removing v4_addr.is_private() check, https://github.com/rustdesk/rustdesk/issues/4663
        if let Ok(s) = UdpSocket::bind(SocketAddr::from((v4_addr, 0))) {
            if s.set_broadcast(true).is_ok() {
                sockets.push(s);
            }
        }
    }
    sockets
}

fn send_query() -> ResultType<Vec<UdpSocket>> {
    let sockets = create_broadcast_sockets();
    if sockets.is_empty() {
        bail!("Found no bindable ipv4 addresses");
    }

    let mut msg_out = Message::new();
    // We may not be able to get the mac address on mobile platforms.
    // So we need to use the id to avoid discovering ourselves.
    #[cfg(any(target_os = "android", target_os = "ios"))]
    let id = crate::ui_interface::get_id();
    // `crate::ui_interface::get_id()` will cause error:
    // `get_id()` uses async code with `current_thread`, which is not allowed in this context.
    //
    // No need to get id for desktop platforms.
    // We can use the mac address to identify the device.
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    let id = "".to_owned();
    let peer = PeerDiscovery {
        cmd: "ping".to_owned(),
        id,
        ..Default::default()
    };
    msg_out.set_peer_discovery(peer);
    let out = msg_out.write_to_bytes()?;
    let maddr = SocketAddr::from(([255, 255, 255, 255], get_broadcast_port()));
    for socket in &sockets {
        allow_err!(socket.send_to(&out, maddr));
    }
    // remotedisplay: in addition to the broadcast, UNICAST ping each host in the
    // local subnets (and Tailscale peers). Covers iOS, where broadcast is
    // blocked without the multicast entitlement, and routed networks (Tailscale)
    // where the broadcast doesn't reach; the host still responds with its identity.
    send_unicast_pings(&sockets, &out);
    log::info!("discover ping sent");
    Ok(sockets)
}

static LAST_UNICAST_PING: std::sync::Mutex<Option<std::time::Instant>> =
    std::sync::Mutex::new(None);

fn send_unicast_pings(sockets: &[UdpSocket], out: &[u8]) {
    {
        let mut last = LAST_UNICAST_PING.lock().unwrap();
        if let Some(t) = *last {
            if t.elapsed().as_secs() < 4 {
                return;
            }
        }
        *last = Some(std::time::Instant::now());
    }
    let Some(socket) = sockets.last() else { return }; // the 0.0.0.0 bind
    let port = get_broadcast_port();
    let targets = scan_targets();
    for ip in &targets {
        allow_err!(socket.send_to(out, SocketAddr::from((*ip, port))));
    }
    log::info!("discover unicast ping: {} hosts", targets.len());
}

fn wait_response(
    socket: UdpSocket,
    timeout: Option<std::time::Duration>,
    tx: UnboundedSender<config::DiscoveryPeer>,
) -> ResultType<()> {
    let mut last_recv_time = Instant::now();

    let local_addr = socket.local_addr();
    let try_get_ip_by_peer = match local_addr.as_ref() {
        Err(..) => true,
        Ok(addr) => addr.ip().is_unspecified(),
    };
    let mut mac: Option<String> = None;

    socket.set_read_timeout(timeout)?;
    loop {
        let mut buf = [0; 2048];
        if let Ok((len, addr)) = socket.recv_from(&mut buf) {
            if let Ok(msg_in) = Message::parse_from_bytes(&buf[0..len]) {
                match msg_in.union {
                    Some(rendezvous_message::Union::PeerDiscovery(p)) => {
                        last_recv_time = Instant::now();
                        if p.cmd == "pong" {
                            let local_mac = if try_get_ip_by_peer {
                                if let Some(self_addr) = get_ipaddr_by_peer(&addr) {
                                    get_mac(&self_addr)
                                } else {
                                    "".to_owned()
                                }
                            } else {
                                match mac.as_ref() {
                                    Some(m) => m.clone(),
                                    None => {
                                        let m = if let Ok(local_addr) = local_addr {
                                            get_mac(&local_addr.ip())
                                        } else {
                                            "".to_owned()
                                        };
                                        mac = Some(m.clone());
                                        m
                                    }
                                }
                            };

                            if local_mac.is_empty() && p.mac.is_empty() || local_mac != p.mac {
                                allow_err!(tx.send(config::DiscoveryPeer {
                                    // remotedisplay: use the IP as the identifier (direct connection, no ID)
                                    id: addr.ip().to_string(),
                                    ip_mac: HashMap::from([
                                        (addr.ip().to_string(), p.mac.clone(),)
                                    ]),
                                    username: p.username.clone(),
                                    hostname: p.hostname.clone(),
                                    platform: p.platform.clone(),
                                    online: true,
                                }));
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
        if last_recv_time.elapsed().as_millis() > 3_000 {
            break;
        }
    }
    Ok(())
}

fn spawn_wait_responses(sockets: Vec<UdpSocket>) -> UnboundedReceiver<config::DiscoveryPeer> {
    let (tx, rx) = unbounded_channel::<_>();
    for socket in sockets {
        let tx_clone = tx.clone();
        std::thread::spawn(move || {
            allow_err!(wait_response(
                socket,
                Some(std::time::Duration::from_millis(10)),
                tx_clone
            ));
        });
    }
    // remotedisplay: active port scan using the same channel
    spawn_port_scan(tx.clone());
    rx
}

async fn handle_received_peers(mut rx: UnboundedReceiver<config::DiscoveryPeer>) -> ResultType<()> {
    let mut peers = config::LanPeers::load().peers;
    peers.iter_mut().for_each(|peer| {
        peer.online = false;
    });

    let mut response_set = HashSet::new();
    let mut last_write_time: Option<Instant> = None;
    loop {
        tokio::select! {
            data = rx.recv() => match data {
                Some(mut peer) => {
                    let in_response_set = !response_set.insert(peer.id.clone());
                    if let Some(pos) = peers.iter().position(|x| x.is_same_peer(&peer) ) {
                        let peer1 = peers.remove(pos);
                        if in_response_set {
                            peer.ip_mac.extend(peer1.ip_mac);
                            peer.online = true;
                        }
                    }
                    peers.insert(0, peer);
                    if last_write_time.map(|t| t.elapsed().as_millis() > 300).unwrap_or(true)  {
                        config::LanPeers::store(&peers);
                        #[cfg(feature = "flutter")]
                        crate::flutter_ffi::main_load_lan_peers();
                        last_write_time = Some(Instant::now());
                    }
                }
                None => {
                    break
                }
            }
        }
    }

    config::LanPeers::store(&peers);
    #[cfg(feature = "flutter")]
    crate::flutter_ffi::main_load_lan_peers();
    Ok(())
}

// ── remotedisplay: discovery via active port scanning ──────────────────
// In addition to the broadcast (same subnet), scans the direct-access port on
// ALL local subnets and Tailscale peers, to find hosts
// running the service without depending on IDs or a server.

fn get_scan_port() -> u16 {
    config::Config::get_option("direct-access-port")
        .parse::<u16>()
        .unwrap_or((RENDEZVOUS_PORT + 2) as u16)
}

fn is_tailscale_ip(u: u32) -> bool {
    // 100.64.0.0/10 (CGNAT — Tailscale's range)
    (u & 0xFFC0_0000) == 0x6440_0000
}

// iOS: Tailscale is a separate app, with no CLI.
#[cfg(target_os = "ios")]
fn tailscale_peer_ips() -> Vec<Ipv4Addr> {
    Vec::new()
}

#[cfg(not(target_os = "ios"))]
fn tailscale_peer_ips() -> Vec<Ipv4Addr> {
    let mut ips = Vec::new();
    let candidates: Vec<String> = if cfg!(target_os = "windows") {
        vec![
            "tailscale".to_owned(),
            r"C:\Program Files\Tailscale\tailscale.exe".to_owned(),
        ]
    } else {
        vec![
            "tailscale".to_owned(),
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale".to_owned(),
            "/usr/local/bin/tailscale".to_owned(),
            "/opt/homebrew/bin/tailscale".to_owned(),
        ]
    };
    for bin in candidates {
        let mut cmd = std::process::Command::new(&bin);
        cmd.arg("status");
        // Without this, on Windows each `tailscale status` call (one per discovery)
        // opens and closes a console window visible over the GUI app.
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(winapi::um::winbase::CREATE_NO_WINDOW);
        }
        if let Ok(out) = cmd.output() {
            if out.status.success() {
                let s = String::from_utf8_lossy(&out.stdout);
                for line in s.lines() {
                    if let Some(tok) = line.split_whitespace().next() {
                        if let Ok(ip) = tok.parse::<Ipv4Addr>() {
                            if is_tailscale_ip(u32::from(ip)) {
                                ips.push(ip);
                            }
                        }
                    }
                }
                break;
            }
        }
    }
    ips
}

/// (address, netmask) of each local IPv4 interface.
#[cfg(not(target_os = "ios"))]
fn local_ipv4_networks() -> Vec<(Ipv4Addr, Ipv4Addr)> {
    let mut out = Vec::new();
    for interface in default_net::get_interfaces() {
        for ipv4 in &interface.ipv4 {
            out.push((ipv4.addr, ipv4.netmask));
        }
    }
    out
}

/// iOS: `default_net` is not available; `getifaddrs` is. Only interfaces
/// that are active, non-loopback, and have a private IP (avoids scanning the cellular network).
#[cfg(target_os = "ios")]
fn local_ipv4_networks() -> Vec<(Ipv4Addr, Ipv4Addr)> {
    use hbb_common::libc;
    let mut out = Vec::new();
    unsafe {
        let mut ifap: *mut libc::ifaddrs = std::ptr::null_mut();
        if libc::getifaddrs(&mut ifap) != 0 {
            return out;
        }
        let mut cur = ifap;
        while !cur.is_null() {
            let ifa = &*cur;
            let up = (ifa.ifa_flags & libc::IFF_UP as u32) != 0;
            let lo = (ifa.ifa_flags & libc::IFF_LOOPBACK as u32) != 0;
            if up
                && !lo
                && !ifa.ifa_addr.is_null()
                && !ifa.ifa_netmask.is_null()
                && (*ifa.ifa_addr).sa_family as i32 == libc::AF_INET
            {
                let sin = &*(ifa.ifa_addr as *const libc::sockaddr_in);
                let mask = &*(ifa.ifa_netmask as *const libc::sockaddr_in);
                let addr = Ipv4Addr::from(u32::from_be(sin.sin_addr.s_addr));
                let netmask = Ipv4Addr::from(u32::from_be(mask.sin_addr.s_addr));
                if addr.is_private() && !addr.is_link_local() {
                    out.push((addr, netmask));
                }
            }
            cur = ifa.ifa_next;
        }
        libc::freeifaddrs(ifap);
    }
    out
}

fn scan_targets() -> Vec<Ipv4Addr> {
    let mut targets: Vec<Ipv4Addr> = Vec::new();
    let mut seen: HashSet<u32> = HashSet::new();
    for (addr, netmask) in local_ipv4_networks() {
        if addr.is_loopback() || addr.is_unspecified() {
            continue;
        }
        let addr_u = u32::from(addr);
        // Tailscale is handled separately (its /10 is too large to scan)
        if is_tailscale_ip(addr_u) {
            continue;
        }
        let mask_u = u32::from(netmask);
        // only reasonable subnets (<= /22 => <= 1024 hosts)
        if mask_u == 0 || mask_u.count_ones() < 22 {
            continue;
        }
        let network = addr_u & mask_u;
        let broadcast = network | !mask_u;
        let mut h = network.wrapping_add(1);
        while h < broadcast {
            if h != addr_u && seen.insert(h) {
                targets.push(Ipv4Addr::from(h));
            }
            h = h.wrapping_add(1);
        }
    }
    // Tailscale peers (via CLI): probed even if they're on a different network
    for ip in tailscale_peer_ips() {
        if seen.insert(u32::from(ip)) {
            targets.push(ip);
        }
    }
    targets
}

// throttle: the "Discovered" tab calls discover() on every rebuild;
// we avoid relaunching the scan (128 threads) more than once every 4s.
static LAST_SCAN: std::sync::Mutex<Option<std::time::Instant>> = std::sync::Mutex::new(None);

fn spawn_port_scan(tx: UnboundedSender<config::DiscoveryPeer>) {
    {
        let mut last = LAST_SCAN.lock().unwrap();
        if let Some(t) = *last {
            if t.elapsed().as_secs() < 4 {
                return;
            }
        }
        *last = Some(std::time::Instant::now());
    }
    let port = get_scan_port();
    let targets = scan_targets();
    if targets.is_empty() {
        return;
    }
    log::info!(
        "port scan: {} targets on port {}",
        targets.len(),
        port
    );
    let queue = std::sync::Arc::new(std::sync::Mutex::new(targets));
    let workers = 128usize;
    for _ in 0..workers {
        let tx = tx.clone();
        let queue = queue.clone();
        std::thread::spawn(move || loop {
            let ip = { queue.lock().unwrap().pop() };
            let ip = match ip {
                Some(ip) => ip,
                None => break,
            };
            let sa = SocketAddr::from((ip, port));
            if std::net::TcpStream::connect_timeout(&sa, std::time::Duration::from_millis(300))
                .is_ok()
            {
                allow_err!(tx.send(config::DiscoveryPeer {
                    id: ip.to_string(),
                    ip_mac: HashMap::from([(ip.to_string(), "".to_owned())]),
                    username: "".to_owned(),
                    hostname: ip.to_string(),
                    platform: "".to_owned(),
                    online: true,
                }));
            }
        });
    }
}
