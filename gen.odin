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

// The generated region, in chunks, centered on the origin. The spawn column is
// filled before the first frame of play; the rest follow, nearest players first.
GROUND_CHUNKS_X :: 16
GROUND_CHUNKS_Z :: 16
GEN_MIN_X :: -GROUND_CHUNKS_X / 2
GEN_MIN_Z :: -GROUND_CHUNKS_Z / 2

// How many ores or trees a frame places once the ground is in. A vein is a
// handful of blocks and a tree is one canopy, so this stays under a column's cost.
ORE_STEPS_PER_FRAME   :: 16
TREE_PLACED_PER_FRAME :: 2

BEDROCK_DEPTH :: 2 // y 0 is always bedrock, y 1 is the jagged band.
DIRT_DEPTH    :: 3

TERRAIN_BASE      :: 64    // The height the noise varies around.
TERRAIN_AMPLITUDE :: 14    // Peak-to-base, in blocks.
TERRAIN_SCALE     :: 220.0 // Blocks per noise unit, so larger is smoother.
TERRAIN_OCTAVES   :: 4

// Below TERRAIN_BASE, so only genuine low ground floods. The gap between the two is the
// only knob that decides how much water the world has.
WATER_LEVEL :: 58

// Which columns have their terrain, and how far the ore and tree passes have
// walked. Those passes stay in their old order, so a finished world matches one
// that was built in a single call.
World_Gen :: struct {
	terrain:      [GROUND_CHUNKS_Z][GROUND_CHUNKS_X]bool,
	terrain_left: int,
	ore_cx:       int,
	ore_cz:       int,
	ore_index:    int,
	ore_attempt:  int,
	ore_done:     bool,
	tree_cx:      int,
	tree_cz:      int,
	tree_done:    bool,
	done:         bool,
}

// Runs the stream to completion. Play does not use this; it fills the spawn
// column and then calls world_gen_advance once per frame.
generate_world :: proc(world: ^World, seed: i64) {
	gen: World_Gen
	world_gen_init(&gen)
	for !gen.done {
		world_gen_advance(&gen, world, seed, nil, false)
	}
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

ORE_HALF_X :: GROUND_CHUNKS_X * CHUNK_SIZE / ORE_CELL / 2
ORE_HALF_Z :: GROUND_CHUNKS_Z * CHUNK_SIZE / ORE_CELL / 2

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

TREE_HALF_X :: GROUND_CHUNKS_X * CHUNK_SIZE / TREE_CELL / 2
TREE_HALF_Z :: GROUND_CHUNKS_Z * CHUNK_SIZE / TREE_CELL / 2

// Classic oak: a straight trunk with the canopy centered on its top.
place_oak :: proc(world: ^World, x, base_y, z: int, trunk: int) {
	top := base_y + trunk - 1
	for y in base_y ..= top {
		// Air, or a leaf from a tree placed earlier. Anything a player put here
		// stays, which matters once trees arrive after play has started.
		block := get_block(world, x, y, z)
		if block == .Air || block == .Oak_Leaves {
			set_block(world, x, y, z, .Oak_Log)
		}
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
// matter what order chunks are built in. The stream fills whichever column is
// closest to a player, so that order is not the old left-to-right scan.
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

world_gen_init :: proc(gen: ^World_Gen) {
	gen^ = {}
	gen.terrain_left = GROUND_CHUNKS_X * GROUND_CHUNKS_Z
	gen.ore_cx = -ORE_HALF_X
	gen.ore_cz = -ORE_HALF_Z
	gen.tree_cx = -TREE_HALF_X
	gen.tree_cz = -TREE_HALF_Z
}

// spots are the block columns players are standing on. An empty list keeps
// filling outward from the origin, which is where everyone is born.
world_gen_advance :: proc(gen: ^World_Gen, world: ^World, seed: i64, spots: [][2]int, sync: bool) {
	if gen.done {
		return
	}
	record := world.record
	world.record = false
	world.syncing = sync
	defer {
		world.syncing = false
		world.record = record
	}

	if gen.terrain_left > 0 {
		if cx, cz, ok := world_gen_nearest(gen, spots); ok {
			world_gen_fill_column(gen, world, seed, cx, cz)
		}
	} else if !gen.ore_done {
		// After every column, because a vein only replaces stone and has to see
		// the dirt and grass cap that landed on it.
		for _ in 0 ..< ORE_STEPS_PER_FRAME {
			if gen.ore_done || !world_gen_ore_step(gen, world, seed) {
				break
			}
		}
	} else if !gen.tree_done {
		// After the ores, and only onto grass, same as a one-shot world.
		placed := 0
		for _ in 0 ..< 64 {
			if placed >= TREE_PLACED_PER_FRAME || gen.tree_done {
				break
			}
			ready, did := world_gen_tree_step(gen, world, seed)
			if !ready {
				break
			}
			if did {
				placed += 1
			}
		}
	}

	gen.done = gen.terrain_left == 0 && gen.ore_done && gen.tree_done
}

// One 16x16 column of terrain, from bedrock to the surface. A second call is a
// no-op, so a player born on a column that already streamed in does not rebuild it.
world_gen_fill_column :: proc(gen: ^World_Gen, world: ^World, seed: i64, cx, cz: int) {
	gx := cx - GEN_MIN_X
	gz := cz - GEN_MIN_Z
	if gx < 0 || gz < 0 || gx >= GROUND_CHUNKS_X || gz >= GROUND_CHUNKS_Z {
		return
	}
	if gen.terrain[gz][gx] {
		return
	}
	x0 := cx * CHUNK_SIZE
	z0 := cz * CHUNK_SIZE
	for x in x0 ..< x0 + CHUNK_SIZE {
		for z in z0 ..< z0 + CHUNK_SIZE {
			generate_column(world, seed, x, z, terrain_height(seed, x, z))
		}
	}
	gen.terrain[gz][gx] = true
	gen.terrain_left -= 1
}

world_gen_nearest :: proc(gen: ^World_Gen, spots: [][2]int) -> (cx, cz: int, ok: bool) {
	best := max(int)
	for gz in 0 ..< GROUND_CHUNKS_Z {
		for gx in 0 ..< GROUND_CHUNKS_X {
			if gen.terrain[gz][gx] {
				continue
			}
			wx := gx + GEN_MIN_X
			wz := gz + GEN_MIN_Z
			// Nobody is in the world yet: keep spreading from the spawn column.
			d := column_distance(wx, wz, 0, 0)
			if len(spots) > 0 {
				d = max(int)
				for spot in spots {
					d = min(d, column_distance(wx, wz, spot.x, spot.y))
				}
			}
			if !ok || d < best || (d == best && (wz < cz || (wz == cz && wx < cx))) {
				best = d
				cx = wx
				cz = wz
				ok = true
			}
		}
	}
	return
}

// Blocks from the standing spot to the nearest cell of this column. Zero when
// the spot is already inside it.
column_distance :: proc(cx, cz, bx, bz: int) -> int {
	x0 := cx * CHUNK_SIZE
	z0 := cz * CHUNK_SIZE
	x1 := x0 + CHUNK_SIZE - 1
	z1 := z0 + CHUNK_SIZE - 1
	dx := 0
	dz := 0
	if bx < x0 {
		dx = x0 - bx
	} else if bx > x1 {
		dx = bx - x1
	}
	if bz < z0 {
		dz = z0 - bz
	} else if bz > z1 {
		dz = bz - z1
	}
	return dx * dx + dz * dz
}

// True when every in-region column under this block rectangle has terrain.
// Columns outside the map are air on purpose, and a vein or canopy may poke
// into them the same way a one-shot world did.
blocks_ready :: proc(gen: ^World_Gen, x0, z0, x1, z1: int) -> bool {
	c0 := chunk_of(x0, 0, z0)
	c1 := chunk_of(x1, 0, z1)
	for cz in c0.z ..= c1.z {
		for cx in c0.x ..= c1.x {
			gx := cx - GEN_MIN_X
			gz := cz - GEN_MIN_Z
			if gx < 0 || gz < 0 || gx >= GROUND_CHUNKS_X || gz >= GROUND_CHUNKS_Z {
				continue
			}
			if !gen.terrain[gz][gx] {
				return false
			}
		}
	}
	return true
}

// One vein, in the same cell order as a one-shot pass. False means the stone
// it might replace is not all generated yet, and the cursor stays put.
world_gen_ore_step :: proc(gen: ^World_Gen, world: ^World, seed: i64) -> bool {
	if gen.ore_done {
		return false
	}
	ore := ORES[gen.ore_index]
	x0 := gen.ore_cx * ORE_CELL - ore.max_size
	x1 := (gen.ore_cx + 1) * ORE_CELL - 1 + ore.max_size
	z0 := gen.ore_cz * ORE_CELL - ore.max_size
	z1 := (gen.ore_cz + 1) * ORE_CELL - 1 + ore.max_size
	if !blocks_ready(gen, x0, z0, x1, z1) {
		return false
	}
	place_vein(world, seed, ore, gen.ore_cx, gen.ore_cz, i64(gen.ore_index), i64(gen.ore_attempt))
	gen.ore_attempt += 1
	if gen.ore_attempt < ore.veins_per_cell {
		return true
	}
	gen.ore_attempt = 0
	gen.ore_index += 1
	if gen.ore_index < len(ORES) {
		return true
	}
	gen.ore_index = 0
	gen.ore_cz += 1
	if gen.ore_cz < ORE_HALF_Z {
		return true
	}
	gen.ore_cz = -ORE_HALF_Z
	gen.ore_cx += 1
	if gen.ore_cx >= ORE_HALF_X {
		gen.ore_done = true
	}
	return true
}

// One tree cell. ready is false when this tree's canopy would land on ground
// that does not exist yet; the cell is left for a later frame. Rejected cells
// still advance, because they write nothing and must not hold up the ones after.
world_gen_tree_step :: proc(gen: ^World_Gen, world: ^World, seed: i64) -> (ready, placed: bool) {
	if gen.tree_done {
		return true, false
	}
	cx := gen.tree_cx
	cz := gen.tree_cz
	h := column_hash(seed, SALT_TREE, cx, cz)
	if h % 100 >= TREE_PERCENT {
		world_gen_tree_advance(gen)
		return true, false
	}

	x := cx * TREE_CELL + int((h >> 8) % TREE_CELL)
	z := cz * TREE_CELL + int((h >> 16) % TREE_CELL)
	// Canopy radius is 2. The trunk sits inside that footprint.
	if !blocks_ready(gen, x - 2, z - 2, x + 2, z + 2) {
		return false, false
	}

	ground := terrain_height(seed, x, z)
	// Grass is the one test that keeps trees out of lakes and off bare stone,
	// because a flooded column is capped with dirt instead.
	if get_block(world, x, ground - 1, z) == .Grass {
		trunk := TRUNK_MIN + int((h >> 24) % (TRUNK_MAX - TRUNK_MIN + 1))
		place_oak(world, x, ground, z, trunk)
		placed = true
	}
	world_gen_tree_advance(gen)
	return true, placed
}

world_gen_tree_advance :: proc(gen: ^World_Gen) {
	gen.tree_cz += 1
	if gen.tree_cz < TREE_HALF_Z {
		return
	}
	gen.tree_cz = -TREE_HALF_Z
	gen.tree_cx += 1
	if gen.tree_cx >= TREE_HALF_X {
		gen.tree_done = true
	}
}
