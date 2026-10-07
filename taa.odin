package main

import "core:c"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// The 3D view, accumulated across frames. The HUD is drawn after the resolve,
// on the backbuffer, so text and the crosshair are never jittered.
TAA :: struct {
	shader:         rl.Shader,
	scene:          rl.RenderTexture2D,
	history:        [2]rl.RenderTexture2D,
	write:          int,
	width:          c.int,
	height:         c.int,
	frame:          u32,
	// False until a resolved frame is in the history, and again after a resize
	// or when the options screen turns TAA back on.
	ready:          bool,
	passthrough:    bool,
	// This frame was drawn into the multisample buffer, then resolved into scene.
	via_msaa:       bool,
	view_proj:      rl.Matrix,
	inv_view_proj:  rl.Matrix,
	prev_view_proj: rl.Matrix,
	loc_depth:      c.int,
	loc_history:    c.int,
	loc_inv:        c.int,
	loc_prev:       c.int,
	loc_resolution: c.int,
	loc_valid:      c.int,
}

taa_init :: proc() -> (taa: TAA) {
	taa.shader = rl.LoadShader(nil, "assets/shaders/taa.fs")
	if taa.shader.id == 0 {
		return
	}
	taa.loc_depth = rl.GetShaderLocation(taa.shader, "depthTex")
	taa.loc_history = rl.GetShaderLocation(taa.shader, "historyTex")
	taa.loc_inv = rl.GetShaderLocation(taa.shader, "invViewProj")
	taa.loc_prev = rl.GetShaderLocation(taa.shader, "prevViewProj")
	taa.loc_resolution = rl.GetShaderLocation(taa.shader, "resolution")
	taa.loc_valid = rl.GetShaderLocation(taa.shader, "historyValid")
	return
}

taa_destroy :: proc(taa: ^TAA) {
	if taa.shader.id != 0 {
		rl.UnloadShader(taa.shader)
	}
	taa_free_targets(taa)
}

// Jitters the projection and redirects world drawing. use_taa accumulates
// frames; use_msaa draws into the 4x buffer first. Drawing happens between
// this and taa_resolve.
taa_begin :: proc(taa: ^TAA, msaa: ^MSAA, camera: rl.Camera3D, use_taa, use_msaa: bool) {
	want_taa := use_taa && taa.shader.id != 0 && taa_ensure_targets(taa)
	want_msaa := use_msaa && msaa.supported && msaa_ensure(msaa, rl.GetScreenWidth(), rl.GetScreenHeight())
	taa.passthrough = !want_taa
	taa.via_msaa = want_msaa

	if want_msaa {
		msaa_bind(msaa)
		rl.ClearBackground(rl.SKYBLUE)
		rl.BeginMode3D(camera)
		if want_taa {
			taa_jitter(taa)
		}
		return
	}

	if !want_taa {
		rl.BeginMode3D(camera)
		return
	}

	rl.BeginTextureMode(taa.scene)
	rl.ClearBackground(rl.SKYBLUE)
	rl.BeginMode3D(camera)
	taa_jitter(taa)
}

// A pixel is 2 units wide in NDC. Halton is in [0, 1), so the half subtracts
// to put the sample inside the pixel rather than on a corner.
taa_jitter :: proc(taa: ^TAA) {
	taa.frame += 1
	jx := (halton(taa.frame, 2) - 0.5) * 2 / f32(taa.width)
	jy := (halton(taa.frame, 3) - 0.5) * 2 / f32(taa.height)

	proj := rlgl.GetMatrixProjection()
	view := rlgl.GetMatrixModelview()
	proj[0, 2] += jx
	proj[1, 2] += jy
	rlgl.SetMatrixProjection(proj)

	taa.view_proj = proj * view
	taa.inv_view_proj = rl.MatrixInvert(taa.view_proj)
}

// Blends the jittered frame with where those pixels were last frame, then
// draws the result into the window. With TAA off, the world is already in the
// window, or it is resolved there from the multisample buffer.
taa_resolve :: proc(taa: ^TAA, msaa: ^MSAA) {
	// EndMode3D only puts the 2D camera back when the default framebuffer is
	// bound, so the multisample target has to be unbound after its draw is flushed.
	if taa.via_msaa {
		rlgl.DrawRenderBatchActive()
		rlgl.DisableFramebuffer()
	}
	rl.EndMode3D()

	if taa.via_msaa && !taa.passthrough {
		msaa_resolve(msaa, taa.scene.id, true)
		taa_temporal(taa)
		return
	}
	if taa.via_msaa {
		msaa_resolve(msaa, 0, false)
		return
	}
	if taa.passthrough {
		return
	}
	rl.EndTextureMode()
	taa_temporal(taa)
}

taa_temporal :: proc(taa: ^TAA) {
	read := 1 - taa.write
	dest := taa.history[taa.write]
	valid := c.int(1 if taa.ready else 0)
	resolution := [2]f32{f32(taa.width), f32(taa.height)}

	// BeginTextureMode and BeginShaderMode both flush the batch, and a flush
	// drops every sampler registered before it. Depth and history have to be
	// bound after the shader is current, or the resolve samples black.
	rl.BeginTextureMode(dest)
	rl.SetShaderValueMatrix(taa.shader, taa.loc_inv, taa.inv_view_proj)
	rl.SetShaderValueMatrix(taa.shader, taa.loc_prev, taa.prev_view_proj)
	rl.SetShaderValue(taa.shader, taa.loc_resolution, &resolution, .VEC2)
	rl.SetShaderValue(taa.shader, taa.loc_valid, &valid, .INT)
	rl.BeginShaderMode(taa.shader)
	rl.SetShaderValueTexture(taa.shader, taa.loc_depth, taa.scene.depth)
	rl.SetShaderValueTexture(taa.shader, taa.loc_history, taa.history[read].texture)
	rl.DrawTextureRec(
		taa.scene.texture,
		{0, 0, f32(taa.width), f32(taa.height)},
		{0, 0},
		rl.WHITE,
	)
	rl.EndShaderMode()
	rl.EndTextureMode()

	// Render textures are stored bottom-up. The negative height flips the
	// blit so the sky stays at the top of the window.
	rl.DrawTextureRec(dest.texture, {0, 0, f32(taa.width), -f32(taa.height)}, {0, 0}, rl.WHITE)

	taa.prev_view_proj = taa.view_proj
	taa.ready = true
	taa.write = read
}

// Halton sequence. Index 0 is 0, so the frame counter starts at 1. Bases 2 and
// 3 are the usual pair for a sub-pixel sample pattern.
halton :: proc(index, base: u32) -> f32 {
	value: f32
	scale: f32 = 1
	i := index
	for i > 0 {
		scale /= f32(base)
		value += scale * f32(i % base)
		i /= base
	}
	return value
}

taa_ensure_targets :: proc(taa: ^TAA) -> bool {
	width := rl.GetScreenWidth()
	height := rl.GetScreenHeight()
	if width < 1 || height < 1 {
		return false
	}
	if taa.scene.id != 0 && taa.width == width && taa.height == height {
		return true
	}

	taa_free_targets(taa)
	taa.scene = rl.LoadRenderTexture(width, height)
	taa.history[0] = rl.LoadRenderTexture(width, height)
	taa.history[1] = rl.LoadRenderTexture(width, height)
	if taa.scene.id == 0 || taa.history[0].id == 0 || taa.history[1].id == 0 {
		taa_free_targets(taa)
		return false
	}

	// The resolve fetches the scene texel by texel. History is sampled between
	// pixels, so it wants bilinear, and clamp so an off-screen reprojection
	// does not wrap to the other side of the frame.
	rl.SetTextureFilter(taa.scene.texture, .POINT)
	rl.SetTextureWrap(taa.scene.texture, .CLAMP)
	for i in 0 ..< 2 {
		rl.SetTextureFilter(taa.history[i].texture, .BILINEAR)
		rl.SetTextureWrap(taa.history[i].texture, .CLAMP)
	}

	// LoadRenderTexture attaches depth as a renderbuffer, which a shader cannot
	// sample. Reprojection was then reading 0 and blending unrelated pixels.
	if !scene_use_depth_texture(&taa.scene) {
		taa_free_targets(taa)
		return false
	}

	taa.width = width
	taa.height = height
	taa.write = 0
	return true
}

// Swaps the scene's depth renderbuffer for a texture, and puts that id in
// scene.depth so the resolve can bind it. The framebuffer delete still frees
// whichever depth object is attached.
scene_use_depth_texture :: proc(scene: ^rl.RenderTexture2D) -> bool {
	old := scene.depth.id
	depth := rlgl.LoadTextureDepth(scene.texture.width, scene.texture.height, false)
	if depth == 0 {
		return false
	}
	rlgl.FramebufferAttach(
		scene.id,
		depth,
		c.int(rlgl.FramebufferAttachType.DEPTH),
		c.int(rlgl.FramebufferAttachTextureType.TEXTURE2D),
		0,
	)
	if !rlgl.FramebufferComplete(scene.id) {
		rlgl.UnloadTexture(depth)
		rlgl.FramebufferAttach(
			scene.id,
			old,
			c.int(rlgl.FramebufferAttachType.DEPTH),
			c.int(rlgl.FramebufferAttachTextureType.RENDERBUFFER),
			0,
		)
		return false
	}
	renderbuffer_free(old)
	scene.depth.id = depth
	return true
}

taa_free_targets :: proc(taa: ^TAA) {
	if taa.scene.id != 0 {
		rl.UnloadRenderTexture(taa.scene)
	}
	if taa.history[0].id != 0 {
		rl.UnloadRenderTexture(taa.history[0])
	}
	if taa.history[1].id != 0 {
		rl.UnloadRenderTexture(taa.history[1])
	}
	taa.scene = {}
	taa.history = {}
	taa.width = 0
	taa.height = 0
	taa.ready = false
}
