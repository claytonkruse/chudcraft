package main

import "core:math"

// Oak_Door is the item, and also the first of DOOR_VARIANTS packed cells.
// The next ids are the same door with a different facing, hinge, open bit, or
// half. A new block enumerator has to start at Oak_Door + DOOR_VARIANTS or it
// will be read as one of those cells.
DOOR_VARIANTS :: 32

// Three pixels on a 16-wide block, the same sliver a wooden door occupies.
DOOR_THICK :: f32(3.0 / 16.0)

// Which way the door looks when it is shut. yaw 0 is +Z, and turning right
// walks the values in order.
Door_Facing :: enum u8 {
	Pos_Z = 0,
	Pos_X = 1,
	Neg_Z = 2,
	Neg_X = 3,
}

Door :: struct {
	facing:      Door_Facing,
	hinge_right: bool,
	open:        bool,
	upper:       bool,
}

// A step on the horizontal grid. z is the world Z, not the second component of a vector.
Door_Step :: struct {
	x, z: int,
}

// Full cube, or a door panel thin on X or on Z. The player hull has to match.
Collide_Shape :: enum {
	Full,
	Thin_X,
	Thin_Z,
}

door_info :: proc(block: Block) -> (door: Door, ok: bool) {
	raw := u8(block)
	base := u8(Block.Oak_Door)
	if raw < base || raw >= base + DOOR_VARIANTS {
		return {}, false
	}
	index := raw - base
	door.facing = Door_Facing(index >> 3)
	door.open = (index & 4) != 0
	door.hinge_right = (index & 2) != 0
	door.upper = (index & 1) != 0
	return door, true
}

block_is_door :: proc(block: Block) -> bool {
	_, ok := door_info(block)
	return ok
}

door_is_open :: proc(block: Block) -> bool {
	door, ok := door_info(block)
	return ok && door.open
}

door_is_lower :: proc(block: Block) -> bool {
	door, ok := door_info(block)
	return ok && !door.upper
}

door_pack :: proc(door: Door) -> Block {
	index := u8(door.facing) << 3
	if door.open {
		index |= 4
	}
	if door.hinge_right {
		index |= 2
	}
	if door.upper {
		index |= 1
	}
	return Block(u8(Block.Oak_Door) + index)
}

// The way the player is looking, flattened. The door faces them.
door_facing_from_yaw :: proc(yaw: f32) -> Door_Facing {
	a := math.mod(yaw, math.TAU)
	if a < 0 {
		a += math.TAU
	}
	if a < math.PI * 0.25 || a >= math.PI * 1.75 {
		return .Pos_Z
	}
	if a < math.PI * 0.75 {
		return .Pos_X
	}
	if a < math.PI * 1.25 {
		return .Neg_Z
	}
	return .Neg_X
}

door_forward :: proc(facing: Door_Facing) -> Door_Step {
	switch facing {
	case .Pos_Z:
		return {0, 1}
	case .Pos_X:
		return {1, 0}
	case .Neg_Z:
		return {0, -1}
	case .Neg_X:
		return {-1, 0}
	}
	return {0, 1}
}

// Player's right when looking the way the door faces.
door_right :: proc(facing: Door_Facing) -> Door_Step {
	switch facing {
	case .Pos_Z:
		return {1, 0}
	case .Pos_X:
		return {0, -1}
	case .Neg_Z:
		return {-1, 0}
	case .Neg_X:
		return {0, 1}
	}
	return {1, 0}
}

door_left :: proc(facing: Door_Facing) -> Door_Step {
	right := door_right(facing)
	return {-right.x, -right.z}
}

// The panel, in world space. Shut, it sits on the face toward the player.
// Open, it swings onto the hinge edge so the rest of the cell is a gap.
door_aabb :: proc(x, y, z: int, door: Door) -> (min, max: [3]f32) {
	min = {f32(x) - 0.5, f32(y), f32(z) - 0.5}
	max = {f32(x) + 0.5, f32(y) + 1, f32(z) + 0.5}
	edge := door_forward(door.facing)
	if door.open {
		if door.hinge_right {
			edge = door_right(door.facing)
		} else {
			edge = door_left(door.facing)
		}
	}
	if edge.x > 0 {
		min.x = max.x - DOOR_THICK
	} else if edge.x < 0 {
		max.x = min.x + DOOR_THICK
	} else if edge.z > 0 {
		min.z = max.z - DOOR_THICK
	} else {
		max.z = min.z + DOOR_THICK
	}
	return
}

// True when the hinge corner is the high end of the panel's long axis, so the
// latch side of the texture stays opposite the hinge after the door swings.
door_hinge_at_max :: proc(door: Door) -> bool {
	edge: Door_Step
	if door.open {
		edge = door_forward(door.facing)
	} else if door.hinge_right {
		edge = door_right(door.facing)
	} else {
		edge = door_left(door.facing)
	}
	if edge.x != 0 {
		return edge.x > 0
	}
	return edge.z > 0
}

// Mesh space for one cell is [0, 1], which is the world cell shifted by half a
// block on X and Z. The draw transform puts the half back.
door_cell_box :: proc(door: Door) -> (min, max: [3]f32) {
	min, max = door_aabb(0, 0, 0, door)
	min.x += 0.5
	max.x += 0.5
	min.z += 0.5
	max.z += 0.5
	return
}

block_hitbox :: proc(block: Block, x, y, z: int) -> (min, max: [3]f32, shape: Collide_Shape, ok: bool) {
	if door, is_door := door_info(block); is_door {
		min, max = door_aabb(x, y, z, door)
		if max.x - min.x < 0.5 {
			return min, max, .Thin_X, true
		}
		return min, max, .Thin_Z, true
	}
	if !block_solid(block) {
		return {}, {}, .Full, false
	}
	min = {f32(x) - 0.5, f32(y), f32(z) - 0.5}
	max = {f32(x) + 0.5, f32(y) + 1, f32(z) + 0.5}
	return min, max, .Full, true
}

door_facing_at :: proc(world: ^World, x, y, z: int, facing: Door_Facing) -> bool {
	door, ok := door_info(get_block(world, x, y, z))
	return ok && door.facing == facing
}

// Solid blocks on a side pull the hinge that way. A door already beside this
// cell wins, so the new one hinges outward. Placement turns the first door to match.
door_choose_hinge :: proc(world: ^World, x, y, z: int, facing: Door_Facing, player: Player) -> bool {
	left := door_left(facing)
	right := door_right(facing)
	left_door := door_facing_at(world, x + left.x, y, z + left.z, facing) || door_facing_at(world, x + left.x, y + 1, z + left.z, facing)
	right_door := door_facing_at(world, x + right.x, y, z + right.z, facing) || door_facing_at(world, x + right.x, y + 1, z + right.z, facing)
	if left_door && !right_door {
		return true
	}
	if right_door && !left_door {
		return false
	}
	left_w := door_wall(world, x + left.x, y, z + left.z)
	right_w := door_wall(world, x + right.x, y, z + right.z)
	if right_w > left_w {
		return true
	}
	if left_w > right_w {
		return false
	}
	// The latch ends up on the side of the cell the player is standing toward.
	side := (player.position.x - f32(x)) * f32(right.x) + (player.position.z - f32(z)) * f32(right.z)
	return side < 0
}

door_wall :: proc(world: ^World, x, y, z: int) -> int {
	weight := 0
	if block_opaque(get_block(world, x, y, z)) {
		weight += 1
	}
	if block_opaque(get_block(world, x, y + 1, z)) {
		weight += 1
	}
	return weight
}

// Rewrites both halves onto a hinge without counting as a new place.
door_retarget_hinge :: proc(world: ^World, x, y, z: int, hinge_right: bool) {
	door, ok := door_info(get_block(world, x, y, z))
	if !ok {
		return
	}
	y0 := y
	if door.upper {
		y0 = y - 1
	}
	hear := world.hear
	world.hear = false
	for dy in 0 ..= 1 {
		block := get_block(world, x, y0 + dy, z)
		half, half_ok := door_info(block)
		if !half_ok || half.facing != door.facing || half.upper != (dy == 1) {
			continue
		}
		if half.hinge_right == hinge_right {
			continue
		}
		half.hinge_right = hinge_right
		set_block(world, x, y0 + dy, z, door_pack(half))
	}
	world.hear = hear
}

// Two air cells, a solid block under them, and a panel that is not inside the body.
door_place :: proc(world: ^World, player: Player, x, y, z: int) -> bool {
	if get_block(world, x, y, z) != .Air || get_block(world, x, y + 1, z) != .Air {
		return false
	}
	if !block_solid(get_block(world, x, y - 1, z)) {
		return false
	}
	facing := door_facing_from_yaw(player.yaw)
	hinge_right := door_choose_hinge(world, x, y, z, facing, player)
	lower := Door{facing = facing, hinge_right = hinge_right, open = false, upper = false}
	upper := lower
	upper.upper = true
	low_min, low_max := door_aabb(x, y, z, lower)
	up_min, up_max := door_aabb(x, y + 1, z, upper)
	if player_overlaps_aabb(player, low_min, low_max) || player_overlaps_aabb(player, up_min, up_max) {
		return false
	}
	// The neighbor flips only once this door is actually going in. A body in the
	// way leaves the door that was already there on its old hinge.
	left := door_left(facing)
	right := door_right(facing)
	left_door := door_facing_at(world, x + left.x, y, z + left.z, facing) || door_facing_at(world, x + left.x, y + 1, z + left.z, facing)
	right_door := door_facing_at(world, x + right.x, y, z + right.z, facing) || door_facing_at(world, x + right.x, y + 1, z + right.z, facing)
	if left_door && !right_door {
		door_retarget_hinge(world, x + left.x, y, z + left.z, false)
	} else if right_door && !left_door {
		door_retarget_hinge(world, x + right.x, y, z + right.z, true)
	}
	hear := world.hear
	set_block(world, x, y, z, door_pack(lower))
	world.hear = false
	set_block(world, x, y + 1, z, door_pack(upper))
	world.hear = hear
	return true
}

// The other leaf of a double door sits on the latch side, hinged the other way.
door_partner_step :: proc(door: Door) -> Door_Step {
	if door.hinge_right {
		return door_left(door.facing)
	}
	return door_right(door.facing)
}

door_toggle :: proc(world: ^World, x, y, z: int) {
	door, ok := door_info(get_block(world, x, y, z))
	if !ok {
		return
	}
	y0 := y
	if door.upper {
		below, below_ok := door_info(get_block(world, x, y - 1, z))
		if below_ok && !below.upper && below.facing == door.facing {
			door = below
			y0 = y - 1
		}
	}
	open := !door.open
	door_set_open(world, x, y0, z, door.facing, door.hinge_right, open)
	step := door_partner_step(door)
	px := x + step.x
	pz := z + step.z
	partner, partner_ok := door_info(get_block(world, px, y0, pz))
	if !partner_ok {
		partner, partner_ok = door_info(get_block(world, px, y0 + 1, pz))
	}
	if !partner_ok || partner.facing != door.facing || partner.hinge_right == door.hinge_right {
		return
	}
	// Beside this lower half. The partner procedure checks both of its halves.
	hear := world.hear
	world.hear = false
	door_set_open(world, px, y0, pz, partner.facing, partner.hinge_right, open)
	world.hear = hear
}

door_set_open :: proc(world: ^World, x, y, z: int, facing: Door_Facing, hinge_right, open: bool) {
	hear := world.hear
	first := true
	for dy in 0 ..= 1 {
		block := get_block(world, x, y + dy, z)
		half, ok := door_info(block)
		if !ok || half.facing != facing || half.upper != (dy == 1) {
			continue
		}
		if !first {
			world.hear = false
		}
		first = false
		half.open = open
		half.hinge_right = hinge_right
		set_block(world, x, y + dy, z, door_pack(half))
	}
	world.hear = hear
}

// Both halves, one break. The upper half is not its own item.
door_remove :: proc(world: ^World, x, y, z: int) {
	door, ok := door_info(get_block(world, x, y, z))
	if !ok {
		return
	}
	y0 := y
	if door.upper {
		y0 = y - 1
	}
	hear := world.hear
	if _, lower_ok := door_info(get_block(world, x, y0, z)); lower_ok {
		set_block(world, x, y0, z, .Air)
	}
	world.hear = false
	if _, upper_ok := door_info(get_block(world, x, y0 + 1, z)); upper_ok {
		set_block(world, x, y0 + 1, z, .Air)
	}
	world.hear = hear
}

door_matches_lower :: proc(below: Block, upper: Door) -> bool {
	door, ok := door_info(below)
	return ok && !door.upper && door.facing == upper.facing
}

// Called after every write. A door whose floor disappeared comes down, and an
// upper half with no lower half does not stay behind as a floating panel.
door_settle :: proc(world: ^World, x, y, z: int) {
	here := get_block(world, x, y, z)
	if door_is_lower(here) && !block_solid(get_block(world, x, y - 1, z)) {
		door_remove(world, x, y, z)
		return
	}
	above := get_block(world, x, y + 1, z)
	if door_is_lower(above) && !block_solid(here) {
		door_remove(world, x, y + 1, z)
		above = get_block(world, x, y + 1, z)
	}
	if door, ok := door_info(above); ok && door.upper && !door_matches_lower(get_block(world, x, y, z), door) {
		hear := world.hear
		world.hear = false
		set_block(world, x, y + 1, z, .Air)
		world.hear = hear
	}
}

// The ray's t is distance along a unit direction. A start inside the panel hits.
ray_hit_box :: proc(origin, dir: [3]f32, bmin, bmax: [3]f32, reach: f32) -> bool {
	t0: f32 = 0
	t1 := reach
	for axis in 0 ..< 3 {
		if abs(dir[axis]) < 1e-7 {
			if origin[axis] < bmin[axis] || origin[axis] > bmax[axis] {
				return false
			}
			continue
		}
		inv := 1 / dir[axis]
		a := (bmin[axis] - origin[axis]) * inv
		b := (bmax[axis] - origin[axis]) * inv
		if a > b {
			a, b = b, a
		}
		if a > t0 {
			t0 = a
		}
		if b < t1 {
			t1 = b
		}
		if t0 > t1 {
			return false
		}
	}
	return true
}
