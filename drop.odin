package main

import "core:math"

// A mined block becomes one of these instead of jumping into the inventory.
// It pops out of the cell, falls, and sits until a player walks over it.
// A full inventory leaves it where it landed.

// Quarter of a block, so the cube reads as an item sitting on a face.
DROP_HALF :: f32(0.125)

DROP_GRAVITY :: f32(18)
// Horizontal spray and the upward hop, in blocks per second.
DROP_POP :: f32(1.2)
DROP_HOP :: f32(3.4)
// Long enough to see the hop before the miner picks the stack back up.
DROP_PICKUP_DELAY :: f32(0.45)
// A thrown stack uses a longer wait, so walking after it does not scoop it back up on the way out.
DROP_THROW_DELAY :: f32(0.9)
DROP_THROW :: f32(5.5)
DROP_THROW_HOP :: f32(1.6)
// How far outside the body a stack can be and still be collected.
DROP_PICKUP_REACH :: f32(0.9)
// Stacks that settle against each other become one, up to a normal slot.
DROP_MERGE :: f32(0.45)
// Five minutes. Anything left on the ground is forgotten rather than kept forever.
DROP_LIFETIME :: f32(300)

// One stack lying in the world. Position is the center of the cube.
Drop :: struct {
	item:     Item,
	count:    int,
	position: [3]f32,
	velocity: [3]f32,
	// Seconds left before a player may pick this up.
	delay:    f32,
	age:      f32,
	// Spin and bob offset, so a pile of the same block does not move as one.
	phase:    f32,
	grounded: bool,
}

// What a client needs in order to draw a stack. The motion stays on the server.
Drop_View :: struct {
	item:     Item,
	count:    int,
	position: [3]f32,
	age:      f32,
	phase:    f32,
}

drop_spawn :: proc(drops: ^[dynamic]Drop, rng: ^u64, item: Item, count, x, y, z: int) {
	if item_empty(item) || count <= 0 {
		return
	}
	limit := stack_limit(item)
	left := count
	for left > 0 {
		take := min(left, limit)
		append(drops, Drop{
			item = item,
			count = take,
			position = {f32(x), f32(y) + 0.5, f32(z)},
			velocity = {
				drop_range(rng, -DROP_POP, DROP_POP),
				DROP_HOP,
				drop_range(rng, -DROP_POP, DROP_POP),
			},
			delay = DROP_PICKUP_DELAY,
			phase = drop_range(rng, 0, math.TAU),
		})
		left -= take
	}
}

// Leaves the hand along the look, a step ahead of the body.
drop_throw :: proc(drops: ^[dynamic]Drop, rng: ^u64, item: Item, count: int, origin, direction: [3]f32) {
	if item_empty(item) || count <= 0 {
		return
	}
	dir := direction
	length := math.sqrt(dir.x*dir.x + dir.y*dir.y + dir.z*dir.z)
	if length == 0 {
		dir = {0, 0, 1}
	} else {
		dir /= length
	}
	left := count
	for left > 0 {
		take := min(left, stack_limit(item))
		append(drops, Drop{
			item = item,
			count = take,
			position = origin + dir * 0.45,
			velocity = dir * DROP_THROW + {
				drop_range(rng, -0.35, 0.35),
				DROP_THROW_HOP,
				drop_range(rng, -0.35, 0.35),
			},
			delay = DROP_THROW_DELAY,
			phase = drop_range(rng, 0, math.TAU),
		})
		left -= take
	}
}

// xorshift64. Zero never leaves zero, so a seed is stored with the low bit set.
drop_range :: proc(state: ^u64, low, high: f32) -> f32 {
	x := state^
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	state^ = x
	unit := f32(x >> 40) * (1.0 / f32(1 << 24))
	return low + (high - low) * unit
}

drops_advance :: proc(drops: ^[dynamic]Drop, world: ^World, players: map[u32]^Server_Player, frame_dt: f32) {
	dt := clamp(frame_dt, 0, 0.05)
	for &drop in drops {
		if drop.count <= 0 {
			continue
		}
		drop.age += dt
		if drop.delay > 0 {
			drop.delay -= dt
		}
		if drop.age >= DROP_LIFETIME || drop.position.y < -30 {
			drop.count = 0
			continue
		}
		left := dt
		for left > 0 {
			step := min(left, 0.02)
			left -= step
			drop_physics(&drop, world, step)
		}
	}
	drop_merge(drops)
	for _, player in players {
		drop_collect(drops, &player.inventory, player.player)
	}
	drop_compact(drops)
}

drop_physics :: proc(drop: ^Drop, world: ^World, dt: f32) {
	drop.velocity.y -= DROP_GRAVITY * dt
	// A little drag, so the hop settles instead of sliding the length of a field.
	drag := f32(math.exp(f64(-0.6 * dt)))
	drop.velocity.x *= drag
	drop.velocity.z *= drag

	falling := drop.velocity.y < 0
	if drop_move(drop, world, 1, drop.velocity.y * dt) {
		// A hard landing bounces once. Anything slower stops, so a resting stack does not chatter against the face.
		if falling && drop.velocity.y < -2.2 {
			drop.velocity.y *= -0.3
			drop.grounded = false
		} else {
			drop.velocity.y = 0
			drop.grounded = falling
		}
	} else {
		drop.grounded = false
	}
	if drop_move(drop, world, 0, drop.velocity.x * dt) {
		drop.velocity.x = 0
	}
	if drop_move(drop, world, 2, drop.velocity.z * dt) {
		drop.velocity.z = 0
	}
	if !drop.grounded {
		return
	}
	friction := f32(math.exp(f64(-10 * dt)))
	drop.velocity.x *= friction
	drop.velocity.z *= friction
	speed := drop.velocity.x * drop.velocity.x + drop.velocity.z * drop.velocity.z
	if speed < 0.01 {
		drop.velocity.x = 0
		drop.velocity.z = 0
	}
}

// Water counts as a floor so a drop lands on the surface instead of sinking.
drop_blocked :: proc(world: ^World, x, y, z: int) -> bool {
	block := get_block(world, x, y, z)
	return block_solid(block) || block == .Water
}

drop_bounds :: proc(position: [3]f32) -> (min, max: [3]f32) {
	min = position - DROP_HALF
	max = position + DROP_HALF
	return
}

// Pushes the cube out of whatever it entered along one axis.
// True when a block stopped the move.
drop_move :: proc(drop: ^Drop, world: ^World, axis: int, delta: f32) -> bool {
	if delta == 0 {
		return false
	}
	drop.position[axis] += delta
	hit := false
	for _ in 0 ..< 4 {
		min, max := drop_bounds(drop.position)
		blocked := false
		x0 := block_index_horizontal(min.x)
		x1 := block_index_horizontal(max.x - 0.001)
		y0 := block_index_vertical(min.y)
		y1 := block_index_vertical(max.y - 0.001)
		z0 := block_index_horizontal(min.z)
		z1 := block_index_horizontal(max.z - 0.001)
		for x := x0; x <= x1; x += 1 {
			for y := y0; y <= y1; y += 1 {
				for z := z0; z <= z1; z += 1 {
					if !drop_blocked(world, x, y, z) {
						continue
					}
					bmin := [3]f32{f32(x) - 0.5, f32(y), f32(z) - 0.5}
					bmax := [3]f32{f32(x) + 0.5, f32(y) + 1, f32(z) + 0.5}
					if separated(min, max, bmin, bmax, axis) {
						continue
					}
					if delta > 0 {
						drop.position[axis] -= max[axis] - bmin[axis]
					} else {
						drop.position[axis] += bmax[axis] - min[axis]
					}
					hit = true
					blocked = true
					break
				}
				if blocked {
					break
				}
			}
			if blocked {
				break
			}
		}
		if !blocked {
			break
		}
	}
	return hit
}

drop_merge :: proc(drops: ^[dynamic]Drop) {
	n := len(drops)
	reach := DROP_MERGE * DROP_MERGE
	for i in 0 ..< n {
		a := &drops[i]
		if a.count <= 0 || !a.grounded {
			continue
		}
		for j in i + 1 ..< n {
			b := &drops[j]
			if b.count <= 0 || !b.grounded || !item_same(b.item, a.item) {
				continue
			}
			if a.count + b.count > stack_limit(a.item) {
				continue
			}
			d := a.position - b.position
			if d.x*d.x + d.y*d.y + d.z*d.z > reach {
				continue
			}
			a.count += b.count
			b.count = 0
		}
	}
}

drop_collect :: proc(drops: ^[dynamic]Drop, inv: ^Inventory, player: Player) {
	min, max := player_bounds(player.position)
	min -= DROP_PICKUP_REACH
	max += DROP_PICKUP_REACH
	for &drop in drops {
		if drop.count <= 0 || drop.delay > 0 {
			continue
		}
		p := drop.position
		if p.x < min.x || p.x > max.x || p.y < min.y || p.y > max.y || p.z < min.z || p.z > max.z {
			continue
		}
		drop.count = inventory_add(inv, drop.item, drop.count)
	}
}

drop_compact :: proc(drops: ^[dynamic]Drop) {
	n := 0
	for i in 0 ..< len(drops) {
		if drops[i].count <= 0 {
			continue
		}
		if n != i {
			drops[n] = drops[i]
		}
		n += 1
	}
	for len(drops) > n {
		pop(drops)
	}
}
