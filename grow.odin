package main

import "core:fmt"

// Grass spreads onto nearby dirt, covered grass turns to dirt, leaves decay,
// and saplings grow, on a date stored with the block. Each chunk's dates are
// soonest-first, and chunks near any player look at the front of that list
// every frame. Farther chunks keep the dates and apply them when a player gets close.

// One step of grass, long enough to watch and short enough to matter in a session.
GRASS_SPREAD_DELAY :: f64(12)

// How long grass waits, with a block sitting on it, before it becomes dirt.
GRASS_TRAMPLE_DELAY :: f64(12)

// How far a leaf can be from a log, counting steps through other leaves, and
// still count as part of the tree. An oak's farthest leaf is 3 steps from its
// trunk, so 4 keeps a standing tree and drops a canopy once the trunk is gone.
LEAF_LOG_DISTANCE :: 4

// After a leaf loses its log, it waits this long, plus a per-block stagger, so
// the canopy falls over a few seconds instead of in one frame.
LEAF_DECAY_DELAY   :: f64(5)
LEAF_DECAY_STAGGER :: f64(8)

// A planted sapling waits about this long, plus a short stagger, then becomes a tree.
SAPLING_GROW_DELAY   :: f64(45)
SAPLING_GROW_STAGGER :: f64(10)

// One decaying leaf in this many leaves a sapling.
SAPLING_ODDS :: u64(10)

// How many dates may apply in one frame. The rest stay on the list, so a forest
// catching up does not remesh all at once.
GROW_BUDGET :: 48
// Chunks this far from the player, in XZ, are the ones that check. Y is ignored
// so a trunk and its canopy are checked together.
GROW_RADIUS :: 4

Grow_Kind :: enum u8 {
	Grass,
	Leaf,
	Trample,
	Sapling,
}

// One waiting block. The index is local to its chunk: 4 bits each of x, y, z.
Deadline :: struct {
	i:    u16,
	at:   f64,
	kind: Grow_Kind,
}

// How many dates a check actually applied. The HUD reads this.
Grow_Report :: struct {
	grass:  int,
	leaves: int,
}

// Every deadline still waiting, near or far. Far chunks hold theirs until the player is close.
grow_queued :: proc(world: ^World) -> int {
	n := 0
	for _, chunk in world.chunks {
		n += len(chunk.pending)
	}
	return n
}

grow_advance :: proc(world: ^World, foci: [][3]int, dt: f64, drops: ^[dynamic]Drop, rng: ^u64) -> (report: Grow_Report) {
	world.time += dt
	if len(foci) == 0 {
		return
	}
	return grow_near(world, foci, GROW_RADIUS, drops, rng)
}

// Applies due dates in chunks near any focus. Time is the caller's concern, so
// one step can cover every player without advancing the clock twice.
grow_near :: proc(world: ^World, foci: [][3]int, radius: int, drops: ^[dynamic]Drop, rng: ^u64) -> (report: Grow_Report) {
	for {
		progressed := false
		for key, chunk in world.chunks {
			if !chunk_near(key, foci, radius) {
				continue
			}
			room := GROW_BUDGET - (report.grass + report.leaves)
			part := grow_chunk(world, key, chunk, room, drops, rng)
			report.grass += part.grass
			report.leaves += part.leaves
			if part.grass+part.leaves > 0 {
				progressed = true
			}
			if report.grass+report.leaves >= GROW_BUDGET {
				return
			}
		}
		if !progressed {
			return
		}
	}
}

chunk_near :: proc(key: [3]int, foci: [][3]int, radius: int) -> bool {
	for focus in foci {
		if abs(key.x-focus.x) <= radius && abs(key.z-focus.z) <= radius {
			return true
		}
	}
	return false
}

grow_chunk :: proc(world: ^World, key: [3]int, chunk: ^Chunk, room: int, drops: ^[dynamic]Drop, rng: ^u64) -> (report: Grow_Report) {
	for len(chunk.pending) > 0 && report.grass+report.leaves < room {
		// Soonest is first, so a future date means the rest of the list is too.
		if chunk.pending[0].at > world.time {
			return
		}
		d := chunk.pending[0]
		ordered_remove(&chunk.pending, 0)
		if !grow_fire(world, key, d, drops, rng) {
			continue
		}
		switch d.kind {
		case .Grass, .Trample, .Sapling:
			report.grass += 1
		case .Leaf:
			report.leaves += 1
		}
	}
	return
}

grow_fire :: proc(world: ^World, key: [3]int, d: Deadline, drops: ^[dynamic]Drop, rng: ^u64) -> bool {
	x := key.x*CHUNK_SIZE + int(d.i&31)
	y := key.y*CHUNK_SIZE + int((d.i>>5)&31)
	z := key.z*CHUNK_SIZE + int((d.i>>10)&31)
	switch d.kind {
	case .Grass:
		if !grass_spread_target(world, x, y, z) {
			return false
		}
		set_block_at(world, x, y, z, .Grass, d.at)
		fmt.printfln("block update: grass spread at %d %d %d", x, y, z)
		return true
	case .Trample:
		above := get_block(world, x, y+1, z)
		if get_block(world, x, y, z) != .Grass || above == .Air || above == .Oak_Sapling {
			return false
		}
		set_block_at(world, x, y, z, .Dirt, d.at)
		fmt.printfln("block update: grass trampled at %d %d %d", x, y, z)
		return true
	case .Leaf:
		if get_block(world, x, y, z) != .Oak_Leaves || leaf_supported(world, x, y, z) {
			return false
		}
		set_block_at(world, x, y, z, .Air, d.at)
		fmt.printfln("block update: leaf decay at %d %d %d", x, y, z)
		if sapling_from_leaf(x, y, z) && drops != nil && rng != nil {
			drop_spawn(drops, rng, item_block(.Oak_Sapling), 1, x, y, z)
		}
		return true
	case .Sapling:
		if get_block(world, x, y, z) != .Oak_Sapling {
			return false
		}
		ground := get_block(world, x, y-1, z)
		if ground != .Dirt && ground != .Grass {
			set_block_at(world, x, y, z, .Air, d.at)
			if drops != nil && rng != nil {
				drop_spawn(drops, rng, item_block(.Oak_Sapling), 1, x, y, z)
			}
			fmt.printfln("block update: sapling uprooted at %d %d %d", x, y, z)
			return true
		}
		trunk := oak_trunk(x, y, z)
		if !oak_fits(world, x, y, z, trunk) {
			deadline_schedule(world, x, y, z, d.at+SAPLING_GROW_DELAY, .Sapling)
			return false
		}
		grow_oak(world, x, y, z, trunk, d.at)
		fmt.printfln("block update: sapling grew at %d %d %d", x, y, z)
		return true
	}
	return false
}

// Called from set_block after the block is written. Dates are measured from at,
// the moment this block became what it is.
reschedule :: proc(world: ^World, x, y, z: int, at: f64) {
	chunk := world.chunks[chunk_of(x, y, z)]
	if chunk == nil {
		return
	}
	deadline_cancel(chunk, deadline_index(local_of(x, y, z)))

	#partial switch get_block(world, x, y, z) {
	case .Dirt:
		if grass_spread_target(world, x, y, z) {
			deadline_schedule(world, x, y, z, at+GRASS_SPREAD_DELAY, .Grass)
		}
	case .Grass:
		// A block on top keeps the sun off it. Taking that block away cancels
		// this date, because reschedule drops whatever was waiting here first.
		// A sapling is not a cover. A log or a placed block is.
		above := get_block(world, x, y+1, z)
		if above != .Air && above != .Oak_Sapling {
			deadline_schedule(world, x, y, z, at+GRASS_TRAMPLE_DELAY, .Trample)
		}
		// Every dirt this grass can reach gets a date from this moment. Dirt that
		// already has an earlier date keeps it.
		for dy in -1 ..= 1 {
			for dz in -1 ..= 1 {
				for dx in -1 ..= 1 {
					if dx == 0 && dy == 0 && dz == 0 {
						continue
					}
					nx, ny, nz := x+dx, y+dy, z+dz
					if get_block(world, nx, ny, nz) != .Dirt {
						continue
					}
					if get_block(world, nx, ny+1, nz) != .Air {
						continue
					}
					deadline_schedule(world, nx, ny, nz, at+GRASS_SPREAD_DELAY, .Grass)
				}
			}
		}
	case .Oak_Sapling:
		deadline_schedule(world, x, y, z, at+sapling_grow_delay(x, y, z), .Sapling)
	}
}

sapling_from_leaf :: proc(x, y, z: int) -> bool {
	h := hash_u64(u64(x)*0xBF58476D1CE4E5B9 ~ u64(y)*0x94D049BB133111EB ~ u64(z)*0xD6E8FEB86659FD93)
	return h%SAPLING_ODDS == 0
}

sapling_grow_delay :: proc(x, y, z: int) -> f64 {
	h := hash_u64(u64(x)*0x9E3779B97F4A7C15 ~ u64(y)*0xC2B2AE3D27D4EB4F ~ u64(z)*0x165667B19E3779F9)
	return SAPLING_GROW_DELAY + f64(h%1000)/1000*SAPLING_GROW_STAGGER
}

oak_trunk :: proc(x, y, z: int) -> int {
	h := hash_u64(u64(x)*0xD1B54A32D192ED03 ~ u64(y)*0xABC98388FB8FAC03 ~ u64(z)*0x94D049BB133111EB)
	span := TRUNK_MAX - TRUNK_MIN + 1
	return TRUNK_MIN + int(h%u64(span))
}

// The trunk column and the canopy have to be air, leaves, or this sapling.
oak_fits :: proc(world: ^World, x, y, z, trunk: int) -> bool {
	top := y + trunk - 1
	for ty in y ..= top {
		if !oak_cell(world, x, ty, z, ty == y) {
			return false
		}
	}
	if !oak_layer(world, x, top-2, z, 2, true) {
		return false
	}
	if !oak_layer(world, x, top-1, z, 2, true) {
		return false
	}
	if !oak_layer(world, x, top, z, 1, false) {
		return false
	}
	if !oak_layer(world, x, top+1, z, 1, true) {
		return false
	}
	return true
}

oak_layer :: proc(world: ^World, x, y, z, radius: int, cut_corners: bool) -> bool {
	for dx in -radius ..= radius {
		for dz in -radius ..= radius {
			if cut_corners && abs(dx) == radius && abs(dz) == radius {
				continue
			}
			if dx == 0 && dz == 0 {
				continue
			}
			if !oak_cell(world, x+dx, y, z+dz, false) {
				return false
			}
		}
	}
	return true
}

oak_cell :: proc(world: ^World, x, y, z: int, sapling: bool) -> bool {
	block := get_block(world, x, y, z)
	if block == .Air || block == .Oak_Leaves {
		return true
	}
	return sapling && block == .Oak_Sapling
}

// The same oak the world generator plants, written through set_block so the new
// leaves get decay dates and clients hear about the trunk.
grow_oak :: proc(world: ^World, x, y, z, trunk: int, at: f64) {
	top := y + trunk - 1
	for ty in y ..= top {
		set_block_at(world, x, ty, z, .Oak_Log, at)
	}
	grow_oak_layer(world, x, top-2, z, 2, true, at)
	grow_oak_layer(world, x, top-1, z, 2, true, at)
	grow_oak_layer(world, x, top, z, 1, false, at)
	grow_oak_layer(world, x, top+1, z, 1, true, at)
}

grow_oak_layer :: proc(world: ^World, x, y, z, radius: int, cut_corners: bool, at: f64) {
	for dx in -radius ..= radius {
		for dz in -radius ..= radius {
			if cut_corners && abs(dx) == radius && abs(dz) == radius {
				continue
			}
			if dx == 0 && dz == 0 {
				continue
			}
			block := get_block(world, x+dx, y, z+dz)
			if block == .Air {
				set_block_at(world, x+dx, y, z+dz, .Oak_Leaves, at)
			}
		}
	}
}

// Dirt with open sky and a grass block in the surrounding 3x3x3.
grass_spread_target :: proc(world: ^World, x, y, z: int) -> bool {
	if get_block(world, x, y, z) != .Dirt {
		return false
	}
	if get_block(world, x, y+1, z) != .Air {
		return false
	}
	for dy in -1 ..= 1 {
		for dz in -1 ..= 1 {
			for dx in -1 ..= 1 {
				if dx == 0 && dy == 0 && dz == 0 {
					continue
				}
				if get_block(world, x+dx, y+dy, z+dz) == .Grass {
					return true
				}
			}
		}
	}
	return false
}

// Steps through leaves to the nearest log, counting the log itself. False when
// nothing is close enough.
leaf_log_distance :: proc(world: ^World, x, y, z: int) -> (ok: bool, dist: int) {
	for face in Face {
		o := FACE_OFFSET[face]
		if get_block(world, x+o.x, y+o.y, z+o.z) == .Oak_Log {
			return true, 1
		}
	}

	Step :: struct {
		x, y, z, dist: int,
	}
	queue: [dynamic]Step
	defer delete(queue)
	seen := make(map[[3]int]struct{})
	defer delete(seen)

	append(&queue, Step{x, y, z, 0})
	seen[{x, y, z}] = {}
	for head := 0; head < len(queue); head += 1 {
		cur := queue[head]
		if cur.dist >= LEAF_LOG_DISTANCE {
			continue
		}
		for face in Face {
			o := FACE_OFFSET[face]
			nx, ny, nz := cur.x+o.x, cur.y+o.y, cur.z+o.z
			block := get_block(world, nx, ny, nz)
			if block == .Oak_Log {
				return true, cur.dist + 1
			}
			if block != .Oak_Leaves {
				continue
			}
			key := [3]int{nx, ny, nz}
			if key in seen {
				continue
			}
			seen[key] = {}
			append(&queue, Step{nx, ny, nz, cur.dist + 1})
		}
	}
	return false, 0
}

leaf_supported :: proc(world: ^World, x, y, z: int) -> bool {
	ok, _ := leaf_log_distance(world, x, y, z)
	return ok
}

// What to do with each leaf reached from a block that just changed.
Leaf_Walk :: enum {
	// The log is still in range, so a decay date would be wrong.
	Cancel,
	// The change may have cut the path. Look again.
	Recheck,
}

leaves_after_change :: proc(world: ^World, x, y, z: int, old, block: Block, at: f64) {
	if old != .Oak_Log && old != .Oak_Leaves && block != .Oak_Log && block != .Oak_Leaves {
		return
	}
	// Taking a log or a leaf away can strand whatever was routing through it.
	if old == .Oak_Log || old == .Oak_Leaves {
		walk_leaves(world, x, y, z, LEAF_LOG_DISTANCE, .Recheck, at)
		return
	}
	if block == .Oak_Log {
		walk_leaves(world, x, y, z, LEAF_LOG_DISTANCE, .Cancel, at)
		return
	}

	// A leaf placed before its neighbors can miss a log that a later leaf
	// reveals. Once this one can reach a log, every leaf still inside the
	// remaining distance can too, so their early dates go away.
	ok, dist := leaf_log_distance(world, x, y, z)
	if !ok {
		deadline_schedule(world, x, y, z, at+leaf_decay_delay(x, y, z), .Leaf)
		return
	}
	walk_leaves(world, x, y, z, LEAF_LOG_DISTANCE-dist, .Cancel, at)
}

reconsider_leaf :: proc(world: ^World, x, y, z: int, at: f64) {
	if get_block(world, x, y, z) != .Oak_Leaves {
		return
	}
	chunk := world.chunks[chunk_of(x, y, z)]
	if chunk == nil {
		return
	}
	if leaf_supported(world, x, y, z) {
		deadline_cancel(chunk, deadline_index(local_of(x, y, z)))
		return
	}
	deadline_schedule(world, x, y, z, at+leaf_decay_delay(x, y, z), .Leaf)
}

// Visits leaves within max_dist steps of x,y,z. The start cell counts as step 0
// when it is itself a leaf, and logs are not a path.
walk_leaves :: proc(world: ^World, x, y, z: int, max_dist: int, mode: Leaf_Walk, at: f64) {
	Step :: struct {
		x, y, z, dist: int,
	}
	queue: [dynamic]Step
	defer delete(queue)
	seen := make(map[[3]int]struct{})
	defer delete(seen)

	append(&queue, Step{x, y, z, 0})
	seen[{x, y, z}] = {}
	for head := 0; head < len(queue); head += 1 {
		cur := queue[head]
		if get_block(world, cur.x, cur.y, cur.z) == .Oak_Leaves {
			switch mode {
			case .Cancel:
				chunk := world.chunks[chunk_of(cur.x, cur.y, cur.z)]
				if chunk != nil {
					deadline_cancel(chunk, deadline_index(local_of(cur.x, cur.y, cur.z)))
				}
			case .Recheck:
				reconsider_leaf(world, cur.x, cur.y, cur.z, at)
			}
		}
		if cur.dist >= max_dist {
			continue
		}
		for face in Face {
			o := FACE_OFFSET[face]
			nx, ny, nz := cur.x+o.x, cur.y+o.y, cur.z+o.z
			if get_block(world, nx, ny, nz) != .Oak_Leaves {
				continue
			}
			key := [3]int{nx, ny, nz}
			if key in seen {
				continue
			}
			seen[key] = {}
			append(&queue, Step{nx, ny, nz, cur.dist + 1})
		}
	}
}

leaf_decay_delay :: proc(x, y, z: int) -> f64 {
	h := hash_u64(u64(x)*0xBF58476D1CE4E5B9 ~ u64(y)*0x94D049BB133111EB ~ u64(z)*0xD6E8FEB86659FD93)
	return LEAF_DECAY_DELAY + f64(h%1000)/1000*LEAF_DECAY_STAGGER
}

deadline_index :: proc(l: [3]int) -> u16 {
	return u16(l.x) | u16(l.y)<<5 | u16(l.z)<<10
}

deadline_schedule :: proc(world: ^World, x, y, z: int, at: f64, kind: Grow_Kind) {
	chunk := world.chunks[chunk_of(x, y, z)]
	if chunk == nil {
		return
	}
	i := deadline_index(local_of(x, y, z))
	for n in 0 ..< len(chunk.pending) {
		d := chunk.pending[n]
		if d.i != i || d.kind != kind {
			continue
		}
		// Already waiting at least this soon, and already in order.
		if at >= d.at {
			return
		}
		ordered_remove(&chunk.pending, n)
		break
	}
	deadline_insert(chunk, Deadline{i = i, at = at, kind = kind})
}

// Inserts by date. Equal times stay in the order they were scheduled.
deadline_insert :: proc(chunk: ^Chunk, d: Deadline) {
	lo := 0
	hi := len(chunk.pending)
	for lo < hi {
		mid := lo + (hi-lo)/2
		if chunk.pending[mid].at <= d.at {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	inject_at(&chunk.pending, lo, d)
}

deadline_waiting :: proc(chunk: ^Chunk, i: u16, kind: Grow_Kind) -> bool {
	for d in chunk.pending {
		if d.i == i && d.kind == kind {
			return true
		}
	}
	return false
}

deadline_cancel :: proc(chunk: ^Chunk, i: u16) {
	n := 0
	for n < len(chunk.pending) {
		if chunk.pending[n].i != i {
			n += 1
			continue
		}
		ordered_remove(&chunk.pending, n)
	}
}
