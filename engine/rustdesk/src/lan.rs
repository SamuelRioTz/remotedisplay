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
    sync::atomic::{AtomicBool, AtomicU32, Ordering},
    time::Instant,
};

type Message = RendezvousMessage;

// remotedisplay: how the last discovery run went, for the client's home: replies to our
// UDP pings against hosts the port scan found. A run with port hits and no reply at all
// means the replies do not reach this client (a firewall rule on it, typically); the home
// says so under its cards instead of silently listing bare addresses. `run` tells one
// run's pushes apart from the next one's.
static DISCOVERY_RUN: AtomicU32 = AtomicU32::new(0);
static DISCOVERY_REPLIES: AtomicU32 = AtomicU32::new(0);
static DISCOVERY_PORT_HITS: AtomicU32 = AtomicU32::new(0);
static DISCOVERY_DONE: AtomicBool = AtomicBool::new(false);

/// `(run, replies, port_hits, done)` of the discovery run in progress or just finished.
pub fn discovery_stats() -> (u32, u32, u32, bool) {
    (
        DISCOVERY_RUN.load(Ordering::Relaxed),
        DISCOVERY_REPLIES.load(Ordering::Relaxed),
        DISCOVERY_PORT_HITS.load(Ordering::Relaxed),
        DISCOVERY_DONE.load(Ordering::Relaxed),
    )
}

/// Opens a new tally and returns its run number. Runs can overlap (the previous
/// run's threads drain for a few seconds): every count is tagged with its run and
/// only the current run's counts land, see [`tally`].
fn begin_discovery_run() -> u32 {
    DISCOVERY_DONE.store(false, Ordering::Relaxed);
    DISCOVERY_REPLIES.store(0, Ordering::Relaxed);
    DISCOVERY_PORT_HITS.store(0, Ordering::Relaxed);
    DISCOVERY_RUN.fetch_add(1, Ordering::Relaxed) + 1
}

fn is_current_run(run: u32) -> bool {
    DISCOVERY_RUN.load(Ordering::Relaxed) == run
}

fn tally(counter: &AtomicU32, run: u32) {
    if is_current_run(run) {
        counter.fetch_add(1, Ordering::Relaxed);
    }
}

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
                                    misc: advertised_addrs(&self_addr),
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
    // remotedisplay: a fresh tally for this run (see discovery_stats).
    let run = begin_discovery_run();
    let sockets = send_query()?;
    let rx = spawn_wait_responses(sockets, run);
    handle_received_peers(rx, run).await?;

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
    run: u32,
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
                                tally(&DISCOVERY_REPLIES, run);
                                allow_err!(tx.send(config::DiscoveryPeer {
                                    // remotedisplay: use the IP as the identifier (direct connection, no ID)
                                    id: addr.ip().to_string(),
                                    ip_mac: HashMap::from([
                                        (addr.ip().to_string(), p.mac.clone(),)
                                    ]),
                                    machine_id: p.id.clone(),
                                    username: p.username.clone(),
                                    hostname: p.hostname.clone(),
                                    platform: p.platform.clone(),
                                    online: true,
                                }));
                                // remotedisplay: the host also tells us its other addresses
                                // (its Tailscale one): one more entry per address, with the
                                // same identity, so the client knows that route before it
                                // ever leaves the LAN. Not probed here (online = false).
                                for extra in parse_advertised_addrs(&p.misc) {
                                    if extra == addr.ip().to_string() {
                                        continue;
                                    }
                                    allow_err!(tx.send(config::DiscoveryPeer {
                                        id: extra.clone(),
                                        ip_mac: HashMap::from([(extra, p.mac.clone())]),
                                        machine_id: p.id.clone(),
                                        username: p.username.clone(),
                                        hostname: p.hostname.clone(),
                                        platform: p.platform.clone(),
                                        online: false,
                                    }));
                                }
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

fn spawn_wait_responses(
    sockets: Vec<UdpSocket>,
    run: u32,
) -> UnboundedReceiver<config::DiscoveryPeer> {
    let (tx, rx) = unbounded_channel::<_>();
    for socket in sockets {
        let tx_clone = tx.clone();
        std::thread::spawn(move || {
            allow_err!(wait_response(
                socket,
                Some(std::time::Duration::from_millis(10)),
                tx_clone,
                run
            ));
        });
    }
    // remotedisplay: active port scan using the same channel
    spawn_port_scan(tx.clone(), run);
    rx
}

async fn handle_received_peers(
    mut rx: UnboundedReceiver<config::DiscoveryPeer>,
    run: u32,
) -> ResultType<()> {
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
                            // remotedisplay: the bare port-scan entry for an address
                            // must not erase the identity its discovery reply carried.
                            if peer.machine_id.is_empty() {
                                peer.machine_id = peer1.machine_id;
                            }
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

    // remotedisplay: the run is over; the final push carries the tally (see
    // discovery_stats) — unless a newer run has taken over the counters meanwhile.
    if is_current_run(run) {
        DISCOVERY_DONE.store(true, Ordering::Relaxed);
        log::info!(
            "discover done: {} replies, {} port hits",
            DISCOVERY_REPLIES.load(Ordering::Relaxed),
            DISCOVERY_PORT_HITS.load(Ordering::Relaxed)
        );
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

/// remotedisplay: what a host tells clients about its other addresses in the discovery
/// reply's `misc` field: `{"addrs":["100.64.0.2"]}`. Only the Tailscale (CGNAT) addresses,
/// other than the one the reply leaves from: a client that saw the Mac on the LAN then knows
/// how to reach it from anywhere, without typing the address by hand.
fn advertised_addrs(self_addr: &IpAddr) -> String {
    let addrs = host_tailscale_addrs(Some(*self_addr));
    if addrs.is_empty() {
        String::new()
    } else {
        serde_json::json!({ "addrs": addrs }).to_string()
    }
}

/// remotedisplay: this host's own Tailscale (CGNAT) addresses, other than `except` (the
/// address a client is already talking to), deduplicated. The set a discovery reply
/// advertises in `misc`, and, since 1.0.15, the login response in its `addrs` (see
/// server/connection.rs): a client that reached the host one way learns the other.
pub(crate) fn host_tailscale_addrs(except: Option<IpAddr>) -> Vec<String> {
    pick_tailscale_addrs(local_ipv4_networks().into_iter().map(|(ip, _)| ip), except)
}

fn pick_tailscale_addrs(ips: impl Iterator<Item = Ipv4Addr>, except: Option<IpAddr>) -> Vec<String> {
    // The direct listener is a dual-stack socket: an accepted connection's local
    // address is the IPv4-mapped IPv6 form (::ffff:100.64.0.2). Compare the plain IPv4.
    let except = except.map(|a| a.to_canonical());
    let mut addrs: Vec<String> = Vec::new();
    for ip in ips {
        if !is_tailscale_ip(u32::from(ip)) || except == Some(IpAddr::V4(ip)) {
            continue;
        }
        let s = ip.to_string();
        if !addrs.contains(&s) {
            addrs.push(s);
        }
    }
    addrs
}

/// remotedisplay: the addresses a host named in its login response (`addrs` in
/// `platform_additions`, Tailscale IPv4 only, anything else ignored), without the one the
/// client is connected through (`this_id`, an address with an optional `:port`). The
/// client files these under the host's identity; see client.rs `spread_identity`.
pub(crate) fn login_addrs(platform_additions: &str, this_id: &str) -> Vec<String> {
    let this_host = match this_id.rsplit_once(':') {
        Some((host, port)) if port.parse::<u16>().is_ok() && !host.contains(']') => host,
        _ => this_id,
    }
    .trim();
    let mut out = Vec::new();
    if platform_additions.is_empty() {
        return out;
    }
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(platform_additions) {
        if let Some(list) = v.get("addrs").and_then(|a| a.as_array()) {
            for a in list.iter().take(16) {
                if let Some(s) = a.as_str() {
                    if let Ok(ip) = s.trim().parse::<Ipv4Addr>() {
                        let s = ip.to_string();
                        if is_tailscale_ip(u32::from(ip)) && s != this_host && !out.contains(&s) {
                            out.push(s);
                        }
                    }
                }
            }
        }
    }
    out
}

/// The addresses of an `advertised_addrs` payload, Tailscale ones only (anything else, or
/// junk, is ignored: the field is free-form).
fn parse_advertised_addrs(misc: &str) -> Vec<String> {
    let mut out = Vec::new();
    if misc.is_empty() {
        return out;
    }
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(misc) {
        if let Some(list) = v.get("addrs").and_then(|a| a.as_array()) {
            for a in list {
                if let Some(s) = a.as_str() {
                    if let Ok(ip) = s.trim().parse::<Ipv4Addr>() {
                        if is_tailscale_ip(u32::from(ip)) && !out.contains(&ip.to_string()) {
                            out.push(ip.to_string());
                        }
                    }
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod advertised_addrs_tests {
    use super::*;

    #[test]
    fn parses_only_tailscale_addresses() {
        let got = parse_advertised_addrs(r#"{"addrs":["100.64.0.2","192.168.1.5","100.64.0.2","nope"]}"#);
        assert_eq!(got, vec!["100.64.0.2".to_string()]);
        assert!(parse_advertised_addrs("").is_empty());
        assert!(parse_advertised_addrs("garbage").is_empty());
        assert!(parse_advertised_addrs(r#"{"addrs":"100.64.0.2"}"#).is_empty());
    }

    #[test]
    fn round_trip_with_the_payload_format() {
        let payload = serde_json::json!({ "addrs": ["100.64.0.7"] }).to_string();
        assert_eq!(parse_advertised_addrs(&payload), vec!["100.64.0.7".to_string()]);
    }

    #[test]
    fn pick_tailscale_addrs_filters_and_dedupes() {
        let ips = ["192.168.1.5", "100.64.0.2", "100.64.0.2", "100.64.0.9", "10.0.0.1"]
            .iter()
            .map(|s| s.parse::<Ipv4Addr>().unwrap());
        let except: IpAddr = "100.64.0.9".parse().unwrap();
        assert_eq!(pick_tailscale_addrs(ips, Some(except)), vec!["100.64.0.2".to_string()]);
    }

    #[test]
    fn pick_tailscale_addrs_excludes_a_mapped_ipv6_local_address() {
        // What a dual-stack listener reports as the local address of a v4 connection.
        let ips = ["100.64.0.2", "100.64.0.9"].iter().map(|s| s.parse::<Ipv4Addr>().unwrap());
        let except: IpAddr = "::ffff:100.64.0.9".parse().unwrap();
        assert_eq!(pick_tailscale_addrs(ips, Some(except)), vec!["100.64.0.2".to_string()]);
    }

    #[test]
    fn login_addrs_keeps_other_tailscale_addresses_only() {
        let pa = r#"{"machine_id":"526326377","addrs":["100.64.0.2","192.168.1.115","100.64.0.2","nope","100.64.0.7"]}"#;
        // Connected through the LAN: both Tailscale addresses are news to us.
        assert_eq!(
            login_addrs(pa, "192.168.1.115"),
            vec!["100.64.0.2".to_string(), "100.64.0.7".to_string()]
        );
        // Connected through one of them (with a port): it is left out.
        assert_eq!(login_addrs(pa, "100.64.0.2:21120"), vec!["100.64.0.7".to_string()]);
        assert!(login_addrs("", "1.2.3.4").is_empty());
        assert!(login_addrs("garbage", "1.2.3.4").is_empty());
        assert!(login_addrs(r#"{"addrs":"100.64.0.2"}"#, "1.2.3.4").is_empty());
        assert!(login_addrs(r#"{"machine_id":"1"}"#, "1.2.3.4").is_empty());
    }
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
    for ip in known_tailscale_ips() {
        if seen.insert(u32::from(ip)) {
            targets.push(ip);
        }
    }
    targets
}

/// remotedisplay: Tailscale addresses this client already knows — discovered before or
/// connected to — probed on every discovery even where there is no Tailscale CLI (iOS,
/// Android). The Tailscale app provides the tunnel and the host answers with its identity,
/// so a Mac at home shows up (and its LAN entry is seen to be gone) from another network.
fn known_tailscale_ips() -> Vec<Ipv4Addr> {
    let mut ips: Vec<Ipv4Addr> = Vec::new();
    let mut push = |id: &str| {
        if let Ok(ip) = id.trim().parse::<Ipv4Addr>() {
            if is_tailscale_ip(u32::from(ip)) && !ips.contains(&ip) {
                ips.push(ip);
            }
        }
    };
    for p in config::LanPeers::load().peers {
        push(&p.id);
    }
    for (id, _, _) in config::PeerConfig::peers(None) {
        push(&id);
    }
    ips
}

// throttle: the "Discovered" tab calls discover() on every rebuild;
// we avoid relaunching the scan (128 threads) more than once every 4s.
static LAST_SCAN: std::sync::Mutex<Option<std::time::Instant>> = std::sync::Mutex::new(None);

fn spawn_port_scan(tx: UnboundedSender<config::DiscoveryPeer>, run: u32) {
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
                tally(&DISCOVERY_PORT_HITS, run);
                allow_err!(tx.send(config::DiscoveryPeer {
                    id: ip.to_string(),
                    ip_mac: HashMap::from([(ip.to_string(), "".to_owned())]),
                    machine_id: "".to_owned(),
                    username: "".to_owned(),
                    hostname: ip.to_string(),
                    platform: "".to_owned(),
                    online: true,
                }));
            }
        });
    }
}
