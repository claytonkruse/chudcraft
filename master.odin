package main

import "core:c"
import "core:fmt"
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

	audio := sound_init()
	defer sound_destroy(&audio)
	ears = &audio
	defer ears = nil

	display := Display{width = WINDOWED_WIDTH, height = WINDOWED_HEIGHT}

	hud_font, owned := load_hud_font()
	defer unload_hud_font(hud_font, owned)

	// The world stays unbuilt until a saved world is opened, or a join succeeds.
	// Esc in a world pauses it. Hosting is a button on that pause menu.
	server: Server
	client: Client
	menu: Menu
	menu_init(&menu)
	defer delete(menu.cards)
	defer delete(menu.servers)
	defer session_shutdown(&server, &client, &menu)
	front := Front.Title
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
		render_distance = RENDER_DISTANCE,
		mipmaps         = true,
		taa             = false,
		msaa            = true,
	}
	paused := false

	// Previous frame's update and draw cost, with the frame limiter's wait left out.
	work_seconds: f64

	// Loop until the window closes. Esc on the title quits; in a world it leaves.
	quit := false
	for !quit && !rl.WindowShouldClose() {
		frame_start := rl.GetTime()
		update_display(&display)

		// The generating line was drawn last frame, so this hitch keeps it up.
		if front == .Generating && menu.paint_gen {
			if session_boot(&server, &client, &menu, options.render_distance) {
				front = .Playing
				rl.DisableCursor()
				options.suppress_look = true
			} else {
				front = .Worlds
				rl.EnableCursor()
			}
			menu.paint_gen = false
		}
		if front == .Connecting && menu.dial_armed && client.link == nil {
			if reason := client_dial(&client, menu_address(&menu), options.render_distance); reason != "" {
				menu_set_status(&menu, reason)
				front = .Join
				menu.dial_armed = false
			}
		}
		if front == .Connecting && client.link != nil {
			if client_link_pump(&client, options.render_distance) {
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
			case .Worlds:
				front = .Title
			case .Create:
				front = .Worlds
			case .Join:
				front = .Title
			case .Server_Add:
				front = .Join
			case .Connecting:
				session_stop(&server, &client)
				front = .Join
				menu.dial_armed = false
				rl.EnableCursor()
			case .Generating:
				front = .Worlds
				menu.paint_gen = false
			case .Playing:
			}
		}

		if front == .Title || front == .Worlds || front == .Create || front == .Join || front == .Server_Add {
			action := menu_update(&menu, front)
			if action != .None {
				sound_ui()
			}
			switch action {
			case .None:
			case .My_Worlds:
				worlds_scan(&menu.cards)
				menu.scroll = 0
				menu_clear_status(&menu)
				front = .Worlds
			case .Join_World:
				menu_clear_status(&menu)
				front = .Join
			case .New_World:
				menu_set_name(&menu, "World")
				menu_clear_status(&menu)
				front = .Create
			case .Create:
				if menu.name_len == 0 {
					menu_set_status(&menu, "Name the world.")
				} else if card, ok := world_card_new(menu_world_name(&menu)); ok {
					menu.current = card
					menu.fresh = true
					menu.paint_gen = false
					menu_clear_status(&menu)
					front = .Generating
				} else {
					menu_set_status(&menu, "Name the world.")
				}
			case .Open_World:
				if menu.picked >= 0 && menu.picked < len(menu.cards) {
					menu.current = menu.cards[menu.picked]
					menu.fresh = false
					menu.paint_gen = false
					menu_clear_status(&menu)
					front = .Generating
				}
			case .Add_Server:
				menu_set_name(&menu, "")
				addr: [64]byte
				addr_text := fmt.bprintf(addr[:], "127.0.0.1:%d", NET_PORT)
				menu_set_address(&menu, addr_text)
				menu.focus = 0
				menu_clear_status(&menu)
				front = .Server_Add
			case .Save_Server:
				if menu.name_len == 0 {
					menu_set_status(&menu, "Name the server.")
				} else if menu.address_len == 0 {
					menu_set_status(&menu, "Enter an address.")
				} else if len(menu.servers) >= SERVERS_MAX {
					menu_set_status(&menu, "The server list is full.")
				} else if entry, made := server_entry_from(menu_world_name(&menu), menu_address(&menu)); made && servers_add(&menu.servers, entry) {
					menu.scroll = 0
					menu_clear_status(&menu)
					front = .Join
				} else {
					menu_set_status(&menu, "Could not save the server list.")
				}
			case .Remove_Server:
				if !servers_remove(&menu.servers, menu.picked) {
					menu_set_status(&menu, "Could not save the server list.")
				} else {
					menu_clear_status(&menu)
				}
			case .Connect:
				if front == .Join {
					if menu.picked < 0 || menu.picked >= len(menu.servers) {
						break
					}
					menu_set_address(&menu, server_entry_address(&menu.servers[menu.picked]))
				}
				if menu.address_len == 0 {
					menu_set_status(&menu, "Enter an address.")
				} else {
					menu.dial_armed = true
					menu_clear_status(&menu)
					front = .Connecting
				}
			case .Back:
				menu_clear_status(&menu)
				if front == .Create {
					front = .Worlds
				} else if front == .Server_Add {
					front = .Join
				} else {
					front = .Title
				}
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
			local_world := client.server != nil
			// The click that opens Settings is not also a click on a setting.
			options_were_open := options.open
			if rl.IsKeyPressed(.E) && !options.open && !paused && !client.chat.open {
				if client.inventory.open {
					want_close = true
				} else {
					inventory_open_screen(&client.inventory)
				}
			}
			if rl.IsKeyPressed(.O) && !client.inventory.open && !client.chat.open {
				options_toggle(&options)
				// Pause keeps the cursor. Closing settings from there must not grab it.
				if paused {
					rl.EnableCursor()
				}
			}
			if rl.IsKeyPressed(.V) && !paused && !client.chat.open {
				client.third_person = !client.third_person
			}
			if rl.IsKeyPressed(.ESCAPE) {
				if client.chat.open {
					chat_close(&client.chat)
				} else if options.open {
					options_close(&options)
					if paused {
						rl.EnableCursor()
					}
				} else if client.inventory.open {
					want_close = true
				} else if paused {
					paused = false
					options.suppress_look = true
					rl.DisableCursor()
				} else {
					paused = true
					options.suppress_look = true
					menu_clear_status(&menu)
					rl.EnableCursor()
				}
			}
			if paused && !options.open && front == .Playing {
				action := pause_click(&menu, local_world)
				if action != .None {
					sound_ui()
				}
				#partial switch action {
				case .Resume:
					paused = false
					options.suppress_look = true
					rl.DisableCursor()
				case .Host:
					if server.host.listening {
						host_shutdown(&server)
						menu_clear_status(&menu)
					} else if reason := host_listen(&server); reason != "" {
						menu_set_status(&menu, reason)
					} else {
						menu_clear_status(&menu)
					}
				case .Settings:
					if !options.open {
						options_toggle(&options)
					}
				case .Leave:
					if local_world && !world_save(&server, &menu.current, client.id) {
						menu_set_status(&menu, "Could not save the world.")
					} else {
						session_stop(&server, &client)
						paused = false
						options.open = false
						pending_close = false
						menu_clear_status(&menu)
						if local_world {
							worlds_scan(&menu.cards)
							front = .Worlds
						} else {
							front = .Title
						}
						rl.EnableCursor()
					}
				}
			}
			if front == .Playing {
				if options_were_open {
					options_handle_click(&options, renderer.textures, renderer.atlas, renderer.sprites, &taa)
				}
				// Right-click on a workbench opens its grid instead of placing
				// against it. The open has to land before the look, so this frame's
				// cursor warp is thrown away with the other screens.
				opened_table := false
				if !options.open && !paused && !client.inventory.open && !client.chat.open && rl.IsMouseButtonPressed(.RIGHT) {
					eye := camera_from_player(client.player)
					look := eye.target - eye.position
					thit, tx, ty, tz, _, _, _ := raycast_block(&client.world, eye.position, look, MINE_REACH)
					if thit && get_block(&client.world, tx, ty, tz) == .Workbench {
						inventory_open_table(&client.inventory)
						client.table_at = {tx, ty, tz}
						opened_table = true
					}
				}
				said: [CHAT_LINE]byte
				said_n := chat_type(&client.chat, !options.open && !paused && !client.inventory.open, said[:])
				playing = !options.open && !paused && !client.inventory.open && !client.chat.open
				look_player(&client.player, playing && !options.suppress_look && !client.inventory.suppress_look)

				frame_dt := f64(rl.GetFrameTime())
				dt := min(f32(frame_dt), 0.05)
				chat_tick(&client.chat, dt)
				chat_welcome(&client.chat, client.id)
				// The click that opened the table is not also a click inside it.
				screen_open := client.inventory.open && !opened_table
				input := client_read_input(client.player, playing, client.chat.open, screen_open, client.inventory.table, client.inventory, &client.drag, &client.clicks, &client.place_delay, client.inventory.selected, dt)
				// A held click repeats a place. A door should swing once per press,
				// or holding the button chatters it open and shut.
				if input.use && !rl.IsMouseButtonPressed(.RIGHT) {
					eye := camera_from_player(client.player)
					look := eye.target - eye.position
					dhit, dx, dy, dz, _, _, _ := raycast_block(&client.world, eye.position, look, MINE_REACH)
					if dhit && block_is_door(get_block(&client.world, dx, dy, dz)) {
						input.use = false
					}
				}
				// A pause freezes the body. dt of zero skips gravity for this player
				// without stopping the world, or anyone else who is still playing.
				if paused {
					yaw := input.move.yaw
					pitch := input.move.pitch
					input = {}
					input.move.yaw = yaw
					input.move.pitch = pitch
				}
				if opened_table {
					input.action = .Open_Table
					input.table_x = client.table_at.x
					input.table_y = client.table_at.y
					input.table_z = client.table_at.z
				}
				input.render_distance = options.render_distance
				if want_close {
					input.action = .Stow
					client.drag = {}
					pending_close = true
				}
				if said_n > 0 {
					n := said_n
					if n > len(input.say) {
						n = len(input.say)
					}
					copy(input.say[:n], said[:n])
					input.say_n = n
				}
				if client.server != nil {
					clear(&commands)
					append(&commands, Player_Command{id = client.id, input = input})
					host_pump(&server, &commands)
					grown = server_step(&server, commands[:], frame_dt)
					host_broadcast(&server)
					client_pull(&client, options.render_distance)
				} else if !client_send_input(&client, input) || !client_link_pump(&client, options.render_distance) {
					copy_link_reason(&menu, &client)
					session_stop(&server, &client)
					options.open = false
					paused = false
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
					sound_bodies(&audio, &client.world, client.player, client.id, client.others[:], client.walks)
					swing := client.mine.swing
					digging := client.mine.on
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
					advance_mine(&client.mine, &client.world, equipped_item(&client.inventory), playing && input.attack, hit, bx, by, bz, dt)
					// A wrap is one impact. The break itself arrives with the block edit.
					if digging && client.mine.on && client.mine.swing < swing {
						sound_strike(&audio, &client.world, client.mine.x, client.mine.y, client.mine.z)
					}
				}
			}
		}

		// Start a new frame.
		rl.BeginDrawing()
		if front == .Playing {
			sky_time := client.sky_time
			if client.server != nil {
				sky_time = server.world.time
			}
			sky := sky_at(sky_time)
			sky_color := sky_clear(sky)
			rl.ClearBackground(sky_color)

			feet := client.player.position
			focus := chunk_of(
				block_index_horizontal(feet.x),
				block_index_vertical(feet.y),
				block_index_horizontal(feet.z),
			)
			// Build the meshes the shadow pass and the color pass both draw.
			mesh_dirty(&renderer, &client.world, focus)
			light_focus := feet + [3]f32{0, 1, 0}
			light_vp, shadowed := render_shadows(&renderer, &client.world, &client, sky, light_focus)
			use_shadow: f32 = 1 if shadowed else 0
			light_bind(renderer.atlas_shader, renderer.atlas_light, sky, light_vp, 1, use_shadow)
			light_bind(renderer.cutout, renderer.cutout_light, sky, light_vp, 1, use_shadow)
			light_bind(renderer.mesh_shader, renderer.mesh_light, sky, light_vp, 1, use_shadow)
			light_bind(renderer.water_shader, renderer.water_light, sky, light_vp, 1, use_shadow)

			// The world is jittered and accumulated when those options are on. The HUD
			// stays on the backbuffer, after the resolve, so the crosshair and text
			// are not blended across frames.
			taa_begin(&taa, &msaa, camera, options.taa, options.msaa, sky_color)
			if shadowed {
				// After the scene target is bound. An earlier bind is dropped when
				// that target is attached.
				bind_shadow_texture(&renderer)
			}
			draw_sky(camera, sky, renderer.stars[:], renderer.star_dot, sky_lst(sky_time))
			draw_world(&renderer, &client.world, camera, focus, client.retired[:])
			clear(&client.retired)
			draw_table_items(&renderer, &client.world, client.tables)
			draw_drops(&renderer, client.drops[:], .Opaque)
			draw_drops(&renderer, client.drops[:], .Cutout)
			draw_remote_players(&renderer, client.others[:])
			if show_self {
				draw_local_player(&renderer, &client)
			}
			if client.mine.on && client.mine.time > 0 {
				block := get_block(&client.world, client.mine.x, client.mine.y, client.mine.z)
				need := mine_seconds(block, client.mine.tool)
				stage := int(client.mine.time / need * f32(BREAK_STAGES))
				if stage >= BREAK_STAGES {
					stage = BREAK_STAGES - 1
				}
				draw_break_cracks(&renderer, client.mine.x, client.mine.y, client.mine.z, stage, block)
			}
			draw_water(&renderer, f32(sky_time))
			draw_drops(&renderer, client.drops[:], .Translucent)
			if playing && hit {
				draw_block_highlight(bx, by, bz, camera.position, get_block(&client.world, bx, by, bz))
			}
			taa_resolve(&taa, &msaa)

			// After the resolve, so clearing depth cannot wipe the buffer the
			// temporal pass just read. Third person already draws the body.
			if !client.third_person {
				// The viewmodel is drawn in view space. Rotate the light into
				// that space so night darkens the hand and the sun still shades it.
				light_viewmodel(&renderer, camera, sky)
				draw_viewmodel(&renderer, camera, equipped_item(&client.inventory), client.mine.swing)
			}

			if playing {
				draw_crosshair()
			}
			if !options.open && !paused && !client.inventory.open {
				draw_nameplates(hud_font, camera, client.others[:])
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
			// The viewmodel bind left the sun in view space. The portrait is a
			// world-space model, so put the daylight direction back first.
			if !client.third_person {
				light_bind(renderer.cutout, renderer.cutout_light, sky, light_vp, 1, 0)
				light_bind(renderer.mesh_shader, renderer.mesh_light, sky, light_vp, 1, 0)
			}
			draw_inventory(hud_font, &renderer, client.inventory, client.drag, client.player, client.walks[client.id])
			if !client.inventory.open && !options.open {
				draw_chat(hud_font, &client.chat)
			}
			if paused && !options.open {
				draw_pause(hud_font, &menu, client.server != nil, server.host.listening)
			}
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

		sound_mix(&audio)

		// Finish the frame and show it.
		rl.EndDrawing()
	}
}

session_boot :: proc(server: ^Server, client: ^Client, menu: ^Menu, render_distance: int) -> bool {
	if menu.fresh {
		server^ = server_start(menu.current.seed)
	} else {
		loaded, reason := world_load(&menu.current)
		if reason != "" {
			menu_set_status(menu, reason)
			return false
		}
		server^ = loaded
	}
	client_connect(client, server, render_distance)
	// A new world is written now, so leaving before the first save still has it.
	if menu.fresh && !world_save(server, &menu.current, client.id) {
		session_stop(server, client)
		menu_set_status(menu, "Could not save the world.")
		return false
	}
	return true
}

// Saves a local world on the way out of the process, then tears the session down.
session_shutdown :: proc(server: ^Server, client: ^Client, menu: ^Menu) {
	if client.server != nil && menu.current.path_len > 0 {
		world_save(server, &menu.current, client.id)
	}
	session_stop(server, client)
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
