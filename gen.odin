package main

import "core:math"
import "core:math/noise"
import "core:math/rand"

// World generation. Writes only through set_block, so everything it produces marks
// the same dirty chunks that mining does and gets remeshed the same way.
// Nothing here knows how a block is drawn.

// A new world each launch. rand.uint64 is lazily seeded from the OS, so this is
// just "pick a 64-bit number"; the generator itself stays deterministic for that number.
generate_seed :: proc() -> i64 {
	return i64(rand.uint64())
}

// The generated region, in chunks, centered on the origin. Streaming replaces this.
GROUND_CHUNKS_X :: 16
GROUND_CHUNKS_Z :: 16

BEDROCK_DEPTH :: 2 // y 0 is always bedrock, y 1 is the jagged band.
DIRT_DEPTH    :: 3

TERRAIN_BASE      :: 64    // The height the noise varies around.
TERRAIN_AMPLITUDE :: 14    // Peak-to-base, in blocks.
TERRAIN_SCALE     :: 220.0 // Blocks per noise unit, so larger is smoother.
TERRAIN_OCTAVES   :: 4

// Below TERRAIN_BASE, so only genuine low ground floods. The gap between the two is the
// only knob that decides how much water the world has.
WATER_LEVEL :: 58

generate_world :: proc(world: ^World, seed: i64) {
	half_x := GROUND_CHUNKS_X * CHUNK_SIZE / 2
	half_z := GROUND_CHUNKS_Z * CHUNK_SIZE / 2
	for x in -half_x ..< half_x {
		for z in -half_z ..< half_z {
			generate_column(world, seed, x, z, terrain_height(seed, x, z))
		}
	}

	// After the terrain, because a vein only replaces stone and so has to be able to
	// see which blocks ended up as the dirt and grass cap.
	generate_ores(world, seed)

	// After the terrain too, since a tree is rejected unless it lands on grass.
	generate_trees(world, seed)
}

// The Y the surface block's top sits at. Fractal noise: each octave doubles the
// frequency and halves the contribution, which puts small bumps on large hills.
terrain_height :: proc(seed: i64, x, z: int) -> int {
	value, amplitude, frequency, normalizer: f32 = 0, 1, 1, 0
	for octave in 0 ..< TERRAIN_OCTAVES {
		p := noise.Vec2 {
			f64(x) * f64(frequency) / TERRAIN_SCALE,
			f64(z) * f64(frequency) / TERRAIN_SCALE,
		}
		// A different seed per octave, so the octaves do not line up into ridges.
		value += noise.noise_2d(seed + i64(octave), p) * amplitude
		normalizer += amplitude
		amplitude *= 0.5
		frequency *= 2
	}
	// Clamped so terrain can never eat into the bedrock band.
	return clamp(TERRAIN_BASE + int(value / normalizer * TERRAIN_AMPLITUDE), BEDROCK_DEPTH + 2, 120)
}

// Fills one column from the bedrock floor up to `height`, which is the Y the player
// stands at. Air is never written, so columns only allocate the chunks they occupy.
generate_column :: proc(world: ^World, seed: i64, x, z: int, height: int) {
	set_block(world, x, 0, z, .Bedrock)

	// The jagged band: half of these come out bedrock, so the floor is uneven.
	for y in 1 ..< BEDROCK_DEPTH {
		jagged := column_hash(seed, SALT_BEDROCK + i64(y), x, z) & 1 == 0
		set_block(world, x, y, z, .Bedrock if jagged else .Stone)
	}

	grass_y := height - 1
	dirt_y := grass_y - DIRT_DEPTH

	for y in BEDROCK_DEPTH ..< dirt_y {
		set_block(world, x, y, z, .Stone)
	}
	for y in max(dirt_y, BEDROCK_DEPTH) ..< grass_y {
		set_block(world, x, y, z, .Dirt)
	}
	if grass_y >= BEDROCK_DEPTH {
		// Grass does not grow underwater, so a flooded column is capped with dirt.
		set_block(world, x, grass_y, z, .Grass if height >= WATER_LEVEL else .Dirt)
	}

	// A low column floods up to the water line, which is what puts lakes in the
	// valleys the heightmap already produced.
	for y in height ..< WATER_LEVEL {
		set_block(world, x, y, z, .Water)
	}
}

// Veins are placed per cell of world rather than per column, which is what bounds how
// many of them a cell can hold and keeps density independent of iteration order.
ORE_CELL :: 16

Ore :: struct {
	block:              Block,
	min_y, max_y:       int,
	veins_per_cell:     int,
	min_size, max_size: int,
}

// Minecraft's depth bands assume a 384-block world and ours is about 80, so they
// compress. Gold is the rarest and the deepest, coal the most common and the shallowest.
@(rodata)
ORES := []Ore {
	{.Coal_Ore, 8, 52, 3, 5, 12},
	{.Iron_Ore, 4, 36, 2, 4, 8},
	{.Gold_Ore, 2, 18, 1, 3, 6},
}

generate_ores :: proc(world: ^World, seed: i64) {
	half_x := GROUND_CHUNKS_X * CHUNK_SIZE / ORE_CELL / 2
	half_z := GROUND_CHUNKS_Z * CHUNK_SIZE / ORE_CELL / 2
	for cx in -half_x ..< half_x {
		for cz in -half_z ..< half_z {
			for ore, index in ORES {
				for attempt in 0 ..< ore.veins_per_cell {
					place_vein(world, seed, ore, cx, cz, i64(index), i64(attempt))
				}
			}
		}
	}
}

// A short random walk from a hashed start inside the ore's band.
place_vein :: proc(world: ^World, seed: i64, ore: Ore, cx, cz: int, index, attempt: i64) {
	h := column_hash(seed, SALT_ORE + index * 0x40 + attempt, cx, cz)

	// Separate bit ranges, so the start and the size do not move together.
	pos := [3]int {
		cx * ORE_CELL + int(h & 0xF),
		ore.min_y + int((h >> 8) % u64(ore.max_y - ore.min_y + 1)),
		cz * ORE_CELL + int((h >> 4) & 0xF),
	}
	size := ore.min_size + int((h >> 32) % u64(ore.max_size - ore.min_size + 1))

	for _ in 0 ..< size {
		// Stone only, which keeps ore out of the bedrock, out of the dirt and grass
		// cap, and out of the air above the surface, with no special cases.
		if get_block(world, pos.x, pos.y, pos.z) == .Stone {
			set_block(world, pos.x, pos.y, pos.z, ore.block)
		}
		// Re-mixed each step, because a vein walks further than 64 bits will carry.
		h = hash_u64(h)
		axis := int(h % 3)
		pos[axis] += 1 if (h >> 2) & 1 == 0 else -1
		pos.y = clamp(pos.y, ore.min_y, ore.max_y)
	}
}

// At most one tree per cell, which is what guarantees a minimum spacing. A per-column
// probability roll instead clumps trees together and gives no control over it.
TREE_CELL    :: 8
TREE_PERCENT :: 35 // Share of cells that get a tree.

TRUNK_MIN :: 4
TRUNK_MAX :: 6

generate_trees :: proc(world: ^World, seed: i64) {
	half_x := GROUND_CHUNKS_X * CHUNK_SIZE / TREE_CELL / 2
	half_z := GROUND_CHUNKS_Z * CHUNK_SIZE / TREE_CELL / 2
	for cx in -half_x ..< half_x {
		for cz in -half_z ..< half_z {
			h := column_hash(seed, SALT_TREE, cx, cz)
			if h % 100 >= TREE_PERCENT {
				continue
			}

			x := cx * TREE_CELL + int((h >> 8) % TREE_CELL)
			z := cz * TREE_CELL + int((h >> 16) % TREE_CELL)
			ground := terrain_height(seed, x, z)

			// Grass is the one test that keeps trees out of lakes and off bare stone,
			// because a flooded column is capped with dirt instead.
			if get_block(world, x, ground - 1, z) != .Grass {
				continue
			}
			trunk := TRUNK_MIN + int((h >> 24) % (TRUNK_MAX - TRUNK_MIN + 1))
			place_oak(world, x, ground, z, trunk)
		}
	}
}

// Classic oak: a straight trunk with the canopy centered on its top.
place_oak :: proc(world: ^World, x, base_y, z: int, trunk: int) {
	top := base_y + trunk - 1
	for y in base_y ..= top {
		set_block(world, x, y, z, .Oak_Log)
	}

	// Two 5x5 layers below the top, then 3x3 above it, with corners off everything
	// except the first 3x3 so the silhouette rounds instead of ending in a block.
	leaf_layer(world, x, top - 2, z, 2, true)
	leaf_layer(world, x, top - 1, z, 2, true)
	leaf_layer(world, x, top, z, 1, false)
	leaf_layer(world, x, top + 1, z, 1, true)
}

leaf_layer :: proc(world: ^World, x, y, z: int, radius: int, cut_corners: bool) {
	for dx in -radius ..= radius {
		for dz in -radius ..= radius {
			if cut_corners && abs(dx) == radius && abs(dz) == radius {
				continue
			}
			// Air only, so a canopy can never eat its own trunk or a neighbor's.
			if get_block(world, x + dx, y, z + dz) == .Air {
				set_block(world, x + dx, y, z + dz, .Oak_Leaves)
			}
		}
	}
}

// Each feature mixes in its own salt, so ores, trees, and the bedrock band never
// correlate with each other despite sharing one hash.
SALT_BEDROCK :: 0x1000
SALT_ORE :: 0x2000
SALT_TREE :: 0x3000

// Position-hashed rather than sequential, so a column generates the same blocks no
// matter what order chunks are built in. That becomes load-bearing once chunks stream
// in and are no longer all generated up front.
column_hash :: proc(seed: i64, salt: i64, x, z: int) -> u64 {
	h := u64(seed) ~ (u64(salt) * 0xD6E8FEB86659FD93)
	h ~= u64(x) * 0xBF58476D1CE4E5B9
	h ~= u64(z) * 0x94D049BB133111EB
	return hash_u64(h)
}

// splitmix64's finalizer, which spreads a small change across every output bit.
hash_u64 :: proc(value: u64) -> u64 {
	h := value
	h ~= h >> 30
	h *= 0xBF58476D1CE4E5B9
	h ~= h >> 27
	h *= 0x94D049BB133111EB
	h ~= h >> 31
	return h
}
