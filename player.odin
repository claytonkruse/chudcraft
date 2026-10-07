package main

import "core:math"
import rl "vendor:raylib"

PLAYER_HALF_WIDTH :: 0.3
PLAYER_HEIGHT     :: 1.8
PLAYER_EYE_HEIGHT :: 1.62
LOOK_SENSITIVITY  :: 0.003
WALK_SPEED        :: 4.5
GRAVITY           :: 32.0
JUMP_SPEED        :: 9.0

// How quickly horizontal velocity settles, in 1/seconds. Getting up to speed
// is quicker than stopping, so releasing the keys coasts about a block.
// Air has no friction, and steering there is weaker, so a jump carries its speed.
GROUND_ACCEL :: 8.0
FRICTION     :: 12.0
AIR_ACCEL    :: 8.0

// The column the player spawns on and falls back to.
SPAWN_X :: 0
SPAWN_Z :: 0

// Feet on whatever the surface is at that column, rather than a hardcoded height.
spawn_position :: proc(world: ^World) -> [3]f32 {
	return {f32(SPAWN_X), f32(surface_height(world, SPAWN_X, SPAWN_Z)), f32(SPAWN_Z)}
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
	wish_length := math.sqrt(wish.x * wish.x + wish.y * wish.y)
	if wish_length > 0 {
		wish *= WALK_SPEED / wish_length
	}

	rate: f32
	if player.grounded {
		rate = GROUND_ACCEL if wish_length > 0 else FRICTION
	} else if wish_length > 0 {
		rate = AIR_ACCEL
	}
	if rate > 0 {
		approach_horizontal(&player.velocity, wish, rate, input.dt)
	}

	player.velocity.y -= GRAVITY * input.dt
	if player.grounded && input.jump {
		player.velocity.y = JUMP_SPEED
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
					if !solid(world, x, y, z) {
						continue
					}
					bmin := [3]f32{f32(x) - 0.5, f32(y), f32(z) - 0.5}
					bmax := [3]f32{f32(x) + 0.5, f32(y) + 1, f32(z) + 0.5}
					if separated(min, max, bmin, bmax, axis) {
						continue
					}
					if delta > 0 {
						player.position[axis] -= max[axis] - bmin[axis]
					} else {
						player.position[axis] += bmax[axis] - min[axis]
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

// True when the body intersects this cell. Placement uses it so a solid block
// cannot be put where the player is standing.
player_overlaps_block :: proc(player: Player, x, y, z: int) -> bool {
	min, max := player_bounds(player.position)
	bmin := [3]f32{f32(x) - 0.5, f32(y), f32(z) - 0.5}
	bmax := [3]f32{f32(x) + 0.5, f32(y) + 1, f32(z) + 0.5}
	return min.x < bmax.x && max.x > bmin.x &&
		min.y < bmax.y && max.y > bmin.y &&
		min.z < bmax.z && max.z > bmin.z
}

player_bounds :: proc(position: [3]f32) -> (min, max: [3]f32) {
	min = position + {-PLAYER_HALF_WIDTH, 0, -PLAYER_HALF_WIDTH}
	max = position + {PLAYER_HALF_WIDTH, PLAYER_HEIGHT, PLAYER_HALF_WIDTH}
	return
}

// slack on the axes we are not moving along, so standing on a block
// does not count as colliding with it while walking.
separated :: proc(min, max, bmin, bmax: [3]f32, axis: int) -> bool {
	for a in 0 ..< 3 {
		slack: f32 = 0.001 if a != axis else 0
		if max[a] <= bmin[a]+slack || min[a] >= bmax[a]-slack {
			return true
		}
	}
	return false
}
