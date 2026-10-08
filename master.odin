package main

import "core:c"
import "core:math"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

main :: proc() {
	claim_dpi_awareness()

	// Antialiasing is a 4x framebuffer the options screen turns on and off, so the
	// window itself is not multisampled. Resizing still picks the resolution.
	// Hidden until a black frame is presented: showing it any earlier lets Windows
	// paint the new window white for the whole load.
	rl.SetConfigFlags({.WINDOW_HIDDEN, .WINDOW_RESIZABLE})
	rl.InitWindow(WINDOWED_WIDTH, WINDOWED_HEIGHT, "Chudcraft")
	defer rl.CloseWindow()
	// Esc is handled in the frame loop: it closes a screen, or quits.
	rl.SetExitKey(.KEY_NULL)

	rl.BeginDrawing()
	rl.ClearBackground(rl.BLACK)
	rl.EndDrawing()
	rl.DisableCursor()
	rl.ClearWindowState({.WINDOW_HIDDEN})

	// 0 means no maximum. Raylib only limits the rate when asked to.
	rl.SetTargetFPS(0)

	display := Display{width = WINDOWED_WIDTH, height = WINDOWED_HEIGHT}

	hud_font, owned := load_hud_font()
	defer unload_hud_font(hud_font, owned)

	// The server owns the world. This window is one client of it.
	server := server_start(generate_seed())
	defer server_destroy(&server)
	client: Client
	defer client_destroy(&client)
	client_connect(&client, &server)

	renderer := renderer_init()
	defer renderer_destroy(&renderer)

	taa := taa_init()
	defer taa_destroy(&taa)

	msaa: MSAA
	msaa_init(&msaa)
	defer msaa_destroy(&msaa)

	options := Options {
		mipmaps = true,
		taa     = false,
		msaa    = true,
	}

	// Previous frame's update and draw cost, with the frame limiter's wait left out.
	work_seconds: f64

	// Loop until the user closes the window or presses Escape.
	quit := false
	for !quit && !rl.WindowShouldClose() {
		frame_start := rl.GetTime()
		update_display(&display)
		want_close := false
		if rl.IsKeyPressed(.E) && !options.open {
			if client.inventory.open {
				want_close = true
			} else {
				inventory_open_screen(&client.inventory)
			}
		}
		if rl.IsKeyPressed(.O) && !client.inventory.open {
			options_toggle(&options)
		}
		if rl.IsKeyPressed(.ESCAPE) {
			if options.open {
				options_close(&options)
			} else if client.inventory.open {
				want_close = true
			} else {
				quit = true
			}
		}
		options_handle_click(&options, renderer.textures, &taa)

		playing := !options.open && !client.inventory.open
		look_player(&client.player, playing && !options.suppress_look && !client.inventory.suppress_look)

		frame_dt := f64(rl.GetFrameTime())
		dt := min(f32(frame_dt), 0.05)
		input := client_read_input(client.player, playing, client.inventory.open, client.inventory.selected, dt)
		if want_close {
			input.action = .Stow
		}
		command := [1]Player_Command{{id = client.id, input = input}}
		grown := server_step(&server, command[:], frame_dt)
		client_pull(&client)
		if want_close && client.inventory.held.count == 0 {
			inventory_close_screen(&client.inventory)
		}
		options.suppress_look = false
		client.inventory.suppress_look = false
		camera := camera_from_player(client.player)
		look := camera.target - camera.position
		hit, bx, by, bz, _, _, _ := raycast_block(&client.world, camera.position, look, MINE_REACH)

		// Start a new frame.
		rl.BeginDrawing()
		// Fill the background with sky blue.
		rl.ClearBackground(rl.SKYBLUE)

		// The world is jittered and accumulated when those options are on. The HUD
		// stays on the backbuffer, after the resolve, so the crosshair and text
		// are not blended across frames.
		taa_begin(&taa, &msaa, camera, options.taa, options.msaa)
		draw_world(&renderer, &client.world)
		draw_drops(&renderer, client.drops[:])
		draw_remote_players(&renderer, client.others[:])
		if playing && hit {
			draw_block_highlight(bx, by, bz, camera.position)
		}
		taa_resolve(&taa, &msaa)

		if playing {
			draw_crosshair()
		}
		draw_fps(hud_font, 8, 8)
		draw_frame_time(hud_font, 8, 30)
		draw_extrapolated_fps(hud_font, 8, 52, work_seconds)
		draw_world_seed(hud_font, 8, 74, client.seed)
		draw_block_updates(hud_font, 8, 96, grown, grow_queued(&server.world))
		draw_player_position(hud_font, client.player)
		draw_player_direction(hud_font, client.player)
		draw_inventory(hud_font, &renderer, client.inventory)
		if options.open {
			draw_options(hud_font, options)
		}

		// Sampled here because EndDrawing is where raylib waits out the frame limiter,
		// and that wait is exactly what this measurement has to exclude.
		work_seconds = rl.GetTime() - frame_start

		// Finish the frame and show it.
		rl.EndDrawing()
	}
}

WINDOWED_WIDTH  :: 1280
WINDOWED_HEIGHT :: 720

// Borderless fullscreen covers the current monitor. Exclusive fullscreen is never used.
Display :: struct {
	// The last windowed size, restored on the way back out of borderless.
	width:      c.int,
	height:     c.int,
	borderless: bool,
}

update_display :: proc(display: ^Display) {
	// Track whatever size the window was dragged to, so leaving borderless returns to it.
	if !display.borderless {
		display.width = rl.GetScreenWidth()
		display.height = rl.GetScreenHeight()
	}

	if !rl.IsKeyPressed(.F11) {
		return
	}

	rl.ToggleBorderlessWindowed()
	display.borderless = !display.borderless
	if !display.borderless {
		rl.SetWindowSize(display.width, display.height)
	}
}

HUD_SIZE :: f32(20)
HUD_SPACING :: f32(0)

// White pixels blended as (1 - destination) invert whatever is behind the crosshair.
draw_crosshair :: proc() {
	rlgl.SetBlendFactorsSeparate(
		rlgl.ONE_MINUS_DST_COLOR, rlgl.ZERO,
		rlgl.ZERO, rlgl.ONE,
		rlgl.FUNC_ADD, rlgl.FUNC_ADD,
	)
	rl.BeginBlendMode(.CUSTOM_SEPARATE)

	center_x := rl.GetScreenWidth() / 2
	center_y := rl.GetScreenHeight() / 2
	// A positive gap splits the arms and leaves the center pixel unchanged.
	gap: c.int = 0
	arm: c.int = 8
	thick: c.int = 2

	rl.DrawRectangle(center_x - gap - arm, center_y - thick / 2, arm, thick, rl.WHITE)
	rl.DrawRectangle(center_x + gap, center_y - thick / 2, arm, thick, rl.WHITE)
	rl.DrawRectangle(center_x - thick / 2, center_y - gap - arm, thick, arm, rl.WHITE)
	rl.DrawRectangle(center_x - thick / 2, center_y + gap, thick, arm, rl.WHITE)

	rl.EndBlendMode()
}

// One shifted copy. Drawing a black glyph on every side fills the letter in.
draw_hud_text :: proc(font: rl.Font, text: cstring, x, y: c.int, color: rl.Color) {
	rl.DrawTextEx(font, text, {f32(x + 1), f32(y + 1)}, HUD_SIZE, HUD_SPACING, rl.BLACK)
	rl.DrawTextEx(font, text, {f32(x), f32(y)}, HUD_SIZE, HUD_SPACING, color)
}

draw_fps :: proc(font: rl.Font, x, y: c.int) {
	fps := rl.GetFPS()
	text := rl.TextFormat("%d FPS", fps)

	color := rl.GREEN
	if fps < 30 do color = rl.ORANGE
	if fps < 15 do color = rl.RED

	draw_hud_text(font, text, x, y, color)
}

// Averaged, because a raw frame time is unreadable at several hundred FPS. The peak
// is what catches a single slow frame, like a chunk remesh, that an average hides.
// It resets every second so it describes now rather than the worst frame ever seen.
draw_frame_time :: proc(font: rl.Font, x, y: c.int) {
	@(static) average: f32
	@(static) peak: f32
	@(static) peak_age: f32

	dt := rl.GetFrameTime()
	average = dt if average == 0 else average*0.9 + dt*0.1

	peak = max(peak, dt)
	peak_age += dt
	if peak_age >= 1 {
		peak = dt
		peak_age = 0
	}

	// Same thresholds as the FPS line, so the two always agree on the color.
	color := rl.GREEN
	if average > 1.0/30 do color = rl.ORANGE
	if average > 1.0/15 do color = rl.RED

	text := rl.TextFormat("%.2f ms  peak %.2f", average*1000, peak*1000)
	draw_hud_text(font, text, x, y, color)
}

// A capped frame time measures the cap, not the machine, because both SetTargetFPS
// and vsync spend the difference waiting inside EndDrawing. Inverting just the update
// and draw work stays meaningful whether or not a limit is on.
// This reads higher than the real frame rate even with no cap, because the buffer
// swap happens inside EndDrawing too and is therefore not counted.
draw_extrapolated_fps :: proc(font: rl.Font, x, y: c.int, work_seconds: f64) {
	@(static) average: f64

	if work_seconds > 0 {
		average = work_seconds if average == 0 else average*0.9 + work_seconds*0.1
	}
	if average <= 0 {
		return
	}

	fps := int(1 / average)

	// Same thresholds as the other two lines.
	color := rl.GREEN
	if fps < 30 do color = rl.ORANGE
	if fps < 15 do color = rl.RED

	text := rl.TextFormat("%d FPS extrapolated  %.2f ms work", fps, average*1000)
	draw_hud_text(font, text, x, y, color)
}

// Totals and the peak are the second that just finished, so the two lines describe
// the same moment. The peak is the busiest single frame in that second.
draw_block_updates :: proc(font: rl.Font, x, y: c.int, grown: Grow_Report, queued: int) {
	@(static) sec_grass, sec_leaves: int
	@(static) show_grass, show_leaves: int
	@(static) peak, show_peak: int
	@(static) age: f32

	frame := grown.grass + grown.leaves
	sec_grass += grown.grass
	sec_leaves += grown.leaves
	peak = max(peak, frame)

	age += rl.GetFrameTime()
	if age >= 1 {
		show_grass = sec_grass
		show_leaves = sec_leaves
		show_peak = peak
		sec_grass = 0
		sec_leaves = 0
		peak = 0
		age = 0
	}

	// Red when a frame used the whole budget, which is the catch-up cap.
	color := rl.GREEN
	if show_peak >= GROW_BUDGET/2 do color = rl.ORANGE
	if show_peak >= GROW_BUDGET do color = rl.RED

	total := show_grass + show_leaves
	text := rl.TextFormat("%d block updates/s  peak %d", c.int(total), c.int(show_peak))
	draw_hud_text(font, text, x, y, color)

	text = rl.TextFormat("grass %d  leaves %d", c.int(show_grass), c.int(show_leaves))
	draw_hud_text(font, text, x, y+22, rl.WHITE)

	text = rl.TextFormat("queued %d", c.int(queued))
	draw_hud_text(font, text, x, y+44, rl.WHITE)
}

draw_world_seed :: proc(font: rl.Font, x, y: c.int, seed: i64) {
	text := rl.TextFormat("Seed %lld", seed)
	draw_hud_text(font, text, x, y, rl.WHITE)
}

draw_player_position :: proc(font: rl.Font, player: Player) {
	margin: c.int = 8
	screen_w := rl.GetScreenWidth()
	labels := [3]string{"X", "Y", "Z"}

	for i in 0 ..< 3 {
		text := rl.TextFormat("%s %6.2f", labels[i], player.position[i])
		width := c.int(rl.MeasureTextEx(font, text, HUD_SIZE, HUD_SPACING).x)
		draw_hud_text(font, text, screen_w - width - margin, margin + c.int(i) * 22, rl.WHITE)
	}
}

// Yaw 0 looks along +Z, and positive yaw turns toward +X. Same basis as the camera.
draw_player_direction :: proc(font: rl.Font, player: Player) {
	margin: c.int = 8
	screen_w := rl.GetScreenWidth()
	y := margin + 3*22

	// -Z is north and +X is east, same as Minecraft. Each name covers 45 degrees.
	sx := math.sin(player.yaw)
	sz := math.cos(player.yaw)
	sector := int(math.floor((math.atan2(sx, -sz) + math.PI/8) / (math.PI/4))) %% 8
	axes := [8]cstring{"-Z", "+X -Z", "+X", "+X +Z", "+Z", "-X +Z", "-X", "-X -Z"}
	names := [8]cstring{"North", "Northeast", "East", "Southeast", "South", "Southwest", "West", "Northwest"}

	yaw := math.mod(player.yaw*180/math.PI, 360)
	if yaw < 0 do yaw += 360
	if yaw > 180 do yaw -= 360
	pitch := player.pitch * 180 / math.PI

	text := rl.TextFormat("Facing %s %s", axes[sector], names[sector])
	width := c.int(rl.MeasureTextEx(font, text, HUD_SIZE, HUD_SPACING).x)
	draw_hud_text(font, text, screen_w-width-margin, y, rl.WHITE)

	text = rl.TextFormat("Yaw %7.2f", yaw)
	width = c.int(rl.MeasureTextEx(font, text, HUD_SIZE, HUD_SPACING).x)
	draw_hud_text(font, text, screen_w-width-margin, y+22, rl.WHITE)

	text = rl.TextFormat("Pitch %7.2f", pitch)
	width = c.int(rl.MeasureTextEx(font, text, HUD_SIZE, HUD_SPACING).x)
	draw_hud_text(font, text, screen_w-width-margin, y+44, rl.WHITE)
}

load_hud_font :: proc() -> (font: rl.Font, owned: bool) {
	font = rl.LoadFontEx("assets/JetBrainsMono-Regular.ttf", 20, nil, 0)
	if font.glyphCount <= 0 {
		return rl.GetFontDefault(), false
	}
	return font, true
}

unload_hud_font :: proc(font: rl.Font, owned: bool) {
	if owned {
		rl.UnloadFont(font)
	}
}
