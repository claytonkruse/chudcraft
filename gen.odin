package main

import "core:math"
import "core:math/noise"
import "core:math/rand"

// World generation. While a column is being filled it writes the chunk array
// directly. Grass and leaves are scheduled once the column is complete.
// Nothing here knows how a block is drawn.

// A new world each launch. rand.uint64 is lazily seeded from the OS, so this is
// just "pick a 64-bit number"; the generator itself stays deterministic for that number.
generate_seed :: proc() -> i64 {
	return i64(rand.uint64())
}

// How many chunks from a player still generate and stay loaded, unless the
// options screen says otherwise. The world has no edge; columns farther than a
// player's distance are not built, and columns past their unload margin are
// dropped until someone walks back.
// 4 chunks of 32 is the same 128-block view the old 8 chunks of 16 had.
RENDER_DISTANCE     :: 4
RENDER_DISTANCE_MIN :: 2
RENDER_DISTANCE_MAX :: 64
// One extra 32-chunk, the same block margin as the old two extra 16-chunks.
UNLOAD_MARGIN :: 1

// A player standing on block (x, z) who keeps `radius` chunks loaded.
// A radius outside the allowed range means the default.
Load_Spot :: struct {
	x, z:   int,
	radius: int,
}

render_radius :: proc(radius: int) -> int {
	if radius < RENDER_DISTANCE_MIN || radius > RENDER_DISTANCE_MAX {
		return RENDER_DISTANCE
	}
	return radius
}

unload_radius :: proc(radius: int) -> int {
	return render_radius(radius) + UNLOAD_MARGIN
}

BEDROCK_DEPTH :: 2 // y 0 is always bedrock, y 1 is the jagged band.
DIRT_DEPTH    :: 3

TERRAIN_BASE      :: 64    // The height the noise varies around.
TERRAIN_AMPLITUDE :: 14    // Peak-to-base, in blocks.
TERRAIN_SCALE     :: 220.0 // Blocks per noise unit, so larger is smoother.
TERRAIN_OCTAVES   :: 4

// Below TERRAIN_BASE, so only genuine low ground floods. The gap between the two is the
// only knob that decides how much water the world has.
WATER_LEVEL :: 58

// Which columns are finished. A finished column already has its water, ore, and
// trees; later columns do not come back and edit it. loaded is the subset
// currently in the world, which is what the render distance keeps around.
World_Gen :: struct {
	columns: map[[2]int]bool,
	loaded:  map[[2]int]bool,
	// Player chunk columns last time far chunks were dropped. Unload waits
	// until that set changes.
	watched:     map[[3]int]bool,
	watch_ready: bool,
	drop_keys:   [dynamic][3]int,
}

// Fills the render distance around the origin. Play does not use this; it
// ensures the spawn column and then calls world_gen_advance once per frame.
generate_world :: proc(world: ^World, seed: i64) {
	gen: World_Gen
	world_gen_init(&gen)
	defer world_gen_destroy(&gen)
	for {
		before := len(gen.loaded)
		world_gen_advance(&gen, world, seed, nil, false)
		if len(gen.loaded) == before {
			return
		}
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
	write_gen_block(world, x, 0, z, .Bedrock)

	// The jagged band: half of these come out bedrock, so the floor is uneven.
	for y in 1 ..< BEDROCK_DEPTH {
		jagged := column_hash(seed, SALT_BEDROCK + i64(y), x, z) & 1 == 0
		write_gen_block(world, x, y, z, .Bedrock if jagged else .Stone)
	}

	grass_y := height - 1
	dirt_y := grass_y - DIRT_DEPTH

	for y in BEDROCK_DEPTH ..< dirt_y {
		write_gen_block(world, x, y, z, .Stone)
	}
	for y in max(dirt_y, BEDROCK_DEPTH) ..< grass_y {
		write_gen_block(world, x, y, z, .Dirt)
	}
	if grass_y >= BEDROCK_DEPTH {
		// Grass does not grow underwater, so a flooded column is capped with dirt.
		write_gen_block(world, x, grass_y, z, .Grass if height >= WATER_LEVEL else .Dirt)
	}

	// A low column floods up to the water line, which is what puts lakes in the
	// valleys the heightmap already produced.
	for y in height ..< WATER_LEVEL {
		write_gen_block(world, x, y, z, .Water)
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
			write_gen_block(world, pos.x, pos.y, pos.z, ore.block)
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

// Classic oak: a straight trunk with the canopy centered on its top.
place_oak :: proc(world: ^World, x, base_y, z: int, trunk: int) {
	top := base_y + trunk - 1
	for y in base_y ..= top {
		// Air, or a leaf from a tree placed earlier. Anything a player put here
		// stays, which matters once trees arrive after play has started.
		block := get_block(world, x, y, z)
		if block == .Air || block == .Oak_Leaves {
			write_gen_block(world, x, y, z, .Oak_Log)
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
				write_gen_block(world, x + dx, y, z + dz, .Oak_Leaves)
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
}

world_gen_destroy :: proc(gen: ^World_Gen) {
	delete(gen.columns)
	delete(gen.loaded)
	delete(gen.watched)
	delete(gen.drop_keys)
	gen^ = {}
}

// spots are the block columns players are standing on, each with the render
// distance that player asked for. An empty list keeps filling outward from the
// origin, which is where everyone is born. One column a frame, the closest
// missing one inside some player's distance, then anything past every unload
// margin leaves memory.
world_gen_advance :: proc(gen: ^World_Gen, world: ^World, seed: i64, spots: []Load_Spot, sync: bool) {
	record := world.record
	world.record = false
	world.syncing = sync
	defer {
		world.syncing = false
		world.record = record
	}

	if cx, cz, ok := world_gen_nearest(gen, spots); ok {
		world_gen_ensure(gen, world, seed, cx, cz)
	}
	if world_gen_spots_changed(gen, spots) {
		world_unload_far(gen, world, spots)
	}
}

world_gen_spots_changed :: proc(gen: ^World_Gen, spots: []Load_Spot) -> bool {
	origins := spots
	fallback := [1]Load_Spot{{0, 0, RENDER_DISTANCE}}
	if len(origins) == 0 {
		origins = fallback[:]
	}
	next: map[[3]int]bool
	for spot in origins {
		origin := chunk_of(spot.x, 0, spot.z)
		next[[3]int{origin.x, origin.z, unload_radius(spot.radius)}] = true
	}
	same := gen.watch_ready && len(next) == len(gen.watched)
	if same {
		for key, _ in next {
			if !gen.watched[key] {
				same = false
				break
			}
		}
	}
	if same {
		delete(next)
		return false
	}
	delete(gen.watched)
	gen.watched = next
	gen.watch_ready = true
	return true
}

// Brings one column into memory. The first visit writes terrain, water, ore, and
// trees. A later visit puts edited chunks back and regenerates the rest, and
// those edited chunks refuse the second write.
world_gen_ensure :: proc(gen: ^World_Gen, world: ^World, seed: i64, cx, cz: int) {
	column := [2]int{cx, cz}
	if gen.loaded[column] {
		return
	}
	world_restore_column(world, cx, cz)

	x0 := cx * CHUNK_SIZE
	z0 := cz * CHUNK_SIZE
	world.gen_x0 = x0
	world.gen_x1 = x0 + CHUNK_SIZE - 1
	world.gen_z0 = z0
	world.gen_z1 = z0 + CHUNK_SIZE - 1
	world.gen_clip = true
	defer world.gen_clip = false

	for x in x0 ..< x0 + CHUNK_SIZE {
		for z in z0 ..< z0 + CHUNK_SIZE {
			generate_column(world, seed, x, z, terrain_height(seed, x, z))
		}
	}
	// Ore and trees land in this same pass, including the part of a neighbor's
	// vein or canopy that falls here. The neighbor's own column writes the rest.
	world_gen_ores(world, seed, cx, cz)
	world_gen_trees(gen, world, seed, cx, cz)
	world_gen_schedule(world, cx, cz)

	gen.columns[column] = true
	gen.loaded[column] = true
}

// Veins start in a 16-wide cell and walk at most a dozen blocks, so only this
// column and the eight around it can leave ore here.
world_gen_ores :: proc(world: ^World, seed: i64, cx, cz: int) {
	for ocx in cx - 1 ..= cx + 1 {
		for ocz in cz - 1 ..= cz + 1 {
			for ore, index in ORES {
				for attempt in 0 ..< ore.veins_per_cell {
					place_vein(world, seed, ore, ocx, ocz, i64(index), i64(attempt))
				}
			}
		}
	}
}

// Canopies reach two blocks, so a trunk just outside this column can still
// drop leaves here. Trunks on grass are decided from the heightmap when that
// column is not generated yet, which is the same test generate_column uses.
world_gen_trees :: proc(gen: ^World_Gen, world: ^World, seed: i64, cx, cz: int) {
	x0 := cx * CHUNK_SIZE
	z0 := cz * CHUNK_SIZE
	x1 := x0 + CHUNK_SIZE - 1
	z1 := z0 + CHUNK_SIZE - 1
	for tcx in tree_cell(x0 - 2) ..= tree_cell(x1 + 2) {
		for tcz in tree_cell(z0 - 2) ..= tree_cell(z1 + 2) {
			h := column_hash(seed, SALT_TREE, tcx, tcz)
			if h % 100 >= TREE_PERCENT {
				continue
			}
			x := tcx * TREE_CELL + int((h >> 8) % TREE_CELL)
			z := tcz * TREE_CELL + int((h >> 16) % TREE_CELL)
			if x+2 < x0 || x-2 > x1 || z+2 < z0 || z-2 > z1 {
				continue
			}
			if !tree_on_grass(gen, world, seed, x, z, cx, cz) {
				continue
			}
			trunk := TRUNK_MIN + int((h >> 24) % (TRUNK_MAX - TRUNK_MIN + 1))
			place_oak(world, x, terrain_height(seed, x, z), z, trunk)
		}
	}
}

tree_on_grass :: proc(gen: ^World_Gen, world: ^World, seed: i64, x, z, cx, cz: int) -> bool {
	origin := chunk_of(x, 0, z)
	if (origin.x == cx && origin.z == cz) || column_done(gen, origin.x, origin.z) {
		return get_block(world, x, terrain_height(seed, x, z)-1, z) == .Grass
	}
	return terrain_height(seed, x, z) >= WATER_LEVEL
}

column_done :: proc(gen: ^World_Gen, cx, cz: int) -> bool {
	return gen.columns[{cx, cz}]
}

// True when this column is inside the square of `radius` chunks around origin.
column_in_radius :: proc(cx, cz, ox, oz, radius: int) -> bool {
	dx := cx - ox
	dz := cz - oz
	if dx < 0 {
		dx = -dx
	}
	if dz < 0 {
		dz = -dz
	}
	return dx <= radius && dz <= radius
}

// Tree cells are TREE_CELL wide and numbered so cell 0 starts at block 0.
// Negative blocks belong to negative cells, unlike a truncating divide.
tree_cell :: proc(block: int) -> int {
	if block >= 0 {
		return block / TREE_CELL
	}
	return (block - (TREE_CELL - 1)) / TREE_CELL
}

world_gen_nearest :: proc(gen: ^World_Gen, spots: []Load_Spot) -> (cx, cz: int, ok: bool) {
	best := max(int)
	origins := spots
	fallback := [1]Load_Spot{{0, 0, RENDER_DISTANCE}}
	if len(origins) == 0 {
		origins = fallback[:]
	}
	for spot in origins {
		origin := chunk_of(spot.x, 0, spot.z)
		radius := render_radius(spot.radius)
		for dz in -radius ..= radius {
			for dx in -radius ..= radius {
				wx := origin.x + dx
				wz := origin.z + dz
				if gen.loaded[{wx, wz}] {
					continue
				}
				d := column_distance(wx, wz, spot.x, spot.z)
				if !ok || d < best || (d == best && (wz < cz || (wz == cz && wx < cx))) {
					best = d
					cx = wx
					cz = wz
					ok = true
				}
			}
		}
	}
	return
}

// Edited chunks wait here. A pristine column is regenerated from the seed, so
// it does not need a copy.
world_restore_column :: proc(world: ^World, cx, cz: int) {
	column := [2]int{cx, cz}
	bin := world.cold[column]
	if len(bin) == 0 {
		return
	}
	for piece in bin {
		key := [3]int{cx, piece.y, cz}
		chunk := piece.chunk
		chunk.keep = true
		mark_dirty(world, key, chunk)
		world.chunks[key] = chunk
		if world.syncing {
			note_sync(world, key, chunk)
		}
	}
	delete(bin)
	delete_key(&world.cold, column)
}

// Grass spread and leaf decay, for the blocks that can have them. Stone never
// schedules anything, so it is not visited through set_block.
world_gen_schedule :: proc(world: ^World, cx, cz: int) {
	keys: [dynamic][3]int
	defer delete(keys)
	for key, chunk in world.chunks {
		if key.x != cx || key.z != cz || chunk.keep {
			continue
		}
		append(&keys, key)
	}
	for key in keys {
		chunk := world.chunks[key]
		if chunk == nil {
			continue
		}
		base := key * CHUNK_SIZE
		for lx in 0 ..< CHUNK_SIZE {
			for ly in 0 ..< CHUNK_SIZE {
				for lz in 0 ..< CHUNK_SIZE {
					block := chunk.blocks[lx][ly][lz]
					x := base.x + lx
					y := base.y + ly
					z := base.z + lz
					#partial switch block {
					case .Grass, .Dirt:
						reschedule(world, x, y, z, world.time)
					case .Oak_Leaves:
						reconsider_leaf(world, x, y, z, world.time)
					}
				}
			}
		}
	}
}

// Drops columns no player is near. Edits and pending growth are kept so walking
// back does not wipe them; everything else is rebuilt from the seed.
world_unload_far :: proc(gen: ^World_Gen, world: ^World, spots: []Load_Spot) {
	origins := spots
	fallback := [1]Load_Spot{{0, 0, RENDER_DISTANCE}}
	if len(origins) == 0 {
		origins = fallback[:]
	}
	clear(&gen.drop_keys)
	for key, _ in world.chunks {
		near := false
		for spot in origins {
			origin := chunk_of(spot.x, 0, spot.z)
			if column_in_radius(key.x, key.z, origin.x, origin.z, unload_radius(spot.radius)) {
				near = true
				break
			}
		}
		if !near {
			append(&gen.drop_keys, key)
		}
	}
	for key in gen.drop_keys {
		chunk := world.chunks[key]
		delete_key(&world.chunks, key)
		delete_key(&gen.loaded, [2]int{key.x, key.z})
		if chunk.queued {
			chunk.queued = false
		}
		chunk.listed = false
		if chunk.edited || len(chunk.pending) > 0 {
			column := [2]int{key.x, key.z}
			bin := world.cold[column]
			append(&bin, Cold_Piece{y = key.y, chunk = chunk})
			world.cold[column] = bin
		} else {
			delete(chunk.pending)
			free(chunk)
		}
	}
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
