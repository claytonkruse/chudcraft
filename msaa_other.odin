#+build !windows
package main

import "core:c"

msaa_load_gl :: proc() -> bool {
	return false
}

msaa_bind :: proc(msaa: ^MSAA) {}

msaa_ensure :: proc(msaa: ^MSAA, width, height: c.int) -> bool {
	return false
}

msaa_resolve :: proc(msaa: ^MSAA, dest: c.uint, depth: bool) {}

msaa_destroy :: proc(msaa: ^MSAA) {}

renderbuffer_free :: proc(id: u32) {}
