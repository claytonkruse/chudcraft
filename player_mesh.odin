package main

import "core:c"
import "core:math"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// Steve, from the Faithful 32x wide skin. The body is 32 pixels tall in that
// skin's model and PLAYER_HEIGHT blocks tall here, so the camera and the mesh agree.
// The head is its own mesh, pivoted at the neck, so it can follow the look pitch.

Player_Model :: struct {
	body, head: rl.Mesh,
	material:   rl.Material,
	preview:    rl.RenderTexture2D,
	ready:      bool,
}

player_model_init :: proc(renderer: ^Renderer) {
	texture := rl.LoadTexture("assets/textures/steve.png")
	if texture.id == 0 {
		return
	}
	prepare_texture(&texture)

	build: Mesh_Build
	defer {
		delete(build.vertices)
		delete(build.texcoords)
		delete(build.colors)
		delete(build.indices)
	}

	// Body, arms, and legs, then the jacket and sleeves a hair larger so they
	// sit outside the skin instead of fighting it for the same depth.
	add_part(&build, {-4, 0, -2}, {4, 12, 4}, 0, 0, 16, texture)
	add_part(&build, {0, 0, -2}, {4, 12, 4}, 0, 16, 48, texture)
	add_part(&build, {-4, 12, -2}, {8, 12, 4}, 0, 16, 16, texture)
	add_part(&build, {-8, 12, -2}, {4, 12, 4}, 0, 40, 16, texture)
	add_part(&build, {4, 12, -2}, {4, 12, 4}, 0, 32, 48, texture)
	add_part(&build, {-4, 0, -2}, {4, 12, 4}, 0.25, 0, 32, texture)
	add_part(&build, {0, 0, -2}, {4, 12, 4}, 0.25, 0, 48, texture)
	add_part(&build, {-4, 12, -2}, {8, 12, 4}, 0.25, 16, 32, texture)
	add_part(&build, {-8, 12, -2}, {4, 12, 4}, 0.25, 40, 32, texture)
	add_part(&build, {4, 12, -2}, {4, 12, 4}, 0.25, 48, 48, texture)
	renderer.player.body = upload_player_mesh(&build)

	clear(&build.vertices)
	clear(&build.texcoords)
	clear(&build.colors)
	clear(&build.indices)
	// Neck at the origin. The hat is the second layer of the head.
	add_part(&build, {-4, 0, -4}, {8, 8, 8}, 0, 0, 0, texture)
	add_part(&build, {-4, 0, -4}, {8, 8, 8}, 0.5, 32, 0, texture)
	renderer.player.head = upload_player_mesh(&build)

	material := rl.LoadMaterialDefault()
	rl.SetMaterialTexture(&material, .ALBEDO, texture)
	if renderer.cutout.id != 0 {
		material.shader = renderer.cutout
	}
	renderer.player.material = material
	renderer.player.preview = rl.LoadRenderTexture(300, 400)
	rl.SetTextureFilter(renderer.player.preview.texture, .POINT)
	renderer.player.ready = true
}

player_model_destroy :: proc(model: ^Player_Model) {
	if !model.ready {
		return
	}
	rl.UnloadMesh(model.body)
	rl.UnloadMesh(model.head)
	// UnloadMaterial frees the Steve texture. The cutout shader is shared, so
	// hand the default back first, the same way the block materials do.
	model.material.shader = {
		id   = rlgl.GetShaderIdDefault(),
		locs = rlgl.GetShaderLocsDefault(),
	}
	rl.UnloadMaterial(model.material)
	rl.UnloadRenderTexture(model.preview)
	model.ready = false
}

// Other players only. The camera sits inside the local player's head.
draw_remote_players :: proc(renderer: ^Renderer, others: []Remote_View) {
	for other in others {
		draw_player_model(renderer, other.position, other.yaw, other.pitch)
	}
}

draw_player_model :: proc(renderer: ^Renderer, position: [3]f32, yaw, pitch: f32) {
	model := &renderer.player
	if !model.ready {
		return
	}
	turn := rl.MatrixRotateY(yaw)
	place := rl.MatrixTranslate(position.x, position.y, position.z)
	rl.DrawMesh(model.body, model.material, place*turn)

	neck_y := position.y + 24*f32(PLAYER_HEIGHT)/32
	neck := rl.MatrixTranslate(position.x, neck_y, position.z)
	nod := rl.MatrixRotateX(-pitch)
	head := neck * (turn * nod)
	rl.DrawMesh(model.head, model.material, head)
}

// Redraws Steve into the inventory pane. The body turns toward the cursor and
// the head nods with it, the same way the inventory preview in Minecraft does.
draw_player_preview :: proc(renderer: ^Renderer, dest: rl.Rectangle, mouse: rl.Vector2) {
	model := &renderer.player
	if !model.ready || dest.width <= 0 {
		return
	}
	cx := dest.x + dest.width*0.5
	cy := dest.y + dest.height*0.5
	dx := clamp((mouse.x-cx)/(dest.width*0.5), -1, 1)
	dy := clamp((mouse.y-cy)/(dest.height*0.5), -1, 1)
	// A small rest angle so the centered cursor still shows the front and one side.
	yaw := 0.4 + dx*0.8
	pitch := -dy * 0.5

	rl.BeginTextureMode(model.preview)
	rl.ClearBackground(rl.BLANK)
	rl.BeginMode3D({
		position   = {0, 0.95, 4.6},
		target     = {0, 0.9, 0},
		up         = {0, 1, 0},
		fovy       = 26,
		projection = .PERSPECTIVE,
	})
	aspect := f32(model.preview.texture.width) / f32(model.preview.texture.height)
	rlgl.SetMatrixProjection(rl.MatrixPerspective(26*math.RAD_PER_DEG, aspect, 0.05, 30))
	rlgl.DisableColorBlend()
	draw_player_model(renderer, {}, yaw, pitch)
	rlgl.EnableColorBlend()
	rl.EndMode3D()
	rl.EndTextureMode()
	rlgl.Viewport(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight())

	tex := model.preview.texture
	// The pane grows with the storage rows. The picture stays the texture's
	// shape and sits in the middle, instead of stretching to fill the pane.
	fit := dest
	fit.height = dest.width / aspect
	if fit.height > dest.height {
		fit.height = dest.height
		fit.width = dest.height * aspect
	}
	fit.x = dest.x + (dest.width-fit.width)*0.5
	fit.y = dest.y + (dest.height-fit.height)*0.5
	src := rl.Rectangle{0, 0, f32(tex.width), -f32(tex.height)}
	rl.DrawTexturePro(tex, src, fit, {}, 0, rl.WHITE)
}

// One box of the skin. min and size are in the 32-pixel model. u and v are the
// texOffs origin on the 64-pixel skin grid, which Faithful draws at twice that.
// A layer whose texels do not fit the image is skipped, so a legacy skin still
// draws the body and the hat.
add_part :: proc(build: ^Mesh_Build, min, size: [3]f32, inflate, u, v: f32, tex: rl.Texture2D) {
	grid := f32(tex.width) / 64
	su := u * grid
	sv := v * grid
	dx := size.x * grid
	dy := size.y * grid
	dz := size.z * grid
	if sv+dz+dy > f32(tex.height)+0.5 {
		return
	}
	scale := f32(PLAYER_HEIGHT) / 32
	bmin := (min - inflate) * scale
	bsize := (size + inflate*2) * scale
	append_skin_face(build, bmin, bsize, .Neg_X, su, sv+dz, dz, dy, tex)
	append_skin_face(build, bmin, bsize, .Pos_Z, su+dz, sv+dz, dx, dy, tex)
	append_skin_face(build, bmin, bsize, .Pos_X, su+dz+dx, sv+dz, dz, dy, tex)
	append_skin_face(build, bmin, bsize, .Neg_Z, su+dz+dx+dz, sv+dz, dx, dy, tex)
	append_skin_face(build, bmin, bsize, .Pos_Y, su+dz, sv, dx, dz, tex)
	append_skin_face(build, bmin, bsize, .Neg_Y, su+dz+dx, sv, dx, dz, tex)
}

append_skin_face :: proc(build: ^Mesh_Build, min, size: [3]f32, face: Face, u, v, w, h: f32, tex: rl.Texture2D) {
	corners := FACE_CORNER[face]
	first := u16(len(build.vertices) / 3)
	tw := f32(tex.width)
	th := f32(tex.height)
	// Bottom-left, bottom-right, top-right, top-left. v grows down the image,
	// and a texture coordinate of 0 is the top, matching the block faces.
	uvs := [4][2]f32{
		{u / tw, (v + h) / th},
		{(u + w) / tw, (v + h) / th},
		{(u + w) / tw, v / th},
		{u / tw, v / th},
	}
	for i in 0 ..< 4 {
		p := min + [3]f32{corners[i].x * size.x, corners[i].y * size.y, corners[i].z * size.z}
		append(&build.vertices, p.x, p.y, p.z)
		append(&build.texcoords, uvs[i].x, uvs[i].y)
		append(&build.colors, 255, 255, 255, 255)
	}
	append(&build.indices, first, first+1, first+2, first, first+2, first+3)
}

upload_player_mesh :: proc(build: ^Mesh_Build) -> rl.Mesh {
	if len(build.indices) == 0 {
		return {}
	}
	mesh := rl.Mesh{
		vertexCount   = c.int(len(build.vertices) / 3),
		triangleCount = c.int(len(build.indices) / 3),
		vertices      = clone_for_raylib(build.vertices[:]),
		texcoords     = clone_for_raylib(build.texcoords[:]),
		colors        = clone_for_raylib(build.colors[:]),
		indices       = clone_for_raylib(build.indices[:]),
	}
	rl.UploadMesh(&mesh, false)
	return mesh
}
