#+build windows
package main

import "core:c"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

foreign import opengl32 "system:opengl32.lib"

@(default_calling_convention = "system")
foreign opengl32 {
	wglGetProcAddress :: proc(name: cstring) -> rawptr ---
	// OpenGL 1.1, so it lives in the DLL and does not need wglGetProcAddress.
	glClear :: proc(mask: u32) ---
}

// Raylib's blit always filters with nearest, which is not a legal resolve of a
// multisampled color buffer, and it has no call for allocating one. The context
// is already current, so the entry points come from WGL.
@(private = "file")
glBindFramebuffer: proc "system" (target, framebuffer: u32)

@(private = "file")
glGenFramebuffers: proc "system" (n: i32, ids: ^u32)

@(private = "file")
glDeleteFramebuffers: proc "system" (n: i32, ids: ^u32)

@(private = "file")
glGenRenderbuffers: proc "system" (n: i32, ids: ^u32)

@(private = "file")
glDeleteRenderbuffers: proc "system" (n: i32, ids: ^u32)

@(private = "file")
glBindRenderbuffer: proc "system" (target, renderbuffer: u32)

@(private = "file")
glRenderbufferStorageMultisample: proc "system" (target: u32, samples: i32, internalformat: u32, width, height: i32)

@(private = "file")
glFramebufferRenderbuffer: proc "system" (target, attachment, renderbuffertarget, renderbuffer: u32)

@(private = "file")
glBlitFramebuffer: proc "system" (srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1: i32, mask, filter: u32)

@(private = "file")
glCheckFramebufferStatus: proc "system" (target: u32) -> u32

GL_NEAREST                :: u32(0x2600)
GL_LINEAR                 :: u32(0x2601)
GL_DEPTH_BUFFER_BIT       :: u32(0x0100)
GL_COLOR_BUFFER_BIT       :: u32(0x4000)
GL_RGBA8                  :: u32(0x8058)
GL_DEPTH_COMPONENT24      :: u32(0x81A6)
GL_FRAMEBUFFER            :: u32(0x8D40)
GL_READ_FRAMEBUFFER       :: u32(0x8CA8)
GL_DRAW_FRAMEBUFFER       :: u32(0x8CA9)
GL_RENDERBUFFER           :: u32(0x8D41)
GL_COLOR_ATTACHMENT0      :: u32(0x8CE0)
GL_DEPTH_ATTACHMENT       :: u32(0x8D00)
GL_FRAMEBUFFER_COMPLETE   :: u32(0x8CD5)

MSAA_SAMPLES :: i32(4)

msaa_load_gl :: proc() -> bool {
	load :: proc($T: typeid, name: cstring) -> T {
		return cast(T)wglGetProcAddress(name)
	}
	glBindFramebuffer = load(type_of(glBindFramebuffer), "glBindFramebuffer")
	glGenFramebuffers = load(type_of(glGenFramebuffers), "glGenFramebuffers")
	glDeleteFramebuffers = load(type_of(glDeleteFramebuffers), "glDeleteFramebuffers")
	glGenRenderbuffers = load(type_of(glGenRenderbuffers), "glGenRenderbuffers")
	glDeleteRenderbuffers = load(type_of(glDeleteRenderbuffers), "glDeleteRenderbuffers")
	glBindRenderbuffer = load(type_of(glBindRenderbuffer), "glBindRenderbuffer")
	glRenderbufferStorageMultisample = load(type_of(glRenderbufferStorageMultisample), "glRenderbufferStorageMultisample")
	glFramebufferRenderbuffer = load(type_of(glFramebufferRenderbuffer), "glFramebufferRenderbuffer")
	glBlitFramebuffer = load(type_of(glBlitFramebuffer), "glBlitFramebuffer")
	glCheckFramebufferStatus = load(type_of(glCheckFramebufferStatus), "glCheckFramebufferStatus")
	return glBindFramebuffer != nil && glGenFramebuffers != nil && glDeleteFramebuffers != nil &&
		glGenRenderbuffers != nil && glDeleteRenderbuffers != nil && glBindRenderbuffer != nil &&
		glRenderbufferStorageMultisample != nil && glFramebufferRenderbuffer != nil &&
		glBlitFramebuffer != nil && glCheckFramebufferStatus != nil
}

msaa_bind :: proc(msaa: ^MSAA) {
	glBindFramebuffer(GL_FRAMEBUFFER, msaa.fbo)
	rlgl.Viewport(0, 0, msaa.width, msaa.height)
}

msaa_ensure :: proc(msaa: ^MSAA, width, height: c.int) -> bool {
	if !msaa.supported || width < 1 || height < 1 {
		return false
	}
	if msaa.fbo != 0 && msaa.width == width && msaa.height == height {
		return true
	}

	msaa_delete(msaa)
	glGenFramebuffers(1, &msaa.fbo)
	glGenRenderbuffers(1, &msaa.color)
	glGenRenderbuffers(1, &msaa.depth)

	glBindRenderbuffer(GL_RENDERBUFFER, msaa.color)
	glRenderbufferStorageMultisample(GL_RENDERBUFFER, MSAA_SAMPLES, GL_RGBA8, width, height)
	glBindRenderbuffer(GL_RENDERBUFFER, msaa.depth)
	glRenderbufferStorageMultisample(GL_RENDERBUFFER, MSAA_SAMPLES, GL_DEPTH_COMPONENT24, width, height)

	glBindFramebuffer(GL_FRAMEBUFFER, msaa.fbo)
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, msaa.color)
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, msaa.depth)
	ok := glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
	glBindFramebuffer(GL_FRAMEBUFFER, 0)
	glBindRenderbuffer(GL_RENDERBUFFER, 0)
	if !ok {
		msaa_delete(msaa)
		return false
	}

	msaa.width = width
	msaa.height = height
	return true
}

// dest 0 is the window. Depth is only needed when the destination is the TAA
// scene, which reprojects from it.
msaa_resolve :: proc(msaa: ^MSAA, dest: c.uint, depth: bool) {
	glBindFramebuffer(GL_READ_FRAMEBUFFER, msaa.fbo)
	glBindFramebuffer(GL_DRAW_FRAMEBUFFER, u32(dest))
	glBlitFramebuffer(0, 0, msaa.width, msaa.height, 0, 0, msaa.width, msaa.height, GL_COLOR_BUFFER_BIT, GL_LINEAR)
	if depth {
		glBlitFramebuffer(0, 0, msaa.width, msaa.height, 0, 0, msaa.width, msaa.height, GL_DEPTH_BUFFER_BIT, GL_NEAREST)
	}
	glBindFramebuffer(GL_FRAMEBUFFER, 0)
	rlgl.Viewport(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight())
}

// Color stays. The viewmodel is drawn over the resolved world, and a near wall
// must not win the depth test against it.
clear_depth_buffer :: proc() -> bool {
	glClear(GL_DEPTH_BUFFER_BIT)
	return true
}

msaa_destroy :: proc(msaa: ^MSAA) {
	if msaa.supported {
		msaa_delete(msaa)
	}
}

// Raylib's render textures attach depth as a renderbuffer. Replacing that with a
// texture (so a shader can read it) leaves the renderbuffer detached.
renderbuffer_free :: proc(id: u32) {
	if id == 0 || glDeleteRenderbuffers == nil {
		return
	}
	local := id
	glDeleteRenderbuffers(1, &local)
}

msaa_delete :: proc(msaa: ^MSAA) {
	if msaa.fbo != 0 {
		glDeleteFramebuffers(1, &msaa.fbo)
	}
	if msaa.color != 0 {
		glDeleteRenderbuffers(1, &msaa.color)
	}
	if msaa.depth != 0 {
		glDeleteRenderbuffers(1, &msaa.depth)
	}
	msaa.fbo = 0
	msaa.color = 0
	msaa.depth = 0
	msaa.width = 0
	msaa.height = 0
}
