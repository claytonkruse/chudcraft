package main

import "core:c"
import "core:math"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// The sun sits at the origin. The earth, which is this world, orbits it once a
// year and spins once a solar day. The moon orbits the earth. Up in the world
// is away from the earth's center at LATITUDE, so the sun's altitude is what
// makes day and night.

DAY_LENGTH :: f64(600) // one solar day, in seconds
YEAR_LENGTH :: f64(DAY_LENGTH * 24)
MOON_PERIOD :: f64(DAY_LENGTH * 8)
OBLIQUITY :: f64(23.439 * math.PI / 180)
MOON_INCLINATION :: f64(5.145 * math.PI / 180)
LATITUDE :: f64(38 * math.PI / 180)
// Negative so a new world starts in the morning, with the sun east of noon.
SOLAR_PHASE :: f64(-0.7)

SKY_RADIUS :: f32(340)
SHADOW_MAP_SIZE :: i32(2048)
SHADOW_HALF :: f32(48)
SHADOW_REACH :: f32(96)

Sky :: struct {
	sun:       [3]f32, // from the ground toward the sun
	moon:      [3]f32, // from the ground toward the moon
	sun_up:    f32,
	moon_up:   f32,
	star_fade: f32, // 1 when the sun is down
	light_on_sun: bool
}

Star :: struct {
	equatorial: [3]f64,
	bright:     f32,
}

STAR_COUNT :: 180

sky_at :: proc(time: f64) -> Sky {
	orbit := math.TAU * time / YEAR_LENGTH
	// Heliocentric: the earth is opposite the direction of the sun.
	sun_ecliptic := [3]f64{math.cos(orbit), math.sin(orbit), 0}
	sun_eq := ecliptic_to_equatorial(sun_ecliptic)

	psi := math.TAU * time / MOON_PERIOD
	moon_ecliptic := [3]f64{
		math.cos(psi),
		math.sin(psi) * math.cos(MOON_INCLINATION),
		math.sin(psi) * math.sin(MOON_INCLINATION),
	}
	moon_eq := ecliptic_to_equatorial(moon_ecliptic)

	// Sidereal spin plus the orbit, so a solar day stays one DAY_LENGTH long.
	lst := orbit + math.TAU*time/DAY_LENGTH + SOLAR_PHASE
	sun := equatorial_to_world(sun_eq, lst)
	moon := equatorial_to_world(moon_eq, lst)
	day := smoothstep_f(-0.12, 0.22, sun.y)
	return Sky{
		sun = sun,
		moon = moon,
		sun_up = sun.y,
		moon_up = moon.y,
		star_fade = 1 - day,
		light_on_sun = sun.y > 0.08 || moon.y <= 0.05,
	}
}

sky_clear :: proc(sky: Sky) -> rl.Color {
	day := smoothstep_f(-0.18, 0.32, sky.sun_up)
	glow := f32(math.exp(f64(-sky.sun_up * sky.sun_up * 22)))
	night := [3]f32{8, 10, 22}
	blue := [3]f32{126, 176, 230}
	warm := [3]f32{232, 126, 64}
	rgb := night + (blue - night)*day
	rgb += warm * glow * (1 - day*0.35)
	return rl.Color{u8(clamp(rgb.x, 0, 255)), u8(clamp(rgb.y, 0, 255)), u8(clamp(rgb.z, 0, 255)), 255}
}

ecliptic_to_equatorial :: proc(v: [3]f64) -> [3]f64 {
	s, c := math.sincos(OBLIQUITY)
	return {v.x, v.y*c - v.z*s, v.y*s + v.z*c}
}

// lst is the right ascension currently on the local meridian.
equatorial_to_world :: proc(eq: [3]f64, lst: f64) -> [3]f32 {
	s, c := math.sincos(lst)
	sl, cl := math.sincos(LATITUDE)
	zenith := [3]f64{cl * c, cl * s, sl}
	east := [3]f64{-s, c, 0}
	north := cross3(zenith, east)
	dir := normalize3(eq)
	return {
		f32(dot3(dir, east)),
		f32(dot3(dir, zenith)),
		f32(dot3(dir, north)),
	}
}

dot3 :: proc(a, b: [3]f64) -> f64 {
	return a.x*b.x + a.y*b.y + a.z*b.z
}

cross3 :: proc(a, b: [3]f64) -> [3]f64 {
	return {a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x}
}

normalize3 :: proc(v: [3]f64) -> [3]f64 {
	length := math.sqrt(dot3(v, v))
	if length == 0 {
		return {0, 1, 0}
	}
	return v / length
}

smoothstep_f :: proc(edge0, edge1, x: f32) -> f32 {
	t := clamp((x-edge0)/(edge1-edge0), 0, 1)
	return t * t * (3 - 2*t)
}

sky_init_stars :: proc() -> (stars: [STAR_COUNT]Star, dot: rl.Texture2D) {
	state: u64 = 0xC0FFEE
	next :: proc(state: ^u64) -> f64 {
		x := state^
		x ~= x << 13
		x ~= x >> 7
		x ~= x << 17
		state^ = x
		return f64(x>>11) / f64(1<<53)
	}
	built: [STAR_COUNT]Star
	for &star in built {
		z := next(&state)*2 - 1
		angle := next(&state) * math.TAU
		ring := math.sqrt(max(0, 1-z*z))
		star.equatorial = {ring * math.cos(angle), ring * math.sin(angle), z}
		star.bright = f32(0.35 + next(&state)*0.65)
	}
	image := rl.GenImageColor(16, 16, rl.BLANK)
	for y in 0 ..< 16 {
		for x in 0 ..< 16 {
			dx := f32(x) - 7.5
			dy := f32(y) - 7.5
			d := math.sqrt(dx*dx + dy*dy) / 7.5
			if d < 1 {
				a := u8((1 - d) * 255)
				rl.ImageDrawPixel(&image, i32(x), i32(y), rl.Color{255, 255, 255, a})
			}
		}
	}
	dot = rl.LoadTextureFromImage(image)
	rl.UnloadImage(image)
	stars = built
	return
}

draw_sky :: proc(camera: rl.Camera3D, sky: Sky, stars: []Star, dot: rl.Texture2D, lst: f64) {
	rlgl.DisableDepthMask()
	defer rlgl.EnableDepthMask()
	if sky.star_fade > 0.04 && dot.id != 0 {
		for star in stars {
			dir := equatorial_to_world(star.equatorial, lst)
			if dir.y <= 0 {
				continue
			}
			fade := sky.star_fade * smoothstep_f(0, 0.06, dir.y) * star.bright
			if fade < 0.05 {
				continue
			}
			pos := camera.position + dir*SKY_RADIUS
			alpha := u8(fade * 255)
			rl.DrawBillboard(camera, dot, pos, 0.45+star.bright*0.7, rl.Color{255, 255, 255, alpha})
		}
	}
	if sky.sun_up > -0.04 {
		pos := camera.position + sky.sun*SKY_RADIUS
		rl.DrawSphere(pos, 7.5, rl.Color{255, 244, 214, 255})
	}
	if sky.moon_up > -0.04 {
		pos := camera.position + sky.moon*SKY_RADIUS
		rl.DrawSphere(pos, 6.2, rl.Color{214, 220, 232, 255})
	}
}

// lst for the stars, matching sky_at.
sky_lst :: proc(time: f64) -> f64 {
	orbit := math.TAU * time / YEAR_LENGTH
	return orbit + math.TAU*time/DAY_LENGTH + SOLAR_PHASE
}

Light_Locs :: struct {
	sun:           c.int,
	moon:          c.int,
	sun_color:     c.int,
	moon_color:    c.int,
	ambient:       c.int,
	sky_fill:      c.int,
	up_dir:        c.int,
	light_vp:      c.int,
	shadow_map:    c.int,
	shadow_texel:  c.int,
	enable:        c.int,
	use_shadow:    c.int,
	shadow_on_sun: c.int,
}

light_locs :: proc(shader: rl.Shader) -> Light_Locs {
	return {
		sun = rl.GetShaderLocation(shader, "sunDir"),
		moon = rl.GetShaderLocation(shader, "moonDir"),
		sun_color = rl.GetShaderLocation(shader, "sunColor"),
		moon_color = rl.GetShaderLocation(shader, "moonColor"),
		ambient = rl.GetShaderLocation(shader, "ambient"),
		sky_fill = rl.GetShaderLocation(shader, "skyFill"),
		up_dir = rl.GetShaderLocation(shader, "upDir"),
		light_vp = rl.GetShaderLocation(shader, "lightVP"),
		shadow_map = rl.GetShaderLocation(shader, "shadowMap"),
		shadow_texel = rl.GetShaderLocation(shader, "shadowTexel"),
		enable = rl.GetShaderLocation(shader, "enableLight"),
		use_shadow = rl.GetShaderLocation(shader, "useShadow"),
		shadow_on_sun = rl.GetShaderLocation(shader, "shadowOnSun"),
	}
}

light_bind :: proc(shader: rl.Shader, locs: Light_Locs, sky: Sky, light_vp: rl.Matrix, enable, use_shadow: f32) {
	if shader.id == 0 {
		return
	}
	sun_amount := smoothstep_f(-0.08, 0.18, sky.sun_up)
	moon_amount := smoothstep_f(-0.05, 0.12, sky.moon_up) * (1 - smoothstep_f(0.02, 0.4, sky.sun_up))
	sun_color := [3]f32{1.05, 0.98, 0.88} * sun_amount
	moon_color := [3]f32{0.45, 0.52, 0.72} * moon_amount * 0.55
	day := smoothstep_f(-0.15, 0.3, sky.sun_up)
	ambient := [3]f32{0.05, 0.055, 0.08} + [3]f32{0.28, 0.30, 0.32}*day
	// Fills the gap between a low sun and an upward face, so the ground stays
	// lit through the day. Zero at night, when sun_amount has fallen off.
	sky_fill := [3]f32{0.85, 0.90, 0.95} * sun_amount
	set3 :: proc(shader: rl.Shader, loc: c.int, v: [3]f32) {
		if loc < 0 {
			return
		}
		value := v
		rl.SetShaderValue(shader, loc, &value, .VEC3)
	}
	set3(shader, locs.sun, sky.sun)
	set3(shader, locs.moon, sky.moon)
	set3(shader, locs.sun_color, sun_color)
	set3(shader, locs.moon_color, moon_color)
	set3(shader, locs.ambient, ambient)
	set3(shader, locs.sky_fill, sky_fill)
	set3(shader, locs.up_dir, {0, 1, 0})
	if locs.light_vp >= 0 {
		rl.SetShaderValueMatrix(shader, locs.light_vp, light_vp)
	}
	if locs.shadow_map >= 0 {
		slot: i32 = 1
		rl.SetShaderValue(shader, locs.shadow_map, &slot, .INT)
	}
	if locs.shadow_texel >= 0 {
		texel := [2]f32{1 / f32(SHADOW_MAP_SIZE), 1 / f32(SHADOW_MAP_SIZE)}
		rl.SetShaderValue(shader, locs.shadow_texel, &texel, .VEC2)
	}
	if locs.enable >= 0 {
		value := enable
		rl.SetShaderValue(shader, locs.enable, &value, .FLOAT)
	}
	if locs.use_shadow >= 0 {
		value := use_shadow
		rl.SetShaderValue(shader, locs.use_shadow, &value, .FLOAT)
	}
	if locs.shadow_on_sun >= 0 {
		on: f32 = 1 if sky.light_on_sun else 0
		rl.SetShaderValue(shader, locs.shadow_on_sun, &on, .FLOAT)
	}
}

// The hand is drawn with the camera cleared, so its normals live in view space.
// The sun has to be rotated the same way, or the hand stays full bright at night.
light_viewmodel :: proc(renderer: ^Renderer, camera: rl.Camera3D, sky: Sky) {
	view := rl.GetCameraMatrix(camera)
	shifted := sky
	shifted.sun = safe_norm(transform_direction(view, sky.sun))
	shifted.moon = safe_norm(transform_direction(view, sky.moon))
	light_bind(renderer.cutout, renderer.cutout_light, shifted, rl.Matrix(1), 1, 0)
	light_bind(renderer.mesh_shader, renderer.mesh_light, shifted, rl.Matrix(1), 1, 0)
	light_bind(renderer.water_shader, renderer.water_light, shifted, rl.Matrix(1), 1, 0)
	up := safe_norm(transform_direction(view, {0, 1, 0}))
	set_up :: proc(shader: rl.Shader, loc: c.int, up: [3]f32) {
		if shader.id == 0 || loc < 0 {
			return
		}
		value := up
		rl.SetShaderValue(shader, loc, &value, .VEC3)
	}
	set_up(renderer.cutout, renderer.cutout_light.up_dir, up)
	set_up(renderer.mesh_shader, renderer.mesh_light.up_dir, up)
	set_up(renderer.water_shader, renderer.water_light.up_dir, up)
}

transform_direction :: proc(m: rl.Matrix, v: [3]f32) -> [3]f32 {
	origin := rl.Vector3Transform({}, m)
	end := rl.Vector3Transform(v, m)
	return end - origin
}

safe_norm :: proc(v: [3]f32) -> [3]f32 {
	length := math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
	if length < 1e-6 {
		return {0, 1, 0}
	}
	return v / length
}

// Fills the shadow map from the light that is up. light_vp is what the color
// pass uses to test the map. Empty when there is nothing to cast from.
render_shadows :: proc(renderer: ^Renderer, world: ^World, client: ^Client, sky: Sky, focus: [3]f32) -> (vp: rl.Matrix, ok: bool) {
	if renderer.shadow_target.id == 0 || renderer.shadow_shader.id == 0 {
		return
	}
	toward := sky.sun if sky.light_on_sun else sky.moon
	if toward.y < 0.05 {
		return
	}
	up := [3]f32{0, 1, 0}
	if abs(toward.y) > 0.92 {
		up = {0, 0, 1}
	}
	eye := focus + toward*SHADOW_REACH
	view := rl.MatrixLookAt(eye, focus, up)
	// Snap the focus to a shadow texel so the map does not shimmer while walking.
	center := rl.Vector3Transform(focus, view)
	texel := (SHADOW_HALF * 2) / f32(SHADOW_MAP_SIZE)
	snapped := [3]f32{
		math.round(center.x/texel) * texel,
		math.round(center.y/texel) * texel,
		center.z,
	}
	delta := rl.Vector3Transform(snapped, rl.MatrixInvert(view)) - focus
	eye += delta
	target := focus + delta
	view = rl.MatrixLookAt(eye, target, up)
	proj := rl.MatrixOrtho(-SHADOW_HALF, SHADOW_HALF, -SHADOW_HALF, SHADOW_HALF, 4, SHADOW_REACH*2)
	vp = proj * view

	rl.BeginTextureMode(renderer.shadow_target)
	rl.ClearBackground(rl.BLACK)
	rlgl.DisableColorBlend()
	rlgl.EnableDepthTest()
	rlgl.EnableDepthMask()
	rlgl.EnableBackfaceCulling()
	rlgl.SetMatrixProjection(proj)
	rlgl.SetMatrixModelview(view)
	draw_shadow_casters(renderer, world, client, focus)
	rlgl.DrawRenderBatchActive()
	rlgl.EnableColorBlend()
	rl.EndTextureMode()
	return vp, true
}

draw_shadow_casters :: proc(renderer: ^Renderer, world: ^World, client: ^Client, focus: [3]f32) {
	cutout: f32 = 0
	rl.SetShaderValue(renderer.shadow_shader, renderer.shadow_cutout, &cutout, .FLOAT)
	limit := SHADOW_HALF + f32(CHUNK_SIZE)
	for key, mesh in renderer.meshes {
		origin := [3]f32{
			f32(key.x*CHUNK_SIZE) + f32(CHUNK_SIZE)*0.5,
			f32(key.y*CHUNK_SIZE) + f32(CHUNK_SIZE)*0.5,
			f32(key.z*CHUNK_SIZE) + f32(CHUNK_SIZE)*0.5,
		}
		if abs(origin.x-focus.x) > limit || abs(origin.z-focus.z) > limit {
			continue
		}
		transform := rl.MatrixTranslate(f32(key.x*CHUNK_SIZE)-0.5, f32(key.y*CHUNK_SIZE), f32(key.z*CHUNK_SIZE)-0.5)
		cutout = 0
		rl.SetShaderValue(renderer.shadow_shader, renderer.shadow_cutout, &cutout, .FLOAT)
		for part in mesh.opaque {
			rl.DrawMesh(part, renderer.shadow_material, transform)
		}
		cutout = 1
		rl.SetShaderValue(renderer.shadow_shader, renderer.shadow_cutout, &cutout, .FLOAT)
		rl.SetMaterialTexture(&renderer.shadow_material, .ALBEDO, renderer.textures.oak_leaves)
		for part in mesh.leaves {
			rl.DrawMesh(part, renderer.shadow_material, transform)
		}
		rl.SetMaterialTexture(&renderer.shadow_material, .ALBEDO, renderer.textures.oak_sapling)
		for part in mesh.plants {
			rl.DrawMesh(part, renderer.shadow_material, transform)
		}
		cutout = 0
		rl.SetShaderValue(renderer.shadow_shader, renderer.shadow_cutout, &cutout, .FLOAT)
		rl.SetMaterialTexture(&renderer.shadow_material, .ALBEDO, renderer.textures.oak_door)
		for part in mesh.doors {
			rl.DrawMesh(part, renderer.shadow_material, transform)
		}
	}

	saved := renderer.player.material.shader
	renderer.player.material.shader = renderer.shadow_shader
	cutout = 1
	rl.SetShaderValue(renderer.shadow_shader, renderer.shadow_cutout, &cutout, .FLOAT)
	draw_remote_players(renderer, client.others[:])
	// The first-person body is not on screen. Casting it paints a dark shape
	// on the ground directly under the crosshair whenever you look down.
	if client.third_person {
		draw_local_player(renderer, client)
	}
	renderer.player.material.shader = saved

	shadow_draw_drops(renderer, client.drops[:])
	shadow_draw_tables(renderer, world, client.tables)
}

shadow_draw_drops :: proc(renderer: ^Renderer, drops: []Drop_View) {
	cutout: f32
	for drop in drops {
		if drop.count <= 0 {
			continue
		}
		hover := 0.04 + math.sin(drop.age*3+drop.phase)*0.03
		spin := rl.MatrixRotateY(drop.age*2.4 + drop.phase)
		place := rl.MatrixTranslate(drop.position.x, drop.position.y+hover, drop.position.z)
		if drop.item.kind != .Block {
			tex := item_sprite(renderer.sprites, drop.item)
			if tex.id == 0 {
				continue
			}
			cutout = 1
			rl.SetShaderValue(renderer.shadow_shader, renderer.shadow_cutout, &cutout, .FLOAT)
			rl.SetMaterialTexture(&renderer.shadow_material, .ALBEDO, tex)
			scale := rl.MatrixScale(0.5, 0.5, 0.5)
			rl.DrawMesh(renderer.item_quad, renderer.shadow_material, place*spin*scale)
			continue
		}
		mesh := &renderer.item_meshes[drop.item.block]
		scale := rl.MatrixScale(DROP_DRAW_SCALE, DROP_DRAW_SCALE, DROP_DRAW_SCALE)
		transform := place * spin * scale
		for surface in Surface {
			if !mesh.filled[surface] || surface_pass(surface) == .Translucent {
				continue
			}
			cutout = 1 if surface_pass(surface) == .Cutout else 0
			rl.SetShaderValue(renderer.shadow_shader, renderer.shadow_cutout, &cutout, .FLOAT)
			rl.SetMaterialTexture(&renderer.shadow_material, .ALBEDO, surface_texture(renderer.textures, surface))
			rl.DrawMesh(mesh.meshes[surface], renderer.shadow_material, transform)
		}
	}
}

shadow_draw_tables :: proc(renderer: ^Renderer, world: ^World, tables: map[[3]int][CRAFT3_N]Slot) {
	if len(tables) == 0 {
		return
	}
	flat := rl.MatrixRotateX(-math.PI * 0.5)
	cell := TABLE_CELL
	rlgl.DisableBackfaceCulling()
	defer rlgl.EnableBackfaceCulling()
	cutout: f32
	for at, grid in tables {
		if get_block(world, at.x, at.y, at.z) != .Workbench {
			continue
		}
		for i in 0 ..< CRAFT3_N {
			slot := grid[i]
			if slot.count <= 0 || item_empty(slot.item) {
				continue
			}
			col := i % 3
			row := i / 3
			place := rl.MatrixTranslate(
				f32(at.x)-0.5+cell[col],
				f32(at.y)+1+0.02,
				f32(at.z)-0.5+cell[row],
			)
			size := rl.MatrixScale(TABLE_ICON, TABLE_ICON, TABLE_ICON)
			transform := place * flat * size
			if slot.item.kind == .Block {
				icon := renderer.icons[slot.item.block]
				if icon.id == 0 {
					continue
				}
				cutout = 1
				rl.SetShaderValue(renderer.shadow_shader, renderer.shadow_cutout, &cutout, .FLOAT)
				rl.SetMaterialTexture(&renderer.shadow_material, .ALBEDO, icon.texture)
				rl.DrawMesh(renderer.item_quad, renderer.shadow_material, transform)
			} else {
				tex := item_sprite(renderer.sprites, slot.item)
				if tex.id == 0 {
					continue
				}
				cutout = 1
				rl.SetShaderValue(renderer.shadow_shader, renderer.shadow_cutout, &cutout, .FLOAT)
				rl.SetMaterialTexture(&renderer.shadow_material, .ALBEDO, tex)
				rl.DrawMesh(renderer.item_quad, renderer.shadow_material, transform)
			}
		}
	}
}

bind_shadow_texture :: proc(renderer: ^Renderer) {
	if renderer.shadow_target.texture.id == 0 {
		return
	}
	rlgl.ActiveTextureSlot(1)
	rlgl.EnableTexture(renderer.shadow_target.texture.id)
	rlgl.ActiveTextureSlot(0)
}
