package main

import rl "vendor:raylib"

// What O opens. Mipmapping and TAA are the passes added on top of the renderer.
// Antialiasing is the 4x multisampling the window used to enable at startup.
Options :: struct {
	open:          bool,
	mipmaps:       bool,
	taa:           bool,
	msaa:          bool,
	// Set on the frame the screen opens or closes. Look stays off so the cursor
	// warp from grabbing or releasing the mouse is not applied to the camera.
	suppress_look: bool,
}

Option_Id :: enum {
	Mipmaps,
	TAA,
	MSAA,
}

OPTION_LABELS := [Option_Id]cstring {
	.Mipmaps = "Mipmapping",
	.TAA     = "TAA",
	.MSAA    = "Antialiasing",
}

OPTIONS_PANEL_W :: f32(440)
OPTIONS_PANEL_H :: f32(320)
OPTION_BUTTON_H :: f32(56)
OPTION_BUTTON_GAP :: f32(12)

options_toggle :: proc(options: ^Options) {
	options.open = !options.open
	options.suppress_look = true
	if options.open {
		rl.EnableCursor()
	} else {
		rl.DisableCursor()
	}
}

options_close :: proc(options: ^Options) {
	if !options.open {
		return
	}
	options.open = false
	options.suppress_look = true
	rl.DisableCursor()
}

options_handle_click :: proc(options: ^Options, textures: Block_Textures, taa: ^TAA) {
	if !options.open || !rl.IsMouseButtonPressed(.LEFT) {
		return
	}
	id, hit := options_hit(rl.GetMousePosition())
	if !hit {
		return
	}
	switch id {
	case .Mipmaps:
		options.mipmaps = !options.mipmaps
		set_block_mipmaps(textures, options.mipmaps)
	case .TAA:
		options.taa = !options.taa
		taa.ready = false
	case .MSAA:
		options.msaa = !options.msaa
		taa.ready = false
	}
}

options_hit :: proc(mouse: rl.Vector2) -> (id: Option_Id, hit: bool) {
	_, buttons := options_layout()
	for option in Option_Id {
		if rl.CheckCollisionPointRec(mouse, buttons[option]) {
			return option, true
		}
	}
	return {}, false
}

draw_options :: proc(font: rl.Font, options: Options) {
	rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), {0, 0, 0, 140})

	panel, buttons := options_layout()
	rl.DrawRectangleRec(panel, {28, 28, 28, 235})
	rl.DrawTextEx(font, "Options", {panel.x + 28, panel.y + 22}, HUD_SIZE, HUD_SPACING, rl.WHITE)

	states := [Option_Id]bool {
		.Mipmaps = options.mipmaps,
		.TAA     = options.taa,
		.MSAA    = options.msaa,
	}
	mouse := rl.GetMousePosition()
	for option in Option_Id {
		button := buttons[option]
		bg := rl.Color{48, 48, 48, 255}
		if rl.CheckCollisionPointRec(mouse, button) {
			bg = {72, 72, 72, 255}
		}
		rl.DrawRectangleRec(button, bg)

		text_y := button.y + (OPTION_BUTTON_H - HUD_SIZE) * 0.5
		rl.DrawTextEx(font, OPTION_LABELS[option], {button.x + 16, text_y}, HUD_SIZE, HUD_SPACING, rl.WHITE)

		state: cstring = "On" if states[option] else "Off"
		color := rl.Color{126, 196, 92, 255} if states[option] else rl.Color{168, 168, 168, 255}
		width := rl.MeasureTextEx(font, state, HUD_SIZE, HUD_SPACING).x
		rl.DrawTextEx(font, state, {button.x + button.width - width - 16, text_y}, HUD_SIZE, HUD_SPACING, color)
	}

	rl.DrawTextEx(
		font,
		"Press O or Esc to close",
		{panel.x + 28, panel.y + panel.height - 42},
		HUD_SIZE,
		HUD_SPACING,
		{160, 160, 160, 255},
	)
}

options_layout :: proc() -> (panel: rl.Rectangle, buttons: [Option_Id]rl.Rectangle) {
	panel = {
		x      = (f32(rl.GetScreenWidth()) - OPTIONS_PANEL_W) * 0.5,
		y      = (f32(rl.GetScreenHeight()) - OPTIONS_PANEL_H) * 0.5,
		width  = OPTIONS_PANEL_W,
		height = OPTIONS_PANEL_H,
	}
	x := panel.x + 28
	y := panel.y + 72
	w := OPTIONS_PANEL_W - 56
	for option in Option_Id {
		buttons[option] = {x, y, w, OPTION_BUTTON_H}
		y += OPTION_BUTTON_H + OPTION_BUTTON_GAP
	}
	return
}
