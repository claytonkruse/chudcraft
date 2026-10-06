package main

import "core:math"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

Block :: enum u8 {
	Air,
	Grass,
	Dirt,
	Stone,
}

WIDTH  :: 16
HEIGHT :: 16
DEPTH  :: 16

// How far, in meters, a look ray can break a block.
MINE_REACH :: 5.0

// Plains grass color. The Faithful grass top is grayscale and gets multiplied by this.
GRASS_TINT :: [4]u8{145, 189, 89, 255}

// Placeholder art from Faithful 32x. Replace these before distributing the game.
// https://faithfulpack.net
Block_Textures :: struct {
	grass_top:  rl.Texture2D,
	grass_side: rl.Texture2D,
	dirt:       rl.Texture2D,
	stone:      rl.Texture2D,
}

Chunk :: [WIDTH][HEIGHT][DEPTH]Block

// Air is the zero value, so only the ground layers need to be filled.
fill_chunk :: proc(chunk: ^Chunk) {
	for x in 0 ..< WIDTH {
		for z in 0 ..< DEPTH {
			chunk[x][0][z] = .Stone
			chunk[x][1][z] = .Stone
			chunk[x][2][z] = .Dirt
			chunk[x][3][z] = .Grass
		}
	}
}

draw_chunk :: proc(chunk: ^Chunk, textures: Block_Textures) {
	for x in 0 ..< WIDTH {
		for y in 0 ..< HEIGHT {
			for z in 0 ..< DEPTH {
				block := chunk[x][y][z]
				if block == .Air {
					continue
				}
				// The block's position is the center of its bottom face.
				// The cube is drawn around a center half a block above that.
				pos := [3]f32{f32(x), f32(y) + 0.5, f32(z)}
				draw_block(pos, block, textures)
				// rl.DrawCubeWires(pos, 1, 1, 1, rl.BLACK)
			}
		}
	}
	rlgl.SetTexture(0)
}

load_block_textures :: proc() -> Block_Textures {
	textures := Block_Textures {
		grass_top  = rl.LoadTexture("assets/textures/grass_block_top.png"),
		grass_side = rl.LoadTexture("assets/textures/grass_block_side.png"),
		dirt       = rl.LoadTexture("assets/textures/dirt.png"),
		stone      = rl.LoadTexture("assets/textures/stone.png"),
	}
	prepare_texture(textures.grass_top)
	prepare_texture(textures.grass_side)
	prepare_texture(textures.dirt)
	prepare_texture(textures.stone)
	return textures
}

unload_block_textures :: proc(textures: Block_Textures) {
	unload_texture(textures.grass_top)
	unload_texture(textures.grass_side)
	unload_texture(textures.dirt)
	unload_texture(textures.stone)
}

prepare_texture :: proc(texture: rl.Texture2D) {
	if texture.id == 0 {
		return
	}
	rl.SetTextureFilter(texture, .POINT)
	rl.SetTextureWrap(texture, .CLAMP)
}

unload_texture :: proc(texture: rl.Texture2D) {
	if texture.id != 0 {
		rl.UnloadTexture(texture)
	}
}

draw_block :: proc(center: [3]f32, block: Block, textures: Block_Textures) {
	if textures.stone.id == 0 {
		rl.DrawCube(center, 1, 1, 1, block_color(block))
		return
	}

	top := textures.stone
	side := textures.stone
	bottom := textures.stone
	top_tint := [4]u8{255, 255, 255, 255}
	switch block {
	case .Grass:
		top = textures.grass_top
		side = textures.grass_side
		bottom = textures.dirt
		top_tint = GRASS_TINT
	case .Dirt:
		top = textures.dirt
		side = textures.dirt
		bottom = textures.dirt
	case .Stone:
		top = textures.stone
		side = textures.stone
		bottom = textures.stone
	case .Air:
		return
	}

	x0 := center.x - 0.5
	x1 := center.x + 0.5
	y0 := center.y - 0.5
	y1 := center.y + 0.5
	z0 := center.z - 0.5
	z1 := center.z + 0.5
	white := [4]u8{255, 255, 255, 255}

	rlgl.SetTexture(side.id)
	rlgl.Begin(rlgl.QUADS)
	draw_quad({x0, y0, z1}, {x1, y0, z1}, {x1, y1, z1}, {x0, y1, z1}, white)
	draw_quad({x1, y0, z0}, {x0, y0, z0}, {x0, y1, z0}, {x1, y1, z0}, white)
	draw_quad({x1, y0, z1}, {x1, y0, z0}, {x1, y1, z0}, {x1, y1, z1}, white)
	draw_quad({x0, y0, z0}, {x0, y0, z1}, {x0, y1, z1}, {x0, y1, z0}, white)
	rlgl.End()

	rlgl.SetTexture(top.id)
	rlgl.Begin(rlgl.QUADS)
	draw_quad({x0, y1, z1}, {x1, y1, z1}, {x1, y1, z0}, {x0, y1, z0}, top_tint)
	rlgl.End()

	rlgl.SetTexture(bottom.id)
	rlgl.Begin(rlgl.QUADS)
	draw_quad({x0, y0, z0}, {x1, y0, z0}, {x1, y0, z1}, {x0, y0, z1}, white)
	rlgl.End()
}

draw_quad :: proc(a, b, c, d: [3]f32, tint: [4]u8) {
	rlgl.Color4ub(tint[0], tint[1], tint[2], tint[3])
	rlgl.TexCoord2f(0, 1)
	rlgl.Vertex3f(a.x, a.y, a.z)
	rlgl.TexCoord2f(1, 1)
	rlgl.Vertex3f(b.x, b.y, b.z)
	rlgl.TexCoord2f(1, 0)
	rlgl.Vertex3f(c.x, c.y, c.z)
	rlgl.TexCoord2f(0, 0)
	rlgl.Vertex3f(d.x, d.y, d.z)
}

// First solid block the ray enters, within reach. Direction does not need to be normalized.
// X and Z are shifted by 0.5 so every block is a unit cell and a grid walk can cross them.
raycast_block :: proc(chunk: ^Chunk, origin, direction: [3]f32, reach: f32) -> (hit: bool, x, y, z: int) {
	length := math.sqrt(direction.x * direction.x + direction.y * direction.y + direction.z * direction.z)
	if length == 0 {
		return false, 0, 0, 0
	}
	dir := direction / length
	pos := [3]f32{origin.x + 0.5, origin.y, origin.z + 0.5}

	x = int(math.floor(pos.x))
	y = int(math.floor(pos.y))
	z = int(math.floor(pos.z))

	step, t_max, t_delta: [3]f32
	for axis in 0 ..< 3 {
		if dir[axis] > 0 {
			step[axis] = 1
			t_delta[axis] = 1 / dir[axis]
			t_max[axis] = (f32(int(math.floor(pos[axis])) + 1) - pos[axis]) * t_delta[axis]
		} else if dir[axis] < 0 {
			step[axis] = -1
			t_delta[axis] = 1 / -dir[axis]
			t_max[axis] = (pos[axis] - f32(int(math.floor(pos[axis])))) * t_delta[axis]
		} else {
			step[axis] = 0
			t_delta[axis] = 1e30
			t_max[axis] = 1e30
		}
	}

	cell := [3]int{x, y, z}
	distance: f32 = 0
	for _ in 0 ..< 64 {
		if distance > reach {
			break
		}
		if solid(chunk, cell.x, cell.y, cell.z) {
			return true, cell.x, cell.y, cell.z
		}

		axis := 0
		if t_max.y < t_max.x do axis = 1
		if t_max.z < t_max[axis] do axis = 2
		if step[axis] == 0 {
			break
		}
		cell[axis] += int(step[axis])
		distance = t_max[axis]
		t_max[axis] += t_delta[axis]
	}
	return false, 0, 0, 0
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

// Horizontally, block i covers [i - 0.5, i + 0.5].
block_index_horizontal :: proc(v: f32) -> int {
	return int(math.floor(v + 0.5))
}

// Vertically, block i covers [i, i + 1], with its bottom on i.
block_index_vertical :: proc(v: f32) -> int {
	return int(math.floor(v))
}

solid :: proc(chunk: ^Chunk, x, y, z: int) -> bool {
	if x < 0 || x >= WIDTH || y < 0 || y >= HEIGHT || z < 0 || z >= DEPTH {
		return false
	}
	return chunk[x][y][z] != .Air
}

block_color :: proc(block: Block) -> rl.Color {
	switch block {
	case .Grass:
		return rl.GREEN
	case .Dirt:
		return rl.BROWN
	case .Stone:
		return rl.GRAY
	case .Air:
		return rl.BLANK
	}
	return rl.BLANK
}
