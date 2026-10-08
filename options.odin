package main

import "core:fmt"
import rl "vendor:raylib"

// What O opens. Render distance is how many chunks stay loaded around this
// player. Mipmapping and TAA are the passes added on top of the renderer.
// Antialiasing is the 4x multisampling the window used to enable at startup.
Options :: struct {
	open:            bool,
	render_distance: int,
	mipmaps:         bool,
	taa:             bool,
	msaa:            bool,
	// Set on the frame the screen opens or closes. Look stays off so the cursor
	// warp from grabbing or releasing the mouse is not applied to the camera.
	suppress_look:   bool,
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
OPTIONS_PANEL_H :: f32(388)
OPTION_BUTTON_H :: f32(56)
OPTION_BUTTON_GAP :: f32(12)
// The "-  8  +" cluster on the right of the render-distance row.
DISTANCE_CTRL_W :: f32(132)

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

options_handle_click :: proc(options: ^Options, textures: Block_Textures, atlas: rl.Texture2D, sprites: Item_Sprites, taa: ^TAA) {
	if !options.open {
		return
	}
	_, _, distance := options_layout()
	mouse := rl.GetMousePosition()
	if rl.IsMouseButtonPressed(.LEFT) {
		down, up := distance_ends(distance)
		if rl.CheckCollisionPointRec(mouse, down) {
			options_set_distance(options, options.render_distance-1)
		} else if rl.CheckCollisionPointRec(mouse, up) {
			options_set_distance(options, options.render_distance+1)
		} else if id, hit := options_hit(mouse); hit {
			switch id {
			case .Mipmaps:
				options.mipmaps = !options.mipmaps
				set_block_mipmaps(textures, atlas, options.mipmaps)
				set_item_mipmaps(sprites, options.mipmaps)
			case .TAA:
				options.taa = !options.taa
				taa.ready = false
			case .MSAA:
				options.msaa = !options.msaa
				taa.ready = false
			}
		}
	}
	if rl.CheckCollisionPointRec(mouse, distance) {
		wheel := rl.GetMouseWheelMove()
		if wheel > 0 {
			options_set_distance(options, options.render_distance+1)
		} else if wheel < 0 {
			options_set_distance(options, options.render_distance-1)
		}
	}
}

options_set_distance :: proc(options: ^Options, radius: int) {
	options.render_distance = clamp(radius, RENDER_DISTANCE_MIN, RENDER_DISTANCE_MAX)
}

options_hit :: proc(mouse: rl.Vector2) -> (id: Option_Id, hit: bool) {
	_, buttons, _ := options_layout()
	for option in Option_Id {
		if rl.CheckCollisionPointRec(mouse, buttons[option]) {
			return option, true
		}
	}
	return {}, false
}

draw_options :: proc(font: rl.Font, options: Options) {
	rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), {0, 0, 0, 140})

	panel, buttons, distance := options_layout()
	rl.DrawRectangleRec(panel, {28, 28, 28, 235})
	rl.DrawTextEx(font, "Options", {panel.x + 28, panel.y + 22}, HUD_SIZE, HUD_SPACING, rl.WHITE)

	draw_distance_row(font, distance, options.render_distance, rl.GetMousePosition())

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

options_layout :: proc() -> (panel: rl.Rectangle, buttons: [Option_Id]rl.Rectangle, distance: rl.Rectangle) {
	panel = {
		x      = (f32(rl.GetScreenWidth()) - OPTIONS_PANEL_W) * 0.5,
		y      = (f32(rl.GetScreenHeight()) - OPTIONS_PANEL_H) * 0.5,
		width  = OPTIONS_PANEL_W,
		height = OPTIONS_PANEL_H,
	}
	x := panel.x + 28
	y := panel.y + 72
	w := OPTIONS_PANEL_W - 56
	distance = {x, y, w, OPTION_BUTTON_H}
	y += OPTION_BUTTON_H + OPTION_BUTTON_GAP
	for option in Option_Id {
		buttons[option] = {x, y, w, OPTION_BUTTON_H}
		y += OPTION_BUTTON_H + OPTION_BUTTON_GAP
	}
	return
}

// The left and right thirds of the value cluster. The middle third is the number.
distance_ends :: proc(row: rl.Rectangle) -> (down, up: rl.Rectangle) {
	third := DISTANCE_CTRL_W / 3
	x := row.x + row.width - DISTANCE_CTRL_W
	down = {x, row.y, third, row.height}
	up = {x + 2*third, row.y, third, row.height}
	return
}

draw_distance_row :: proc(font: rl.Font, row: rl.Rectangle, radius: int, mouse: rl.Vector2) {
	bg := rl.Color{48, 48, 48, 255}
	if rl.CheckCollisionPointRec(mouse, row) {
		bg = {72, 72, 72, 255}
	}
	rl.DrawRectangleRec(row, bg)

	text_y := row.y + (OPTION_BUTTON_H - HUD_SIZE) * 0.5
	rl.DrawTextEx(font, "Render Distance", {row.x + 16, text_y}, HUD_SIZE, HUD_SPACING, rl.WHITE)

	down, up := distance_ends(row)
	dim := rl.Color{110, 110, 110, 255}
	minus_color := rl.WHITE
	if radius <= RENDER_DISTANCE_MIN {
		minus_color = dim
	}
	plus_color := rl.WHITE
	if radius >= RENDER_DISTANCE_MAX {
		plus_color = dim
	}
	draw_centered(font, "-", down, text_y, minus_color)

	buf: [8]byte
	text := fmt.bprintf(buf[:], "%d", radius)
	if len(text) < len(buf) {
		buf[len(text)] = 0
	}
	number := cstring(raw_data(buf[:]))
	mid := rl.Rectangle{down.x + down.width, row.y, DISTANCE_CTRL_W / 3, row.height}
	draw_centered(font, number, mid, text_y, {126, 196, 92, 255})
	draw_centered(font, "+", up, text_y, plus_color)
}

draw_centered :: proc(font: rl.Font, text: cstring, area: rl.Rectangle, y: f32, color: rl.Color) {
	width := rl.MeasureTextEx(font, text, HUD_SIZE, HUD_SPACING).x
	x := area.x + (area.width - width) * 0.5
	rl.DrawTextEx(font, text, {x, y}, HUD_SIZE, HUD_SPACING, color)
}
