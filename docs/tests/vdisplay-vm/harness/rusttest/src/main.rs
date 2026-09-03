// Integration test for the Rust mac_vdisplay layer (the wrappers invoked by
// Connection::change_resolution and toggle_virtual_display), linked against the
// real macos.mm. Validates that the Rust logic (name parsing, gating via
// MacIsOurVirtualDisplay, plug_out routing by index, dynamic_main with
// defaults, change_resolution_if_is_virtual_display) correctly calls into the C layer.

mod stubs {
    pub type ResultType<T> = Result<T, String>;
    #[macro_export] macro_rules! bail { ($($a:tt)*) => { return Err(format!($($a)*)) }; }
    pub use crate::bail;
    pub mod log {
        macro_rules! info { ($($a:tt)*) => { println!("[info] {}", format!($($a)*)) }; }
        macro_rules! error { ($($a:tt)*) => { eprintln!("[error] {}", format!($($a)*)) }; }
        pub(crate) use {info, error};
    }
}
pub const MAC_DYNAMIC_MAIN_INDEX: i32 = -2;

#[path = "mac_vdisplay.rs"]
pub mod mac_vdisplay;

use std::process::exit;

extern "C" {
    fn CGMainDisplayID() -> u32;
    fn CGGetActiveDisplayList(max: u32, ids: *mut u32, count: *mut u32) -> i32;
    fn CGDisplayPixelsWide(d: u32) -> usize;
    fn CGDisplayPixelsHigh(d: u32) -> usize;
}

fn active_ids() -> Vec<u32> {
    let mut ids = [0u32; 16];
    let mut n = 0u32;
    unsafe { CGGetActiveDisplayList(16, ids.as_mut_ptr(), &mut n); }
    ids[..n as usize].to_vec()
}

static mut FAILS: i32 = 0;
fn check(cond: bool, what: &str) {
    println!("{} {}", if cond { "PASS" } else { "FAIL" }, what);
    if !cond { unsafe { FAILS += 1; } }
}
fn wait_dim(id: u32, w: usize, h: usize, tries: u32) -> bool {
    for _ in 0..tries {
        if unsafe { CGDisplayPixelsWide(id) } == w && unsafe { CGDisplayPixelsHigh(id) } == h { return true; }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    false
}

fn main() {
    use mac_vdisplay as v;
    let phys = unsafe { CGMainDisplayID() };
    println!("=== Rust mac_vdisplay test (physical={}) ===", phys);

    check(v::is_supported(), "is_supported() = true");

    // plug_in_monitor (case 2)
    check(v::plug_in_monitor().is_ok(), "plug_in_monitor() Ok");
    std::thread::sleep(std::time::Duration::from_secs(1));
    let vds = v::get_virtual_displays();
    check(vds.len() == 1, "get_virtual_displays() reports 1");
    let vid = vds[0];
    // is_virtual_display by name (how display_service calls it)
    check(v::is_virtual_display(&vid.to_string()), "is_virtual_display(\"<id>\") = true");
    check(!v::is_virtual_display(&phys.to_string()), "is_virtual_display(physical) = false");
    check(!v::is_virtual_display("not-a-number"), "is_virtual_display(non-numeric) = false");

    // change_resolution_if_is_virtual_display (what change_resolution calls)
    let r = v::change_resolution_if_is_virtual_display(&vid.to_string(), 1600, 1000);
    check(r == Some(true), "change_resolution_if_is_virtual_display(virtual) = Some(true)");
    check(wait_dim(vid, 1600, 1000, 40), "the mode was applied at 1600x1000 (pixels)");
    let r2 = v::change_resolution_if_is_virtual_display(&phys.to_string(), 800, 600);
    check(r2.is_none(), "change_resolution_if_is_virtual_display(physical) = None (doesn't touch the physical)");

    // plug_out_monitor by index (case 2)
    check(v::plug_out_monitor(0).is_ok(), "plug_out_monitor(0) Ok");
    std::thread::sleep(std::time::Duration::from_millis(800));
    check(v::get_virtual_displays().is_empty(), "no virtuals after plug_out");

    // dynamic_main (case 1) with defaults
    check(v::dynamic_main(true, 0, 0).is_ok(), "dynamic_main(true, defaults) Ok");
    std::thread::sleep(std::time::Duration::from_secs(2));
    check(v::is_dynamic_main_active(), "is_dynamic_main_active() = true");
    let dvid = v::dynamic_main_virtual_id();
    check(dvid != 0, "dynamic_main_virtual_id() != 0");
    check(unsafe { CGMainDisplayID() } == dvid, "the virtual is main");
    check(active_ids().len() == 1 && active_ids()[0] == dvid, "only the virtual active (physical mirrored)");

    // dynamic resize via the same entrypoint the handler uses (repeated ToggleVirtualDisplay ON)
    check(v::dynamic_main(true, 1680, 1050).is_ok(), "dynamic_main resize to 1680x1050");
    check(wait_dim(dvid, 1680, 1050, 60), "the dynamic main's virtual followed to 1680x1050");

    // OFF via plug_out_monitor(MAC_DYNAMIC_MAIN_INDEX) — the handler's real routing
    check(v::plug_out_monitor(MAC_DYNAMIC_MAIN_INDEX).is_ok(), "plug_out_monitor(-2) turns off dynamic main");
    std::thread::sleep(std::time::Duration::from_secs(1));
    check(!v::is_dynamic_main_active(), "dynamic main inactive after plug_out(-2)");
    check(unsafe { CGMainDisplayID() } == phys, "the physical became main again");
    check(active_ids().len() == 1 && active_ids()[0] == phys, "only the physical active again");

    // reset_all cleans up everything
    check(v::reset_all().is_ok(), "reset_all() Ok");

    let f = unsafe { FAILS };
    println!("=== {} ({} failures) ===", if f == 0 { "ALL OK" } else { "THERE WERE FAILURES" }, f);
    exit(if f == 0 { 0 } else { 1 });
}
