package main

import "core:c"
import "core:math"
import b3 "vendor:box3d"
import rl "vendor:raylib"

// The vendor binding stores manifold points inline. The C function writes through
// a pointer the caller provides, so this layout matches b3LocalManifold.
Contact_Manifold :: struct {
	normal:          b3.Vec3,
	triangle_normal: b3.Vec3,
	points:          [^]b3.LocalManifoldPoint,
	point_count:     c.int,
}

#assert(offset_of(Contact_Manifold, points) == 24)
#assert(offset_of(Contact_Manifold, point_count) == 32)

// Vertical capsule: this radius, with hemispheres at the feet and the top of the head.
PLAYER_RADIUS :: 0.3
PLAYER_HEIGHT :: 1.8
PLAYER_EYE_HEIGHT :: 1.62
LOOK_SENSITIVITY  :: 0.003
WALK_SPEED        :: 4.5
GRAVITY           :: 32.0
JUMP_SPEED        :: 9.0

// Wading is a shallow pool with your feet on the floor. Swimming is everything
// deeper, and it is slower. The hop is what gets you back onto the bank.
WADE_SPEED  :: 2.6
SWIM_SPEED  :: 3.0
WATER_HOP   :: 6.0
WATER_DRAG  :: 4.5
// Pulls the eyes up to the water line. Clamped so a deep pool does not launch you.
WATER_LIFT  :: 16.0

// How quickly horizontal velocity settles, in 1/seconds. Getting up to speed
// is quicker than stopping, so releasing the keys coasts about a block.
// Air has no friction, and steering there is weaker, so a jump carries its speed.
GROUND_ACCEL :: 8.0
FRICTION     :: 12.0
AIR_ACCEL    :: 8.0

// Feet on the meadow the seed chose, rather than a hardcoded height. The origin
// is often ocean once biomes own the shape of the ground.
spawn_position :: proc(world: ^World) -> [3]f32 {
	return {f32(world.spawn_x), f32(surface_height(world, world.spawn_x, world.spawn_z)), f32(world.spawn_z)}
}

Player :: struct {
	position: [3]f32,
	velocity: [3]f32,
	yaw:      f32,
	pitch:    f32,
	grounded: bool,
}

// What the client sends for one step of movement. The server applies it; the
// keyboard is never read on that side.
Move_Input :: struct {
	dt:                          f32,
	yaw, pitch:                  f32,
	forward, back, left, right:  bool,
	jump:                        bool,
}

// look is false while a screen has the cursor. The delta is still consumed,
// so closing the screen does not fling the camera with the cursor's travel.
look_player :: proc(player: ^Player, enabled: bool) {
	mouse := rl.GetMouseDelta()
	if !enabled {
		return
	}
	player.yaw -= mouse.x * LOOK_SENSITIVITY
	player.pitch -= mouse.y * LOOK_SENSITIVITY
	player.pitch = clamp(player.pitch, -1.55, 1.55)
}

// Movement keeps going while a screen is open; the client simply keeps sending keys.
simulate_player :: proc(player: ^Player, world: ^World, input: Move_Input) {
	player.yaw = input.yaw
	player.pitch = clamp(input.pitch, -1.55, 1.55)

	sin_yaw := math.sin(player.yaw)
	cos_yaw := math.cos(player.yaw)
	forward := [2]f32{sin_yaw, cos_yaw}
	right := [2]f32{cos_yaw, -sin_yaw}

	wish: [2]f32
	if input.forward do wish += forward
	if input.left do wish += right
	if input.back do wish -= forward
	if input.right do wish -= right
	surface, wet, toward, foam := body_in_water(world, player.position, f32(world.time))
	eye := player.position.y + PLAYER_EYE_HEIGHT
	// Shallow water with solid ground under you is wading. Anything else wet is a swim.
	wading := wet && player.grounded && eye > surface+0.02
	swimming := wet && !wading

	speed: f32 = WALK_SPEED
	if swimming {
		speed = SWIM_SPEED
	} else if wading {
		speed = WADE_SPEED
	}
	wish_length := math.sqrt(wish.x * wish.x + wish.y * wish.y)
	if wish_length > 0 {
		wish *= speed / wish_length
	}

	rate: f32
	if swimming {
		rate = 10
	} else if player.grounded {
		rate = GROUND_ACCEL if wish_length > 0 else FRICTION
	} else if wish_length > 0 {
		rate = AIR_ACCEL
	}
	if rate > 0 {
		approach_horizontal(&player.velocity, wish, rate, input.dt)
	}

	if swimming {
		swim_vertical(player, surface, input.jump, input.dt)
	} else {
		player.velocity.y -= GRAVITY * input.dt
		if player.grounded && input.jump {
			player.velocity.y = JUMP_SPEED
		}
	}
	// A crest that is pitching shoreward shoves whatever is in the wash.
	// toward is xz; its second component is Z.
	if wet && foam > 0.35 {
		player.velocity.x += toward.x * 11 * foam * input.dt
		player.velocity.z += toward.y * 11 * foam * input.dt
	}

	falling := player.velocity.y < 0
	hit := move_player(player, world, 1, player.velocity.y * input.dt)
	player.grounded = falling && hit
	move_player(player, world, 0, player.velocity.x * input.dt)
	move_player(player, world, 2, player.velocity.z * input.dt)

	if player.position.y < -20 {
		player.position = spawn_position(world)
		player.velocity = {}
		player.grounded = true
	}
}

// Water the body is touching, and the Y of that water's wave surface.
// A crest lifts the body and a trough lets it down. The blocks never change.
// A column the capsule only brushes still counts, which is what makes a shoreline
// start to swim as soon as the body enters it.
// toward points at the land the highest crest is breaking toward. foam is how
// hard that crest is pitching. Both stay zero on flat water.
body_in_water :: proc(world: ^World, position: [3]f32, time: f32) -> (surface: f32, wet: bool, toward: [2]f32, foam: f32) {
	min, max := player_bounds(position)
	x0 := block_index_horizontal(min.x)
	x1 := block_index_horizontal(max.x - 0.001)
	z0 := block_index_horizontal(min.z)
	z1 := block_index_horizontal(max.z - 0.001)
	y0 := block_index_vertical(min.y)
	y1 := block_index_vertical(max.y - 0.001)

	for x := x0; x <= x1; x += 1 {
		for z := z0; z <= z1; z += 1 {
			if cell_horiz_distance_sq(position.x, position.z, x, z) >= PLAYER_RADIUS*PLAYER_RADIUS {
				continue
			}
			face, field, ok := column_wave(world, x, z, y0, y1, time, position.x, position.z)
			if ok {
				_, f := wave_height(position.x, position.z, time, field.shore, field.fetch)
				if !wet || face > surface {
					surface = face
					wet = true
					toward = field.toward
					foam = f
				}
				continue
			}
			wash, dir, f, hit := shore_wash(world, x, z, min.y, time)
			if !hit {
				continue
			}
			if !wet || wash > surface {
				surface = wash
				wet = true
				toward = dir
				foam = f
			}
		}
	}
	if !wet {
		return
	}
	depth := clamp(surface-min.y, 0, PLAYER_HEIGHT)
	if depth <= 0.001 {
		return
	}
	return
}

// A breaking crest runs a short way up the first land block, then pulls back.
// Ankle deep, so the wash slows you without turning the beach into a swim.
shore_wash :: proc(world: ^World, x, z: int, feet, time: f32) -> (y: f32, toward: [2]f32, foam: f32, ok: bool) {
	ground := block_index_vertical(feet - 0.02)
	if !solid(world, x, ground, z) {
		return
	}
	top := f32(ground + 1)
	if feet > top+0.35 {
		return
	}
	best: f32
	for dz in -1 ..= 1 {
		for dx in -1 ..= 1 {
			if dx == 0 && dz == 0 {
				continue
			}
			nx := x + dx
			nz := z + dz
			if get_block(world, nx, ground, nz) != .Water &&
			   get_block(world, nx, ground-1, nz) != .Water &&
			   get_block(world, nx, ground+1, nz) != .Water {
				continue
			}
			sample_x := f32(nx)
			sample_z := f32(nz)
			face, field, found := column_wave(world, nx, nz, ground-2, ground+2, time, sample_x, sample_z)
			if !found || field.fetch < WAVE_MIN_FETCH {
				continue
			}
			h, f := wave_height(sample_x, sample_z, time, field.shore, field.fetch)
			if abs(face-h-top) > 1.25 || f < 0.4 {
				continue
			}
			wash := top + 0.08 + 0.42*f
			if !ok || wash > best {
				best = wash
				toward = field.toward
				foam = f
				ok = true
			}
		}
	}
	if !ok {
		return
	}
	return best, toward, foam, true
}

// Floats the eyes to just above the water line. Jump strokes upward, and a jump
// that is already at the surface hops onto the bank instead of stroking in place.
swim_vertical :: proc(player: ^Player, surface: f32, jump: bool, dt: f32) {
	eye := player.position.y + PLAYER_EYE_HEIGHT
	error := (surface - 0.05) - eye
	if jump && error < 0.35 && player.velocity.y <= 0.5 {
		player.velocity.y = WATER_HOP
	} else if jump {
		player.velocity.y += WATER_LIFT * dt
	} else if error > 0 {
		player.velocity.y += min(error, 2) * WATER_LIFT * dt
	} else {
		player.velocity.y += max(error, -0.35) * 8 * dt
	}
	player.velocity.y *= f32(math.exp(f64(-WATER_DRAG * dt)))
	player.velocity.y = clamp(player.velocity.y, -4, WATER_HOP)
}

// One step of dv/dt = rate * (target - v). Exact for the frame's dt, so a long
// frame does not overshoot and the feel does not depend on the frame rate.
approach_horizontal :: proc(velocity: ^[3]f32, target: [2]f32, rate, dt: f32) {
	blend := f32(1 - math.exp(-rate * dt))
	velocity.x += (target.x - velocity.x) * blend
	velocity.z += (target.y - velocity.z) * blend
	speed_sq := velocity.x * velocity.x + velocity.z * velocity.z
	if target == 0 && speed_sq < 1e-4 {
		velocity.x = 0
		velocity.z = 0
	}
}

// Moves the player along one axis and pushes them out of any block they enter.
// Returns true when that move was stopped by a block.
move_player :: proc(player: ^Player, world: ^World, axis: int, delta: f32) -> bool {
	if delta == 0 {
		return false
	}

	player.position[axis] += delta
	hit := false

	// A few passes, so a corner hit can push the player out of more than one block.
	for _ in 0 ..< 8 {
		min, max := player_bounds(player.position)
		blocked := false
		x0, x1 := block_index_horizontal(min.x), block_index_horizontal(max.x - 0.001)
		y0, y1 := block_index_vertical(min.y), block_index_vertical(max.y - 0.001)
		z0, z1 := block_index_horizontal(min.z), block_index_horizontal(max.z - 0.001)

		for x := x0; x <= x1; x += 1 {
			for y := y0; y <= y1; y += 1 {
				for z := z0; z <= z1; z += 1 {
					bmin, bmax, shape, blocked_cell := block_hitbox(get_block(world, x, y, z), x, y, z)
					if !blocked_cell {
						continue
					}
					hull := unit_block_hull()
					switch shape {
					case .Full:
					case .Thin_X:
						hull = door_hull_x()
					case .Thin_Z:
						hull = door_hull_z()
					}
					if !capsule_push(player, bmin, bmax, axis, delta, hull) {
						continue
					}
					hit = true
					blocked = true
					break
				}
				if blocked do break
			}
			if blocked do break
		}
		if !blocked {
			break
		}
	}

	if hit {
		player.velocity[axis] = 0
	}
	return hit
}

look_direction :: proc(yaw, pitch: f32) -> [3]f32 {
	cos_pitch := math.cos(pitch)
	return {
		cos_pitch * math.sin(yaw),
		math.sin(pitch),
		cos_pitch * math.cos(yaw),
	}
}

camera_from_player :: proc(player: Player) -> rl.Camera3D {
	eye := player.position + {0, PLAYER_EYE_HEIGHT, 0}
	look := look_direction(player.yaw, player.pitch)
	return {
		position   = eye,
		target     = eye + look,
		up         = {0, 1, 0},
		fovy       = 70,
		projection = .PERSPECTIVE,
	}
}

// How far behind the eyes the third-person camera sits, and how far it stays
// off a block it would otherwise enter. Closer than the hide distance, the
// body is not drawn, because the camera is inside the head.
THIRD_PERSON_DISTANCE :: f32(4)
THIRD_PERSON_MARGIN   :: f32(0.3)
THIRD_PERSON_HIDE     :: f32(0.85)

// Same look direction as the first-person camera, pulled back along it.
// A solid block shortens that pull so the view stays in the air.
camera_behind :: proc(world: ^World, player: Player) -> (camera: rl.Camera3D, distance: f32) {
	eye := player.position + {0, PLAYER_EYE_HEIGHT, 0}
	look := look_direction(player.yaw, player.pitch)
	back := -look
	distance = THIRD_PERSON_DISTANCE
	for t := f32(0.05); t <= THIRD_PERSON_DISTANCE; t += 0.05 {
		p := eye + back*t
		bx := block_index_horizontal(p.x)
		by := block_index_vertical(p.y)
		bz := block_index_horizontal(p.z)
		if block_contains(get_block(world, bx, by, bz), bx, by, bz, p) {
			distance = max(t-THIRD_PERSON_MARGIN, 0.15)
			break
		}
	}
	pos := eye + back*distance
	camera = {
		position   = pos,
		target     = pos + look,
		up         = {0, 1, 0},
		fovy       = 70,
		projection = .PERSPECTIVE,
	}
	return
}

// True when the capsule intersects this cell. Placement uses it so a solid block
// cannot be put where the player is standing.
player_overlaps_block :: proc(player: Player, x, y, z: int) -> bool {
	bmin := [3]f32{f32(x) - 0.5, f32(y), f32(z) - 0.5}
	bmax := [3]f32{f32(x) + 0.5, f32(y) + 1, f32(z) + 0.5}
	return player_overlaps_aabb(player, bmin, bmax)
}

player_overlaps_aabb :: proc(player: Player, bmin, bmax: [3]f32) -> bool {
	return capsule_distance_sq(player.position, bmin, bmax) < PLAYER_RADIUS*PLAYER_RADIUS
}

// A point in the cell's collision, which for a door is the panel and not the gap.
block_contains :: proc(block: Block, x, y, z: int, p: [3]f32) -> bool {
	bmin, bmax, _, ok := block_hitbox(block, x, y, z)
	if !ok {
		return false
	}
	return p.x >= bmin.x && p.x <= bmax.x && p.y >= bmin.y && p.y <= bmax.y && p.z >= bmin.z && p.z <= bmax.z
}

// Slack on the axes a box is not moving along, so standing on a block does not
// count as hitting it. Drops are boxes; the player uses the capsule instead.
separated :: proc(min, max, bmin, bmax: [3]f32, axis: int) -> bool {
	for a in 0 ..< 3 {
		slack: f32 = 0.001 if a != axis else 0
		if max[a] <= bmin[a]+slack || min[a] >= bmax[a]-slack {
			return true
		}
	}
	return false
}

// The capsule's bounding box. The shape itself is round; this is only the search.
player_bounds :: proc(position: [3]f32) -> (min, max: [3]f32) {
	min = position + {-PLAYER_RADIUS, 0, -PLAYER_RADIUS}
	max = position + {PLAYER_RADIUS, PLAYER_HEIGHT, PLAYER_RADIUS}
	return
}

// Horizontal distance from a point to a block column's square.
cell_horiz_distance_sq :: proc(px, pz: f32, x, z: int) -> f32 {
	minx, maxx := f32(x)-0.5, f32(x)+0.5
	minz, maxz := f32(z)-0.5, f32(z)+0.5
	dx := px - clamp(px, minx, maxx)
	dz := pz - clamp(pz, minz, maxz)
	return dx*dx + dz*dz
}

// Distance from the capsule's core segment to a block. The segment runs between
// the two sphere centers, so a result under the radius means the body hits.
capsule_distance_sq :: proc(position, bmin, bmax: [3]f32) -> f32 {
	dx := position.x - clamp(position.x, bmin.x, bmax.x)
	dz := position.z - clamp(position.z, bmin.z, bmax.z)
	horiz := dx*dx + dz*dz
	lo := position.y + PLAYER_RADIUS
	hi := position.y + PLAYER_HEIGHT - PLAYER_RADIUS
	if hi < bmin.y {
		dy := bmin.y - hi
		return horiz + dy*dy
	}
	if lo > bmax.y {
		dy := lo - bmax.y
		return horiz + dy*dy
	}
	return horiz
}

// One unit block, centered on the origin. Offsets are relative, so the copy is safe.
unit_block: b3.BoxHull
unit_block_ready: bool
door_box_x, door_box_z: b3.BoxHull
door_hulls_ready: bool

unit_block_hull :: proc() -> ^b3.HullData {
	if !unit_block_ready {
		unit_block = b3.MakeBoxHull(0.5, 0.5, 0.5)
		unit_block_ready = true
	}
	return &unit_block.base
}

door_hulls_init :: proc() {
	if door_hulls_ready {
		return
	}
	door_box_x = b3.MakeBoxHull(DOOR_THICK*0.5, 0.5, 0.5)
	door_box_z = b3.MakeBoxHull(0.5, 0.5, DOOR_THICK*0.5)
	door_hulls_ready = true
}

door_hull_x :: proc() -> ^b3.HullData {
	door_hulls_init()
	return &door_box_x.base
}

door_hull_z :: proc() -> ^b3.HullData {
	door_hulls_init()
	return &door_box_z.base
}

// Pushes the capsule out of one block along the axis it just moved on.
// The contact normal decides which axis owns the hit: a floor (normal along Y)
// cannot throw the body across the block, and a wall cannot lift it onto a step.
capsule_push :: proc(player: ^Player, bmin, bmax: [3]f32, axis: int, delta: f32, hull: ^b3.HullData) -> bool {
	center := (bmin + bmax) * 0.5
	feet := player.position
	cap := b3.Capsule{
		center1 = {feet.x - center.x, feet.y + PLAYER_RADIUS - center.y, feet.z - center.z},
		center2 = {feet.x - center.x, feet.y + PLAYER_HEIGHT - PLAYER_RADIUS - center.y, feet.z - center.z},
		radius  = PLAYER_RADIUS,
	}
	points: [2]b3.LocalManifoldPoint
	manifold: Contact_Manifold
	manifold.points = &points[0]
	cache: b3.SimplexCache
	// #by_ptr would hand the C function a copy of the hull header. The points live
	// after that header, so the call has to see the hull in place.
	Collide :: proc "c" (manifold: rawptr, capacity: c.int, hull, capsule: rawptr, transform: b3.Transform, cache: rawptr)
	collide := transmute(Collide)b3.CollideHullAndCapsule
	collide(&manifold, 2, hull, &cap, b3.Transform_identity, &cache)
	if manifold.point_count <= 0 {
		return false
	}

	sep: f32 = 0
	overlapped := false
	count := int(manifold.point_count)
	if count > len(points) {
		count = len(points)
	}
	for i in 0 ..< count {
		s := points[i].separation
		if s < sep {
			sep = s
			overlapped = true
		}
	}
	// A positive separation is a speculative near-miss, not something to resolve.
	if !overlapped {
		return false
	}

	// Mostly this axis. A floor normal stays out of the horizontal passes.
	n := manifold.normal[axis]
	if abs(n) < 0.5 {
		return false
	}
	shift := -sep / n
	// Only undo the move that caused the overlap. Pushing the other way launches.
	if shift*delta >= 0 {
		return false
	}
	player.position[axis] += shift
	return true
}
