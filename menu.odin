package main

import "core:fmt"
import rl "vendor:raylib"

// What is on screen before a world exists. Play and Host start one here.
// Join connects to a world somebody else is already hosting.
Front :: enum {
	Title,
	Join,
	Generating,
	Connecting,
	Playing,
}

Menu_Button :: enum {
	Play,
	Host,
	Join,
	Connect,
	Back,
}

Menu_Action :: enum {
	None,
	Play,
	Host,
	Join,
	Connect,
	Back,
}

MENU_LABELS := [Menu_Button]cstring {
	.Play    = "Play alone",
	.Host    = "Host a world",
	.Join    = "Join a world",
	.Connect = "Connect",
	.Back    = "Back",
}

TITLE_BUTTONS := [3]Menu_Button{.Play, .Host, .Join}
JOIN_BUTTONS  := [2]Menu_Button{.Connect, .Back}

MENU_PANEL_W    :: f32(640)
MENU_BUTTON_H   :: f32(56)
MENU_BUTTON_GAP :: f32(12)
MENU_FIELD_H    :: f32(48)

Menu :: struct {
	// The address typed on the join screen, always null-terminated.
	address:     [64]byte,
	address_len: int,
	// Shown under the buttons when hosting or joining did not work.
	status:      [180]byte,
	// Set once the generating screen has been presented, so the hitch happens
	// while that text is already up.
	paint_gen:   bool,
	// Set when Connect is chosen, so the dial happens on the next frame, with
	// "Connecting..." already on screen.
	dial_armed:  bool,
}

menu_init :: proc(menu: ^Menu) {
	text := fmt.bprintf(menu.address[:], "127.0.0.1:%d", NET_PORT)
	menu.address_len = len(text)
	if menu.address_len < len(menu.address) {
		menu.address[menu.address_len] = 0
	}
}

menu_set_status :: proc(menu: ^Menu, text: string) {
	put_text(menu.status[:], text)
}

menu_clear_status :: proc(menu: ^Menu) {
	menu.status[0] = 0
}

menu_set_address :: proc(menu: ^Menu, text: string) {
	n := min(len(text), len(menu.address)-1)
	copy(menu.address[:n], text)
	menu.address[n] = 0
	menu.address_len = n
}

menu_address :: proc(menu: ^Menu) -> string {
	return string(menu.address[:menu.address_len])
}

// Clicks and, on the join screen, the address being typed.
menu_update :: proc(menu: ^Menu, front: Front) -> Menu_Action {
	if front == .Join {
		for {
			ch := rl.GetCharPressed()
			if ch == 0 {
				break
			}
			if ch >= 32 && ch < 127 && menu.address_len < len(menu.address)-1 {
				menu.address[menu.address_len] = u8(ch)
				menu.address_len += 1
				menu.address[menu.address_len] = 0
			}
		}
		if (rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE)) && menu.address_len > 0 {
			menu.address_len -= 1
			menu.address[menu.address_len] = 0
		}
		if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
			return .Connect
		}
	}

	if !rl.IsMouseButtonPressed(.LEFT) {
		return .None
	}
	button, hit := menu_hit(menu, front, rl.GetMousePosition())
	if !hit {
		return .None
	}
	switch button {
	case .Play:
		return .Play
	case .Host:
		return .Host
	case .Join:
		return .Join
	case .Connect:
		return .Connect
	case .Back:
		return .Back
	}
	return .None
}

draw_front :: proc(font: rl.Font, menu: ^Menu, front: Front) {
	rl.ClearBackground({18, 22, 28, 255})
	switch front {
	case .Title, .Join:
		draw_menu(font, menu, front)
	case .Generating:
		draw_center_message(font, "Generating world...")
	case .Connecting:
		draw_center_message(font, "Connecting...")
		draw_center_hint(font, "Esc cancels")
	case .Playing:
	}
}

draw_menu :: proc(font: rl.Font, menu: ^Menu, front: Front) {
	panel := menu_panel(menu, front)
	rl.DrawRectangleRec(panel, {28, 28, 28, 235})

	title: cstring = "Chudcraft"
	sub: cstring = "Host a world, or join someone who is."
	hint: cstring = "Esc quits"
	if front == .Join {
		title = "Join a world"
		sub = "Use the address on the host's screen."
		hint = "Enter connects. Esc goes back."
	}
	rl.DrawTextEx(font, title, {panel.x + 28, panel.y + 22}, HUD_SIZE, HUD_SPACING, rl.WHITE)
	rl.DrawTextEx(font, sub, {panel.x + 28, panel.y + 52}, HUD_SIZE, HUD_SPACING, {168, 168, 168, 255})

	if front == .Join {
		field := menu_field(panel)
		rl.DrawRectangleRec(field, {16, 16, 16, 255})
		text_y := field.y + (MENU_FIELD_H - HUD_SIZE) * 0.5
		shown := cstring(raw_data(menu.address[:]))
		rl.DrawTextEx(font, shown, {field.x + 16, text_y}, HUD_SIZE, HUD_SPACING, rl.WHITE)
		if int(rl.GetTime()*2) % 2 == 0 {
			width := rl.MeasureTextEx(font, shown, HUD_SIZE, HUD_SPACING).x
			rl.DrawRectangleRec({field.x + 16 + width + 2, text_y, 2, HUD_SIZE}, rl.WHITE)
		}
	}

	mouse := rl.GetMousePosition()
	buttons := menu_buttons(front, panel)
	for button in menu_button_list(front) {
		rect := buttons[button]
		bg := rl.Color{48, 48, 48, 255}
		if rl.CheckCollisionPointRec(mouse, rect) {
			bg = {72, 72, 72, 255}
		}
		rl.DrawRectangleRec(rect, bg)
		text_y := rect.y + (MENU_BUTTON_H - HUD_SIZE) * 0.5
		rl.DrawTextEx(font, MENU_LABELS[button], {rect.x + 16, text_y}, HUD_SIZE, HUD_SPACING, rl.WHITE)
	}

	list := menu_button_list(front)
	last := buttons[list[len(list)-1]]
	footer_y := last.y + last.height + 28
	if menu.status[0] != 0 {
		rl.DrawTextEx(
			font,
			cstring(raw_data(menu.status[:])),
			{panel.x + 28, footer_y},
			HUD_SIZE,
			HUD_SPACING,
			{220, 140, 120, 255},
		)
		footer_y += 36
	}
	rl.DrawTextEx(font, hint, {panel.x + 28, footer_y}, HUD_SIZE, HUD_SPACING, {160, 160, 160, 255})
}

draw_center_message :: proc(font: rl.Font, text: cstring) {
	width := rl.MeasureTextEx(font, text, HUD_SIZE, HUD_SPACING).x
	x := (f32(rl.GetScreenWidth()) - width) * 0.5
	y := f32(rl.GetScreenHeight())*0.5 - HUD_SIZE*0.5
	rl.DrawTextEx(font, text, {x, y}, HUD_SIZE, HUD_SPACING, rl.WHITE)
}

draw_center_hint :: proc(font: rl.Font, text: cstring) {
	width := rl.MeasureTextEx(font, text, HUD_SIZE, HUD_SPACING).x
	x := (f32(rl.GetScreenWidth()) - width) * 0.5
	y := f32(rl.GetScreenHeight())*0.5 + HUD_SIZE
	rl.DrawTextEx(font, text, {x, y}, HUD_SIZE, HUD_SPACING, {160, 160, 160, 255})
}

menu_hit :: proc(menu: ^Menu, front: Front, mouse: rl.Vector2) -> (button: Menu_Button, hit: bool) {
	panel := menu_panel(menu, front)
	buttons := menu_buttons(front, panel)
	for id in menu_button_list(front) {
		if rl.CheckCollisionPointRec(mouse, buttons[id]) {
			return id, true
		}
	}
	return {}, false
}

menu_button_list :: proc(front: Front) -> []Menu_Button {
	if front == .Join {
		return JOIN_BUTTONS[:]
	}
	return TITLE_BUTTONS[:]
}

menu_panel :: proc(menu: ^Menu, front: Front) -> rl.Rectangle {
	list := menu_button_list(front)
	// Title, the gap under it, then either the buttons or the address field plus the buttons.
	height := f32(96)
	if front == .Join {
		height += MENU_FIELD_H + 18
	}
	height += f32(len(list))*MENU_BUTTON_H + f32(len(list)-1)*MENU_BUTTON_GAP
	height += 28 + HUD_SIZE + 28
	if menu.status[0] != 0 {
		height += 36
	}
	return {
		x      = (f32(rl.GetScreenWidth()) - MENU_PANEL_W) * 0.5,
		y      = (f32(rl.GetScreenHeight()) - height) * 0.5,
		width  = MENU_PANEL_W,
		height = height,
	}
}

menu_field :: proc(panel: rl.Rectangle) -> rl.Rectangle {
	return {
		x      = panel.x + 28,
		y      = panel.y + 96,
		width  = MENU_PANEL_W - 56,
		height = MENU_FIELD_H,
	}
}

menu_buttons :: proc(front: Front, panel: rl.Rectangle) -> [Menu_Button]rl.Rectangle {
	buttons: [Menu_Button]rl.Rectangle
	y := panel.y + 96
	if front == .Join {
		y = panel.y + 96 + MENU_FIELD_H + 18
	}
	x := panel.x + 28
	w := MENU_PANEL_W - 56
	for button in menu_button_list(front) {
		buttons[button] = {x, y, w, MENU_BUTTON_H}
		y += MENU_BUTTON_H + MENU_BUTTON_GAP
	}
	return buttons
}
