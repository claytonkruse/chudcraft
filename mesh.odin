package main

import "core:c"
import "core:math"
import "core:slice"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// One mesh per texture, so drawing a chunk costs a few calls instead of one per block.
Surface :: enum {
	Grass_Top,
	Grass_Side,
	Dirt,
	Stone,
	Bedrock,
	Coal_Ore,
	Iron_Ore,
	Gold_Ore,
	Water,
	// The log's end grain differs from its bark, so it needs two surfaces.
	Oak_Log_Top,
	Oak_Log_Side,
	Oak_Leaves,
	Oak_Planks,
	Workbench_Top,
	Workbench_Front,
	Oak_Sapling,
	Sand,
	Gravel,
	// Not in the atlas. A door is a thin panel with its own picture, both halves
	// stacked in that one texture.
	Oak_Door,
}

// Which draw pass a surface belongs to. Cutout keeps depth writes on and throws away
// its transparent texels, which avoids sorting; only genuinely translucent surfaces
// have to blend.
Surface_Pass :: enum {
	Opaque,
	Cutout,
	Translucent,
}

surface_pass :: proc(surface: Surface) -> Surface_Pass {
	#partial switch surface {
	case .Water:
		return .Translucent
	case .Oak_Leaves, .Oak_Sapling:
		return .Cutout
	}
	return .Opaque
}

Face :: enum {
	Pos_X,
	Neg_X,
	Pos_Y,
	Neg_Y,
	Pos_Z,
	Neg_Z,
}

// The block sitting against a face, which is what decides whether the face is visible.
@(rodata)
FACE_OFFSET := [Face][3]int {
	.Pos_X = { 1,  0,  0},
	.Neg_X = {-1,  0,  0},
	.Pos_Y = { 0,  1,  0},
	.Neg_Y = { 0, -1,  0},
	.Pos_Z = { 0,  0,  1},
	.Neg_Z = { 0,  0, -1},
}

// Corner offsets within a block, wound counter-clockwise seen from outside so that
// backface culling keeps them. Paired with FACE_UV to hold the texture's orientation.
@(rodata)
FACE_CORNER := [Face][4][3]f32 {
	.Pos_X = {{1, 0, 1}, {1, 0, 0}, {1, 1, 0}, {1, 1, 1}},
	.Neg_X = {{0, 0, 0}, {0, 0, 1}, {0, 1, 1}, {0, 1, 0}},
	.Pos_Y = {{0, 1, 1}, {1, 1, 1}, {1, 1, 0}, {0, 1, 0}},
	.Neg_Y = {{0, 0, 0}, {1, 0, 0}, {1, 0, 1}, {0, 0, 1}},
	.Pos_Z = {{0, 0, 1}, {1, 0, 1}, {1, 1, 1}, {0, 1, 1}},
	.Neg_Z = {{1, 0, 0}, {0, 0, 0}, {0, 1, 0}, {1, 1, 0}},
}

@(rodata)
FACE_UV := [4][2]f32{{0, 1}, {1, 1}, {1, 0}, {0, 0}}

// Brightness of each face of a block item. The icon is baked with the sun off,
// and the held cube is one small mesh, so this is what makes the sides read:
// top full, Z sides a step down, X sides another, bottom half.
@(rodata)
FACE_LIGHT := [Face]f32{
	.Pos_Y = 1,
	.Neg_Y = 0.5,
	.Pos_Z = 0.8,
	.Neg_Z = 0.8,
	.Pos_X = 0.6,
	.Neg_X = 0.6,
}

// Plains grass color. The Faithful grass top is grayscale and gets multiplied by this.
GRASS_TINT :: [4]u8{145, 189, 89, 255}

// Minecraft's plains water color. The Faithful water texture is grayscale, and its own
// uniform alpha of 180 is what makes water translucent, so this tint keeps alpha at 255.
WATER_TINT :: [4]u8{63, 118, 228, 255}

// Plains leaf color, for the same reason as GRASS_TINT: the leaf texture is grayscale.
FOLIAGE_TINT :: [4]u8{76, 158, 57, 255}

WHITE_TINT :: [4]u8{255, 255, 255, 255}

// Placeholder art from Faithful 32x. Replace these before distributing the game.
// https://faithfulpack.net
Block_Textures :: struct {
	grass_top:  rl.Texture2D,
	grass_side: rl.Texture2D,
	dirt:       rl.Texture2D,
	stone:      rl.Texture2D,
	bedrock:    rl.Texture2D,
	coal_ore:   rl.Texture2D,
	iron_ore:   rl.Texture2D,
	gold_ore:   rl.Texture2D,
	water:      rl.Texture2D,
	oak_log_top:  rl.Texture2D,
	oak_log_side: rl.Texture2D,
	oak_leaves:   rl.Texture2D,
	oak_planks:   rl.Texture2D,
	workbench_top:   rl.Texture2D,
	workbench_front: rl.Texture2D,
	oak_sapling:     rl.Texture2D,
	sand:            rl.Texture2D,
	gravel:          rl.Texture2D,
	oak_door:        rl.Texture2D,
}

// Flat pictures for sticks and tools. Blocks keep the cube icons.
Item_Sprites :: struct {
	stick:          rl.Texture2D,
	wood_shovel:    rl.Texture2D,
	wood_pickaxe:   rl.Texture2D,
	stone_shovel:   rl.Texture2D,
	stone_pickaxe:  rl.Texture2D,
	stone_axe:      rl.Texture2D,
	wood_axe:       rl.Texture2D,
	iron_shovel:    rl.Texture2D,
	iron_pickaxe:   rl.Texture2D,
	iron_axe:       rl.Texture2D,
	iron_ingot:     rl.Texture2D,
}

// A chunk's geometry on the GPU, kept between frames and rebuilt only when the
// chunk is marked dirty. A surface with no visible faces has no mesh.
Chunk_Mesh :: struct {
	meshes: [Surface]rl.Mesh,
	filled: [Surface]bool,
}

// Scratch geometry, reused for every chunk so meshing does not allocate per chunk.
Mesh_Build :: struct {
	vertices:  [dynamic]f32,
	texcoords: [dynamic]f32,
	colors:    [dynamic]u8,
	indices:   [dynamic]u16,
	// Water only. texcoords2 is (shore distance, open-water fetch).
	// normals.xy points toward the nearest shore; normals.z is 1 on the
	// free surface so the shader leaves every other vertex still.
	texcoords2: [dynamic]f32,
	normals:    [dynamic]f32,
}

Renderer :: struct {
	textures:  Block_Textures,
	materials: [Surface]rl.Material,
	meshes:    map[[3]int]^World_Mesh,
	build:     [Surface]Mesh_Build,
	// Shared by every cutout surface, which is why renderer_destroy cannot let
	// UnloadMaterial free it.
	cutout:    rl.Shader,
	// Opaque drops and held blocks. Chunks use the atlas shader instead.
	mesh_shader: rl.Shader,
	water_shader: rl.Shader,
	wave_time:    c.int,
	atlas_light: Light_Locs,
	cutout_light: Light_Locs,
	mesh_light: Light_Locs,
	water_light: Light_Locs,
	shadow_shader: rl.Shader,
	shadow_material: rl.Material,
	shadow_target: rl.RenderTexture2D,
	shadow_cutout: c.int,
	stars: [STAR_COUNT]Star,
	star_dot: rl.Texture2D,
	// One picture per block, drawn in the hotbar and the inventory. Baked once;
	// a slot redraws the picture, not the mesh.
	icons:     [Block]rl.RenderTexture2D,
	// The cube those pictures were drawn from, kept so a drop can spin in the world.
	item_meshes: [Block]Chunk_Mesh,
	sprites:   Item_Sprites,
	// Ten crack pictures, indexed by how far the dig has gotten.
	breaks:    [BREAK_STAGES]rl.Texture2D,
	break_material: rl.Material,
	// One upright quad and a material whose texture is swapped per item. The
	// material must not own that texture, or unloading it would free the sprite.
	// item_card is that picture extruded; the Z scale on the draw sets the thickness.
	item_quad: rl.Mesh,
	item_card: rl.Mesh,
	item_material: rl.Material,
	player:    Player_Model,
	// Dirty chunks, nearest the player first. A frame meshes the ground underfoot
	// and leaves the rest of a newly loaded column for the frames after.
	pending_meshes: [dynamic]Pending_Mesh,
	// Opaque block textures packed into one picture. World chunks sample it with
	// atlas_shader; icons keep the loose textures.
	atlas:          rl.Texture2D,
	atlas_shader:   rl.Shader,
	atlas_material: rl.Material,
	atlas_tiles:    [16][4]f32,
	// Planes filled by draw_world and reused for the water pass.
	frustum:        [6][4]f32,
	frustum_ready:  bool,
	// One face direction of solidity, reused while a chunk is meshed.
	masks:          [ATLAS_COUNT][CHUNK_SIZE]u32,
}

// A world chunk on the GPU: one greedy opaque mesh (split if the indices would
// pass 65535), plus leaves and water. Water tops are subdivided so a wave
// can bend inside a block.
World_Mesh :: struct {
	opaque: [dynamic]rl.Mesh,
	leaves: [dynamic]rl.Mesh,
	water:  [dynamic]rl.Mesh,
	plants: [dynamic]rl.Mesh,
	doors:  [dynamic]rl.Mesh,
}

ATLAS_COUNT :: 15
ATLAS_PAD   :: 1

renderer_init :: proc() -> Renderer {
	renderer: Renderer
	renderer.textures = load_block_textures()
	// nil keeps raylib's default vertex shader, which is all this needs to replace.
	renderer.cutout = rl.LoadShader("assets/shaders/world.vs", "assets/shaders/cutout.fs")
	renderer.mesh_shader = rl.LoadShader("assets/shaders/world.vs", "assets/shaders/mesh.fs")
	renderer.water_shader = rl.LoadShader("assets/shaders/water.vs", "assets/shaders/water.fs")
	renderer.wave_time = -1
	if renderer.water_shader.id != 0 {
		renderer.wave_time = rl.GetShaderLocation(renderer.water_shader, "waveTime")
	}

	for surface in Surface {
		material := rl.LoadMaterialDefault()
		if texture := surface_texture(renderer.textures, surface); texture.id != 0 {
			rl.SetMaterialTexture(&material, .ALBEDO, texture)
		}
		if surface_pass(surface) == .Cutout && renderer.cutout.id != 0 {
			material.shader = renderer.cutout
		}
		renderer.materials[surface] = material
	}
	for surface in Surface {
		if surface_pass(surface) == .Opaque && renderer.mesh_shader.id != 0 {
			renderer.materials[surface].shader = renderer.mesh_shader
		}
		if surface_pass(surface) == .Translucent && renderer.water_shader.id != 0 {
			renderer.materials[surface].shader = renderer.water_shader
		}
	}
	renderer.cutout_light = light_locs(renderer.cutout)
	renderer.mesh_light = light_locs(renderer.mesh_shader)
	renderer.water_light = light_locs(renderer.water_shader)
	light_off := Sky{}
	light_bind(renderer.cutout, renderer.cutout_light, light_off, rl.Matrix(1), 0, 0)
	light_bind(renderer.mesh_shader, renderer.mesh_light, light_off, rl.Matrix(1), 0, 0)
	light_bind(renderer.water_shader, renderer.water_light, light_off, rl.Matrix(1), 0, 0)
	build_block_icons(&renderer)
	renderer.sprites = load_item_sprites()
	renderer.breaks = load_break_textures()
	renderer.break_material = rl.LoadMaterialDefault()
	renderer.item_quad = build_item_quad()
	renderer.item_card = build_item_card()
	renderer.item_material = rl.LoadMaterialDefault()
	if renderer.cutout.id != 0 {
		renderer.item_material.shader = renderer.cutout
	}
	player_model_init(&renderer)
	build_block_atlas(&renderer)
	return renderer
}

renderer_destroy :: proc(renderer: ^Renderer) {
	for _, mesh in renderer.meshes {
		unload_world_mesh(mesh)
		free(mesh)
	}
	delete(renderer.meshes)
	delete(renderer.pending_meshes)
	for block in Block {
		unload_chunk_mesh(&renderer.item_meshes[block])
	}

	for surface in Surface {
		// UnloadMaterial frees any shader that is not raylib's default, which would
		// free the shared cutout shader once per cutout surface. Hand the default back
		// so the one unload below is the only one.
		renderer.materials[surface].shader = {
			id   = rlgl.GetShaderIdDefault(),
			locs = rlgl.GetShaderLocsDefault(),
		}
		// This also unloads the texture bound to the material, so the textures in
		// `renderer.textures` must not be unloaded again.
		rl.UnloadMaterial(renderer.materials[surface])

		delete(renderer.build[surface].vertices)
		delete(renderer.build[surface].texcoords)
		delete(renderer.build[surface].colors)
		delete(renderer.build[surface].indices)
		delete(renderer.build[surface].texcoords2)
		delete(renderer.build[surface].normals)
	}

	renderer.item_material.shader = {
		id   = rlgl.GetShaderIdDefault(),
		locs = rlgl.GetShaderLocsDefault(),
	}
	rl.SetMaterialTexture(&renderer.item_material, .ALBEDO, {id = rlgl.GetTextureIdDefault()})
	rl.UnloadMaterial(renderer.item_material)
	if renderer.item_quad.vertexCount > 0 {
		rl.UnloadMesh(renderer.item_quad)
	}
	if renderer.item_card.vertexCount > 0 {
		rl.UnloadMesh(renderer.item_card)
	}
	unload_item_sprites(renderer.sprites)
	rl.SetMaterialTexture(&renderer.break_material, .ALBEDO, {id = rlgl.GetTextureIdDefault()})
	rl.UnloadMaterial(renderer.break_material)
	unload_break_textures(renderer.breaks)

	if renderer.atlas.id != 0 {
		renderer.atlas_material.shader = {
			id   = rlgl.GetShaderIdDefault(),
			locs = rlgl.GetShaderLocsDefault(),
		}
		rl.UnloadMaterial(renderer.atlas_material)
		rl.UnloadShader(renderer.atlas_shader)
	}
	if renderer.cutout.id != 0 {
		rl.UnloadShader(renderer.cutout)
	}
	if renderer.mesh_shader.id != 0 {
		rl.UnloadShader(renderer.mesh_shader)
	}
	if renderer.water_shader.id != 0 {
		rl.UnloadShader(renderer.water_shader)
	}
	renderer.shadow_material.shader = {
		id   = rlgl.GetShaderIdDefault(),
		locs = rlgl.GetShaderLocsDefault(),
	}
	rl.SetMaterialTexture(&renderer.shadow_material, .ALBEDO, {id = rlgl.GetTextureIdDefault()})
	rl.UnloadMaterial(renderer.shadow_material)
	if renderer.shadow_shader.id != 0 {
		rl.UnloadShader(renderer.shadow_shader)
	}
	if renderer.shadow_target.id != 0 {
		rl.UnloadRenderTexture(renderer.shadow_target)
	}
	if renderer.star_dot.id != 0 {
		rl.UnloadTexture(renderer.star_dot)
	}
	for block in Block {
		if renderer.icons[block].id != 0 {
			rl.UnloadRenderTexture(renderer.icons[block])
		}
	}
	player_model_destroy(&renderer.player)
}

// How many chunk meshes a frame will build. The column under the player is a
// handful of these, so the ground is visible on the frame it loads and the
// rest of the world catches up over the frames after.
MESH_PER_FRAME :: 2

Pending_Mesh :: struct {
	key:  [3]int,
	dist: int,
}

mesh_nearer :: proc(a, b: Pending_Mesh) -> bool {
	return a.dist < b.dist
}

// Rebuilds the dirty chunks closest to focus, then draws the depth-writing passes.
// Water is draw_water, and it has to come after players and drops. Those write
// depth; water does not, so anything drawn after it composites in front of the
// surface even when it is standing behind it.
// retired is the chunks just unloaded. Their GPU meshes go with them, so this
// pass does not walk every mesh looking for a missing chunk.
draw_world :: proc(renderer: ^Renderer, world: ^World, camera: rl.Camera3D, focus: [3]int, retired: [][3]int) {
	for key in retired {
		mesh := renderer.meshes[key]
		if mesh == nil {
			continue
		}
		unload_world_mesh(mesh)
		free(mesh)
		delete_key(&renderer.meshes, key)
	}

	mesh_dirty(renderer, world, focus)
	fill_frustum(renderer, camera)

	draw_world_meshes(renderer, .Opaque)
	draw_world_meshes(renderer, .Cutout)
}

// Water must not hide what is behind it. With depth writes off it also cannot hide
// other water, which is what lets this pass skip sorting the meshes entirely.
draw_water :: proc(renderer: ^Renderer, time: f32) {
	if renderer.water_shader.id != 0 && renderer.wave_time >= 0 {
		t := time
		rl.SetShaderValue(renderer.water_shader, renderer.wave_time, &t, .FLOAT)
	}
	rl.BeginBlendMode(.ALPHA)
	rlgl.DisableDepthMask()
	draw_world_meshes(renderer, .Translucent)
	rlgl.EnableDepthMask()
	rl.EndBlendMode()
}

mesh_dirty :: proc(renderer: ^Renderer, world: ^World, focus: [3]int) {
	clear(&renderer.pending_meshes)
	for key in world.dirty {
		chunk := world.chunks[key]
		if chunk == nil || !chunk.listed {
			continue
		}
		chunk.listed = false
		if !chunk.dirty {
			continue
		}
		dx := key.x - focus.x
		dy := key.y - focus.y
		dz := key.z - focus.z
		append(&renderer.pending_meshes, Pending_Mesh{key, dx * dx + dy * dy + dz * dz})
	}
	clear(&world.dirty)
	slice.sort_by(renderer.pending_meshes[:], mesh_nearer)
	n := min(len(renderer.pending_meshes), MESH_PER_FRAME)
	for i in 0 ..< n {
		key := renderer.pending_meshes[i].key
		chunk := world.chunks[key]
		if chunk == nil {
			continue
		}
		mesh := renderer.meshes[key]
		if mesh == nil {
			mesh = new(World_Mesh)
			renderer.meshes[key] = mesh
		}
		build_chunk_mesh(renderer, world, key, mesh)
		chunk.dirty = false
		chunk.listed = false
	}
	for i in n ..< len(renderer.pending_meshes) {
		key := renderer.pending_meshes[i].key
		chunk := world.chunks[key]
		if chunk == nil || !chunk.dirty {
			continue
		}
		chunk.listed = true
		append(&world.dirty, key)
	}
}

fill_frustum :: proc(renderer: ^Renderer, camera: rl.Camera3D) {
	view := rl.GetCameraMatrix(camera)
	proj := rlgl.GetMatrixProjection()
	clip := proj * view
	row := [4][4]f32 {
		{clip[0, 0], clip[0, 1], clip[0, 2], clip[0, 3]},
		{clip[1, 0], clip[1, 1], clip[1, 2], clip[1, 3]},
		{clip[2, 0], clip[2, 1], clip[2, 2], clip[2, 3]},
		{clip[3, 0], clip[3, 1], clip[3, 2], clip[3, 3]},
	}
	renderer.frustum[0] = row[3] + row[0]
	renderer.frustum[1] = row[3] - row[0]
	renderer.frustum[2] = row[3] + row[1]
	renderer.frustum[3] = row[3] - row[1]
	renderer.frustum[4] = row[3] + row[2]
	renderer.frustum[5] = row[3] - row[2]
	renderer.frustum_ready = true
}

chunk_in_frustum :: proc(renderer: ^Renderer, key: [3]int) -> bool {
	if !renderer.frustum_ready {
		return true
	}
	minp := [3]f32 {
		f32(key.x * CHUNK_SIZE) - 0.5,
		f32(key.y * CHUNK_SIZE),
		f32(key.z * CHUNK_SIZE) - 0.5,
	}
	// Waves lift the top of a chunk by most of a block, and a trough drops it.
	maxp := minp + CHUNK_SIZE
	minp.y -= 1
	maxp.y += 1
	for plane in renderer.frustum {
		x := maxp.x if plane[0] >= 0 else minp.x
		y := maxp.y if plane[1] >= 0 else minp.y
		z := maxp.z if plane[2] >= 0 else minp.z
		if plane[0] * x + plane[1] * y + plane[2] * z + plane[3] < 0 {
			return false
		}
	}
	return true
}

draw_world_meshes :: proc(renderer: ^Renderer, pass: Surface_Pass) {
	for key, mesh in renderer.meshes {
		if !chunk_in_frustum(renderer, key) {
			continue
		}
		origin := [3]f32 {
			f32(key.x * CHUNK_SIZE) - 0.5,
			f32(key.y * CHUNK_SIZE),
			f32(key.z * CHUNK_SIZE) - 0.5,
		}
		transform := rl.MatrixTranslate(origin.x, origin.y, origin.z)
		list: []rl.Mesh
		material: rl.Material
		switch pass {
		case .Opaque:
			list = mesh.opaque[:]
			material = renderer.atlas_material
		case .Cutout:
			list = mesh.leaves[:]
			material = renderer.materials[.Oak_Leaves]
		case .Translucent:
			list = mesh.water[:]
			material = renderer.materials[.Water]
		}
		for part in list {
			rl.DrawMesh(part, material, transform)
		}
		if pass == .Cutout {
			for part in mesh.plants {
				rl.DrawMesh(part, renderer.materials[.Oak_Sapling], transform)
			}
		}
		if pass == .Opaque {
			for part in mesh.doors {
				rl.DrawMesh(part, renderer.materials[.Oak_Door], transform)
			}
		}
	}
}

// Opaque neighbors hide a face, and so does the same see-through block. Leaf
// faces are the exception: they are drawn against every transparent neighbor,
// including other leaves.
face_culled :: proc(block, neighbor: Block) -> bool {
	if block_opaque(neighbor) {
		return true
	}
	if block == .Oak_Leaves {
		return false
	}
	return neighbor == block
}

build_chunk_mesh :: proc(renderer: ^Renderer, world: ^World, key: [3]int, out: ^World_Mesh) {
	opaque := &renderer.build[.Stone]
	leaves := &renderer.build[.Oak_Leaves]
	water := &renderer.build[.Water]
	clear(&opaque.vertices)
	clear(&opaque.texcoords)
	clear(&opaque.colors)
	clear(&opaque.indices)
	clear(&leaves.vertices)
	clear(&leaves.texcoords)
	clear(&leaves.colors)
	clear(&leaves.indices)
	clear(&water.vertices)
	clear(&water.texcoords)
	clear(&water.colors)
	clear(&water.indices)
	clear(&water.texcoords2)
	clear(&water.normals)
	plants := &renderer.build[.Oak_Sapling]
	clear(&plants.vertices)
	clear(&plants.texcoords)
	clear(&plants.colors)
	clear(&plants.indices)
	doors := &renderer.build[.Oak_Door]
	clear(&doors.vertices)
	clear(&doors.texcoords)
	clear(&doors.colors)
	clear(&doors.indices)
	unload_world_mesh(out)

	chunk := world.chunks[key]
	textured := renderer.textures.stone.id != 0
	base := key * CHUNK_SIZE
	shores: map[int]^Water_Shore
	defer {
		for _, shore in shores {
			shore_destroy(shore)
		}
		delete(shores)
	}

	for lx in 0 ..< CHUNK_SIZE {
		for ly in 0 ..< CHUNK_SIZE {
			for lz in 0 ..< CHUNK_SIZE {
				if chunk.blocks[lx][ly][lz] != .Oak_Sapling {
					continue
				}
				if len(plants.indices)+24 > 65535 {
					commit_mesh(plants, &out.plants)
				}
				append_cross(plants, f32(lx), f32(ly), f32(lz))
			}
		}
	}

	for lx in 0 ..< CHUNK_SIZE {
		for ly in 0 ..< CHUNK_SIZE {
			for lz in 0 ..< CHUNK_SIZE {
				door, is_door := door_info(chunk.blocks[lx][ly][lz])
				if !is_door {
					continue
				}
				if len(doors.indices)+36 > 65535 {
					commit_mesh(doors, &out.doors)
				}
				append_world_door(doors, lx, ly, lz, door)
			}
		}
	}

	for face in Face {
		for slice in 0 ..< CHUNK_SIZE {
			for tile in 0 ..< ATLAS_COUNT {
				for row in 0 ..< CHUNK_SIZE {
					renderer.masks[tile][row] = 0
				}
			}
			for a in 0 ..< CHUNK_SIZE {
				for b in 0 ..< CHUNK_SIZE {
					lx, ly, lz := slice_block(face, slice, a, b)
					block := chunk.blocks[lx][ly][lz]
					if block == .Air || block == .Oak_Sapling || block_is_door(block) {
						continue
					}
					neighbor := mesh_neighbor(world, chunk, key, base, lx, ly, lz, face)
					if face_culled(block, neighbor) {
						continue
					}
					surface := block_surface(block, face)
					if surface == .Water {
						append_water_face(water, &out.water, world, &shores, base, lx, ly, lz, face, surface_tint(surface, textured))
						continue
					}
					tile := atlas_tile(surface)
					if tile < 0 {
						ensure_mesh_room(leaves, &out.leaves)
						append_face(leaves, {f32(lx), f32(ly), f32(lz)}, face, surface_tint(surface, textured))
						continue
					}
					tu, tv := face_tile_coord(face, lx, ly, lz)
					renderer.masks[tile][tv] |= u32(1) << uint(tu)
				}
			}
			for tile in 0 ..< ATLAS_COUNT {
				greedy_face(renderer, opaque, out, face, slice, tile, textured)
			}
		}
	}
	commit_mesh(opaque, &out.opaque)
	commit_mesh(leaves, &out.leaves)
	commit_mesh(water, &out.water)
	commit_mesh(plants, &out.plants)
	commit_mesh(doors, &out.doors)
}

slice_block :: proc(face: Face, slice, a, b: int) -> (x, y, z: int) {
	switch face {
	case .Pos_Y, .Neg_Y:
		return a, slice, b
	case .Pos_X, .Neg_X:
		return slice, b, a
	case .Pos_Z, .Neg_Z:
		return a, b, slice
	}
	return 0, 0, 0
}

leaves_list :: proc(out: ^World_Mesh, surface: Surface) -> ^[dynamic]rl.Mesh {
	if surface == .Oak_Leaves {
		return &out.leaves
	}
	return &out.water
}

mesh_neighbor :: proc(world: ^World, chunk: ^Chunk, key, base: [3]int, lx, ly, lz: int, face: Face) -> Block {
	offset := FACE_OFFSET[face]
	nx := lx + offset.x
	ny := ly + offset.y
	nz := lz + offset.z
	if nx >= 0 && nx < CHUNK_SIZE && ny >= 0 && ny < CHUNK_SIZE && nz >= 0 && nz < CHUNK_SIZE {
		return chunk.blocks[nx][ny][nz]
	}
	return get_block(world, base.x + lx + offset.x, base.y + ly + offset.y, base.z + lz + offset.z)
}

// Texture-space column and row of a block on this face. Bit 0 of a mask row is
// texture u 0, so a greedy run repeats the tile in the same direction as the UVs.
face_tile_coord :: proc(face: Face, x, y, z: int) -> (tu, tv: int) {
	switch face {
	case .Pos_Y:
		return x, z
	case .Neg_Y:
		return x, CHUNK_MASK - z
	case .Pos_X:
		return CHUNK_MASK - z, CHUNK_MASK - y
	case .Neg_X:
		return z, CHUNK_MASK - y
	case .Pos_Z:
		return x, CHUNK_MASK - y
	case .Neg_Z:
		return CHUNK_MASK - x, CHUNK_MASK - y
	}
	return 0, 0
}

greedy_face :: proc(renderer: ^Renderer, build: ^Mesh_Build, out: ^World_Mesh, face: Face, slice, tile: int, textured: bool) {
	surface := surface_from_tile(tile)
	tint := surface_tint(surface, textured)
	mask := &renderer.masks[tile]
	for v in 0 ..< CHUNK_SIZE {
		for mask[v] != 0 {
			row := mask[v]
			u := 0
			for row & 1 == 0 {
				row >>= 1
				u += 1
			}
			w := 0
			for row & 1 == 1 {
				row >>= 1
				w += 1
			}
			h := 1
			need: u32 = ~u32(0) if w == 32 else ((u32(1) << uint(w)) - 1) << uint(u)
			for v + h < CHUNK_SIZE && mask[v + h] & need == need {
				h += 1
			}
			for k in 0 ..< h {
				mask[v + k] &~= need
			}
			ensure_mesh_room(build, &out.opaque)
			append_greedy_quad(build, face, slice, u, v, w, h, tile, tint)
		}
	}
}

append_greedy_quad :: proc(build: ^Mesh_Build, face: Face, slice, u, v, w, h, tile: int, tint: [4]u8) {
	u_dir, v_dir, start := face_quad_basis(face, slice, u, v)
	first := u16(len(build.vertices) / 3)
	wf := f32(w)
	hf := f32(h)
	tile_y := f32(tile) * 64
	for i in 0 ..< 4 {
		tex_u := FACE_UV[i].x * wf
		tex_v := FACE_UV[i].y * hf
		p := start + u_dir * tex_u + v_dir * tex_v
		append(&build.vertices, p.x, p.y, p.z)
		append(&build.texcoords, tex_u, tex_v + tile_y)
		append(&build.colors, tint[0], tint[1], tint[2], tint[3])
	}
	append(&build.indices, first, first + 1, first + 2, first, first + 2, first + 3)
}

face_quad_basis :: proc(face: Face, slice, u, v: int) -> (u_dir, v_dir, start: [3]f32) {
	uf := f32(u)
	vf := f32(v)
	sf := f32(slice)
	switch face {
	case .Pos_Y:
		return {1, 0, 0}, {0, 0, 1}, {uf, sf + 1, vf}
	case .Neg_Y:
		return {1, 0, 0}, {0, 0, -1}, {uf, sf, f32(CHUNK_MASK - v) + 1}
	case .Pos_X:
		return {0, 0, -1}, {0, -1, 0}, {sf + 1, f32(CHUNK_MASK - v) + 1, f32(CHUNK_MASK - u) + 1}
	case .Neg_X:
		return {0, 0, 1}, {0, -1, 0}, {sf, f32(CHUNK_MASK - v) + 1, uf}
	case .Pos_Z:
		return {1, 0, 0}, {0, -1, 0}, {uf, f32(CHUNK_MASK - v) + 1, sf + 1}
	case .Neg_Z:
		return {-1, 0, 0}, {0, -1, 0}, {f32(CHUNK_MASK - u) + 1, f32(CHUNK_MASK - v) + 1, sf}
	}
	return {}, {}, {}
}

ensure_mesh_room :: proc(build: ^Mesh_Build, into: ^[dynamic]rl.Mesh) {
	if len(build.indices) + 6 <= 65535 {
		return
	}
	commit_mesh(build, into)
}

commit_mesh :: proc(build: ^Mesh_Build, into: ^[dynamic]rl.Mesh) {
	if len(build.indices) == 0 {
		return
	}
	append(into, upload_build(build))
	clear(&build.vertices)
	clear(&build.texcoords)
	clear(&build.colors)
	clear(&build.indices)
	clear(&build.texcoords2)
	clear(&build.normals)
}

upload_build :: proc(build: ^Mesh_Build) -> rl.Mesh {
	mesh := rl.Mesh {
		vertexCount   = c.int(len(build.vertices) / 3),
		triangleCount = c.int(len(build.indices) / 3),
		vertices      = clone_for_raylib(build.vertices[:]),
		texcoords     = clone_for_raylib(build.texcoords[:]),
		colors        = clone_for_raylib(build.colors[:]),
		indices       = clone_for_raylib(build.indices[:]),
	}
	if len(build.texcoords2) == len(build.vertices)/3*2 {
		mesh.texcoords2 = clone_for_raylib(build.texcoords2[:])
	}
	if len(build.normals) == len(build.vertices) {
		mesh.normals = clone_for_raylib(build.normals[:])
	}
	rl.UploadMesh(&mesh, false)
	return mesh
}

unload_world_mesh :: proc(mesh: ^World_Mesh) {
	for part in mesh.opaque {
		rl.UnloadMesh(part)
	}
	for part in mesh.leaves {
		rl.UnloadMesh(part)
	}
	for part in mesh.water {
		rl.UnloadMesh(part)
	}
	for part in mesh.plants {
		rl.UnloadMesh(part)
	}
	for part in mesh.doors {
		rl.UnloadMesh(part)
	}
	delete(mesh.opaque)
	delete(mesh.leaves)
	delete(mesh.water)
	delete(mesh.plants)
	delete(mesh.doors)
	mesh.opaque = nil
	mesh.leaves = nil
	mesh.water = nil
	mesh.plants = nil
	mesh.doors = nil
}

append_face :: proc(build: ^Mesh_Build, origin: [3]f32, face: Face, tint: [4]u8) {
	corners := FACE_CORNER[face]
	first := u16(len(build.vertices) / 3)

	for i in 0 ..< 4 {
		p := origin + corners[i]
		append(&build.vertices, p.x, p.y, p.z)
		append(&build.texcoords, FACE_UV[i].x, FACE_UV[i].y)
		append(&build.colors, tint[0], tint[1], tint[2], tint[3])
	}
	append(&build.indices, first, first + 1, first + 2, first, first + 2, first + 3)
}

// Quads per water top, along each edge. Enough samples for a breaker a few
// blocks long without a mesh per wave.
WATER_DIV :: 8

// Shore field for one surface height in this chunk. Columns cover one past
// the chunk on every side, so a vertex shared with the neighbor blends the
// same four centers.
Water_Shore :: struct {
	x0, z0, n: int,
	land_x:    []int,
	land_z:    []int,
	have:      []bool,
	fetch:     []f32,
}

shore_destroy :: proc(shore: ^Water_Shore) {
	delete(shore.land_x)
	delete(shore.land_z)
	delete(shore.have)
	delete(shore.fetch)
	free(shore)
}

// One mask for the whole chunk, then a land search per column. A vertex
// blends the four centers around it, same as wave_field_at.
build_shore :: proc(world: ^World, base_x, base_z, sy: int) -> ^Water_Shore {
	n := CHUNK_SIZE + 2
	span := n + WAVE_REACH*2
	x0 := base_x - 1 - WAVE_REACH
	z0 := base_z - 1 - WAVE_REACH
	cell := make([]u8, span*span)
	defer delete(cell)
	wave_mask(world, x0, z0, sy, span, cell)
	shore := new(Water_Shore)
	shore.x0 = base_x - 1
	shore.z0 = base_z - 1
	shore.n = n
	shore.land_x = make([]int, n*n)
	shore.land_z = make([]int, n*n)
	shore.have = make([]bool, n*n)
	shore.fetch = make([]f32, n*n)
	for iz in 0 ..< n {
		for ix in 0 ..< n {
			i := iz*n + ix
			lx, lz, have, fetch := wave_column(shore.x0+ix, shore.z0+iz, x0, z0, span, cell)
			shore.land_x[i] = lx
			shore.land_z[i] = lz
			shore.have[i] = have
			shore.fetch[i] = fetch
		}
	}
	return shore
}

take_shore :: proc(shores: ^map[int]^Water_Shore, world: ^World, base: [3]int, sy: int) -> ^Water_Shore {
	if shore, ok := shores[sy]; ok {
		return shore
	}
	shore := build_shore(world, base.x, base.z, sy)
	shores[sy] = shore
	return shore
}

shore_sample :: proc(shore: ^Water_Shore, wx, wz: int) -> Column_Land {
	ix := wx - shore.x0
	iz := wz - shore.z0
	if ix < 0 {
		ix = 0
	} else if ix >= shore.n {
		ix = shore.n - 1
	}
	if iz < 0 {
		iz = 0
	} else if iz >= shore.n {
		iz = shore.n - 1
	}
	i := iz*shore.n + ix
	return {
		x = shore.land_x[i],
		z = shore.land_z[i],
		have = shore.have[i],
		fetch = shore.fetch[i],
	}
}

// Same blend as wave_field_at, from the columns this chunk already searched.
shore_at :: proc(shore: ^Water_Shore, px, pz: f32) -> Wave_Field {
	ix0 := int(math.floor(px))
	iz0 := int(math.floor(pz))
	tx := px - f32(ix0)
	tz := pz - f32(iz0)
	return blend_land(
		px, pz, tx, tz,
		shore_sample(shore, ix0, iz0),
		shore_sample(shore, ix0+1, iz0),
		shore_sample(shore, ix0, iz0+1),
		shore_sample(shore, ix0+1, iz0+1),
	)
}

append_water_vert :: proc(build: ^Mesh_Build, p: [3]f32, uv: [2]f32, tint: [4]u8, field: Wave_Field, surface: bool) {
	append(&build.vertices, p.x, p.y, p.z)
	append(&build.texcoords, uv.x, uv.y)
	append(&build.colors, tint.x, tint.y, tint.z, tint.w)
	if surface {
		append(&build.texcoords2, field.shore, field.fetch)
		append(&build.normals, field.toward.x, field.toward.y, 1)
	} else {
		append(&build.texcoords2, 0, 0)
		append(&build.normals, 0, 0, 0)
	}
}

append_water_face :: proc(build: ^Mesh_Build, into: ^[dynamic]rl.Mesh, world: ^World, shores: ^map[int]^Water_Shore, base: [3]int, lx, ly, lz: int, face: Face, tint: [4]u8) {
	sy := base.y + ly
	if face == .Pos_Y {
		need := 6 * WATER_DIV * WATER_DIV
		if len(build.indices)+need > 65535 {
			commit_mesh(build, into)
		}
		shore := take_shore(shores, world, base, sy)
		append_water_top(build, shore, base, lx, ly, lz, tint)
		return
	}
	if len(build.indices)+6 > 65535 {
		commit_mesh(build, into)
	}
	on_surface := water_surface(world, base.x+lx, sy, base.z+lz)
	shore: ^Water_Shore
	if on_surface {
		shore = take_shore(shores, world, base, sy)
	}
	origin := [3]f32{f32(lx), f32(ly), f32(lz)}
	corners := FACE_CORNER[face]
	first := u16(len(build.vertices) / 3)
	for i in 0 ..< 4 {
		p := origin + corners[i]
		field: Wave_Field
		top := on_surface && corners[i].y == 1
		if top {
			wx := f32(base.x) - 0.5 + p.x
			wz := f32(base.z) - 0.5 + p.z
			field = shore_at(shore, wx, wz)
		}
		append_water_vert(build, p, FACE_UV[i], tint, field, top)
	}
	append(&build.indices, first, first+1, first+2, first, first+2, first+3)
}

append_water_top :: proc(build: ^Mesh_Build, shore: ^Water_Shore, base: [3]int, lx, ly, lz: int, tint: [4]u8) {
	div := WATER_DIV
	n := div + 1
	first := u16(len(build.vertices) / 3)
	for iz in 0 ..= div {
		fz := f32(iz) / f32(div)
		for ix in 0 ..= div {
			fx := f32(ix) / f32(div)
			local := [3]f32{f32(lx) + fx, f32(ly) + 1, f32(lz) + fz}
			wx := f32(base.x) - 0.5 + local.x
			wz := f32(base.z) - 0.5 + local.z
			append_water_vert(build, local, {fx, fz}, tint, shore_at(shore, wx, wz), true)
		}
	}
	row := u16(n)
	for iz in 0 ..< div {
		for ix in 0 ..< div {
			i := first + u16(iz*n+ix)
			a := i + row
			b := a + 1
			c := i + 1
			append(&build.indices, a, b, c, a, c, i)
		}
	}
}

// Two crossed quads, each drawn from both sides. The picture's bottom sits on the
// ground and its top reaches the top of the cell.
append_cross :: proc(build: ^Mesh_Build, x, y, z: f32) {
	append_quad(build, {x, y, z}, {x + 1, y, z + 1}, {x + 1, y + 1, z + 1}, {x, y + 1, z})
	append_quad(build, {x + 1, y, z + 1}, {x, y, z}, {x, y + 1, z}, {x + 1, y + 1, z + 1})
	append_quad(build, {x, y, z + 1}, {x + 1, y, z}, {x + 1, y + 1, z}, {x, y + 1, z + 1})
	append_quad(build, {x + 1, y, z}, {x, y, z + 1}, {x, y + 1, z + 1}, {x + 1, y + 1, z})
}

append_quad :: proc(build: ^Mesh_Build, a, b, c, d: [3]f32) {
	uvs := [4][2]f32{FACE_UV[0], FACE_UV[1], FACE_UV[2], FACE_UV[3]}
	append_uv_quad(build, a, b, c, d, uvs, WHITE_TINT)
}

append_uv_quad :: proc(build: ^Mesh_Build, a, b, c, d: [3]f32, uvs: [4][2]f32, tint: [4]u8) {
	first := u16(len(build.vertices) / 3)
	corners := [4][3]f32{a, b, c, d}
	for corner, i in corners {
		append(&build.vertices, corner.x, corner.y, corner.z)
		append(&build.texcoords, uvs[i].x, uvs[i].y)
		append(&build.colors, tint.x, tint.y, tint.z, tint.w)
	}
	append(&build.indices, first, first + 1, first + 2, first, first + 2, first + 3)
}

// vb is the texture v at the bottom of this half, vt at the top. The picture
// stacks the upper half of the door on the top of the image. flip puts the
// latch edge of the picture opposite the hinge.
append_world_door :: proc(build: ^Mesh_Build, lx, ly, lz: int, door: Door) {
	min, max := door_cell_box(door)
	origin := [3]f32{f32(lx), f32(ly), f32(lz)}
	vb: f32 = 1
	vt: f32 = 0.5
	if door.upper {
		vb = 0.5
		vt = 0
	}
	append_door_panel(build, origin + min, origin + max, vb, vt, door_hinge_at_max(door), false)
}

append_door_panel :: proc(build: ^Mesh_Build, bmin, bmax: [3]f32, vb, vt: f32, flip, bake: bool) {
	span := bmax - bmin
	thin_x := span.x < span.z
	for face in Face {
		corner := FACE_CORNER[face]
		pts: [4][3]f32
		for i in 0 ..< 4 {
			c := corner[i]
			pts[i] = {
				bmin.x + c.x * span.x,
				bmin.y + c.y * span.y,
				bmin.z + c.z * span.z,
			}
		}
		large := (thin_x && (face == .Pos_X || face == .Neg_X)) || (!thin_x && (face == .Pos_Z || face == .Neg_Z))
		uvs: [4][2]f32
		if large {
			uvs = door_large_uv(face, vb, vt, flip)
		} else {
			uvs = {{0.02, vb}, {0.08, vb}, {0.08, vt}, {0.02, vt}}
		}
		tint := WHITE_TINT
		if bake {
			tint = shade_tint(WHITE_TINT, face)
		}
		append_uv_quad(build, pts[0], pts[1], pts[2], pts[3], uvs, tint)
	}
}

door_large_uv :: proc(face: Face, vb, vt: f32, flip: bool) -> (uvs: [4][2]f32) {
	u: [4]f32
	switch face {
	case .Pos_Z:
		u = {0, 1, 1, 0}
	case .Neg_Z:
		u = {1, 0, 0, 1}
	case .Pos_X:
		u = {1, 0, 0, 1}
	case .Neg_X:
		u = {0, 1, 1, 0}
	case .Pos_Y, .Neg_Y:
		u = {0, 1, 1, 0}
	}
	if flip {
		for i in 0 ..< 4 {
			u[i] = 1 - u[i]
		}
	}
	v := [4]f32{vb, vb, vt, vt}
	for i in 0 ..< 4 {
		uvs[i] = {u[i], v[i]}
	}
	return
}

// Replaces one surface mesh with the scratch geometry and uploads it.
// A 16-wide chunk cannot exceed the u16 index range even when every block is exposed;
// a larger CHUNK_SIZE could, and would need the mesh split or the indices widened.
upload_surface :: proc(out: ^Chunk_Mesh, surface: Surface, build: ^Mesh_Build) {
	if out.filled[surface] {
		rl.UnloadMesh(out.meshes[surface])
		out.meshes[surface] = {}
		out.filled[surface] = false
	}
	if len(build.indices) == 0 {
		return
	}

	mesh := rl.Mesh {
		vertexCount   = c.int(len(build.vertices) / 3),
		triangleCount = c.int(len(build.indices) / 3),
		vertices      = clone_for_raylib(build.vertices[:]),
		texcoords     = clone_for_raylib(build.texcoords[:]),
		colors        = clone_for_raylib(build.colors[:]),
		indices       = clone_for_raylib(build.indices[:]),
	}
	rl.UploadMesh(&mesh, false)

	out.meshes[surface] = mesh
	out.filled[surface] = true
}

// UnloadMesh frees these arrays itself, so they have to come from raylib's allocator.
clone_for_raylib :: proc(data: []$T) -> [^]T {
	out := make([]T, len(data), rl.MemAllocator())
	copy(out, data)
	return raw_data(out)
}

// Square, so the block fills a slot without a wide margin. BeginMode3D sizes the
// projection for the window, which would squash this picture, so the projection
// is replaced with a matching square.
ICON_RES :: c.int(160)
ICON_SPAN :: f32(0.88)

build_block_icons :: proc(renderer: ^Renderer) {
	for block in Block {
		if block == .Air {
			continue
		}
		mesh := &renderer.item_meshes[block]
		build_icon_mesh(renderer, block, mesh)
		target := rl.LoadRenderTexture(ICON_RES, ICON_RES)
		if target.id != 0 {
			rl.SetTextureFilter(target.texture, .BILINEAR)
			rl.SetTextureWrap(target.texture, .CLAMP)
			draw_icon_mesh(renderer, mesh, target)
			renderer.icons[block] = target
		}
	}
}

unload_chunk_mesh :: proc(mesh: ^Chunk_Mesh) {
	for surface in Surface {
		if mesh.filled[surface] {
			rl.UnloadMesh(mesh.meshes[surface])
			mesh.meshes[surface] = {}
			mesh.filled[surface] = false
		}
	}
}

// A drop is the block's cube, small, spinning, and hovering just off the face it landed on.
DROP_DRAW_SCALE :: f32(0.25)

draw_drops :: proc(renderer: ^Renderer, drops: []Drop_View, pass: Surface_Pass) {
	if len(drops) == 0 {
		return
	}
	if pass == .Translucent {
		rl.BeginBlendMode(.ALPHA)
		rlgl.DisableDepthMask()
	}
	for drop in drops {
		hover := 0.04 + math.sin(drop.age * 3 + drop.phase) * 0.03
		spin := rl.MatrixRotateY(drop.age * 2.4 + drop.phase)
		place := rl.MatrixTranslate(drop.position.x, drop.position.y + hover, drop.position.z)
		// Tools and sticks are a flat picture. The transparent texels belong to
		// the cutout pass, the same way leaves do.
		if drop.item.kind != .Block {
			if pass == .Cutout {
				scale := rl.MatrixScale(0.5, 0.5, 0.5)
				draw_item_sprite(renderer, drop.item, place*spin*scale)
			}
			continue
		}
		mesh := &renderer.item_meshes[drop.item.block]
		scale := rl.MatrixScale(DROP_DRAW_SCALE, DROP_DRAW_SCALE, DROP_DRAW_SCALE)
		transform := place * spin * scale
		for surface in Surface {
			if mesh.filled[surface] && surface_pass(surface) == pass {
				rl.DrawMesh(mesh.meshes[surface], renderer.materials[surface], transform)
			}
		}
	}
	if pass == .Translucent {
		rlgl.EnableDepthMask()
		rl.EndBlendMode()
	}
}

// Every face, centered on the origin, so the icon camera can sit on a corner
// and show the top and two sides.
build_icon_mesh :: proc(renderer: ^Renderer, block: Block, out: ^Chunk_Mesh) {
	for surface in Surface {
		build := &renderer.build[surface]
		clear(&build.vertices)
		clear(&build.texcoords)
		clear(&build.colors)
		clear(&build.indices)
	}
	textured := renderer.textures.stone.id != 0
	if block == .Oak_Sapling {
		append_cross(&renderer.build[.Oak_Sapling], -0.5, -0.5, -0.5)
	} else if block == .Oak_Door {
		// One panel, both halves of the picture, so the slot reads as a door.
		append_door_panel(&renderer.build[.Oak_Door], {-0.30, -0.72, -0.07}, {0.30, 0.72, 0.07}, 1, 0, false, true)
	} else {
		for face in Face {
			surface := block_surface(block, face)
			append_face(&renderer.build[surface], {-0.5, -0.5, -0.5}, face, shade_tint(surface_tint(surface, textured), face))
		}
	}
	for surface in Surface {
		upload_surface(out, surface, &renderer.build[surface])
	}
}

draw_icon_mesh :: proc(renderer: ^Renderer, mesh: ^Chunk_Mesh, target: rl.RenderTexture2D) {
	rl.BeginTextureMode(target)
	rl.ClearBackground(rl.BLANK)
	rl.BeginMode3D({
		position   = {1.45, 1.05, 1.15},
		target     = {0, 0, 0},
		up         = {0, 1, 0},
		fovy       = ICON_SPAN * 2,
		projection = .ORTHOGRAPHIC,
	})
	rlgl.SetMatrixProjection(rl.MatrixOrtho(-ICON_SPAN, ICON_SPAN, -ICON_SPAN, ICON_SPAN, 0.01, 20))
	// Blend would composite onto the clear color and store premultiplied pixels.
	// The slot draws the picture with its own alpha later.
	rlgl.DisableColorBlend()
	transform := rl.Matrix(1)
	for pass in Surface_Pass {
		for surface in Surface {
			if mesh.filled[surface] && surface_pass(surface) == pass {
				rl.DrawMesh(mesh.meshes[surface], renderer.materials[surface], transform)
			}
		}
	}
	rlgl.EnableColorBlend()
	rl.EndMode3D()
	rl.EndTextureMode()
	rlgl.Viewport(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight())
}

// A unit quad in the XY plane, facing +Z, so a view-space draw looks at the picture.
build_item_quad :: proc() -> rl.Mesh {
	vertices := [?]f32 {
		-0.5, -0.5, 0,
		0.5, -0.5, 0,
		0.5, 0.5, 0,
		-0.5, 0.5, 0,
	}
	texcoords := [?]f32 {
		0, 1,
		1, 1,
		1, 0,
		0, 0,
	}
	colors := [?]u8 {
		255, 255, 255, 255,
		255, 255, 255, 255,
		255, 255, 255, 255,
		255, 255, 255, 255,
	}
	indices := [?]u16 {0, 1, 2, 0, 2, 3}
	mesh := rl.Mesh {
		vertexCount   = 4,
		triangleCount = 2,
		vertices      = clone_for_raylib(vertices[:]),
		texcoords     = clone_for_raylib(texcoords[:]),
		colors        = clone_for_raylib(colors[:]),
		indices       = clone_for_raylib(indices[:]),
	}
	rl.UploadMesh(&mesh, false)
	return mesh
}

// A unit box. The ±Z faces carry the whole sprite; the rim repeats its edge.
// Scale Z by 1/16 to make a tool a sixteenth of a meter thick.
build_item_card :: proc() -> rl.Mesh {
	Corner :: struct {
		p:  [3]f32,
		uv: [2]f32,
	}
	faces := [6][4]Corner{
		// Front, facing +Z.
		{
			{p = {-0.5, -0.5, 0.5}, uv = {0, 1}},
			{p = {0.5, -0.5, 0.5}, uv = {1, 1}},
			{p = {0.5, 0.5, 0.5}, uv = {1, 0}},
			{p = {-0.5, 0.5, 0.5}, uv = {0, 0}},
		},
		// Back, facing -Z, so the picture still reads from behind the hand.
		{
			{p = {0.5, -0.5, -0.5}, uv = {0, 1}},
			{p = {-0.5, -0.5, -0.5}, uv = {1, 1}},
			{p = {-0.5, 0.5, -0.5}, uv = {1, 0}},
			{p = {0.5, 0.5, -0.5}, uv = {0, 0}},
		},
		// Right edge of the sprite.
		{
			{p = {0.5, -0.5, 0.5}, uv = {1, 1}},
			{p = {0.5, -0.5, -0.5}, uv = {1, 1}},
			{p = {0.5, 0.5, -0.5}, uv = {1, 0}},
			{p = {0.5, 0.5, 0.5}, uv = {1, 0}},
		},
		// Left edge.
		{
			{p = {-0.5, -0.5, -0.5}, uv = {0, 1}},
			{p = {-0.5, -0.5, 0.5}, uv = {0, 1}},
			{p = {-0.5, 0.5, 0.5}, uv = {0, 0}},
			{p = {-0.5, 0.5, -0.5}, uv = {0, 0}},
		},
		// Top edge.
		{
			{p = {-0.5, 0.5, 0.5}, uv = {0, 0}},
			{p = {0.5, 0.5, 0.5}, uv = {1, 0}},
			{p = {0.5, 0.5, -0.5}, uv = {1, 0}},
			{p = {-0.5, 0.5, -0.5}, uv = {0, 0}},
		},
		// Bottom edge.
		{
			{p = {-0.5, -0.5, -0.5}, uv = {0, 1}},
			{p = {0.5, -0.5, -0.5}, uv = {1, 1}},
			{p = {0.5, -0.5, 0.5}, uv = {1, 1}},
			{p = {-0.5, -0.5, 0.5}, uv = {0, 1}},
		},
	}

	vertices: [72]f32
	texcoords: [48]f32
	colors: [96]u8
	indices: [36]u16
	for face in 0 ..< 6 {
		for corner in 0 ..< 4 {
			i := face*4 + corner
			vertices[i*3 + 0] = faces[face][corner].p.x
			vertices[i*3 + 1] = faces[face][corner].p.y
			vertices[i*3 + 2] = faces[face][corner].p.z
			texcoords[i*2 + 0] = faces[face][corner].uv.x
			texcoords[i*2 + 1] = faces[face][corner].uv.y
			colors[i*4 + 0] = 255
			colors[i*4 + 1] = 255
			colors[i*4 + 2] = 255
			colors[i*4 + 3] = 255
		}
		base := u16(face * 4)
		indices[face*6 + 0] = base + 0
		indices[face*6 + 1] = base + 1
		indices[face*6 + 2] = base + 2
		indices[face*6 + 3] = base + 0
		indices[face*6 + 4] = base + 2
		indices[face*6 + 5] = base + 3
	}
	mesh := rl.Mesh {
		vertexCount   = 24,
		triangleCount = 12,
		vertices      = clone_for_raylib(vertices[:]),
		texcoords     = clone_for_raylib(texcoords[:]),
		colors        = clone_for_raylib(colors[:]),
		indices       = clone_for_raylib(indices[:]),
	}
	rl.UploadMesh(&mesh, false)
	return mesh
}

item_sprite :: proc(sprites: Item_Sprites, item: Item) -> rl.Texture2D {
	switch item.kind {
	case .Stick:
		return sprites.stick
	case .Wood_Shovel:
		return sprites.wood_shovel
	case .Wood_Pickaxe:
		return sprites.wood_pickaxe
	case .Stone_Shovel:
		return sprites.stone_shovel
	case .Stone_Pickaxe:
		return sprites.stone_pickaxe
	case .Wood_Axe:
		return sprites.wood_axe
	case .Stone_Axe:
		return sprites.stone_axe
	case .Iron_Shovel:
		return sprites.iron_shovel
	case .Iron_Pickaxe:
		return sprites.iron_pickaxe
	case .Iron_Axe:
		return sprites.iron_axe
	case .Iron_Ingot:
		return sprites.iron_ingot
	case .None, .Block:
		return {}
	}
	return {}
}

// Centers of the nine squares painted on the workbench's top, in texture
// space. The picture's top row is the block's -Z side, matching the face UVs.
TABLE_CELL :: [3]f32{9.0 / 32.0, 16.0 / 32.0, 23.0 / 32.0}

// Sits inside one of those squares, just above the face so it does not z-fight.
TABLE_ICON :: f32(0.15)

// The items arranged on a workbench, drawn in the 3x3 on its top face.
draw_table_items :: proc(renderer: ^Renderer, world: ^World, tables: map[[3]int][CRAFT3_N]Slot) {
	if len(tables) == 0 || renderer.item_quad.vertexCount == 0 {
		return
	}
	flat := rl.MatrixRotateX(-math.PI * 0.5)
	cell := TABLE_CELL
	// The quad faces +Z. Laying it flat turns that winding away from the sky.
	rlgl.DisableBackfaceCulling()
	defer rlgl.EnableBackfaceCulling()
	for at, grid in tables {
		if get_block(world, at.x, at.y, at.z) != .Workbench {
			continue
		}
		for i in 0 ..< CRAFT3_N {
			slot := grid[i]
			if slot.count <= 0 || item_empty(slot.item) {
				continue
			}
			col := i % 3
			row := i / 3
			place := rl.MatrixTranslate(
				f32(at.x) - 0.5 + cell[col],
				f32(at.y) + 1 + 0.02,
				f32(at.z) - 0.5 + cell[row],
			)
			size := rl.MatrixScale(TABLE_ICON, TABLE_ICON, TABLE_ICON)
			transform := place * flat * size
			if slot.item.kind == .Block {
				icon := renderer.icons[slot.item.block]
				if icon.id == 0 {
					continue
				}
				rl.SetMaterialTexture(&renderer.item_material, .ALBEDO, icon.texture)
				rl.DrawMesh(renderer.item_quad, renderer.item_material, transform)
			} else {
				draw_item_sprite(renderer, slot.item, transform)
			}
		}
	}
}

draw_item_sprite :: proc(renderer: ^Renderer, item: Item, transform: rl.Matrix) {
	tex := item_sprite(renderer.sprites, item)
	if tex.id == 0 || renderer.item_quad.vertexCount == 0 {
		return
	}
	rl.SetMaterialTexture(&renderer.item_material, .ALBEDO, tex)
	rl.DrawMesh(renderer.item_quad, renderer.item_material, transform)
}

// The same sprite as draw_item_sprite, with the thickness already in the transform.
draw_item_card :: proc(renderer: ^Renderer, item: Item, transform: rl.Matrix) {
	tex := item_sprite(renderer.sprites, item)
	if tex.id == 0 || renderer.item_card.vertexCount == 0 {
		return
	}
	rl.SetMaterialTexture(&renderer.item_material, .ALBEDO, tex)
	rl.DrawMesh(renderer.item_card, renderer.item_material, transform)
}

draw_item_icon :: proc(renderer: ^Renderer, item: Item, dest: rl.Rectangle) {
	if item.kind == .Block {
		draw_block_icon(renderer, item.block, dest)
		return
	}
	tex := item_sprite(renderer.sprites, item)
	if tex.id == 0 {
		return
	}
	src := rl.Rectangle{0, 0, f32(tex.width), f32(tex.height)}
	rl.DrawTexturePro(tex, src, dest, {}, 0, rl.WHITE)
}

// The picture is bottom-up, so the source height is negative and it draws upright.
draw_block_icon :: proc(renderer: ^Renderer, block: Block, dest: rl.Rectangle) {
	icon := renderer.icons[block]
	if icon.id == 0 {
		return
	}
	tex := icon.texture
	src := rl.Rectangle{0, 0, f32(tex.width), -f32(tex.height)}
	rl.DrawTexturePro(tex, src, dest, {}, 0, rl.WHITE)
}

block_surface :: proc(block: Block, face: Face) -> Surface {
	if block_is_door(block) {
		return .Oak_Door
	}
	switch block {
	case .Grass:
		switch face {
		case .Pos_Y:
			return .Grass_Top
		case .Neg_Y:
			return .Dirt
		case .Pos_X, .Neg_X, .Pos_Z, .Neg_Z:
			return .Grass_Side
		}
	case .Dirt:
		return .Dirt
	case .Bedrock:
		return .Bedrock
	case .Coal_Ore:
		return .Coal_Ore
	case .Iron_Ore:
		return .Iron_Ore
	case .Gold_Ore:
		return .Gold_Ore
	case .Water:
		return .Water
	case .Oak_Log:
		switch face {
		case .Pos_Y, .Neg_Y:
			return .Oak_Log_Top
		case .Pos_X, .Neg_X, .Pos_Z, .Neg_Z:
			return .Oak_Log_Side
		}
	case .Oak_Leaves:
		return .Oak_Leaves
	case .Oak_Sapling:
		return .Oak_Sapling
	case .Sand:
		return .Sand
	case .Gravel:
		return .Gravel
	case .Oak_Planks:
		return .Oak_Planks
	case .Workbench:
		switch face {
		case .Pos_Y:
			return .Workbench_Top
		case .Neg_Y:
			return .Oak_Planks
		case .Pos_X, .Neg_X, .Pos_Z, .Neg_Z:
			return .Workbench_Front
		}
	case .Oak_Door:
		return .Oak_Door
	case .Stone, .Air:
		return .Stone
	}
	return .Stone
}

surface_texture :: proc(textures: Block_Textures, surface: Surface) -> rl.Texture2D {
	switch surface {
	case .Grass_Top:
		return textures.grass_top
	case .Grass_Side:
		return textures.grass_side
	case .Dirt:
		return textures.dirt
	case .Stone:
		return textures.stone
	case .Sand:
		return textures.sand
	case .Gravel:
		return textures.gravel
	case .Bedrock:
		return textures.bedrock
	case .Coal_Ore:
		return textures.coal_ore
	case .Iron_Ore:
		return textures.iron_ore
	case .Gold_Ore:
		return textures.gold_ore
	case .Water:
		return textures.water
	case .Oak_Log_Top:
		return textures.oak_log_top
	case .Oak_Log_Side:
		return textures.oak_log_side
	case .Oak_Leaves:
		return textures.oak_leaves
	case .Oak_Planks:
		return textures.oak_planks
	case .Workbench_Top:
		return textures.workbench_top
	case .Workbench_Front:
		return textures.workbench_front
	case .Oak_Sapling:
		return textures.oak_sapling
	case .Oak_Door:
		return textures.oak_door
	}
	return {}
}

// The surface color, scaled by that face's share of the light.
shade_tint :: proc(tint: [4]u8, face: Face) -> [4]u8 {
	s := FACE_LIGHT[face]
	return {
		u8(f32(tint[0]) * s + 0.5),
		u8(f32(tint[1]) * s + 0.5),
		u8(f32(tint[2]) * s + 0.5),
		tint[3],
	}
}

surface_tint :: proc(surface: Surface, textured: bool) -> [4]u8 {
	// These textures are grayscale and get their color from the tint, so they want it
	// whether or not the texture loaded.
	#partial switch surface {
	case .Grass_Top:
		return GRASS_TINT
	case .Water:
		return WATER_TINT
	case .Oak_Leaves:
		return FOLIAGE_TINT
	}
	if textured {
		return WHITE_TINT
	}
	// Flat stand-in colors, so a missing texture still reads as the right block.
	#partial switch surface {
	case .Grass_Side:
		return {130, 160, 90, 255}
	case .Dirt:
		return {134, 96, 67, 255}
	case .Stone:
		return {125, 125, 125, 255}
	case .Bedrock:
		return {80, 80, 80, 255}
	case .Coal_Ore:
		return {55, 55, 55, 255}
	case .Iron_Ore:
		return {181, 142, 115, 255}
	case .Gold_Ore:
		return {231, 190, 70, 255}
	case .Oak_Log_Top:
		return {175, 143, 85, 255}
	case .Oak_Log_Side:
		return {103, 82, 49, 255}
	case .Oak_Planks:
		return {168, 134, 80, 255}
	case .Workbench_Top:
		return {140, 110, 65, 255}
	case .Workbench_Front:
		return {122, 96, 56, 255}
	case .Sand:
		return {219, 201, 140, 255}
	case .Gravel:
		return {128, 128, 128, 255}
	}
	return WHITE_TINT
}

// Opaque surfaces packed left to right. Water and leaves stay on their own textures.
atlas_tile :: proc(surface: Surface) -> int {
	#partial switch surface {
	case .Water, .Oak_Leaves, .Oak_Sapling, .Oak_Door:
		return -1
	}
	id := int(surface)
	if surface > .Water {
		id -= 1
	}
	if surface > .Oak_Leaves {
		id -= 1
	}
	if surface > .Oak_Sapling {
		id -= 1
	}
	return id
}

surface_from_tile :: proc(tile: int) -> Surface {
	id := tile
	if id >= int(Surface.Water) {
		id += 1
	}
	if id >= int(Surface.Oak_Leaves) {
		id += 1
	}
	if id >= int(Surface.Oak_Sapling) {
		id += 1
	}
	return Surface(id)
}

atlas_file :: proc(surface: Surface) -> cstring {
	switch surface {
	case .Grass_Top:
		return "assets/textures/grass_block_top.png"
	case .Grass_Side:
		return "assets/textures/grass_block_side.png"
	case .Dirt:
		return "assets/textures/dirt.png"
	case .Stone:
		return "assets/textures/stone.png"
	case .Sand:
		return "assets/textures/sand.png"
	case .Gravel:
		return "assets/textures/gravel.png"
	case .Bedrock:
		return "assets/textures/bedrock.png"
	case .Coal_Ore:
		return "assets/textures/coal_ore.png"
	case .Iron_Ore:
		return "assets/textures/iron_ore.png"
	case .Gold_Ore:
		return "assets/textures/gold_ore.png"
	case .Oak_Log_Top:
		return "assets/textures/oak_log_top.png"
	case .Oak_Log_Side:
		return "assets/textures/oak_log.png"
	case .Oak_Planks:
		return "assets/textures/oak_planks.png"
	case .Workbench_Top:
		return "assets/textures/workbench_top.png"
	case .Workbench_Front:
		return "assets/textures/workbench_front.png"
	case .Water, .Oak_Leaves, .Oak_Sapling, .Oak_Door:
		return nil
	}
	return nil
}

// Repeats each tile's edge into a one-pixel pad so a mipmap average stays inside
// the tile. The shader samples the inner rectangle.
build_block_atlas :: proc(renderer: ^Renderer) {
	first := rl.LoadImage(atlas_file(.Stone))
	defer rl.UnloadImage(first)
	if first.width == 0 || first.height == 0 {
		return
	}
	tile_w := int(first.width)
	tile_h := int(first.height)
	stride_w := tile_w + ATLAS_PAD * 2
	stride_h := tile_h + ATLAS_PAD * 2
	image := rl.GenImageColor(c.int(stride_w * ATLAS_COUNT), c.int(stride_h), rl.BLANK)
	defer rl.UnloadImage(image)
	for surface in Surface {
		tile := atlas_tile(surface)
		if tile < 0 {
			continue
		}
		src := first
		owned := false
		if surface != .Stone {
			src = rl.LoadImage(atlas_file(surface))
			owned = true
		}
		if src.width != 0 {
			for py in -ATLAS_PAD ..< tile_h + ATLAS_PAD {
				for px in -ATLAS_PAD ..< tile_w + ATLAS_PAD {
					sx := clamp(px, 0, tile_w - 1)
					sy := clamp(py, 0, tile_h - 1)
					color := rl.GetImageColor(src, c.int(sx), c.int(sy))
					rl.ImageDrawPixel(&image, c.int(tile * stride_w + px + ATLAS_PAD), c.int(py + ATLAS_PAD), color)
				}
			}
			ox := f32(tile * stride_w + ATLAS_PAD) / f32(stride_w * ATLAS_COUNT)
			oy := f32(ATLAS_PAD) / f32(stride_h)
			sx := f32(tile_w) / f32(stride_w * ATLAS_COUNT)
			sy := f32(tile_h) / f32(stride_h)
			renderer.atlas_tiles[tile] = {ox, oy, sx, sy}
		}
		if owned {
			rl.UnloadImage(src)
		}
	}
	renderer.atlas = rl.LoadTextureFromImage(image)
	prepare_texture(&renderer.atlas)
	renderer.atlas_shader = rl.LoadShader("assets/shaders/world.vs", "assets/shaders/world.fs")
	if renderer.atlas_shader.id != 0 {
		loc := rl.GetShaderLocation(renderer.atlas_shader, "tiles")
		rl.SetShaderValueV(renderer.atlas_shader, loc, &renderer.atlas_tiles[0], .VEC4, ATLAS_COUNT)
		renderer.atlas_light = light_locs(renderer.atlas_shader)
		light_bind(renderer.atlas_shader, renderer.atlas_light, Sky{}, rl.Matrix(1), 0, 0)
	}
	renderer.shadow_shader = rl.LoadShader("assets/shaders/shadow.vs", "assets/shaders/shadow.fs")
	renderer.shadow_cutout = rl.GetShaderLocation(renderer.shadow_shader, "cutout")
	renderer.shadow_material = rl.LoadMaterialDefault()
	if renderer.shadow_shader.id != 0 {
		renderer.shadow_material.shader = renderer.shadow_shader
	}
	renderer.shadow_target = rl.LoadRenderTexture(SHADOW_MAP_SIZE, SHADOW_MAP_SIZE)
	if renderer.shadow_target.texture.id != 0 {
		rl.SetTextureFilter(renderer.shadow_target.texture, .POINT)
		rl.SetTextureWrap(renderer.shadow_target.texture, .CLAMP)
	}
	renderer.stars, renderer.star_dot = sky_init_stars()
	renderer.atlas_material = rl.LoadMaterialDefault()
	if renderer.atlas.id != 0 {
		rl.SetMaterialTexture(&renderer.atlas_material, .ALBEDO, renderer.atlas)
	}
	if renderer.atlas_shader.id != 0 {
		renderer.atlas_material.shader = renderer.atlas_shader
	}
}

load_block_textures :: proc() -> Block_Textures {
	textures := Block_Textures {
		grass_top  = rl.LoadTexture("assets/textures/grass_block_top.png"),
		grass_side = rl.LoadTexture("assets/textures/grass_block_side.png"),
		dirt       = rl.LoadTexture("assets/textures/dirt.png"),
		stone      = rl.LoadTexture("assets/textures/stone.png"),
		bedrock    = rl.LoadTexture("assets/textures/bedrock.png"),
		coal_ore   = rl.LoadTexture("assets/textures/coal_ore.png"),
		iron_ore   = rl.LoadTexture("assets/textures/iron_ore.png"),
		gold_ore   = rl.LoadTexture("assets/textures/gold_ore.png"),
		water      = rl.LoadTexture("assets/textures/water.png"),

		oak_log_top  = rl.LoadTexture("assets/textures/oak_log_top.png"),
		oak_log_side = rl.LoadTexture("assets/textures/oak_log.png"),
		oak_leaves   = rl.LoadTexture("assets/textures/oak_leaves.png"),
		oak_planks     = rl.LoadTexture("assets/textures/oak_planks.png"),
		workbench_top   = rl.LoadTexture("assets/textures/workbench_top.png"),
		workbench_front = rl.LoadTexture("assets/textures/workbench_front.png"),
		oak_sapling     = rl.LoadTexture("assets/textures/oak_sapling.png"),
		sand            = rl.LoadTexture("assets/textures/sand.png"),
		gravel          = rl.LoadTexture("assets/textures/gravel.png"),
		oak_door        = rl.LoadTexture("assets/textures/oak_door.png"),
	}
	prepare_texture(&textures.grass_top)
	prepare_texture(&textures.grass_side)
	prepare_texture(&textures.dirt)
	prepare_texture(&textures.stone)
	prepare_texture(&textures.bedrock)
	prepare_texture(&textures.coal_ore)
	prepare_texture(&textures.iron_ore)
	prepare_texture(&textures.gold_ore)
	prepare_texture(&textures.water)
	prepare_texture(&textures.oak_log_top)
	prepare_texture(&textures.oak_log_side)
	prepare_texture(&textures.oak_leaves)
	prepare_texture(&textures.oak_planks)
	prepare_texture(&textures.workbench_top)
	prepare_texture(&textures.workbench_front)
	prepare_texture(&textures.oak_sapling)
	prepare_texture(&textures.sand)
	prepare_texture(&textures.gravel)
	prepare_texture(&textures.oak_door)
	return textures
}

load_item_sprites :: proc() -> Item_Sprites {
	sprites := Item_Sprites {
		stick         = rl.LoadTexture("assets/textures/stick.png"),
		wood_shovel   = rl.LoadTexture("assets/textures/wooden_shovel.png"),
		wood_pickaxe  = rl.LoadTexture("assets/textures/wooden_pickaxe.png"),
		stone_shovel  = rl.LoadTexture("assets/textures/stone_shovel.png"),
		stone_pickaxe = rl.LoadTexture("assets/textures/stone_pickaxe.png"),
		wood_axe      = rl.LoadTexture("assets/textures/wooden_axe.png"),
		stone_axe     = rl.LoadTexture("assets/textures/stone_axe.png"),
		iron_shovel   = rl.LoadTexture("assets/textures/iron_shovel.png"),
		iron_pickaxe  = rl.LoadTexture("assets/textures/iron_pickaxe.png"),
		iron_axe      = rl.LoadTexture("assets/textures/iron_axe.png"),
		iron_ingot    = rl.LoadTexture("assets/textures/iron_ingot.png"),
	}
	prepare_texture(&sprites.stick)
	prepare_texture(&sprites.wood_shovel)
	prepare_texture(&sprites.wood_pickaxe)
	prepare_texture(&sprites.stone_shovel)
	prepare_texture(&sprites.stone_pickaxe)
	prepare_texture(&sprites.wood_axe)
	prepare_texture(&sprites.stone_axe)
	prepare_texture(&sprites.iron_shovel)
	prepare_texture(&sprites.iron_pickaxe)
	prepare_texture(&sprites.iron_axe)
	prepare_texture(&sprites.iron_ingot)
	return sprites
}

unload_item_sprites :: proc(sprites: Item_Sprites) {
	if sprites.stick.id != 0 do rl.UnloadTexture(sprites.stick)
	if sprites.wood_shovel.id != 0 do rl.UnloadTexture(sprites.wood_shovel)
	if sprites.wood_pickaxe.id != 0 do rl.UnloadTexture(sprites.wood_pickaxe)
	if sprites.stone_shovel.id != 0 do rl.UnloadTexture(sprites.stone_shovel)
	if sprites.stone_pickaxe.id != 0 do rl.UnloadTexture(sprites.stone_pickaxe)
	if sprites.wood_axe.id != 0 do rl.UnloadTexture(sprites.wood_axe)
	if sprites.stone_axe.id != 0 do rl.UnloadTexture(sprites.stone_axe)
	if sprites.iron_shovel.id != 0 do rl.UnloadTexture(sprites.iron_shovel)
	if sprites.iron_pickaxe.id != 0 do rl.UnloadTexture(sprites.iron_pickaxe)
	if sprites.iron_axe.id != 0 do rl.UnloadTexture(sprites.iron_axe)
	if sprites.iron_ingot.id != 0 do rl.UnloadTexture(sprites.iron_ingot)
}

// The chain has to exist before the filter is chosen. Raylib only selects a mip
// filter when the texture already has more than one level, and POINT then means
// nearest texel within the nearest level, so distant faces stop shimmering
// without the pixels going soft.
prepare_texture :: proc(texture: ^rl.Texture2D) {
	if texture.id == 0 {
		return
	}
	rl.GenTextureMipmaps(texture)
	rl.SetTextureFilter(texture^, .POINT)
	rl.SetTextureWrap(texture^, .CLAMP)
}

// SetTextureFilter turns mip sampling back on whenever a chain exists, so the
// options screen sets the minification filter directly.
set_block_mipmaps :: proc(textures: Block_Textures, atlas: rl.Texture2D, enabled: bool) {
	// GL_NEAREST_MIPMAP_NEAREST, or GL_NEAREST when the chain should be ignored.
	filter: c.int = 0x2700 if enabled else 0x2600
	set :: proc(texture: rl.Texture2D, filter: c.int) {
		if texture.id == 0 {
			return
		}
		rlgl.TextureParameters(texture.id, 0x2801, filter) // GL_TEXTURE_MIN_FILTER
		rlgl.TextureParameters(texture.id, 0x2800, 0x2600) // GL_TEXTURE_MAG_FILTER, GL_NEAREST
	}
	set(textures.grass_top, filter)
	set(textures.grass_side, filter)
	set(textures.dirt, filter)
	set(textures.stone, filter)
	set(textures.bedrock, filter)
	set(textures.coal_ore, filter)
	set(textures.iron_ore, filter)
	set(textures.gold_ore, filter)
	set(textures.water, filter)
	set(textures.oak_log_top, filter)
	set(textures.oak_log_side, filter)
	set(textures.oak_leaves, filter)
	set(textures.oak_planks, filter)
	set(textures.workbench_top, filter)
	set(textures.workbench_front, filter)
	set(textures.oak_sapling, filter)
	set(textures.sand, filter)
	set(textures.gravel, filter)
	set(textures.oak_door, filter)
	set(atlas, filter)
}

set_item_mipmaps :: proc(sprites: Item_Sprites, enabled: bool) {
	filter: c.int = 0x2700 if enabled else 0x2600
	set :: proc(texture: rl.Texture2D, filter: c.int) {
		if texture.id == 0 {
			return
		}
		rlgl.TextureParameters(texture.id, 0x2801, filter)
		rlgl.TextureParameters(texture.id, 0x2800, 0x2600)
	}
	set(sprites.stick, filter)
	set(sprites.wood_shovel, filter)
	set(sprites.wood_pickaxe, filter)
	set(sprites.stone_shovel, filter)
	set(sprites.stone_pickaxe, filter)
	set(sprites.wood_axe, filter)
	set(sprites.stone_axe, filter)
	set(sprites.iron_shovel, filter)
	set(sprites.iron_pickaxe, filter)
	set(sprites.iron_axe, filter)
	set(sprites.iron_ingot, filter)
}

// Far enough in front of the block face that the wires win the depth test, close enough to still read as the block edge.
HIGHLIGHT_BIAS :: 0.005

draw_block_highlight :: proc(x, y, z: int, eye: [3]f32, block: Block) {
	center := [3]f32{f32(x), f32(y) + 0.5, f32(z)}
	size := [3]f32{1, 1, 1}
	if door, is_door := door_info(block); is_door {
		bmin, bmax := door_aabb(x, y, z, door)
		center = (bmin + bmax) * 0.5
		size = bmax - bmin
	}
	to_eye := eye - center
	length := math.sqrt(to_eye.x*to_eye.x + to_eye.y*to_eye.y + to_eye.z*to_eye.z)
	if length > 0 {
		center += to_eye * (HIGHLIGHT_BIAS / length)
	}
	rl.DrawCubeWires(center, size.x + HIGHLIGHT_BIAS*2, size.y + HIGHLIGHT_BIAS*2, size.z + HIGHLIGHT_BIAS*2, rl.BLACK)
}

BREAK_STAGES :: 10

load_break_textures :: proc() -> [BREAK_STAGES]rl.Texture2D {
	paths := [BREAK_STAGES]cstring {
		"assets/textures/destroy_stage_0.png",
		"assets/textures/destroy_stage_1.png",
		"assets/textures/destroy_stage_2.png",
		"assets/textures/destroy_stage_3.png",
		"assets/textures/destroy_stage_4.png",
		"assets/textures/destroy_stage_5.png",
		"assets/textures/destroy_stage_6.png",
		"assets/textures/destroy_stage_7.png",
		"assets/textures/destroy_stage_8.png",
		"assets/textures/destroy_stage_9.png",
	}
	textures: [BREAK_STAGES]rl.Texture2D
	for path, i in paths {
		textures[i] = rl.LoadTexture(path)
		prepare_texture(&textures[i])
	}
	return textures
}

unload_break_textures :: proc(textures: [BREAK_STAGES]rl.Texture2D) {
	for texture in textures {
		if texture.id != 0 {
			rl.UnloadTexture(texture)
		}
	}
}

// The crack sits a hair off each face so it wins the depth test against the block.
CRACK_OUTSET :: f32(0.004)

draw_break_cracks :: proc(renderer: ^Renderer, x, y, z, stage: int, block: Block) {
	if stage < 0 || stage >= BREAK_STAGES || renderer.breaks[stage].id == 0 || renderer.item_quad.vertexCount == 0 {
		return
	}
	if door, is_door := door_info(block); is_door {
		bmin, bmax := door_aabb(x, y, z, door)
		draw_door_cracks(renderer, bmin, bmax, stage)
		return
	}
	center := [3]f32{f32(x), f32(y) + 0.5, f32(z)}
	out := 0.5 + CRACK_OUTSET
	faces := [6]rl.Matrix {
		rl.MatrixTranslate(center.x, center.y, center.z + out),
		rl.MatrixTranslate(center.x, center.y, center.z - out) * rl.MatrixRotateY(math.PI),
		rl.MatrixTranslate(center.x + out, center.y, center.z) * rl.MatrixRotateY(math.PI * 0.5),
		rl.MatrixTranslate(center.x - out, center.y, center.z) * rl.MatrixRotateY(-math.PI * 0.5),
		rl.MatrixTranslate(center.x, center.y + out, center.z) * rl.MatrixRotateX(-math.PI * 0.5),
		rl.MatrixTranslate(center.x, center.y - out, center.z) * rl.MatrixRotateX(math.PI * 0.5),
	}
	rl.SetMaterialTexture(&renderer.break_material, .ALBEDO, renderer.breaks[stage])
	rl.BeginBlendMode(.ALPHA)
	rlgl.DisableDepthMask()
	rlgl.DisableBackfaceCulling()
	for face in faces {
		rl.DrawMesh(renderer.item_quad, renderer.break_material, face)
	}
	rlgl.EnableBackfaceCulling()
	rlgl.EnableDepthMask()
	rl.EndBlendMode()
}

// The two broad faces of the panel. The crack quad faces +Z and is a meter wide,
// so it is scaled to the panel and turned when the panel faces X.
draw_door_cracks :: proc(renderer: ^Renderer, bmin, bmax: [3]f32, stage: int) {
	sx := bmax.x - bmin.x
	sy := bmax.y - bmin.y
	sz := bmax.z - bmin.z
	center := (bmin + bmax) * 0.5
	bias := CRACK_OUTSET
	faces: [2]rl.Matrix
	if sx < sz {
		scale := rl.MatrixScale(sz, sy, 1)
		faces[0] = rl.MatrixTranslate(bmax.x + bias, center.y, center.z) * rl.MatrixRotateY(math.PI * 0.5) * scale
		faces[1] = rl.MatrixTranslate(bmin.x - bias, center.y, center.z) * rl.MatrixRotateY(-math.PI * 0.5) * scale
	} else {
		scale := rl.MatrixScale(sx, sy, 1)
		faces[0] = rl.MatrixTranslate(center.x, center.y, bmax.z + bias) * scale
		faces[1] = rl.MatrixTranslate(center.x, center.y, bmin.z - bias) * rl.MatrixRotateY(math.PI) * scale
	}
	rl.SetMaterialTexture(&renderer.break_material, .ALBEDO, renderer.breaks[stage])
	rl.BeginBlendMode(.ALPHA)
	rlgl.DisableDepthMask()
	rlgl.DisableBackfaceCulling()
	for face in faces {
		rl.DrawMesh(renderer.item_quad, renderer.break_material, face)
	}
	rlgl.EnableBackfaceCulling()
	rlgl.EnableDepthMask()
	rl.EndBlendMode()
}
