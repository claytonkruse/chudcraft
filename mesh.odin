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
	case .Oak_Leaves:
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
}

// Flat pictures for sticks and tools. Blocks keep the cube icons.
Item_Sprites :: struct {
	stick:          rl.Texture2D,
	wood_shovel:    rl.Texture2D,
	wood_pickaxe:   rl.Texture2D,
	stone_shovel:   rl.Texture2D,
	stone_pickaxe:  rl.Texture2D,
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
}

Renderer :: struct {
	textures:  Block_Textures,
	materials: [Surface]rl.Material,
	meshes:    map[[3]int]^World_Mesh,
	build:     [Surface]Mesh_Build,
	// Shared by every cutout surface, which is why renderer_destroy cannot let
	// UnloadMaterial free it.
	cutout:    rl.Shader,
	// One picture per block, drawn in the hotbar and the inventory. Baked once;
	// a slot redraws the picture, not the mesh.
	icons:     [Block]rl.RenderTexture2D,
	// The cube those pictures were drawn from, kept so a drop can spin in the world.
	item_meshes: [Block]Chunk_Mesh,
	sprites:   Item_Sprites,
	// One upright quad and a material whose texture is swapped per item. The
	// material must not own that texture, or unloading it would free the sprite.
	item_quad: rl.Mesh,
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
// pass 65535), plus leaves and water, which stay one quad per face.
World_Mesh :: struct {
	opaque: [dynamic]rl.Mesh,
	leaves: [dynamic]rl.Mesh,
	water:  [dynamic]rl.Mesh,
}

ATLAS_COUNT :: 14
ATLAS_PAD   :: 1

renderer_init :: proc() -> Renderer {
	renderer: Renderer
	renderer.textures = load_block_textures()
	// nil keeps raylib's default vertex shader, which is all this needs to replace.
	renderer.cutout = rl.LoadShader(nil, "assets/shaders/cutout.fs")

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
	build_block_icons(&renderer)
	renderer.sprites = load_item_sprites()
	renderer.item_quad = build_item_quad()
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
	unload_item_sprites(renderer.sprites)

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
draw_water :: proc(renderer: ^Renderer) {
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
	maxp := minp + CHUNK_SIZE
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
	unload_world_mesh(out)

	chunk := world.chunks[key]
	textured := renderer.textures.stone.id != 0
	base := key * CHUNK_SIZE

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
					if block == .Air {
						continue
					}
					neighbor := mesh_neighbor(world, chunk, key, base, lx, ly, lz, face)
					if face_culled(block, neighbor) {
						continue
					}
					surface := block_surface(block, face)
					tile := atlas_tile(surface)
					if tile < 0 {
						build := leaves if surface == .Oak_Leaves else water
						ensure_mesh_room(build, leaves_list(out, surface))
						append_face(build, {f32(lx), f32(ly), f32(lz)}, face, surface_tint(surface, textured))
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
	delete(mesh.opaque)
	delete(mesh.leaves)
	delete(mesh.water)
	mesh.opaque = nil
	mesh.leaves = nil
	mesh.water = nil
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
	for face in Face {
		surface := block_surface(block, face)
		append_face(&renderer.build[surface], {-0.5, -0.5, -0.5}, face, surface_tint(surface, textured))
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
	}
	return {}
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
	}
	return WHITE_TINT
}

// Opaque surfaces packed left to right. Water and leaves stay on their own textures.
atlas_tile :: proc(surface: Surface) -> int {
	#partial switch surface {
	case .Water, .Oak_Leaves:
		return -1
	}
	id := int(surface)
	if surface > .Water {
		id -= 1
	}
	if surface > .Oak_Leaves {
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
	case .Water, .Oak_Leaves:
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
	}
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
	return textures
}

load_item_sprites :: proc() -> Item_Sprites {
	sprites := Item_Sprites {
		stick         = rl.LoadTexture("assets/textures/stick.png"),
		wood_shovel   = rl.LoadTexture("assets/textures/wooden_shovel.png"),
		wood_pickaxe  = rl.LoadTexture("assets/textures/wooden_pickaxe.png"),
		stone_shovel  = rl.LoadTexture("assets/textures/stone_shovel.png"),
		stone_pickaxe = rl.LoadTexture("assets/textures/stone_pickaxe.png"),
	}
	prepare_texture(&sprites.stick)
	prepare_texture(&sprites.wood_shovel)
	prepare_texture(&sprites.wood_pickaxe)
	prepare_texture(&sprites.stone_shovel)
	prepare_texture(&sprites.stone_pickaxe)
	return sprites
}

unload_item_sprites :: proc(sprites: Item_Sprites) {
	if sprites.stick.id != 0 do rl.UnloadTexture(sprites.stick)
	if sprites.wood_shovel.id != 0 do rl.UnloadTexture(sprites.wood_shovel)
	if sprites.wood_pickaxe.id != 0 do rl.UnloadTexture(sprites.wood_pickaxe)
	if sprites.stone_shovel.id != 0 do rl.UnloadTexture(sprites.stone_shovel)
	if sprites.stone_pickaxe.id != 0 do rl.UnloadTexture(sprites.stone_pickaxe)
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
}

// Far enough in front of the block face that the wires win the depth test, close enough to still read as the block edge.
HIGHLIGHT_BIAS :: 0.005

draw_block_highlight :: proc(x, y, z: int, eye: [3]f32) {
	center := [3]f32{f32(x), f32(y) + 0.5, f32(z)}
	to_eye := eye - center
	length := math.sqrt(to_eye.x*to_eye.x + to_eye.y*to_eye.y + to_eye.z*to_eye.z)
	if length > 0 {
		center += to_eye * (HIGHLIGHT_BIAS / length)
	}
	rl.DrawCubeWires(center, 1, 1, 1, rl.BLACK)
}
