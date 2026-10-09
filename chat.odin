package main

import "core:c"
import "core:fmt"
import rl "vendor:raylib"

// One line of chat, typed with T. A line that starts with / is a command and
// stays on the server: the speaker's client only sends the text. Replies come
// back with the rest of the step, the same way a block edit does.
//
// Players are their join numbers. That number is what /tp and /tphere take,
// and it is drawn above everyone else's head.

CHAT_LINE      :: 96
CHAT_TEXT      :: 160
CHAT_HISTORY   :: 50
CHAT_VISIBLE   :: 8
CHAT_LINGER    :: f32(8)
CHAT_NOTES_MAX :: 32
GIVE_MAX       :: 640

Chat_Note :: struct {
	// 0 is everyone. A command reply names the player it is for.
	to:     u32,
	system: bool,
	n:      int,
	text:   [CHAT_TEXT]byte,
}

Chat_Line :: struct {
	system: bool,
	age:    f32,
	n:      int,
	text:   [CHAT_TEXT]byte,
}

Chat :: struct {
	open:      bool,
	welcomed:  bool,
	len:       int,
	line:      [CHAT_LINE]byte,
	lines:     [dynamic]Chat_Line,
}

chat_close :: proc(chat: ^Chat) {
	chat.open = false
	chat.len = 0
	chat.line[0] = 0
}

chat_open :: proc(chat: ^Chat, command: bool) {
	chat.open = true
	chat.len = 0
	chat.line[0] = 0
	if command {
		chat.line[0] = '/'
		chat.line[1] = 0
		chat.len = 1
	}
}

// capture is false while a screen has the keyboard. Returns the line that was
// just sent, copied into dst, or 0. The slash that opened a command is not
// typed twice: that frame's characters are thrown away.
chat_type :: proc(chat: ^Chat, capture: bool, dst: []byte) -> int {
	if !chat.open {
		slash := rl.IsKeyPressed(.SLASH) || rl.IsKeyPressed(.KP_DIVIDE)
		t := rl.IsKeyPressed(.T)
		for {
			ch := rl.GetCharPressed()
			if ch == 0 {
				break
			}
			if ch == '/' {
				slash = true
			}
		}
		if !capture {
			return 0
		}
		if slash {
			chat_open(chat, true)
		} else if t {
			chat_open(chat, false)
		}
		return 0
	}
	if !capture {
		chat_close(chat)
		return 0
	}
	for {
		ch := rl.GetCharPressed()
		if ch == 0 {
			break
		}
		if ch >= 32 && ch < 127 && chat.len < CHAT_LINE {
			chat.line[chat.len] = u8(ch)
			chat.len += 1
			chat.line[chat.len] = 0
		}
	}
	if (rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE)) && chat.len > 0 {
		chat.len -= 1
		chat.line[chat.len] = 0
	}
	if !rl.IsKeyPressed(.ENTER) && !rl.IsKeyPressed(.KP_ENTER) {
		return 0
	}
	text := trim_space(string(chat.line[:chat.len]))
	chat_close(chat)
	if len(text) == 0 || text == "/" {
		return 0
	}
	n := min(len(dst), len(text))
	copy(dst[:n], text)
	return n
}

chat_tick :: proc(chat: ^Chat, dt: f32) {
	for &line in chat.lines {
		line.age += dt
	}
}

chat_welcome :: proc(chat: ^Chat, id: u32) {
	if chat.welcomed || id == 0 {
		return
	}
	chat.welcomed = true
	buf: [CHAT_TEXT]byte
	chat_push(chat, true, fmt.bprintf(buf[:], "You are player %d. Commands: /tp, /tphere, /i.", id))
}

chat_push :: proc(chat: ^Chat, system: bool, text: string) {
	if len(text) == 0 {
		return
	}
	if len(chat.lines) >= CHAT_HISTORY {
		last := len(chat.lines) - 1
		for i in 0 ..< last {
			chat.lines[i] = chat.lines[i+1]
		}
		pop(&chat.lines)
	}
	line: Chat_Line
	line.system = system
	line.n = min(len(text), CHAT_TEXT-1)
	copy(line.text[:line.n], text)
	line.text[line.n] = 0
	append(&chat.lines, line)
}

take_chat :: proc(chat: ^Chat, server: ^Server, self: u32) {
	for &note in server.notes {
		if note.to != 0 && note.to != self {
			continue
		}
		chat_push(chat, note.system, string(note.text[:note.n]))
	}
}

chat_note :: proc(server: ^Server, to: u32, system: bool, text: string) {
	if len(text) == 0 {
		return
	}
	note: Chat_Note
	note.to = to
	note.system = system
	note.n = min(len(text), CHAT_TEXT-1)
	copy(note.text[:note.n], text)
	note.text[note.n] = 0
	append(&server.notes, note)
}

// Printable ASCII only. A joined game can send anything that fits the field.
clean_line :: proc(dst: []byte, src: string) -> string {
	n := 0
	for i in 0 ..< len(src) {
		ch := src[i]
		if ch < 32 || ch >= 127 {
			continue
		}
		if n >= len(dst) {
			break
		}
		dst[n] = ch
		n += 1
	}
	return trim_space(string(dst[:n]))
}

server_say :: proc(server: ^Server, id: u32, raw: string) {
	buf: [CHAT_LINE]byte
	text := clean_line(buf[:], raw)
	if len(text) == 0 {
		return
	}
	if text[0] == '/' {
		server_command(server, id, trim_space(text[1:]))
		return
	}
	line: [CHAT_TEXT]byte
	chat_note(server, 0, false, fmt.bprintf(line[:], "<%d> %s", id, text))
}

server_command :: proc(server: ^Server, id: u32, body: string) {
	if len(body) == 0 {
		chat_note(server, id, true, "Unknown command. Try /tp, /tphere, or /i.")
		return
	}
	cmd, rest := split_word(body)
	if same_word(cmd, "tp") {
		command_tp(server, id, rest)
	} else if same_word(cmd, "tphere") {
		command_tphere(server, id, rest)
	} else if same_word(cmd, "i") {
		command_give(server, id, rest)
	} else {
		chat_note(server, id, true, "Unknown command. Try /tp, /tphere, or /i.")
	}
}

command_tp :: proc(server: ^Server, id: u32, rest: string) {
	token, extra := split_word(rest)
	if len(token) == 0 || len(extra) > 0 {
		chat_note(server, id, true, "Usage: /tp <player>")
		return
	}
	who, ok := parse_player(server, id, token)
	if !ok {
		chat_missing(server, id)
		return
	}
	if who == id {
		chat_note(server, id, true, "You are already there.")
		return
	}
	self := server.players[id]
	other := server.players[who]
	place_at(&self.player, other.player)
	told: [CHAT_TEXT]byte
	chat_note(server, id, true, fmt.bprintf(told[:], "Teleported to %d.", who))
	chat_note(server, who, true, fmt.bprintf(told[:], "%d teleported to you.", id))
}

command_tphere :: proc(server: ^Server, id: u32, rest: string) {
	token, extra := split_word(rest)
	if len(token) == 0 || len(extra) > 0 {
		chat_note(server, id, true, "Usage: /tphere <player>")
		return
	}
	who, ok := parse_player(server, id, token)
	if !ok {
		chat_missing(server, id)
		return
	}
	if who == id {
		chat_note(server, id, true, "You are already here.")
		return
	}
	self := server.players[id]
	other := server.players[who]
	place_at(&other.player, self.player)
	told: [CHAT_TEXT]byte
	chat_note(server, id, true, fmt.bprintf(told[:], "Teleported %d to you.", who))
	chat_note(server, who, true, fmt.bprintf(told[:], "%d teleported you.", id))
}

command_give :: proc(server: ^Server, id: u32, rest: string) {
	name, count, kind := give_args(rest)
	if kind == .Missing {
		chat_note(server, id, true, "Usage: /i <item> [amount]")
		return
	}
	if kind == .Bad_Amount {
		buf: [CHAT_TEXT]byte
		chat_note(server, id, true, fmt.bprintf(buf[:], "Amount must be from 1 to %d.", GIVE_MAX))
		return
	}
	item, found := item_from_name(name)
	if !found {
		chat_note(server, id, true, "No such item.")
		return
	}
	player := server.players[id]
	left := inventory_add(&player.inventory, item, count)
	got := count - left
	label := string(item_name(item))
	buf: [CHAT_TEXT]byte
	if got <= 0 {
		chat_note(server, id, true, "Your inventory is full.")
	} else if left > 0 {
		chat_note(server, id, true, fmt.bprintf(buf[:], "Gave you %d %s. The rest did not fit.", got, label))
	} else {
		chat_note(server, id, true, fmt.bprintf(buf[:], "Gave you %d %s.", got, label))
	}
}

Give_Kind :: enum {
	Ok,
	Missing,
	Bad_Amount,
}

// The last word is the amount when it is a number. "oak planks 16" is sixteen
// planks; "wooden shovel" is one shovel.
give_args :: proc(rest: string) -> (name: string, count: int, kind: Give_Kind) {
	body := trim_space(rest)
	if len(body) == 0 {
		return "", 0, .Missing
	}
	last := -1
	for i in 0 ..< len(body) {
		if body[i] == ' ' {
			last = i
		}
	}
	if last >= 0 {
		head := trim_space(body[:last])
		tail := trim_space(body[last+1:])
		if len(head) > 0 {
			if n, parsed := parse_amount(tail); parsed {
				if n < 1 || n > GIVE_MAX {
					return head, 0, .Bad_Amount
				}
				return head, n, .Ok
			}
		}
	}
	return body, 1, .Ok
}

parse_amount :: proc(token: string) -> (n: int, ok: bool) {
	if len(token) == 0 || len(token) > 6 {
		return 0, false
	}
	value := 0
	for i in 0 ..< len(token) {
		ch := token[i]
		if ch < '0' || ch > '9' {
			return 0, false
		}
		value = value*10 + int(ch-'0')
	}
	return value, true
}

place_at :: proc(body: ^Player, at: Player) {
	body.position = at.position
	body.velocity = {}
	body.grounded = at.grounded
}

chat_missing :: proc(server: ^Server, id: u32) {
	list: [80]byte
	buf: [CHAT_TEXT]byte
	chat_note(server, id, true, fmt.bprintf(buf[:], "No such player. Online: %s", list_online(server, list[:])))
}

parse_player :: proc(server: ^Server, speaker: u32, token: string) -> (id: u32, ok: bool) {
	if same_word(token, "me") {
		if server.players[speaker] == nil {
			return 0, false
		}
		return speaker, true
	}
	if len(token) == 0 || len(token) > 9 {
		return 0, false
	}
	value: u32
	for i in 0 ..< len(token) {
		ch := token[i]
		if ch < '0' || ch > '9' {
			return 0, false
		}
		value = value*10 + u32(ch-'0')
	}
	if value == 0 || server.players[value] == nil {
		return 0, false
	}
	return value, true
}

list_online :: proc(server: ^Server, dst: []byte) -> string {
	ids: [NET_MAX_PLAYERS]u32
	n := 0
	for id, _ in server.players {
		if n >= len(ids) {
			break
		}
		ids[n] = id
		n += 1
	}
	for i in 1 ..< n {
		key := ids[i]
		j := i
		for j > 0 && ids[j-1] > key {
			ids[j] = ids[j-1]
			j -= 1
		}
		ids[j] = key
	}
	w := 0
	for i in 0 ..< n {
		if i > 0 {
			if w+2 > len(dst) {
				break
			}
			dst[w] = ','
			dst[w+1] = ' '
			w += 2
		}
		wrote := write_dec(dst[w:], ids[i])
		if wrote == 0 {
			break
		}
		w += wrote
	}
	return string(dst[:w])
}

write_dec :: proc(dst: []byte, value: u32) -> int {
	if len(dst) == 0 {
		return 0
	}
	if value == 0 {
		dst[0] = '0'
		return 1
	}
	tmp: [16]byte
	n := 0
	v := value
	for v > 0 && n < len(tmp) {
		tmp[n] = u8('0' + v%10)
		n += 1
		v /= 10
	}
	if n > len(dst) {
		return 0
	}
	for i in 0 ..< n {
		dst[i] = tmp[n-1-i]
	}
	return n
}

split_word :: proc(s: string) -> (word, rest: string) {
	t := trim_space(s)
	i := 0
	for i < len(t) && t[i] != ' ' {
		i += 1
	}
	return t[:i], trim_space(t[i:])
}

trim_space :: proc(s: string) -> string {
	a := 0
	b := len(s)
	for a < b && s[a] == ' ' {
		a += 1
	}
	for b > a && s[b-1] == ' ' {
		b -= 1
	}
	return s[a:b]
}

same_word :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if fold_ascii(a[i]) != fold_ascii(b[i]) {
			return false
		}
	}
	return true
}

fold_ascii :: proc(ch: u8) -> u8 {
	if ch >= 'A' && ch <= 'Z' {
		return ch + 32
	}
	return ch
}

Item_Alias :: struct {
	name: string,
	item: Item,
}

ITEM_ALIASES :: [?]Item_Alias{
	{"stick", {kind = .Stick}},
	{"wooden shovel", {kind = .Wood_Shovel}},
	{"wood shovel", {kind = .Wood_Shovel}},
	{"wooden pickaxe", {kind = .Wood_Pickaxe}},
	{"wood pickaxe", {kind = .Wood_Pickaxe}},
	{"wooden axe", {kind = .Wood_Axe}},
	{"wood axe", {kind = .Wood_Axe}},
	{"stone shovel", {kind = .Stone_Shovel}},
	{"stone pickaxe", {kind = .Stone_Pickaxe}},
	{"stone axe", {kind = .Stone_Axe}},
	{"iron shovel", {kind = .Iron_Shovel}},
	{"iron pickaxe", {kind = .Iron_Pickaxe}},
	{"iron axe", {kind = .Iron_Axe}},
	{"iron ingot", {kind = .Iron_Ingot}},
	{"ingot", {kind = .Iron_Ingot}},
	{"grass", {kind = .Block, block = .Grass}},
	{"dirt", {kind = .Block, block = .Dirt}},
	{"stone", {kind = .Block, block = .Stone}},
	{"bedrock", {kind = .Block, block = .Bedrock}},
	{"coal ore", {kind = .Block, block = .Coal_Ore}},
	{"iron ore", {kind = .Block, block = .Iron_Ore}},
	{"gold ore", {kind = .Block, block = .Gold_Ore}},
	{"water", {kind = .Block, block = .Water}},
	{"oak log", {kind = .Block, block = .Oak_Log}},
	{"log", {kind = .Block, block = .Oak_Log}},
	{"oak leaves", {kind = .Block, block = .Oak_Leaves}},
	{"leaves", {kind = .Block, block = .Oak_Leaves}},
	{"oak planks", {kind = .Block, block = .Oak_Planks}},
	{"planks", {kind = .Block, block = .Oak_Planks}},
	{"workbench", {kind = .Block, block = .Workbench}},
	{"crafting table", {kind = .Block, block = .Workbench}},
	{"oak sapling", {kind = .Block, block = .Oak_Sapling}},
	{"sapling", {kind = .Block, block = .Oak_Sapling}},
	{"sand", {kind = .Block, block = .Sand}},
	{"gravel", {kind = .Block, block = .Gravel}},
	{"oak door", {kind = .Block, block = .Oak_Door}},
	{"door", {kind = .Block, block = .Oak_Door}},
}

item_from_name :: proc(name: string) -> (item: Item, ok: bool) {
	folded: [64]byte
	key := fold_name(folded[:], name)
	if len(key) == 0 {
		return {}, false
	}
	for alias in ITEM_ALIASES {
		if key == alias.name {
			return alias.item, true
		}
	}
	return {}, false
}

fold_name :: proc(dst: []byte, src: string) -> string {
	n := 0
	spaced := true
	for i in 0 ..< len(src) {
		ch := src[i]
		if ch == '_' || ch == ' ' || ch == '-' {
			if spaced {
				continue
			}
			if n >= len(dst) {
				break
			}
			dst[n] = ' '
			n += 1
			spaced = true
			continue
		}
		if ch >= 'A' && ch <= 'Z' {
			ch += 32
		}
		digit := ch >= '0' && ch <= '9'
		letter := ch >= 'a' && ch <= 'z'
		if !digit && !letter {
			continue
		}
		if n >= len(dst) {
			break
		}
		dst[n] = ch
		n += 1
		spaced = false
	}
	if n > 0 && dst[n-1] == ' ' {
		n -= 1
	}
	return string(dst[:n])
}

write_chat_notes :: proc(buf: ^[dynamic]u8, server: ^Server, self: u32) {
	match := 0
	for &note in server.notes {
		if note.to == 0 || note.to == self {
			match += 1
		}
	}
	skip := match - CHAT_NOTES_MAX
	if skip < 0 {
		skip = 0
	}
	write_u32(buf, u32(match-skip))
	seen := 0
	for &note in server.notes {
		if note.to != 0 && note.to != self {
			continue
		}
		if seen < skip {
			seen += 1
			continue
		}
		seen += 1
		append(buf, u8(1) if note.system else 0)
		n := note.n
		if n < 0 {
			n = 0
		}
		if n > CHAT_TEXT-1 {
			n = CHAT_TEXT - 1
		}
		append(buf, u8(n))
		append(buf, ..note.text[:n])
	}
}

read_chat_notes :: proc(client: ^Client, reader: ^Reader) -> bool {
	count := int(read_u32(reader))
	if !reader.ok || count < 0 || count > CHAT_NOTES_MAX {
		return false
	}
	for _ in 0 ..< count {
		system := read_u8(reader) != 0
		n := int(read_u8(reader))
		if !reader.ok || n <= 0 || n >= CHAT_TEXT || reader.i+n > len(reader.b) {
			reader.ok = false
			return false
		}
		chat_push(&client.chat, system, string(reader.b[reader.i:][:n]))
		reader.i += n
	}
	return reader.ok
}

draw_chat :: proc(font: rl.Font, chat: ^Chat) {
	screen_h := f32(rl.GetScreenHeight())
	hotbar_top := screen_h - SLOT_SIZE - HOTBAR_SCREEN_MARGIN
	// The held item's name sits just above the hotbar. Leave it that row.
	base := hotbar_top - HUD_SIZE - 12
	if chat.open {
		bar_h: f32 = 28
		bar_w := f32(rl.GetScreenWidth()) - 16
		if bar_w > 520 {
			bar_w = 520
		}
		bar_y := base - 6 - bar_h
		rl.DrawRectangleRec({8, bar_y, bar_w, bar_h}, {0, 0, 0, 160})
		fit: [CHAT_LINE + 1]byte
		_ = fit_tail(font, chat.line[:], chat.len, bar_w-16, fit[:])
		text_y := bar_y + (bar_h-HUD_SIZE)*0.5
		rl.DrawTextEx(font, cstring(raw_data(fit[:])), {16, text_y}, HUD_SIZE, HUD_SPACING, rl.WHITE)
		if int(rl.GetTime()*2) % 2 == 0 {
			width := rl.MeasureTextEx(font, cstring(raw_data(fit[:])), HUD_SIZE, HUD_SPACING).x
			rl.DrawRectangleRec({16 + width + 1, text_y, 2, HUD_SIZE}, rl.WHITE)
		}
		base = bar_y - 4
	}

	start := len(chat.lines) - CHAT_VISIBLE
	if start < 0 {
		start = 0
	}
	shown: [CHAT_VISIBLE]int
	n := 0
	for i in start ..< len(chat.lines) {
		if !chat.open && chat.lines[i].age >= CHAT_LINGER {
			continue
		}
		shown[n] = i
		n += 1
	}
	line_h := HUD_SIZE + 4
	y := base
	for i := n - 1; i >= 0; i -= 1 {
		line := &chat.lines[shown[i]]
		y -= line_h
		alpha: u8 = 255
		if !chat.open {
			remain := CHAT_LINGER - line.age
			if remain < 1 {
				alpha = u8(clamp(remain, 0, 1) * 255)
			}
		}
		color := rl.Color{255, 255, 255, alpha}
		if line.system {
			color = {255, 214, 102, alpha}
		}
		draw_chat_text(font, cstring(raw_data(line.text[:])), 8, y, color, alpha)
	}
}

fit_tail :: proc(font: rl.Font, line: []byte, n: int, max_w: f32, dst: []byte) -> int {
	if len(dst) == 0 {
		return 0
	}
	start := 0
	for {
		m := n - start
		if m > len(dst)-1 {
			m = len(dst) - 1
		}
		if m < 0 {
			m = 0
		}
		copy(dst[:m], line[start:][:m])
		dst[m] = 0
		width := rl.MeasureTextEx(font, cstring(raw_data(dst)), HUD_SIZE, HUD_SPACING).x
		if width <= max_w || start >= n {
			return m
		}
		start += 1
	}
}

draw_chat_text :: proc(font: rl.Font, text: cstring, x, y: f32, color: rl.Color, alpha: u8) {
	rl.DrawTextEx(font, text, {x + 1, y + 1}, HUD_SIZE, HUD_SPACING, {0, 0, 0, alpha})
	rl.DrawTextEx(font, text, {x, y}, HUD_SIZE, HUD_SPACING, color)
}

// The number /tp uses. Drawn in front of the camera, above the head.
draw_nameplates :: proc(font: rl.Font, camera: rl.Camera3D, others: []Remote_View) {
	forward := camera.target - camera.position
	screen_w := f32(rl.GetScreenWidth())
	screen_h := f32(rl.GetScreenHeight())
	for other in others {
		head := other.position + [3]f32{0, PLAYER_HEIGHT + 0.35, 0}
		to := head - camera.position
		if forward.x*to.x + forward.y*to.y + forward.z*to.z <= 0.2 {
			continue
		}
		if to.x*to.x + to.y*to.y + to.z*to.z > 48*48 {
			continue
		}
		screen := rl.GetWorldToScreen(head, camera)
		if screen.x < -40 || screen.y < -40 || screen.x > screen_w+40 || screen.y > screen_h+40 {
			continue
		}
		text := rl.TextFormat("%d", c.int(other.id))
		width := rl.MeasureTextEx(font, text, HUD_SIZE, HUD_SPACING).x
		x := screen.x - width*0.5
		y := screen.y - HUD_SIZE - 4
		rl.DrawRectangleRec({x - 5, y - 2, width + 10, HUD_SIZE + 4}, {0, 0, 0, 140})
		draw_hud_text(font, text, c.int(x), c.int(y), rl.WHITE)
	}
}
