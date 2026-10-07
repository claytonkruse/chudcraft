package main

// Linking core:sys/windows is not an option here: it pulls in user32.lib, whose
// CloseWindow collides with raylib's. kernel32 has no such clash, so the one
// function needed gets resolved from user32.dll at runtime instead.
foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	LoadLibraryA :: proc(name: cstring) -> rawptr ---
	GetProcAddress :: proc(module: rawptr, name: cstring) -> rawptr ---
}

// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
PER_MONITOR_AWARE_V2 :: rawptr(~uintptr(3))

// Without this, Windows stretches the window past the size raylib asked for, so
// borderless fullscreen comes out larger than the monitor with its right and bottom
// edges off screen. Raylib's WINDOW_HIGHDPI flag is not a substitute: it scales the
// window a second time on top of the stretch, which is worse.
// Must run before the window is created.
claim_dpi_awareness :: proc() {
	user32 := LoadLibraryA("user32.dll")
	if user32 == nil {
		return
	}

	if address := GetProcAddress(user32, "SetProcessDpiAwarenessContext"); address != nil {
		set_context := cast(proc "system" (context_handle: rawptr) -> b32)address
		if set_context(PER_MONITOR_AWARE_V2) {
			return
		}
	}

	// Older Windows only has the process-wide, system-DPI version.
	if address := GetProcAddress(user32, "SetProcessDPIAware"); address != nil {
		set_aware := cast(proc "system" () -> b32)address
		set_aware()
	}
}
