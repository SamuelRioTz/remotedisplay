// remotedisplay (macOS): the single owner of the Mac's display configuration.
//
// Every change to the displays — the server-side virtual monitor, the "main screen
// follows remote" mirror (dynamic main), a client resizing or re-scaling the virtual
// it views, the reset when the service stops — is an operation queued to ONE worker
// thread. Connections, the IPC handler behind the menu-bar app and the shutdown path
// only enqueue and wait: none of them blocks a tokio runtime, and no two multi-step
// configuration sequences (unmirror → settle → promote → mirror) ever interleave.
//
// While an operation runs, the display service holds its automatic "Displays changed"
// broadcast (one user action is a burst of reconfiguration callbacks, and every
// broadcast costs the clients a video restart); when the topology has settled the
// worker announces the display list ONCE. Reads (`state()`, the platform additions)
// come from cached flags and never configure anything. Between operations the worker
// reconciles the dynamic main's mirror when macOS dissolves it (MacDynamicMainReconcile).
//
// The configuration lives only in this process: nothing is persisted, and `ResetAll`
// on SIGTERM/quit puts the Mac back the way it was — like quitting SimpleDisplay did.

use crate::virtual_display_manager::mac_vdisplay as vd;
use hbb_common::{anyhow::anyhow, bail, lazy_static, log, tokio::sync::oneshot, ResultType};
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Mutex,
    },
    time::{Duration, Instant, SystemTime},
};

#[derive(Debug, Clone, PartialEq)]
pub enum Op {
    /// Add the server-side virtual monitor if there is none.
    PlugVirtual,
    /// Remove every standalone virtual monitor (the dynamic main's is left alone).
    UnplugVirtuals,
    /// Mirror the main physical display onto a resizable virtual (true) or undo it (false).
    DynamicMain(bool),
    /// Hot-resize one of our virtuals, in points.
    Resize { id: u32, width: u32, height: u32 },
    /// HiDPI (2x backing) on or off for one of our virtuals.
    SetHiDPI { id: u32, on: bool },
    /// Everything back to normal (service stop / quit).
    ResetAll,
}

/// What the menu-bar app shows. Also written to a JSON file next to the permissions one.
#[derive(Debug, Clone, Default)]
pub struct State {
    pub virtual_monitor: bool,
    pub dynamic_main: bool,
    pub busy: bool,
    pub virtual_ids: Vec<u32>,
}

type Reply = Box<dyn FnOnce(ResultType<()>) + Send>;

struct Job {
    op: Op,
    reply: Option<Reply>,
}

lazy_static::lazy_static! {
    static ref QUEUE: Mutex<Option<mpsc::Sender<Job>>> = Mutex::new(None);
    static ref STATE: Mutex<State> = Mutex::new(State::default());
}
static SHUTTING_DOWN: AtomicBool = AtomicBool::new(false);

/// Start the worker (idempotent). Called at server start so the state file exists
/// with everything off and the reconcile ticker runs.
pub fn init() {
    let _ = sender();
}

fn sender() -> mpsc::Sender<Job> {
    let mut q = QUEUE.lock().unwrap();
    if let Some(s) = q.as_ref() {
        return s.clone();
    }
    let (tx, rx) = mpsc::channel::<Job>();
    if let Err(e) = std::thread::Builder::new()
        .name("display-manager".into())
        .spawn(move || worker(rx))
    {
        log::error!("display manager: could not start the worker thread: {e}");
    }
    *q = Some(tx.clone());
    drop(q);
    refresh_state(false);
    tx
}

/// Queue `op` and wait for it. Async callers (connections, IPC) never block their
/// runtime thread while the displays reconfigure.
pub async fn run(op: Op) -> ResultType<()> {
    let (tx, rx) = oneshot::channel::<ResultType<()>>();
    sender()
        .send(Job {
            op,
            reply: Some(Box::new(move |r| {
                let _ = tx.send(r);
            })),
        })
        .map_err(|_| anyhow!("the display manager is gone"))?;
    match rx.await {
        Ok(r) => r,
        Err(_) => bail!("the display manager dropped the request"),
    }
}

/// Queue `op` and return at once; the outcome shows up in the announced display list.
pub fn submit(op: Op) {
    if sender().send(Job { op, reply: None }).is_err() {
        log::error!("display manager: queue closed");
    }
}

/// Queue `op` and block the calling thread up to `timeout` (sync callers only).
pub fn run_blocking(op: Op, timeout: Duration) -> ResultType<()> {
    let (tx, rx) = mpsc::channel::<ResultType<()>>();
    sender()
        .send(Job {
            op,
            reply: Some(Box::new(move |r| {
                let _ = tx.send(r);
            })),
        })
        .map_err(|_| anyhow!("the display manager is gone"))?;
    match rx.recv_timeout(timeout) {
        Ok(r) => r,
        Err(_) => bail!(
            "the display manager did not finish in {} s",
            timeout.as_secs()
        ),
    }
}

pub fn state() -> State {
    STATE.lock().unwrap().clone()
}

/// SIGTERM/quit: put the displays back through the queue (a running operation finishes
/// first) and fall back to a direct reset if the worker does not answer in time.
pub fn reset_for_shutdown() {
    SHUTTING_DOWN.store(true, Ordering::SeqCst);
    if let Err(e) = run_blocking(Op::ResetAll, Duration::from_secs(12)) {
        log::warn!("display manager: queued reset failed ({e}); resetting directly");
        if let Err(e) = vd::reset_all() {
            log::error!("mac_vdisplay: reset on shutdown failed: {e}");
        }
    }
    refresh_state(false);
}

fn worker(rx: mpsc::Receiver<Job>) {
    loop {
        match rx.recv_timeout(Duration::from_millis(1000)) {
            Ok(job) => {
                if SHUTTING_DOWN.load(Ordering::SeqCst) && job.op != Op::ResetAll {
                    if let Some(reply) = job.reply {
                        reply(Err(anyhow!("the service is shutting down")));
                    }
                    continue;
                }
                let res = perform(&job.op);
                if let Some(reply) = job.reply {
                    reply(res);
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if !SHUTTING_DOWN.load(Ordering::SeqCst) && vd::is_dynamic_main_active() {
                    reconcile();
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
}

/// One operation: hold the automatic announcements, run the primitive, wait for macOS
/// to settle, announce once (only if something changed) and publish the state.
fn perform(op: &Op) -> ResultType<()> {
    let started = Instant::now();
    let before = crate::platform::display_topology_hash();
    refresh_state(true);
    super::display_service::hold_announcements(true);
    let res = execute(op);
    let did_something = matches!(res, Ok(true));
    // WindowServer applies — and especially removes — displays asynchronously: a change
    // that was really made gets up to 3 s to show in the topology before it counts as
    // "nothing changed". A no-op (already on/off) skips the wait.
    let mut changed = crate::platform::display_topology_hash() != before;
    if did_something && !changed {
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(100));
            if crate::platform::display_topology_hash() != before {
                changed = true;
                break;
            }
        }
    }
    if changed {
        super::video_service::wait_for_stable_topology();
    }
    // Mark the list unsynced BEFORE releasing the hold: the display service then
    // broadcasts exactly once on its next tick. The HiDPI flag travels in
    // platform_additions even when the mode (and so the hash) has not changed yet.
    if changed || matches!(op, Op::SetHiDPI { .. }) {
        super::display_service::announce_displays();
    }
    super::display_service::hold_announcements(false);
    refresh_state(false);
    let res = res.map(|_| ());
    match &res {
        Ok(()) => log::info!(
            "display manager: {op:?} done in {} ms (topology {})",
            started.elapsed().as_millis(),
            if changed { "changed" } else { "unchanged" }
        ),
        Err(e) => log::error!(
            "display manager: {op:?} failed after {} ms: {e}",
            started.elapsed().as_millis()
        ),
    }
    res
}

/// Runs the primitive. Ok(true) = the displays were touched; Ok(false) = it was
/// already so (nothing to wait for or announce).
fn execute(op: &Op) -> ResultType<bool> {
    match op {
        Op::PlugVirtual => {
            let n = vd::get_virtual_displays().len();
            vd::menu_virtual_set(true)?;
            Ok(vd::get_virtual_displays().len() != n)
        }
        Op::UnplugVirtuals => {
            let dm = vd::dynamic_main_virtual_id();
            let had = vd::get_virtual_displays().into_iter().any(|id| id != dm);
            vd::menu_virtual_set(false)?;
            Ok(had)
        }
        Op::DynamicMain(on) => {
            // "On" while already on would resize the virtual back to its default size.
            if vd::is_dynamic_main_active() == *on {
                return Ok(false);
            }
            vd::dynamic_main(*on, 0, 0)?;
            Ok(true)
        }
        Op::Resize { id, width, height } => {
            match vd::change_resolution_if_is_virtual_display(&id.to_string(), *width, *height) {
                Some(true) => Ok(true),
                Some(false) => bail!("resize of virtual display {id} to {width}x{height} failed"),
                None => bail!("display {id} is not a Remote Display virtual display"),
            }
        }
        Op::SetHiDPI { id, on } => {
            vd::set_hidpi(*id, *on)?;
            Ok(true)
        }
        Op::ResetAll => {
            let had = !vd::get_virtual_displays().is_empty()
                || vd::is_dynamic_main_active()
                || !vd::get_inactive_physical_displays().is_empty();
            vd::reset_all()?;
            Ok(had)
        }
    }
}

/// macOS 26 dissolves the dynamic main's mirror when another display changes mode:
/// repair it, or turn it off if it cannot be repaired — on this thread only.
fn reconcile() {
    let before = crate::platform::display_topology_hash();
    super::display_service::hold_announcements(true);
    let changed = vd::dynamic_main_reconcile();
    if changed {
        super::video_service::wait_for_stable_topology();
    }
    if changed || crate::platform::display_topology_hash() != before {
        super::display_service::announce_displays();
        refresh_state(false);
    }
    super::display_service::hold_announcements(false);
}

/// Recompute the cached state from the backend and publish it for the menu-bar app.
fn refresh_state(busy: bool) {
    let dm = vd::dynamic_main_virtual_id();
    let ids: Vec<u32> = vd::get_virtual_displays()
        .into_iter()
        .filter(|id| *id != dm)
        .collect();
    let st = State {
        virtual_monitor: !ids.is_empty(),
        dynamic_main: vd::is_dynamic_main_active(),
        busy,
        virtual_ids: ids,
    };
    *STATE.lock().unwrap() = st.clone();
    write_state_file(&st);
}

/// `~/Library/Application Support/remotedisplay-displays.json`, read by the menu-bar app
/// every 2 s (no process is spawned to ask). Atomic write, like the permissions file.
fn write_state_file(st: &State) {
    let home = std::env::var("HOME").unwrap_or_default();
    if home.is_empty() {
        return;
    }
    let path = format!("{home}/Library/Application Support/remotedisplay-displays.json");
    let now = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let body = serde_json::json!({
        "virtual_monitor": st.virtual_monitor,
        "dynamic_main": st.dynamic_main,
        "busy": st.busy,
        "virtual_ids": st.virtual_ids,
        "updated": now,
    })
    .to_string();
    let tmp = format!("{path}.tmp");
    if std::fs::write(&tmp, body).is_ok() {
        let _ = std::fs::rename(&tmp, &path);
    }
}
