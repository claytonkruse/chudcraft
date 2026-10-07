package main

import "core:c"

// 4x multisampling, the antialiasing the window used to request at startup.
// The sample count of the default framebuffer is fixed once the window exists,
// so this target is what the options screen turns on and off.
MSAA :: struct {
	supported: bool,
	fbo:       u32,
	color:     u32,
	depth:     u32,
	width:     c.int,
	height:    c.int,
}

msaa_init :: proc(msaa: ^MSAA) {
	msaa.supported = msaa_load_gl()
}
