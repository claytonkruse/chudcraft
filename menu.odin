package main

import "core:fmt"
import rl "vendor:raylib"

// What is on screen before a world exists. A saved world starts from My Worlds.
// Join picks a saved server. Adding one writes servers.chud.
Front :: enum {
	Title,
	Worlds,
	Create,
	Join,
	Server_Add,
	Generating,
	Connecting,
	Playing,
}

Menu_Button :: enum {
	My_Worlds,
	Join_World,
	New_World,
	Create,
	Add_Server,
	Add,
	Back,
}

Menu_Action :: enum {
	None,
	My_Worlds,
	Join_World,
	New_World,
	Create,
	Open_World,
	Add_Server,
	Save_Server,
	Remove_Server,
	Connect,
	Back,
}

MENU_LABELS := [Menu_Button]cstring {
	.My_Worlds  = "My Worlds",
	.Join_World = "Join World",
	.New_World  = "New World",
	.Create     = "Create",
	.Add_Server = "Add Server",
	.Add        = "Add",
	.Back       = "Back",
}

TITLE_BUTTONS  := [2]Menu_Button{.My_Worlds, .Join_World}
CREATE_BUTTONS := [2]Menu_Button{.Create, .Back}
ADD_BUTTONS    := [2]Menu_Button{.Add, .Back}

MENU_PANEL_W    :: f32(640)
MENU_BUTTON_H   :: f32(56)
MENU_BUTTON_GAP :: f32(12)
MENU_FIELD_H    :: f32(48)
// How many saved worlds or servers the list shows at once. The wheel moves the rest.
WORLD_VISIBLE :: 5

Pause_Action :: enum {
	None,
	Resume,
	Host,
	Settings,
	Leave,
}

Menu :: struct {
	// The address being typed, or the one a list row is about to dial.
	address:     [64]byte,
	address_len: int,
	// The name typed for a new world or a new server.
	name:        [33]byte,
	name_len:    int,
	// Which line the add-server screen is typing into. 0 is the name.
	focus:       int,
	// Saved worlds, newest first. current is the one being played or created.
	cards:       [dynamic]World_Card,
	// Saved servers, newest first.
	servers:     [dynamic]Server_Entry,
	scroll:      int,
	picked:      int,
	current:     World_Card,
	// True when current has not been written yet, so boot generates it.
	fresh:       bool,
	// Shown under the buttons when hosting, saving, or joining did not work.
	status:      [180]byte,
	// Set once the generating line has been presented, so the hitch happens
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
	worlds_scan(&menu.cards)
	servers_load(&menu.servers)
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

menu_set_name :: proc(menu: ^Menu, text: string) {
	n := min(len(text), WORLD_NAME_MAX)
	copy(menu.name[:n], text)
	menu.name[n] = 0
	menu.name_len = n
}

menu_world_name :: proc(menu: ^Menu) -> string {
	return string(menu.name[:menu.name_len])
}

// Clicks and, on the create and add-server screens, the line being typed.
menu_update :: proc(menu: ^Menu, front: Front) -> Menu_Action {
	if front == .Server_Add {
		if menu.focus == 0 {
			type_line(menu.name[:], &menu.name_len)
		} else {
			type_line(menu.address[:], &menu.address_len)
		}
		if rl.IsKeyPressed(.TAB) {
			menu.focus = 1 - menu.focus
		}
		if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
			return .Save_Server
		}
	}
	if front == .Create {
		type_line(menu.name[:], &menu.name_len)
		if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
			return .Create
		}
	}
	if front == .Worlds {
		menu.scroll -= int(rl.GetMouseWheelMove())
		clamp_world_scroll(menu)
	}
	if front == .Join {
		menu.scroll -= int(rl.GetMouseWheelMove())
		clamp_server_scroll(menu)
	}

	if !rl.IsMouseButtonPressed(.LEFT) {
		return .None
	}
	if front == .Worlds {
		return worlds_click(menu)
	}
	if front == .Join {
		return servers_click(menu)
	}
	if front == .Server_Add {
		return server_add_click(menu)
	}
	button, hit := menu_hit(menu, front, rl.GetMousePosition())
	if !hit {
		return .None
	}
	switch button {
	case .My_Worlds:
		return .My_Worlds
	case .Join_World:
		return .Join_World
	case .New_World:
		return .New_World
	case .Create:
		return .Create
	case .Add_Server:
		return .Add_Server
	case .Add:
		return .Save_Server
	case .Back:
		return .Back
	}
	return .None
}

type_line :: proc(buf: []byte, length: ^int) {
	for {
		ch := rl.GetCharPressed()
		if ch == 0 {
			break
		}
		if ch >= 32 && ch < 127 && length^ < len(buf)-1 {
			buf[length^] = u8(ch)
			length^ += 1
			buf[length^] = 0
		}
	}
	if (rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE)) && length^ > 0 {
		length^ -= 1
		buf[length^] = 0
	}
}

draw_front :: proc(font: rl.Font, menu: ^Menu, front: Front) {
	rl.ClearBackground({18, 22, 28, 255})
	switch front {
	case .Title, .Create:
		draw_menu(font, menu, front)
	case .Worlds:
		draw_worlds(font, menu)
	case .Join:
		draw_servers(font, menu)
	case .Server_Add:
		draw_server_add(font, menu)
	case .Generating:
		text: cstring = "Loading world..."
		if menu.fresh {
			text = "Generating world..."
		}
		draw_center_message(font, text)
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
	sub: cstring = "Play a saved world, or join one."
	if front == .Create {
		title = "New World"
		sub = "This world stays on this computer."
	}
	rl.DrawTextEx(font, title, {panel.x + 28, panel.y + 22}, HUD_SIZE, HUD_SPACING, rl.WHITE)
	rl.DrawTextEx(font, sub, {panel.x + 28, panel.y + 52}, HUD_SIZE, HUD_SPACING, {168, 168, 168, 255})

	if front == .Create {
		field := menu_field(panel)
		draw_text_field(font, field, cstring(raw_data(menu.name[:])), true, false)
	}

	draw_button_list(font, menu, front, panel)
}

draw_worlds :: proc(font: rl.Font, menu: ^Menu) {
	layout := worlds_layout(menu)
	rl.DrawRectangleRec(layout.panel, {28, 28, 28, 235})
	rl.DrawTextEx(font, "My Worlds", {layout.panel.x + 28, layout.panel.y + 22}, HUD_SIZE, HUD_SPACING, rl.WHITE)
	rl.DrawTextEx(font, "Open one, then host it from the pause menu.", {layout.panel.x + 28, layout.panel.y + 52}, HUD_SIZE, HUD_SPACING, {168, 168, 168, 255})

	mouse := rl.GetMousePosition()
	if len(menu.cards) == 0 {
		rl.DrawTextEx(font, "No worlds yet.", {layout.panel.x + 28, layout.panel.y + 108}, HUD_SIZE, HUD_SPACING, {168, 168, 168, 255})
	}
	clamp_world_scroll(menu)
	for i in 0 ..< layout.row_n {
		card := menu.cards[menu.scroll+i]
		rect := layout.rows[i]
		bg := rl.Color{48, 48, 48, 255}
		if rl.CheckCollisionPointRec(mouse, rect) {
			bg = {72, 72, 72, 255}
		}
		rl.DrawRectangleRec(rect, bg)
		text_y := rect.y + (MENU_BUTTON_H - HUD_SIZE) * 0.5
		rl.DrawTextEx(font, cstring(raw_data(card.name[:])), {rect.x + 16, text_y}, HUD_SIZE, HUD_SPACING, rl.WHITE)
	}

	draw_labeled_button(font, layout.new_world, "New World", mouse)
	draw_labeled_button(font, layout.back, "Back", mouse)

	footer_y := layout.back.y + layout.back.height + 28
	hint: cstring = "Esc goes back."
	if len(menu.cards) > WORLD_VISIBLE {
		hint = "Scroll for more. Esc goes back."
	}
	draw_footer(font, menu, layout.panel.x+28, footer_y, hint)
}

draw_servers :: proc(font: rl.Font, menu: ^Menu) {
	layout := servers_layout(menu)
	rl.DrawRectangleRec(layout.panel, {28, 28, 28, 235})
	rl.DrawTextEx(font, "Join World", {layout.panel.x + 28, layout.panel.y + 22}, HUD_SIZE, HUD_SPACING, rl.WHITE)
	rl.DrawTextEx(font, "Pick a server, or add one.", {layout.panel.x + 28, layout.panel.y + 52}, HUD_SIZE, HUD_SPACING, {168, 168, 168, 255})

	mouse := rl.GetMousePosition()
	if len(menu.servers) == 0 {
		rl.DrawTextEx(font, "No servers yet.", {layout.panel.x + 28, layout.panel.y + 108}, HUD_SIZE, HUD_SPACING, {168, 168, 168, 255})
	}
	clamp_server_scroll(menu)
	for i in 0 ..< layout.row_n {
		entry := &menu.servers[menu.scroll+i]
		join := layout.rows[i]
		bg := rl.Color{48, 48, 48, 255}
		if rl.CheckCollisionPointRec(mouse, join) {
			bg = {72, 72, 72, 255}
		}
		rl.DrawRectangleRec(join, bg)
		text_y := join.y + (MENU_BUTTON_H - HUD_SIZE) * 0.5
		name_w := join.width * 0.42
		rl.BeginScissorMode(i32(join.x+16), i32(join.y), i32(name_w), i32(join.height))
		rl.DrawTextEx(font, cstring(raw_data(entry.name[:])), {join.x + 16, text_y}, HUD_SIZE, HUD_SPACING, rl.WHITE)
		rl.EndScissorMode()
		addr_x := join.x + 16 + name_w
		rl.BeginScissorMode(i32(addr_x), i32(join.y), i32(join.width-name_w-32), i32(join.height))
		rl.DrawTextEx(font, cstring(raw_data(entry.address[:])), {addr_x, text_y}, HUD_SIZE, HUD_SPACING, {168, 168, 168, 255})
		rl.EndScissorMode()
		draw_labeled_button(font, layout.remove[i], "Remove", mouse)
	}

	draw_labeled_button(font, layout.add, "Add Server", mouse)
	draw_labeled_button(font, layout.back, "Back", mouse)

	footer_y := layout.back.y + layout.back.height + 28
	hint: cstring = "Esc goes back."
	if len(menu.servers) > WORLD_VISIBLE {
		hint = "Scroll for more. Esc goes back."
	}
	draw_footer(font, menu, layout.panel.x+28, footer_y, hint)
}

draw_server_add :: proc(font: rl.Font, menu: ^Menu) {
	layout := server_add_layout(menu)
	rl.DrawRectangleRec(layout.panel, {28, 28, 28, 235})
	rl.DrawTextEx(font, "Add Server", {layout.panel.x + 28, layout.panel.y + 22}, HUD_SIZE, HUD_SPACING, rl.WHITE)
	rl.DrawTextEx(font, "Name it, then the host's address.", {layout.panel.x + 28, layout.panel.y + 52}, HUD_SIZE, HUD_SPACING, {168, 168, 168, 255})

	draw_text_field(font, layout.name, field_shown(menu.name[:], menu.name_len, "Name"), menu.focus == 0, menu.name_len == 0)
	draw_text_field(font, layout.address, field_shown(menu.address[:], menu.address_len, "Address"), menu.focus == 1, menu.address_len == 0)

	mouse := rl.GetMousePosition()
	draw_labeled_button(font, layout.add, "Add", mouse)
	draw_labeled_button(font, layout.back, "Back", mouse)

	footer_y := layout.back.y + layout.back.height + 28
	draw_footer(font, menu, layout.panel.x+28, footer_y, "Tab switches lines. Enter adds. Esc goes back.")
}

field_shown :: proc(buf: []byte, length: int, placeholder: cstring) -> cstring {
	if length == 0 {
		return placeholder
	}
	return cstring(raw_data(buf))
}

draw_text_field :: proc(font: rl.Font, field: rl.Rectangle, shown: cstring, focused, placeholder: bool) {
	rl.DrawRectangleRec(field, {16, 16, 16, 255})
	if focused {
		rl.DrawRectangleLinesEx(field, 2, {180, 180, 180, 255})
	}
	text_y := field.y + (MENU_FIELD_H - HUD_SIZE) * 0.5
	color := rl.WHITE
	if placeholder {
		color = {120, 120, 120, 255}
	}
	rl.DrawTextEx(font, shown, {field.x + 16, text_y}, HUD_SIZE, HUD_SPACING, color)
	if focused && int(rl.GetTime()*2) % 2 == 0 {
		width: f32 = 0
		if !placeholder {
			width = rl.MeasureTextEx(font, shown, HUD_SIZE, HUD_SPACING).x
		}
		rl.DrawRectangleRec({field.x + 16 + width + 2, text_y, 2, HUD_SIZE}, rl.WHITE)
	}
}

draw_pause :: proc(font: rl.Font, menu: ^Menu, local, hosting: bool) {
	rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), {0, 0, 0, 140})
	layout := pause_layout(menu, local)
	rl.DrawRectangleRec(layout.panel, {28, 28, 28, 235})
	rl.DrawTextEx(font, "Paused", {layout.panel.x + 28, layout.panel.y + 22}, HUD_SIZE, HUD_SPACING, rl.WHITE)
	sub: cstring = "Joined"
	if local {
		sub = cstring(raw_data(menu.current.name[:]))
	}
	rl.DrawTextEx(font, sub, {layout.panel.x + 28, layout.panel.y + 52}, HUD_SIZE, HUD_SPACING, {168, 168, 168, 255})

	mouse := rl.GetMousePosition()
	draw_labeled_button(font, layout.resume, "Resume", mouse)
	if local {
		host: cstring = "Host"
		if hosting {
			host = "Stop hosting"
		}
		draw_labeled_button(font, layout.host, host, mouse)
	}
	draw_labeled_button(font, layout.settings, "Settings", mouse)
	leave: cstring = "Leave"
	if local {
		leave = "Save and Leave"
	}
	draw_labeled_button(font, layout.leave, leave, mouse)

	footer_y := layout.leave.y + layout.leave.height + 28
	draw_footer(font, menu, layout.panel.x+28, footer_y, "Esc resumes")
}

pause_click :: proc(menu: ^Menu, local: bool) -> Pause_Action {
	if !rl.IsMouseButtonPressed(.LEFT) {
		return .None
	}
	layout := pause_layout(menu, local)
	mouse := rl.GetMousePosition()
	if rl.CheckCollisionPointRec(mouse, layout.resume) {
		return .Resume
	}
	if local && rl.CheckCollisionPointRec(mouse, layout.host) {
		return .Host
	}
	if rl.CheckCollisionPointRec(mouse, layout.settings) {
		return .Settings
	}
	if rl.CheckCollisionPointRec(mouse, layout.leave) {
		return .Leave
	}
	return .None
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

draw_button_list :: proc(font: rl.Font, menu: ^Menu, front: Front, panel: rl.Rectangle) {
	mouse := rl.GetMousePosition()
	buttons := menu_buttons(front, panel)
	for button in menu_button_list(front) {
		draw_labeled_button(font, buttons[button], MENU_LABELS[button], mouse)
	}
	list := menu_button_list(front)
	last := buttons[list[len(list)-1]]
	footer_y := last.y + last.height + 28
	hint: cstring = "Esc quits"
	if front == .Create {
		hint = "Enter creates. Esc goes back."
	}
	draw_footer(font, menu, panel.x+28, footer_y, hint)
}

draw_labeled_button :: proc(font: rl.Font, rect: rl.Rectangle, label: cstring, mouse: rl.Vector2) {
	bg := rl.Color{48, 48, 48, 255}
	if rl.CheckCollisionPointRec(mouse, rect) {
		bg = {72, 72, 72, 255}
	}
	rl.DrawRectangleRec(rect, bg)
	text_y := rect.y + (MENU_BUTTON_H - HUD_SIZE) * 0.5
	rl.DrawTextEx(font, label, {rect.x + 16, text_y}, HUD_SIZE, HUD_SPACING, rl.WHITE)
}

draw_footer :: proc(font: rl.Font, menu: ^Menu, x, y: f32, hint: cstring) {
	footer_y := y
	if menu.status[0] != 0 {
		rl.DrawTextEx(
			font,
			cstring(raw_data(menu.status[:])),
			{x, footer_y},
			HUD_SIZE,
			HUD_SPACING,
			{220, 140, 120, 255},
		)
		footer_y += 36
	}
	rl.DrawTextEx(font, hint, {x, footer_y}, HUD_SIZE, HUD_SPACING, {160, 160, 160, 255})
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

worlds_click :: proc(menu: ^Menu) -> Menu_Action {
	layout := worlds_layout(menu)
	mouse := rl.GetMousePosition()
	for i in 0 ..< layout.row_n {
		if rl.CheckCollisionPointRec(mouse, layout.rows[i]) {
			menu.picked = menu.scroll + i
			return .Open_World
		}
	}
	if rl.CheckCollisionPointRec(mouse, layout.new_world) {
		return .New_World
	}
	if rl.CheckCollisionPointRec(mouse, layout.back) {
		return .Back
	}
	return .None
}

servers_click :: proc(menu: ^Menu) -> Menu_Action {
	layout := servers_layout(menu)
	mouse := rl.GetMousePosition()
	for i in 0 ..< layout.row_n {
		if rl.CheckCollisionPointRec(mouse, layout.remove[i]) {
			menu.picked = menu.scroll + i
			return .Remove_Server
		}
		if rl.CheckCollisionPointRec(mouse, layout.rows[i]) {
			menu.picked = menu.scroll + i
			return .Connect
		}
	}
	if rl.CheckCollisionPointRec(mouse, layout.add) {
		return .Add_Server
	}
	if rl.CheckCollisionPointRec(mouse, layout.back) {
		return .Back
	}
	return .None
}

server_add_click :: proc(menu: ^Menu) -> Menu_Action {
	layout := server_add_layout(menu)
	mouse := rl.GetMousePosition()
	if rl.CheckCollisionPointRec(mouse, layout.name) {
		menu.focus = 0
		return .None
	}
	if rl.CheckCollisionPointRec(mouse, layout.address) {
		menu.focus = 1
		return .None
	}
	if rl.CheckCollisionPointRec(mouse, layout.add) {
		return .Save_Server
	}
	if rl.CheckCollisionPointRec(mouse, layout.back) {
		return .Back
	}
	return .None
}

menu_button_list :: proc(front: Front) -> []Menu_Button {
	switch front {
	case .Create:
		return CREATE_BUTTONS[:]
	case .Server_Add:
		return ADD_BUTTONS[:]
	case .Title, .Worlds, .Join, .Generating, .Connecting, .Playing:
		return TITLE_BUTTONS[:]
	}
	return TITLE_BUTTONS[:]
}

menu_panel :: proc(menu: ^Menu, front: Front) -> rl.Rectangle {
	list := menu_button_list(front)
	// Title, the gap under it, then either the buttons or the address field plus the buttons.
	height := f32(96)
	if front == .Create {
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
	if front == .Create {
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

Worlds_Layout :: struct {
	panel:     rl.Rectangle,
	rows:      [WORLD_VISIBLE]rl.Rectangle,
	row_n:     int,
	new_world: rl.Rectangle,
	back:      rl.Rectangle,
}

worlds_layout :: proc(menu: ^Menu) -> (layout: Worlds_Layout) {
	clamp_world_scroll(menu)
	layout.row_n = min(WORLD_VISIBLE, len(menu.cards)-menu.scroll)
	rows := layout.row_n
	if rows == 0 {
		rows = 1
	}
	height := f32(96)
	height += f32(rows)*MENU_BUTTON_H + f32(max(rows-1, 0))*MENU_BUTTON_GAP
	height += 18 + MENU_BUTTON_H + MENU_BUTTON_GAP + MENU_BUTTON_H
	height += 28 + HUD_SIZE + 28
	if menu.status[0] != 0 {
		height += 36
	}
	layout.panel = {
		x      = (f32(rl.GetScreenWidth()) - MENU_PANEL_W) * 0.5,
		y      = (f32(rl.GetScreenHeight()) - height) * 0.5,
		width  = MENU_PANEL_W,
		height = height,
	}
	y := layout.panel.y + 96
	x := layout.panel.x + 28
	w := MENU_PANEL_W - 56
	if len(menu.cards) == 0 {
		y += MENU_BUTTON_H + MENU_BUTTON_GAP
	}
	for i in 0 ..< layout.row_n {
		layout.rows[i] = {x, y, w, MENU_BUTTON_H}
		y += MENU_BUTTON_H + MENU_BUTTON_GAP
	}
	if layout.row_n > 0 {
		y += 18 - MENU_BUTTON_GAP
	}
	layout.new_world = {x, y, w, MENU_BUTTON_H}
	y += MENU_BUTTON_H + MENU_BUTTON_GAP
	layout.back = {x, y, w, MENU_BUTTON_H}
	return
}

Servers_Layout :: struct {
	panel:  rl.Rectangle,
	rows:   [WORLD_VISIBLE]rl.Rectangle,
	remove: [WORLD_VISIBLE]rl.Rectangle,
	row_n:  int,
	add:    rl.Rectangle,
	back:   rl.Rectangle,
}

SERVER_REMOVE_W :: f32(148)

servers_layout :: proc(menu: ^Menu) -> (layout: Servers_Layout) {
	clamp_server_scroll(menu)
	layout.row_n = min(WORLD_VISIBLE, len(menu.servers)-menu.scroll)
	rows := layout.row_n
	if rows == 0 {
		rows = 1
	}
	height := f32(96)
	height += f32(rows)*MENU_BUTTON_H + f32(max(rows-1, 0))*MENU_BUTTON_GAP
	height += 18 + MENU_BUTTON_H + MENU_BUTTON_GAP + MENU_BUTTON_H
	height += 28 + HUD_SIZE + 28
	if menu.status[0] != 0 {
		height += 36
	}
	layout.panel = {
		x      = (f32(rl.GetScreenWidth()) - MENU_PANEL_W) * 0.5,
		y      = (f32(rl.GetScreenHeight()) - height) * 0.5,
		width  = MENU_PANEL_W,
		height = height,
	}
	y := layout.panel.y + 96
	x := layout.panel.x + 28
	w := MENU_PANEL_W - 56
	if len(menu.servers) == 0 {
		y += MENU_BUTTON_H + MENU_BUTTON_GAP
	}
	join_w := w - SERVER_REMOVE_W - MENU_BUTTON_GAP
	for i in 0 ..< layout.row_n {
		layout.rows[i] = {x, y, join_w, MENU_BUTTON_H}
		layout.remove[i] = {x + join_w + MENU_BUTTON_GAP, y, SERVER_REMOVE_W, MENU_BUTTON_H}
		y += MENU_BUTTON_H + MENU_BUTTON_GAP
	}
	if layout.row_n > 0 {
		y += 18 - MENU_BUTTON_GAP
	}
	layout.add = {x, y, w, MENU_BUTTON_H}
	y += MENU_BUTTON_H + MENU_BUTTON_GAP
	layout.back = {x, y, w, MENU_BUTTON_H}
	return
}

clamp_server_scroll :: proc(menu: ^Menu) {
	max_scroll := max(len(menu.servers)-WORLD_VISIBLE, 0)
	if menu.scroll < 0 {
		menu.scroll = 0
	}
	if menu.scroll > max_scroll {
		menu.scroll = max_scroll
	}
}

Server_Add_Layout :: struct {
	panel:   rl.Rectangle,
	name:    rl.Rectangle,
	address: rl.Rectangle,
	add:     rl.Rectangle,
	back:    rl.Rectangle,
}

server_add_layout :: proc(menu: ^Menu) -> (layout: Server_Add_Layout) {
	height := f32(96)
	height += MENU_FIELD_H + MENU_BUTTON_GAP + MENU_FIELD_H + 18
	height += MENU_BUTTON_H + MENU_BUTTON_GAP + MENU_BUTTON_H
	height += 28 + HUD_SIZE + 28
	if menu.status[0] != 0 {
		height += 36
	}
	layout.panel = {
		x      = (f32(rl.GetScreenWidth()) - MENU_PANEL_W) * 0.5,
		y      = (f32(rl.GetScreenHeight()) - height) * 0.5,
		width  = MENU_PANEL_W,
		height = height,
	}
	x := layout.panel.x + 28
	w := MENU_PANEL_W - 56
	y := layout.panel.y + 96
	layout.name = {x, y, w, MENU_FIELD_H}
	y += MENU_FIELD_H + MENU_BUTTON_GAP
	layout.address = {x, y, w, MENU_FIELD_H}
	y += MENU_FIELD_H + 18
	layout.add = {x, y, w, MENU_BUTTON_H}
	y += MENU_BUTTON_H + MENU_BUTTON_GAP
	layout.back = {x, y, w, MENU_BUTTON_H}
	return
}

clamp_world_scroll :: proc(menu: ^Menu) {
	max_scroll := max(len(menu.cards)-WORLD_VISIBLE, 0)
	if menu.scroll < 0 {
		menu.scroll = 0
	}
	if menu.scroll > max_scroll {
		menu.scroll = max_scroll
	}
}

Pause_Layout :: struct {
	panel:    rl.Rectangle,
	resume:   rl.Rectangle,
	host:     rl.Rectangle,
	settings: rl.Rectangle,
	leave:    rl.Rectangle,
}

pause_layout :: proc(menu: ^Menu, local: bool) -> (layout: Pause_Layout) {
	count := 3
	if local {
		count = 4
	}
	height := f32(96)
	height += f32(count)*MENU_BUTTON_H + f32(count-1)*MENU_BUTTON_GAP
	height += 28 + HUD_SIZE + 28
	if menu.status[0] != 0 {
		height += 36
	}
	width := f32(480)
	layout.panel = {
		x      = (f32(rl.GetScreenWidth()) - width) * 0.5,
		y      = (f32(rl.GetScreenHeight()) - height) * 0.5,
		width  = width,
		height = height,
	}
	y := layout.panel.y + 96
	x := layout.panel.x + 28
	w := width - 56
	layout.resume = {x, y, w, MENU_BUTTON_H}
	y += MENU_BUTTON_H + MENU_BUTTON_GAP
	if local {
		layout.host = {x, y, w, MENU_BUTTON_H}
		y += MENU_BUTTON_H + MENU_BUTTON_GAP
	}
	layout.settings = {x, y, w, MENU_BUTTON_H}
	y += MENU_BUTTON_H + MENU_BUTTON_GAP
	layout.leave = {x, y, w, MENU_BUTTON_H}
	return
}
