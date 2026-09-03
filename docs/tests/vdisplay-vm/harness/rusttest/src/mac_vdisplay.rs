// EXTRACTED from virtual_display_manager.rs (mod unwrapped, use statements adapted)

    use crate::stubs::*;

    pub const DEFAULT_WIDTH: u32 = 1920;
    pub const DEFAULT_HEIGHT: u32 = 1080;
    const MAX_VIRTUAL_DISPLAYS: usize = 4;

    extern "C" {
        fn MacVirtualDisplaySupported() -> bool;
        fn MacCreateVirtualDisplay(
            width: u32,
            height: u32,
            refresh_rate: f64,
            hidpi: bool,
            name: *const std::os::raw::c_char,
        ) -> u32;
        fn MacResizeVirtualDisplay(display_id: u32, width: u32, height: u32) -> bool;
        fn MacDestroyVirtualDisplay(display_id: u32) -> bool;
        fn MacDestroyAllVirtualDisplays();
        fn MacListVirtualDisplays(ids: *mut u32, max: u32) -> u32;
        fn MacIsOurVirtualDisplay(display_id: u32) -> bool;
        fn MacDynamicMainOn(width: u32, height: u32, hidpi: bool) -> bool;
        fn MacDynamicMainOff() -> bool;
        fn MacDynamicMainActive() -> bool;
        fn MacDynamicMainVirtualID() -> u32;
    }

    #[inline]
    pub fn is_supported() -> bool {
        unsafe { MacVirtualDisplaySupported() }
    }

    pub fn get_virtual_displays() -> Vec<u32> {
        let mut ids = [0u32; MAX_VIRTUAL_DISPLAYS];
        let n = unsafe { MacListVirtualDisplays(ids.as_mut_ptr(), ids.len() as _) };
        ids[..n as usize].to_vec()
    }

    #[inline]
    pub fn is_virtual_display(name: &str) -> bool {
        // On macOS display.name() is the CGDirectDisplayID as a string.
        name.parse::<u32>()
            .map(|id| unsafe { MacIsOurVirtualDisplay(id) })
            .unwrap_or(false)
    }

    pub fn plug_in_monitor() -> ResultType<()> {
        if get_virtual_displays().len() >= MAX_VIRTUAL_DISPLAYS {
            bail!("Max virtual displays reached");
        }
        let name = std::ffi::CString::new("Remote Display Virtual").map_err(|e| e.to_string())?;
        let id = unsafe {
            MacCreateVirtualDisplay(DEFAULT_WIDTH, DEFAULT_HEIGHT, 60.0, false, name.as_ptr())
        };
        if id == 0 {
            bail!("Failed to create CGVirtualDisplay");
        }
        log::info!("mac_vdisplay: plugged in virtual display {id}");
        Ok(())
    }

    pub fn plug_out_monitor(index: i32) -> ResultType<()> {
        if index == crate::MAC_DYNAMIC_MAIN_INDEX {
            return dynamic_main(false, 0, 0);
        }
        if index < 0 {
            // -1 = all (Windows convention) — also turns off the dynamic main.
            let _ = dynamic_main(false, 0, 0);
            unsafe { MacDestroyAllVirtualDisplays() };
            return Ok(());
        }
        // The "index" the client sends is the position in our list of virtual
        // displays; if it doesn't match, try it as a raw CGDirectDisplayID.
        let displays = get_virtual_displays();
        let id = displays
            .get(index as usize)
            .copied()
            .unwrap_or(index as u32);
        if unsafe { !MacDestroyVirtualDisplay(id) } {
            bail!("No virtual display at index {index}");
        }
        Ok(())
    }

    /// Hot resize if `name` is one of our virtual displays.
    /// Returns Some(true/false) if it was one (success/failure), None if it wasn't.
    pub fn change_resolution_if_is_virtual_display(name: &str, w: u32, h: u32) -> Option<bool> {
        let id = name.parse::<u32>().ok()?;
        if unsafe { !MacIsOurVirtualDisplay(id) } {
            return None;
        }
        let ok = unsafe { MacResizeVirtualDisplay(id, w, h) };
        if !ok {
            log::error!("mac_vdisplay: resize of {id} to {w}x{h} failed");
        }
        Some(ok)
    }

    #[inline]
    pub fn is_dynamic_main_active() -> bool {
        unsafe { MacDynamicMainActive() }
    }

    #[inline]
    pub fn dynamic_main_virtual_id() -> u32 {
        unsafe { MacDynamicMainVirtualID() }
    }

    /// Case 1: turns the "dynamic main" (physical mirrored onto a virtual) on/off.
    /// With on=true and width/height at 0, uses the default size.
    pub fn dynamic_main(on: bool, width: u32, height: u32) -> ResultType<()> {
        if on {
            let w = if width == 0 { DEFAULT_WIDTH } else { width };
            let h = if height == 0 { DEFAULT_HEIGHT } else { height };
            if unsafe { !MacDynamicMainOn(w, h, false) } {
                bail!("Failed to enable dynamic main display");
            }
        } else {
            if unsafe { !MacDynamicMainOff() } {
                bail!("Failed to disable dynamic main display (unmirror)");
            }
        }
        Ok(())
    }

    pub fn reset_all() -> ResultType<()> {
        let _ = dynamic_main(false, 0, 0);
        unsafe { MacDestroyAllVirtualDisplays() };
        Ok(())
    }
