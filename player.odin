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

// Feet on the middle of the grass block at (8, 3, 2). Its top is y = 4.
SPAWN_POSITION :: [3]f32{0, 9, 0}

Player :: struct {
	position: [3]f32,
	velocity: [3]f32,
	yaw:      f32,
	pitch:    f32,
	grounded: bool,
}

update_player :: proc(player: ^Player, chunk: ^Chunk, dt: f32) {
	mouse := rl.GetMouseDelta()
	player.yaw -= mouse.x * LOOK_SENSITIVITY
	player.pitch -= mouse.y * LOOK_SENSITIVITY
	player.pitch = clamp(player.pitch, -1.55, 1.55)

	sin_yaw := math.sin(player.yaw)
	cos_yaw := math.cos(player.yaw)
	forward := [2]f32{sin_yaw, cos_yaw}
	right := [2]f32{cos_yaw, -sin_yaw}

	wish: [2]f32
	if rl.IsKeyDown(.W) do wish += forward
	if rl.IsKeyDown(.A) do wish += right
	if rl.IsKeyDown(.S) do wish -= forward
	if rl.IsKeyDown(.D) do wish -= right
	wish_length := math.sqrt(wish.x * wish.x + wish.y * wish.y)
	if wish_length > 0 {
		wish *= WALK_SPEED / wish_length
	}
	player.velocity.x = wish.x
	player.velocity.z = wish.y

	player.velocity.y -= GRAVITY * dt
	if player.grounded && rl.IsKeyDown(.SPACE) {
		player.velocity.y = JUMP_SPEED
	}

	falling := player.velocity.y < 0
	hit := move_player(player, chunk, 1, player.velocity.y * dt)
	player.grounded = falling && hit
	move_player(player, chunk, 0, player.velocity.x * dt)
	move_player(player, chunk, 2, player.velocity.z * dt)

	if player.position.y < -20 {
		player.position = SPAWN_POSITION
		player.velocity = {}
		player.grounded = true
	}
}

// Moves the player along one axis and pushes them out of any block they enter.
// Returns true when that move was stopped by a block.
move_player :: proc(player: ^Player, chunk: ^Chunk, axis: int, delta: f32) -> bool {
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
					if !solid(chunk, x, y, z) {
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

camera_from_player :: proc(player: Player) -> rl.Camera3D {
	eye := player.position + {0, PLAYER_EYE_HEIGHT, 0}
	cos_pitch := math.cos(player.pitch)
	look := [3]f32 {
		cos_pitch * math.sin(player.yaw),
		math.sin(player.pitch),
		cos_pitch * math.cos(player.yaw),
	}
	return {
		position   = eye,
		target     = eye + look,
		up         = {0, 1, 0},
		fovy       = 70,
		projection = .PERSPECTIVE,
	}
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
