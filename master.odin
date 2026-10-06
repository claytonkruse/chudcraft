package main

import "core:c"
import rl "vendor:raylib"

main :: proc() {
	rl.SetConfigFlags({.MSAA_4X_HINT}) // enable antialiasing
	rl.InitWindow(1280, 720, "Chudcraft")
	defer rl.CloseWindow()

	rl.SetTargetFPS(60)

	hud_font, owned := load_hud_font()
	defer unload_hud_font(hud_font, owned)

	chunk: Chunk
	fill_chunk(&chunk)

	// Stand on the grass, looking across the chunk (+Z).
	player := Player {
		position = SPAWN_POSITION,
		grounded = true,
	}

	rl.DisableCursor()

	// Loop until the user closes the window or presses Escape.
	for !rl.WindowShouldClose() {
		dt := min(rl.GetFrameTime(), 0.05)
		update_player(&player, &chunk, dt)
		camera := camera_from_player(player)

		// Start a new frame.
		rl.BeginDrawing()
		// Fill the background with sky blue.
		rl.ClearBackground(rl.SKYBLUE)

		// Draw 3D geometry using this camera.
		rl.BeginMode3D(camera)
		draw_chunk(&chunk)
		// Finish 3D drawing.
		rl.EndMode3D()

		draw_fps(hud_font, 8, 8)
		draw_player_position(hud_font, player)

		// Finish the frame and show it.
		rl.EndDrawing()
	}
}

HUD_SIZE :: f32(20)
HUD_SPACING :: f32(0)

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
