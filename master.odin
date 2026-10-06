package main

import rl "vendor:raylib"

main :: proc() {
	rl.SetConfigFlags({.MSAA_4X_HINT}) // enable antialiasing
	rl.InitWindow(1280, 720, "Chudcraft")
	defer rl.CloseWindow()

	rl.SetTargetFPS(60)

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

		// Finish the frame and show it.
		rl.EndDrawing()
	}
}
