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
	// The title screen needs the cursor. Play grabs it when a world starts.
	rl.EnableCursor()
	rl.ClearWindowState({.WINDOW_HIDDEN})

	// 0 means no maximum. Raylib only limits the rate when asked to.
	rl.SetTargetFPS(0)

	display := Display{width = WINDOWED_WIDTH, height = WINDOWED_HEIGHT}

	hud_font, owned := load_hud_font()
	defer unload_hud_font(hud_font, owned)

	// The world stays unbuilt until Play, Host, or a successful join. Esc from a
	// world comes back here, so this window can host and then join someone else.
	server: Server
	client: Client
	defer session_stop(&server, &client)
	menu: Menu
	menu_init(&menu)
	front := Front.Title
	want_host := false
	commands: [dynamic]Player_Command
	defer delete(commands)
	// Closing the inventory asks the server to stow the cursor stack first.
	// A joined game hears about that a frame later, so the request has to wait.
	pending_close := false

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

	// Loop until the window closes. Esc on the title quits; in a world it leaves.
	quit := false
	for !quit && !rl.WindowShouldClose() {
		frame_start := rl.GetTime()
		update_display(&display)

		// The generating line was drawn last frame, so this hitch keeps it up.
		if front == .Generating && menu.paint_gen {
			if session_boot(&server, &client, want_host, &menu) {
				front = .Playing
				rl.DisableCursor()
				options.suppress_look = true
			} else {
				front = .Title
				rl.EnableCursor()
			}
			menu.paint_gen = false
		}
		if front == .Connecting && menu.dial_armed && client.link == nil {
			if reason := client_dial(&client, menu_address(&menu)); reason != "" {
				menu_set_status(&menu, reason)
				front = .Join
				menu.dial_armed = false
			}
		}
		if front == .Connecting && client.link != nil {
			if client_link_pump(&client) {
				front = .Playing
				rl.DisableCursor()
				options.suppress_look = true
				menu.dial_armed = false
			} else if client.link.failed {
				copy_link_reason(&menu, &client)
				session_stop(&server, &client)
				front = .Join
				menu.dial_armed = false
				rl.EnableCursor()
			}
		}

		if rl.IsKeyPressed(.ESCAPE) {
			switch front {
			case .Title:
				quit = true
			case .Join:
				front = .Title
			case .Connecting:
				session_stop(&server, &client)
				front = .Join
				menu.dial_armed = false
				rl.EnableCursor()
			case .Generating:
				front = .Title
				menu.paint_gen = false
			case .Playing:
			}
		}

		if front == .Title || front == .Join {
			#partial switch menu_update(&menu, front) {
			case .Play:
				want_host = false
				menu.paint_gen = false
				menu_clear_status(&menu)
				front = .Generating
			case .Host:
				want_host = true
				menu.paint_gen = false
				menu_clear_status(&menu)
				front = .Generating
			case .Join:
				menu_clear_status(&menu)
				front = .Join
			case .Connect:
				if menu.address_len == 0 {
					menu_set_status(&menu, "Enter an address.")
				} else {
					menu.dial_armed = true
					menu_clear_status(&menu)
					front = .Connecting
				}
			case .Back:
				menu_clear_status(&menu)
				front = .Title
			}
		}

		playing := false
		hit := false
		bx, by, bz: int
		grown: Grow_Report
		camera: rl.Camera3D
		show_self := false
		if front == .Playing {
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
			if rl.IsKeyPressed(.V) {
				client.third_person = !client.third_person
			}
			if rl.IsKeyPressed(.ESCAPE) {
				if options.open {
					options_close(&options)
				} else if client.inventory.open {
					want_close = true
				} else {
					session_stop(&server, &client)
					options.open = false
					pending_close = false
					front = .Title
					rl.EnableCursor()
				}
			}
			if front == .Playing {
				options_handle_click(&options, renderer.textures, renderer.sprites, &taa)
				// Right-click on a crafting table opens its grid instead of placing
				// against it. The open has to land before the look, so this frame's
				// cursor warp is thrown away with the other screens.
				opened_table := false
				if !options.open && !client.inventory.open && rl.IsMouseButtonPressed(.RIGHT) {
					eye := camera_from_player(client.player)
					look := eye.target - eye.position
					thit, tx, ty, tz, _, _, _ := raycast_block(&client.world, eye.position, look, MINE_REACH)
					if thit && get_block(&client.world, tx, ty, tz) == .Crafting_Table {
						inventory_open_table(&client.inventory)
						opened_table = true
					}
				}
				playing = !options.open && !client.inventory.open
				look_player(&client.player, playing && !options.suppress_look && !client.inventory.suppress_look)

				frame_dt := f64(rl.GetFrameTime())
				dt := min(f32(frame_dt), 0.05)
				// The click that opened the table is not also a click inside it.
				screen_open := client.inventory.open && !opened_table
				input := client_read_input(client.player, playing, screen_open, client.inventory.table, client.inventory.selected, dt)
				if want_close {
					input.action = .Stow
					pending_close = true
				}
				if client.server != nil {
					clear(&commands)
					append(&commands, Player_Command{id = client.id, input = input})
					host_pump(&server, &commands)
					grown = server_step(&server, commands[:], frame_dt)
					host_broadcast(&server)
					client_pull(&client)
				} else if !client_send_input(&client, input) || !client_link_pump(&client) {
					copy_link_reason(&menu, &client)
					session_stop(&server, &client)
					options.open = false
					pending_close = false
					front = .Join
					rl.EnableCursor()
				}
				if front == .Playing && pending_close && client.inventory.held.count == 0 {
					inventory_close_screen(&client.inventory)
					pending_close = false
				}
				options.suppress_look = false
				client.inventory.suppress_look = false
				if front == .Playing {
					advance_walk_cycles(&client, dt)
					// Mining stays on the eye ray. Third person only moves the view.
					eye := camera_from_player(client.player)
					camera = eye
					if client.third_person {
						distance: f32
						camera, distance = camera_behind(&client.world, client.player)
						show_self = distance >= THIRD_PERSON_HIDE
					}
					look := eye.target - eye.position
					hit, bx, by, bz, _, _, _ = raycast_block(&client.world, eye.position, look, MINE_REACH)
				}
			}
		}

		// Start a new frame.
		rl.BeginDrawing()
		if front == .Playing {
			// Fill the background with sky blue.
			rl.ClearBackground(rl.SKYBLUE)

			// The world is jittered and accumulated when those options are on. The HUD
			// stays on the backbuffer, after the resolve, so the crosshair and text
			// are not blended across frames.
			taa_begin(&taa, &msaa, camera, options.taa, options.msaa)
			draw_world(&renderer, &client.world)
			draw_drops(&renderer, client.drops[:], .Opaque)
			draw_drops(&renderer, client.drops[:], .Cutout)
			draw_remote_players(&renderer, client.others[:])
			if show_self {
				draw_local_player(&renderer, &client)
			}
			draw_water(&renderer)
			draw_drops(&renderer, client.drops[:], .Translucent)
			if playing && hit {
				draw_block_highlight(bx, by, bz, camera.position)
			}
			taa_resolve(&taa, &msaa)

			// After the resolve, so clearing depth cannot wipe the buffer the
			// temporal pass just read. Third person already draws the body.
			if !client.third_person {
				draw_viewmodel(&renderer, camera, equipped_item(&client.inventory))
			}

			if playing {
				draw_crosshair()
			}
			draw_fps(hud_font, 8, 8)
			draw_frame_time(hud_font, 8, 30)
			draw_extrapolated_fps(hud_font, 8, 52, work_seconds)
			draw_world_seed(hud_font, 8, 74, client.seed)
			if client.server != nil {
				draw_block_updates(hud_font, 8, 96, grown, grow_queued(&server.world))
				draw_host_banner(hud_font, &server)
			} else {
				draw_hud_text(hud_font, "Joined", 8, 96, rl.WHITE)
			}
			draw_player_position(hud_font, client.player)
			draw_player_direction(hud_font, client.player)
			draw_inventory(hud_font, &renderer, client.inventory)
			if options.open {
				draw_options(hud_font, options)
			}
		} else {
			draw_front(hud_font, &menu, front)
			if front == .Generating {
				menu.paint_gen = true
			}
		}

		// Sampled here because EndDrawing is where raylib waits out the frame limiter,
		// and that wait is exactly what this measurement has to exclude.
		work_seconds = rl.GetTime() - frame_start

		// Finish the frame and show it.
		rl.EndDrawing()
	}
}

session_boot :: proc(server: ^Server, client: ^Client, host: bool, menu: ^Menu) -> bool {
	server^ = server_start(generate_seed())
	if host {
		if reason := host_listen(server); reason != "" {
			server_destroy(server)
			server^ = {}
			menu_set_status(menu, reason)
			return false
		}
	}
	client_connect(client, server)
	return true
}

session_stop :: proc(server: ^Server, client: ^Client) {
	client_destroy(client)
	server_destroy(server)
	client^ = {}
	server^ = {}
}

copy_link_reason :: proc(menu: ^Menu, client: ^Client) {
	link := client.link
	if link == nil || link.reason[0] == 0 {
		menu_set_status(menu, "Lost the connection to the host.")
		return
	}
	n := 0
	for n < len(link.reason) && link.reason[n] != 0 {
		n += 1
	}
	menu_set_status(menu, string(link.reason[:n]))
}

draw_host_banner :: proc(font: rl.Font, server: ^Server) {
	if !server.host.listening || server.host.join_at[0] == 0 {
		return
	}
	text := rl.TextFormat("Others can join at %s", cstring(raw_data(server.host.join_at[:])))
	draw_hud_text(font, text, 8, 162, rl.WHITE)
	y: c.int = 184
	if server.host.lan {
		local := rl.TextFormat("Same computer: 127.0.0.1:%d", c.int(server.host.port))
		draw_hud_text(font, local, 8, y, rl.WHITE)
		y += 22
	}
	others := len(server.players) - 1
	if others == 0 {
		draw_hud_text(font, "Waiting for others", 8, y, rl.WHITE)
	} else if others == 1 {
		draw_hud_text(font, "1 other player", 8, y, rl.WHITE)
	} else {
		text = rl.TextFormat("%d other players", c.int(others))
		draw_hud_text(font, text, 8, y, rl.WHITE)
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
