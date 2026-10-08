package main

import "core:c"
import "core:math"
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
	meshes:    map[[3]int]^Chunk_Mesh,
	build:     [Surface]Mesh_Build,
	// Shared by every cutout surface, which is why renderer_destroy cannot let
	// UnloadMaterial free it.
	cutout:    rl.Shader,
	// One picture per block, drawn in the hotbar and the inventory. Baked once;
	// a slot redraws the picture, not the mesh.
	icons:     [Block]rl.RenderTexture2D,
	// The cube those pictures were drawn from, kept so a drop can spin in the world.
	item_meshes: [Block]Chunk_Mesh,
	player:    Player_Model,
}

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
	player_model_init(&renderer)
	return renderer
}

renderer_destroy :: proc(renderer: ^Renderer) {
	for _, mesh in renderer.meshes {
		for surface in Surface {
			if mesh.filled[surface] {
				rl.UnloadMesh(mesh.meshes[surface])
			}
		}
		free(mesh)
	}
	delete(renderer.meshes)
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

// Rebuilds whatever is dirty, then draws every chunk mesh once.
draw_world :: proc(renderer: ^Renderer, world: ^World) {
	for key, chunk in world.chunks {
		mesh := renderer.meshes[key]
		if mesh == nil {
			mesh = new(Chunk_Mesh)
			renderer.meshes[key] = mesh
			chunk.dirty = true
		}
		if chunk.dirty {
			build_chunk_mesh(renderer, world, key, mesh)
			chunk.dirty = false
		}
	}

	// Depth-writing passes first, so the depth buffer is complete before anything blends.
	draw_pass(renderer, .Opaque)
	draw_pass(renderer, .Cutout)

	// Water must not hide what is behind it. With depth writes off it also cannot hide
	// other water, which is what lets this pass skip sorting the meshes entirely.
	rl.BeginBlendMode(.ALPHA)
	rlgl.DisableDepthMask()
	draw_pass(renderer, .Translucent)
	rlgl.EnableDepthMask()
	rl.EndBlendMode()
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

draw_pass :: proc(renderer: ^Renderer, pass: Surface_Pass) {
	for key, mesh in renderer.meshes {
		// Vertices are chunk-local, so the chunk's world position and the half-block
		// shift that centers blocks on X and Z both live in this transform.
		origin := [3]f32 {
			f32(key.x * CHUNK_SIZE) - 0.5,
			f32(key.y * CHUNK_SIZE),
			f32(key.z * CHUNK_SIZE) - 0.5,
		}
		transform := rl.MatrixTranslate(origin.x, origin.y, origin.z)
		for surface in Surface {
			if mesh.filled[surface] && surface_pass(surface) == pass {
				rl.DrawMesh(mesh.meshes[surface], renderer.materials[surface], transform)
			}
		}
	}
}

build_chunk_mesh :: proc(renderer: ^Renderer, world: ^World, key: [3]int, out: ^Chunk_Mesh) {
	for surface in Surface {
		build := &renderer.build[surface]
		clear(&build.vertices)
		clear(&build.texcoords)
		clear(&build.colors)
		clear(&build.indices)
	}

	chunk := world.chunks[key]
	base := key * CHUNK_SIZE
	// Without textures the vertex tint is all the color a block has left.
	textured := renderer.textures.stone.id != 0

	for lx in 0 ..< CHUNK_SIZE {
		for ly in 0 ..< CHUNK_SIZE {
			for lz in 0 ..< CHUNK_SIZE {
				block := chunk.blocks[lx][ly][lz]
				if block == .Air {
					continue
				}
				for face in Face {
					offset := FACE_OFFSET[face]
					// Reading through the world, not the chunk, so a face against
					// the neighboring chunk is culled too.
					neighbor := get_block(
						world,
						base.x + lx + offset.x,
						base.y + ly + offset.y,
						base.z + lz + offset.z,
					)
					if face_culled(block, neighbor) {
						continue
					}
					surface := block_surface(block, face)
					append_face(
						&renderer.build[surface],
						{f32(lx), f32(ly), f32(lz)},
						face,
						surface_tint(surface, textured),
					)
				}
			}
		}
	}

	for surface in Surface {
		upload_surface(out, surface, &renderer.build[surface])
	}
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

draw_drops :: proc(renderer: ^Renderer, drops: []Drop_View) {
	if len(drops) == 0 {
		return
	}
	for pass in Surface_Pass {
		if pass == .Translucent {
			rl.BeginBlendMode(.ALPHA)
			rlgl.DisableDepthMask()
		}
		for drop in drops {
			mesh := &renderer.item_meshes[drop.block]
			hover := 0.04 + math.sin(drop.age * 3 + drop.phase) * 0.03
			spin := rl.MatrixRotateY(drop.age * 2.4 + drop.phase)
			scale := rl.MatrixScale(DROP_DRAW_SCALE, DROP_DRAW_SCALE, DROP_DRAW_SCALE)
			place := rl.MatrixTranslate(drop.position.x, drop.position.y + hover, drop.position.z)
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
	}
	return WHITE_TINT
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
	return textures
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
set_block_mipmaps :: proc(textures: Block_Textures, enabled: bool) {
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
