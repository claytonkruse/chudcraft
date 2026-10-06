package main

import "core:math"
import rl "vendor:raylib"

Block :: enum u8 {
	Air,
	Grass,
	Dirt,
	Stone,
}

WIDTH  :: 16
HEIGHT :: 16
DEPTH  :: 16

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

draw_chunk :: proc(chunk: ^Chunk) {
	for x in 0 ..< WIDTH {
		for y in 0 ..< HEIGHT {
			for z in 0 ..< DEPTH {
				block := chunk[x][y][z]
				if block == .Air {
					continue
				}
				// Each block is a 1-unit cube centered on its grid coordinate.
				pos := [3]f32{f32(x), f32(y), f32(z)}
				rl.DrawCube(pos, 1, 1, 1, block_color(block))
				rl.DrawCubeWires(pos, 1, 1, 1, rl.BLACK)
			}
		}
	}
}

// A block at integer coordinate i fills [i - 0.5, i + 0.5].
block_index :: proc(v: f32) -> int {
	return int(math.floor(v + 0.5))
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
