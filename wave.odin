package main

import "core:math"

// Waves are a height on top of the water blocks. The blocks stay put; the
// same function displaces the mesh and the swim / drop surface, so a crest
// is something you float on.
// assets/shaders/water.vs evaluates the same height. Keep the two in step.

// How far a shore search looks, in blocks. Past this, water counts as open.
WAVE_REACH :: 18
// A pond smaller than this, in blocks of open water, stays flat.
WAVE_MIN_FETCH :: f32(8)
WAVE_FULL_FETCH :: f32(14)
// Width of the band where a crest steepens and collapses onto the bank.
WAVE_SURF :: f32(6.5)
// Crests travel this way in xz. Fixed so the phase does not jump where the
// nearest land cell changes.
WAVE_WIND_X :: f32(0.60)
WAVE_WIND_Z :: f32(0.80)

WAVE_MASK :: WAVE_REACH*2 + 1

// A column the search cannot see yet. It is not land: an unloaded neighbor
// must not look like a shore, or the ocean breaks along the loading edge.
WAVE_UNKNOWN :: u8(0)
WAVE_WATER   :: u8(1)
WAVE_LAND    :: u8(2)

Wave_Field :: struct {
	// Blocks from this point to the nearest land. Zero on the shoreline.
	shore:  f32,
	// Longest open-water run in any of eight directions, capped at WAVE_REACH.
	fetch:  f32,
	// Unit direction toward that land, in xz. Zero when no land is in range.
	toward: [2]f32,
}

// True when this cell is the top of a water column the player can see.
water_surface :: proc(world: ^World, x, y, z: int) -> bool {
	if get_block(world, x, y, z) != .Water {
		return false
	}
	above := get_block(world, x, y+1, z)
	return above != .Water && !block_opaque(above)
}

wave_smooth :: proc(edge0, edge1, x: f32) -> f32 {
	t := clamp((x-edge0)/(edge1-edge0), 0, 1)
	return t*t*(3-2*t)
}

// cell is row-major, cell[z*span+x], covering columns [x0, x0+span).
wave_mask :: proc(world: ^World, x0, z0, sy, span: int, cell: []u8) {
	for z in 0 ..< span {
		for x in 0 ..< span {
			wx := x0 + x
			wz := z0 + z
			i := z*span + x
			if _, ok := world.chunks[chunk_of(wx, sy, wz)]; !ok {
				cell[i] = WAVE_UNKNOWN
				continue
			}
			cell[i] = WAVE_WATER if water_surface(world, wx, sy, wz) else WAVE_LAND
		}
	}
}

cell_at :: proc(cell: []u8, x0, z0, span, x, z: int) -> u8 {
	lx := x - x0
	lz := z - z0
	if lx < 0 || lz < 0 || lx >= span || lz >= span {
		return WAVE_UNKNOWN
	}
	return cell[lz*span+lx]
}

// Distance from a point to the square a block occupies in xz.
dist_to_block :: proc(px, pz: f32, bx, bz: int) -> f32 {
	dx: f32
	if px < f32(bx)-0.5 {
		dx = f32(bx) - 0.5 - px
	} else if px > f32(bx)+0.5 {
		dx = px - (f32(bx) + 0.5)
	}
	dz: f32
	if pz < f32(bz)-0.5 {
		dz = f32(bz) - 0.5 - pz
	} else if pz > f32(bz)+0.5 {
		dz = pz - (f32(bz) + 0.5)
	}
	return math.sqrt(dx*dx + dz*dz)
}

// Nearest land to the center of column (cx, cz), and how much open water
// sits around it. Land outside the mask is ignored, so the mask has to
// cover WAVE_REACH in every direction or a shore gets missed.
wave_column :: proc(cx, cz, x0, z0, span: int, cell: []u8) -> (land_x, land_z: int, have: bool, fetch: f32) {
	px := f32(cx)
	pz := f32(cz)
	best := f32(WAVE_REACH + 1)
	for r in 1 ..= WAVE_REACH {
		if have && best <= f32(r)-1.01 {
			break
		}
		for oz in -r ..= r {
			for ox in -r ..= r {
				if max(abs(ox), abs(oz)) != r {
					continue
				}
				nx := cx + ox
				nz := cz + oz
				// Unknown is unloaded, not a beach. Off the mask is the same.
				if cell_at(cell, x0, z0, span, nx, nz) != WAVE_LAND {
					continue
				}
				d := dist_to_block(px, pz, nx, nz)
				if d < best {
					best = d
					land_x = nx
					land_z = nz
					have = true
				}
			}
		}
	}

	dirs := [8][2]f32 {
		{1, 0},
		{-1, 0},
		{0, 1},
		{0, -1},
		{0.70710678, 0.70710678},
		{0.70710678, -0.70710678},
		{-0.70710678, 0.70710678},
		{-0.70710678, -0.70710678},
	}
	for dir in dirs {
		traveled: f32
		for step in 1 ..= WAVE_REACH {
			nx := block_index_horizontal(px + dir.x*f32(step))
			nz := block_index_horizontal(pz + dir.y*f32(step))
			state := cell_at(cell, x0, z0, span, nx, nz)
			if state == WAVE_LAND {
				break
			}
			// Past the loaded world, assume the water keeps going.
			if state == WAVE_UNKNOWN {
				traveled = f32(WAVE_REACH)
				break
			}
			traveled = f32(step)
		}
		if traveled > fetch {
			fetch = traveled
		}
	}
	return
}

// Land found for one column center. Blended across the four centers around
// a sample so the shore distance the mesh and the collision share does not
// step at the column edge.
Column_Land :: struct {
	x, z:  int,
	have:  bool,
	fetch: f32,
}

blend_land :: proc(px, pz, tx, tz: f32, s00, s10, s01, s11: Column_Land) -> Wave_Field {
	w00 := (1 - tx) * (1 - tz)
	w10 := tx * (1 - tz)
	w01 := (1 - tx) * tz
	w11 := tx * tz
	fetch := s00.fetch*w00 + s10.fetch*w10 + s01.fetch*w01 + s11.fetch*w11
	lx, lz, w: f32
	fold :: proc(s: Column_Land, weight: f32, lx, lz, w: ^f32) {
		if !s.have || weight <= 0 {
			return
		}
		lx^ += f32(s.x) * weight
		lz^ += f32(s.z) * weight
		w^ += weight
	}
	fold(s00, w00, &lx, &lz, &w)
	fold(s10, w10, &lx, &lz, &w)
	fold(s01, w01, &lx, &lz, &w)
	fold(s11, w11, &lx, &lz, &w)
	if w <= 0 {
		return {shore = f32(WAVE_REACH), fetch = fetch}
	}
	lx /= w
	lz /= w
	dx := lx - px
	dz := lz - pz
	length := math.sqrt(dx*dx + dz*dz)
	shore := length - 0.5
	if shore < 0 {
		shore = 0
	}
	toward: [2]f32
	if length > 1e-4 {
		toward = {dx / length, dz / length}
	}
	return {shore = shore, fetch = fetch, toward = toward}
}

// Field at a world point. The four surrounding column centers are blended,
// which is the same sample the water mesh bakes.
WAVE_FIELD_SPAN :: WAVE_REACH*2 + 2

wave_field_at :: proc(world: ^World, px, pz: f32, sy: int) -> Wave_Field {
	ix0 := int(math.floor(px))
	iz0 := int(math.floor(pz))
	tx := px - f32(ix0)
	tz := pz - f32(iz0)
	x0 := ix0 - WAVE_REACH
	z0 := iz0 - WAVE_REACH
	cell: [WAVE_FIELD_SPAN * WAVE_FIELD_SPAN]u8
	wave_mask(world, x0, z0, sy, WAVE_FIELD_SPAN, cell[:])
	take :: proc(cell: []u8, x0, z0, cx, cz: int) -> Column_Land {
		lx, lz, have, fetch := wave_column(cx, cz, x0, z0, WAVE_FIELD_SPAN, cell)
		return {x = lx, z = lz, have = have, fetch = fetch}
	}
	return blend_land(
		px, pz, tx, tz,
		take(cell[:], x0, z0, ix0, iz0),
		take(cell[:], x0, z0, ix0+1, iz0),
		take(cell[:], x0, z0, ix0, iz0+1),
		take(cell[:], x0, z0, ix0+1, iz0+1),
	)
}

// Height above the flat top of the water block, and how broken the crest is.
// Small fetches are ponds and stay at rest. The crest travels with a fixed
// wind so neighboring columns stay continuous; shore distance only steepens
// it and pins it to the bank.
wave_height :: proc(x, z, time, shore, fetch: f32) -> (height, foam: f32) {
	open := wave_smooth(WAVE_MIN_FETCH, WAVE_FULL_FETCH, fetch)
	if open <= 0 {
		return 0, 0
	}
	lip := wave_smooth(0.2, 1.35, shore)
	offshore := wave_smooth(2.2, WAVE_SURF, shore)

	swell: f32
	swell += math.sin(x*0.085 + z*0.045 - time*1.15) * 0.16
	swell += math.sin(-x*0.06 + z*0.11 - time*0.82) * 0.08
	swell += math.sin(x*0.17 - z*0.13 - time*1.70) * 0.04
	swell *= (0.45 + 0.55*offshore) * open

	// Positive time moves a constant phase toward decreasing seaward,
	// which is downwind. One wind for the whole sea, so a crest is a
	// line and not a spike at every column.
	seaward := -(x*WAVE_WIND_X + z*WAVE_WIND_Z)
	k := 0.18 + (1-offshore)*0.22
	phase := seaward*k + time*1.35
	u := phase / 6.28318530718
	u -= math.floor(u)

	rise := wave_smooth(0.05, 0.72, u)
	face := wave_smooth(0.55, 0.86, u)
	crash := 1 - wave_smooth(0.80, 0.98, u)
	shape := rise*crash*0.85 + face*crash*0.15 - 0.16
	break_env := math.sin(clamp(shore/WAVE_SURF, 0, 1)*3.14159265) * open
	breaker := shape * 0.40 * break_env

	height = clamp((swell+breaker)*lip, -0.55, 0.90)
	crest := wave_smooth(0.62, 0.82, u) * crash
	wash := (1 - wave_smooth(0.25, 1.8, shore)) * wave_smooth(0.50, 0.82, u)
	foam = clamp(break_env*crest*1.15 + wash*open, 0, 1)
	return
}

// Free surface of the water column, including a crest that reaches into the
// air block above the water. y_lo is extended one block down so feet that
// the crest has already lifted still find the column.
column_wave :: proc(world: ^World, x, z, y_lo, y_hi: int, time, sample_x, sample_z: f32) -> (y: f32, field: Wave_Field, ok: bool) {
	sy := 0
	found := false
	for y := y_lo - 1; y <= y_hi; y += 1 {
		if get_block(world, x, y, z) == .Water {
			sy = y
			found = true
			break
		}
	}
	if !found {
		return
	}
	for _ in 0 ..< 48 {
		if get_block(world, x, sy+1, z) != .Water {
			break
		}
		sy += 1
	}
	above := get_block(world, x, sy+1, z)
	if above == .Water || block_opaque(above) {
		return f32(sy + 1), {}, true
	}
	field = wave_field_at(world, sample_x, sample_z, sy)
	h, _ := wave_height(sample_x, sample_z, time, field.shore, field.fetch)
	return f32(sy+1) + h, field, true
}
