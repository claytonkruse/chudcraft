package main

import "core:c"
import "core:math"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// Steve, from the Faithful 32x wide skin. The body is 32 pixels tall in that
// skin's model and PLAYER_HEIGHT blocks tall here, so the camera and the mesh agree.
// The head is its own mesh, pivoted at the neck, so it can follow the look pitch.

Player_Model :: struct {
	torso:                 rl.Mesh,
	head:                  rl.Mesh,
	right_leg, left_leg:   rl.Mesh,
	right_arm, left_arm:   rl.Mesh,
	material:              rl.Material,
	preview:               rl.RenderTexture2D,
	ready:                 bool,
}

// A stride is about two blocks, and the limbs reach roughly a right angle at a full walk.
WALK_STRIDE :: f32(2.8)
WALK_LEG    :: f32(1.15)
WALK_ARM    :: f32(0.9)
WALK_BOB    :: f32(0.055)

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

	// Each limb is its own mesh so the walk can swing it from the hip or shoulder.
	// The second box is the jacket layer, a hair larger so it sits outside the skin.
	add_part(&build, {-4, 0, -2}, {4, 12, 4}, 0, 0, 16, texture)
	add_part(&build, {-4, 0, -2}, {4, 12, 4}, 0.25, 0, 32, texture)
	renderer.player.right_leg = upload_player_mesh(&build)
	clear_mesh_build(&build)

	add_part(&build, {0, 0, -2}, {4, 12, 4}, 0, 16, 48, texture)
	add_part(&build, {0, 0, -2}, {4, 12, 4}, 0.25, 0, 48, texture)
	renderer.player.left_leg = upload_player_mesh(&build)
	clear_mesh_build(&build)

	add_part(&build, {-4, 12, -2}, {8, 12, 4}, 0, 16, 16, texture)
	add_part(&build, {-4, 12, -2}, {8, 12, 4}, 0.25, 16, 32, texture)
	renderer.player.torso = upload_player_mesh(&build)
	clear_mesh_build(&build)

	add_part(&build, {-8, 12, -2}, {4, 12, 4}, 0, 40, 16, texture)
	add_part(&build, {-8, 12, -2}, {4, 12, 4}, 0.25, 40, 32, texture)
	renderer.player.right_arm = upload_player_mesh(&build)
	clear_mesh_build(&build)

	add_part(&build, {4, 12, -2}, {4, 12, 4}, 0, 32, 48, texture)
	add_part(&build, {4, 12, -2}, {4, 12, 4}, 0.25, 48, 48, texture)
	renderer.player.left_arm = upload_player_mesh(&build)
	clear_mesh_build(&build)
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
	unload_player_mesh(model.torso)
	unload_player_mesh(model.head)
	unload_player_mesh(model.right_leg)
	unload_player_mesh(model.left_leg)
	unload_player_mesh(model.right_arm)
	unload_player_mesh(model.left_arm)
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

// Everyone except the local player. The local body is drawn only in third person.
draw_remote_players :: proc(renderer: ^Renderer, others: []Remote_View) {
	for other in others {
		draw_player_model(renderer, other.position, other.yaw, other.pitch, other.phase, other.amount)
	}
}

draw_local_player :: proc(renderer: ^Renderer, client: ^Client) {
	cycle := client.walks[client.id]
	player := client.player
	draw_player_model(renderer, player.position, player.yaw, player.pitch, cycle.phase, cycle.amount)
}

// Steps the stride from how far each remote player moved. A warp, such as a
// respawn, does not spin the limbs. Call this after the views are refreshed.
advance_walk_cycles :: proc(client: ^Client, dt: f32) {
	step := max(dt, 0.001)
	seen: [NET_MAX_PLAYERS]u32
	n := 0
	for &other in client.others {
		if n < len(seen) {
			seen[n] = other.id
			n += 1
		}
		cycle := step_walk(client.walks[other.id], other.position.x, other.position.z, step)
		client.walks[other.id] = cycle
		other.phase = cycle.phase
		other.amount = cycle.amount
	}
	// The local stride, so third person swings the arms and legs you are moving.
	local := step_walk(client.walks[client.id], client.player.position.x, client.player.position.z, step)
	client.walks[client.id] = local

	stale: [NET_MAX_PLAYERS]u32
	sn := 0
	for id, _ in client.walks {
		found := false
		for i in 0 ..< n {
			if seen[i] == id {
				found = true
				break
			}
		}
		if !found && id != client.id && sn < len(stale) {
			stale[sn] = id
			sn += 1
		}
	}
	for i in 0 ..< sn {
		delete_key(&client.walks, stale[i])
	}
}

step_walk :: proc(cycle: Walk_Cycle, x, z, step: f32) -> Walk_Cycle {
	next := cycle
	target: f32
	if next.has {
		dx := x - next.x
		dz := z - next.z
		dist := math.sqrt(dx*dx + dz*dz)
		if dist < 1 {
			next.phase += dist * WALK_STRIDE
			speed := dist / step
			target = clamp(speed/WALK_SPEED, 0, 1)
		}
	}
	blend := f32(1 - math.exp(f64(-12*step)))
	next.amount += (target - next.amount) * blend
	next.x = x
	next.z = z
	next.has = true
	return next
}

draw_player_model :: proc(renderer: ^Renderer, position: [3]f32, yaw, pitch, phase, amount: f32) {
	model := &renderer.player
	if !model.ready {
		return
	}
	// Highest mid-stride, planted when a leg is fully extended.
	bob := math.abs(math.sin(phase)) * WALK_BOB * amount
	pos := position
	pos.y += bob
	swing := math.cos(phase) * amount
	scale := f32(PLAYER_HEIGHT) / 32

	turn := rl.MatrixRotateY(yaw)
	place := rl.MatrixTranslate(pos.x, pos.y, pos.z)
	draw_player_mesh(model.torso, model.material, place*turn)
	draw_player_mesh(model.right_leg, model.material, place*turn*limb_swing({-2 * scale, 12 * scale, 0}, swing*WALK_LEG))
	draw_player_mesh(model.left_leg, model.material, place*turn*limb_swing({2 * scale, 12 * scale, 0}, -swing*WALK_LEG))
	draw_player_mesh(model.right_arm, model.material, place*turn*limb_swing({-6 * scale, 24 * scale, 0}, -swing*WALK_ARM))
	draw_player_mesh(model.left_arm, model.material, place*turn*limb_swing({6 * scale, 24 * scale, 0}, swing*WALK_ARM))

	neck_y := pos.y + 24*scale
	neck := rl.MatrixTranslate(pos.x, neck_y, pos.z)
	nod := rl.MatrixRotateX(-pitch)
	draw_player_mesh(model.head, model.material, neck*(turn*nod))
}

// First person, in view space, so the arm stays on the right of the screen.
// The shoulder of the right-arm mesh sits at this point in feet space.
viewmodel_arm :: proc() -> rl.Matrix {
	scale := f32(PLAYER_HEIGHT) / 32
	pivot := [3]f32{-6 * scale, 24 * scale, 0}
	// The mesh hangs in -Y. Past a quarter turn it points up and forward, so the
	// forearm runs from the bottom-right corner toward the middle of the view.
	return rl.MatrixTranslate(0.58, -0.62, -0.40) *
		rl.MatrixRotateZ(-0.30) *
		rl.MatrixRotateY(0.90) *
		rl.MatrixRotateX(2.15) *
		rl.MatrixTranslate(-pivot.x, -pivot.y, -pivot.z)
}

// A bit larger than a dropped cube, turned so the top and two sides read.
VIEW_ITEM_SCALE :: f32(0.34)

viewmodel_item :: proc() -> rl.Matrix {
	scale := rl.MatrixScale(VIEW_ITEM_SCALE, VIEW_ITEM_SCALE, VIEW_ITEM_SCALE)
	return rl.MatrixTranslate(0.44, -0.30, -0.68) *
		rl.MatrixRotateY(0.65) *
		rl.MatrixRotateX(0.40) *
		scale
}

// A tool texture is already drawn on a diagonal, so a small tilt is enough to
// sit it in the corner of the view.
viewmodel_tool :: proc() -> rl.Matrix {
	scale := rl.MatrixScale(0.62, 0.62, 0.62)
	return rl.MatrixTranslate(0.58, -0.38, -0.72) *
		rl.MatrixRotateZ(-0.45) *
		scale
}

// item is empty for the bare hand. Drawn with the depth buffer cleared so a
// wall in front of the eyes cannot clip it. Water blends the same way the
// world pass does, or the held cube would write depth and look solid.
draw_viewmodel :: proc(renderer: ^Renderer, camera: rl.Camera3D, item: Item) {
	arm := item_empty(item)
	if arm && !renderer.player.ready {
		return
	}
	rl.BeginMode3D(camera)
	// Identity view: the transforms above are already relative to the camera.
	// BeginMode3D has installed the world view, which would park the arm in the world.
	rlgl.SetMatrixModelview(rl.Matrix(1))
	rlgl.EnableDepthTest()
	rlgl.EnableDepthMask()
	rlgl.DrawRenderBatchActive()
	if !clear_depth_buffer() {
		rlgl.DisableDepthTest()
	}
	if arm {
		draw_player_mesh(renderer.player.right_arm, renderer.player.material, viewmodel_arm())
	} else if item.kind == .Block {
		draw_held_item(renderer, item.block, viewmodel_item())
	} else {
		draw_item_sprite(renderer, item, viewmodel_tool())
	}
	rlgl.EnableDepthTest()
	rlgl.EnableDepthMask()
	rl.EndMode3D()
}

draw_held_item :: proc(renderer: ^Renderer, block: Block, transform: rl.Matrix) {
	mesh := &renderer.item_meshes[block]
	for surface in Surface {
		if mesh.filled[surface] && surface_pass(surface) != .Translucent {
			rl.DrawMesh(mesh.meshes[surface], renderer.materials[surface], transform)
		}
	}
	blended := false
	for surface in Surface {
		if !mesh.filled[surface] || surface_pass(surface) != .Translucent {
			continue
		}
		if !blended {
			rl.BeginBlendMode(.ALPHA)
			rlgl.DisableDepthMask()
			blended = true
		}
		rl.DrawMesh(mesh.meshes[surface], renderer.materials[surface], transform)
	}
	if blended {
		rlgl.EnableDepthMask()
		rl.EndBlendMode()
	}
}

// Positive angle swings the far end of the limb forward, along the body's +Z.
limb_swing :: proc(pivot: [3]f32, angle: f32) -> rl.Matrix {
	return rl.MatrixTranslate(pivot.x, pivot.y, pivot.z) *
		rl.MatrixRotateX(-angle) *
		rl.MatrixTranslate(-pivot.x, -pivot.y, -pivot.z)
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
	draw_player_model(renderer, {}, yaw, pitch, 0, 0)
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

clear_mesh_build :: proc(build: ^Mesh_Build) {
	clear(&build.vertices)
	clear(&build.texcoords)
	clear(&build.colors)
	clear(&build.indices)
}

draw_player_mesh :: proc(mesh: rl.Mesh, material: rl.Material, transform: rl.Matrix) {
	if mesh.vertexCount == 0 {
		return
	}
	rl.DrawMesh(mesh, material, transform)
}

unload_player_mesh :: proc(mesh: rl.Mesh) {
	if mesh.vertexCount > 0 {
		rl.UnloadMesh(mesh)
	}
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
