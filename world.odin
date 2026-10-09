package main

import "core:math"

// Air has to stay the zero value, because that is what an absent chunk reads as.
Block :: enum u8 {
	Air,
	Grass,
	Dirt,
	Stone,
	Bedrock,
	Coal_Ore,
	Iron_Ore,
	Gold_Ore,
	Water,
	Oak_Log,
	Oak_Leaves,
	Oak_Planks,
	Workbench,
	Oak_Sapling,
	Sand,
	Gravel,
	// Item id, and the first of the 32 packed door cells that follow it.
	// door.odin owns that range. The next real block starts after it.
	Oak_Door,
}

// A power of two, so splitting a world coordinate is a shift and a mask.
CHUNK_SIZE  :: 32
CHUNK_SHIFT :: 5
CHUNK_MASK  :: CHUNK_SIZE - 1

// How far, in meters, a look ray can break a block.
MINE_REACH :: 5.0

// How far up and down a column is searched for ground.
SURFACE_SCAN :: 256

Chunk :: struct {
	blocks: [CHUNK_SIZE][CHUNK_SIZE][CHUNK_SIZE]Block,
	// Set when a block here changed, so this chunk's mesh gets rebuilt.
	dirty:  bool,
	// Already sitting in World.dirty, so a second edit does not queue it twice.
	listed: bool,
	// Dirt waiting to become grass, and leaves waiting to decay, soonest first.
	// A check stops at the first date that is not due. Absent while the chunk is
	// unloaded; the date is what lets the change happen anyway.
	pending: [dynamic]Deadline,
	// In World.sync_queue. Cleared once clients have copied this chunk's blocks.
	queued:  bool,
	// A player or the growth sim wrote this, so unloading must keep the blocks.
	edited:  bool,
	// Restored from a save or an unload. Generation will not overwrite it.
	keep:    bool,
}

// One unloaded chunk, kept with the other chunks of its column.
Cold_Piece :: struct {
	y:     int,
	chunk: ^Chunk,
}

// Chunks exist only where blocks do, which is what leaves the world without a build
// height limit: a coordinate with no chunk reads as air and costs nothing.
// Chunks are allocated on their own because the mesher holds onto them across frames,
// and growing the map would move values stored inline.
World :: struct {
	chunks: map[[3]int]^Chunk,
	// Seconds since this world started. Deadlines are measured on this clock.
	time: f64,
	// Block edits recorded for clients. Generation leaves this off, then the
	// server turns it on so only play is replicated.
	record:  bool,
	// Set for the one edit a player caused. Growth writes blocks through the
	// same path, and those must not be played back as breaks and places.
	hear:    bool,
	changes: [dynamic]Block_Change,
	// Generation sets this and appends each touched chunk to sync_queue, so a
	// column is copied once instead of one change per block.
	syncing:    bool,
	sync_queue: [dynamic][3]int,
	// Chunks whose mesh is out of date, nearest-first when drawn.
	dirty:      [dynamic][3]int,
	// The world a window draws. The server copy stays false, so its edits do
	// not grow a queue nobody drains.
	meshing:    bool,
	// Edits and deadlines parked by column, so walking back restores that column only.
	cold:       map[[2]int][dynamic]Cold_Piece,
	// Where a new player stands. Derived from the seed, because the origin can
	// be ocean. Filled in when the world is created or loaded.
	spawn_x, spawn_z: int,
	// While set, generation only writes this column. A kept chunk is one that
	// was restored, and this pass must not overwrite it.
	gen_clip:   bool,
	gen_x0, gen_x1, gen_z0, gen_z1: int,
}

// One cell a client should copy. The server is the only place a block changes.
Block_Change :: struct {
	x, y, z: int,
	block:   Block,
	// A player broke or placed this. Leaf decay and a spreading lawn stay false.
	audible: bool,
}

world_destroy :: proc(world: ^World) {
	for _, chunk in world.chunks {
		delete(chunk.pending)
		free(chunk)
	}
	for _, bin in world.cold {
		for piece in bin {
			delete(piece.chunk.pending)
			free(piece.chunk)
		}
		delete(bin)
	}
	delete(world.chunks)
	delete(world.cold)
	delete(world.changes)
	delete(world.sync_queue)
	delete(world.dirty)
}

// A shift floors toward negative infinity. Odin's `/` truncates toward zero, which
// would fold the chunks just below the origin onto the ones just above it.
chunk_of :: proc(x, y, z: int) -> [3]int {
	return {x >> CHUNK_SHIFT, y >> CHUNK_SHIFT, z >> CHUNK_SHIFT}
}

// The matching non-negative remainder, for the same reason.
local_of :: proc(x, y, z: int) -> [3]int {
	return {x & CHUNK_MASK, y & CHUNK_MASK, z & CHUNK_MASK}
}

get_block :: proc(world: ^World, x, y, z: int) -> Block {
	chunk := world.chunks[chunk_of(x, y, z)]
	if chunk == nil {
		return .Air
	}
	l := local_of(x, y, z)
	return chunk.blocks[l.x][l.y][l.z]
}

set_block :: proc(world: ^World, x, y, z: int, block: Block) {
	set_block_at(world, x, y, z, block, world.time)
}

// at is when the block took this form. A deadline fired late passes its own time,
// so the dirt beside the new grass is dated from then and can already be due.
set_block_at :: proc(world: ^World, x, y, z: int, block: Block, at: f64) {
	old, wrote := store_block(world, x, y, z, block)
	if !wrote {
		return
	}
	reschedule(world, x, y, z, at)
	// Opening or closing the block above is what makes the dirt underneath
	// eligible for grass, or takes that eligibility away. Grass underneath
	// gains or loses its trample date the same way.
	below := get_block(world, x, y-1, z)
	if below == .Dirt || below == .Grass {
		reschedule(world, x, y-1, z, at)
	}
	// Leaves remember whether they can reach a log. A new one can complete a
	// path that an earlier leaf could not see yet, and removing one can break it.
	leaves_after_change(world, x, y, z, old, block, at)
	door_settle(world, x, y, z)
}

// Writes one cell and marks the meshes that show it. No growth scheduling: the
// server does that itself, and a client copy only wants the new block.
store_block :: proc(world: ^World, x, y, z: int, block: Block) -> (old: Block, wrote: bool) {
	if world.gen_clip && !gen_clip_allows(world, x, z) {
		return get_block(world, x, y, z), false
	}
	key := chunk_of(x, y, z)
	chunk := world.chunks[key]
	if chunk != nil && chunk.keep && world.gen_clip {
		return get_block(world, x, y, z), false
	}
	if chunk == nil {
		// Already air, and an empty chunk is not worth allocating.
		if block == .Air {
			return .Air, false
		}
		chunk = new(Chunk)
		world.chunks[key] = chunk
	}

	l := local_of(x, y, z)
	old = chunk.blocks[l.x][l.y][l.z]
	if old == block {
		return old, false
	}
	chunk.blocks[l.x][l.y][l.z] = block
	mark_dirty(world, key, chunk)
	if world.syncing {
		note_sync(world, key, chunk)
	}

	// A block on a border decides which faces the chunk across that border draws,
	// so that chunk has to be rebuilt too.
	for axis in 0 ..< 3 {
		if l[axis] != 0 && l[axis] != CHUNK_MASK {
			continue
		}
		neighbor := key
		neighbor[axis] += -1 if l[axis] == 0 else 1
		if adjacent, ok := world.chunks[neighbor]; ok {
			mark_dirty(world, neighbor, adjacent)
			if world.syncing {
				note_sync(world, neighbor, adjacent)
			}
		}
	}
	if world.record {
		chunk.edited = true
		append(&world.changes, Block_Change{x = x, y = y, z = z, block = block, audible = world.hear})
	}
	return old, true
}

mark_dirty :: proc(world: ^World, key: [3]int, chunk: ^Chunk) {
	chunk.dirty = true
	if !world.meshing || chunk.listed {
		return
	}
	chunk.listed = true
	append(&world.dirty, key)
}

// Writes a generated block without growth bookkeeping. The column schedules
// grass and leaves once, after every block is in place. A kept chunk is one
// that was restored, and this pass must not overwrite it.
write_gen_block :: proc(world: ^World, x, y, z: int, block: Block) {
	if block == .Air {
		return
	}
	if world.gen_clip && !gen_clip_allows(world, x, z) {
		return
	}
	key := chunk_of(x, y, z)
	chunk := world.chunks[key]
	if chunk != nil && chunk.keep && world.gen_clip {
		return
	}
	if chunk == nil {
		chunk = new(Chunk)
		world.chunks[key] = chunk
	}
	l := local_of(x, y, z)
	if chunk.blocks[l.x][l.y][l.z] == block {
		return
	}
	chunk.blocks[l.x][l.y][l.z] = block
	mark_dirty(world, key, chunk)
	if world.syncing {
		note_sync(world, key, chunk)
	}
	for axis in 0 ..< 3 {
		if l[axis] != 0 && l[axis] != CHUNK_MASK {
			continue
		}
		neighbor := key
		neighbor[axis] += -1 if l[axis] == 0 else 1
		if adjacent, ok := world.chunks[neighbor]; ok {
			mark_dirty(world, neighbor, adjacent)
			if world.syncing {
				note_sync(world, neighbor, adjacent)
			}
		}
	}
}

// Inside the column being generated. Anywhere else belongs to the column that
// writes itself, including the rest of an infinite world.
gen_clip_allows :: proc(world: ^World, x, z: int) -> bool {
	return x >= world.gen_x0 && x <= world.gen_x1 && z >= world.gen_z0 && z <= world.gen_z1
}

// The chunk's blocks are copied to clients at the end of the step.
note_sync :: proc(world: ^World, key: [3]int, chunk: ^Chunk) {
	if chunk.queued {
		return
	}
	chunk.queued = true
	append(&world.sync_queue, key)
}

// Whether a block stops the player. The break ray uses block_targetable, which
// also stops on a sapling.
solid :: proc(world: ^World, x, y, z: int) -> bool {
	return block_solid(get_block(world, x, y, z))
}

// Hides the face of whatever is next to it, so the mesher can skip that face.
block_opaque :: proc(block: Block) -> bool {
	if block_is_door(block) {
		return false
	}
	#partial switch block {
	case .Air, .Water, .Oak_Leaves, .Oak_Sapling:
		return false
	}
	return true
}

// Stops the player. Water does not. A sapling does not either: it is a plant,
// and the break ray still stops on it.
block_solid :: proc(block: Block) -> bool {
	// A door is a panel, not a cube. Collision asks block_hitbox for the sliver.
	if block_is_door(block) {
		return false
	}
	return block != .Air && block != .Water && block != .Oak_Sapling
}

// What the break ray and the crosshair stop on.
block_targetable :: proc(block: Block) -> bool {
	return block_solid(block) || block == .Oak_Sapling
}

// Bedrock is the floor of the world, so it has to stay put.
breakable :: proc(block: Block) -> bool {
	return block != .Air && block != .Bedrock
}

// The Y a player stands at on this column. Y is bottom-aligned, so the block at y
// has its top face at y + 1.
surface_height :: proc(world: ^World, x, z: int) -> int {
	for y := SURFACE_SCAN; y >= -SURFACE_SCAN; y -= 1 {
		if solid(world, x, y, z) {
			return y + 1
		}
	}
	return 0
}

// First solid block the ray enters, within reach, and the cell it was entered from.
// That cell is where a placed block goes. Direction does not need to be normalized.
// X and Z are shifted by 0.5 so every block is a unit cell and a grid walk can cross them.
raycast_block :: proc(world: ^World, origin, direction: [3]f32, reach: f32) -> (hit: bool, x, y, z, px, py, pz: int) {
	length := math.sqrt(direction.x * direction.x + direction.y * direction.y + direction.z * direction.z)
	if length == 0 {
		return false, 0, 0, 0, 0, 0, 0
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
	// The cell the ray is leaving. A hit on the first cell leaves this equal to
	// the hit, and placement then sees a block that is already there.
	prev := cell
	distance: f32 = 0
	for _ in 0 ..< 64 {
		if distance > reach {
			break
		}
		block := get_block(world, cell.x, cell.y, cell.z)
		// The empty part of a door cell is air to the ray, so an open door can
		// be looked through at the block behind it.
		if door, is_door := door_info(block); is_door {
			bmin, bmax := door_aabb(cell.x, cell.y, cell.z, door)
			if ray_hit_box(origin, dir, bmin, bmax, reach) {
				return true, cell.x, cell.y, cell.z, prev.x, prev.y, prev.z
			}
		} else if block_targetable(block) {
			return true, cell.x, cell.y, cell.z, prev.x, prev.y, prev.z
		}

		axis := 0
		if t_max.y < t_max.x do axis = 1
		if t_max.z < t_max[axis] do axis = 2
		if step[axis] == 0 {
			break
		}
		prev = cell
		cell[axis] += int(step[axis])
		distance = t_max[axis]
		t_max[axis] += t_delta[axis]
	}
	return false, 0, 0, 0, 0, 0, 0
}

// Horizontally, block i covers [i - 0.5, i + 0.5].
block_index_horizontal :: proc(v: f32) -> int {
	return int(math.floor(v + 0.5))
}

// Vertically, block i covers [i, i + 1], with its bottom on i.
block_index_vertical :: proc(v: f32) -> int {
	return int(math.floor(v))
}
