package main

import rl "vendor:raylib"

// A view of one server. The world here is a copy: drawing and the crosshair
// read it, and block changes arrive from the server after each step.
Client :: struct {
	id:        u32,
	server:    ^Server,
	world:     World,
	player:    Player,
	inventory: Inventory,
	seed:      i64,
	others:    [dynamic]Remote_View,
	drops:     [dynamic]Drop_View,
	walks:     map[u32]Walk_Cycle,
	// This window only. Another player does not see your camera.
	third_person: bool,
	// Set when this window joined someone else's host. Nil for the host itself.
	link:      ^Client_Link,
	// This window's mouse gesture. The server hears it when the button comes up.
	drag:      Drag,
	// The previous left click, so a second one on the same slot can gather.
	clicks:    Click_Memory,
	// Ingredients on placed workbenches, copied from the server each step.
	tables:    map[[3]int][CRAFT3_N]Slot,
	// The block whose 3x3 this window is editing. Meaningful while inventory.table.
	table_at:  [3]int,
}

client_connect :: proc(client: ^Client, server: ^Server, render_distance: int) {
	client.server = server
	client.seed = server.seed
	// A loaded world already has its player. A new one still has to be born.
	if len(server.players) == 0 {
		client.id = server_join(server, render_distance)
	} else {
		for id, _ in server.players {
			client.id = id
			break
		}
		if player := server.players[client.id]; player != nil {
			player.render_distance = render_radius(render_distance)
		}
	}
	if player := server.players[client.id]; player != nil {
		bx := block_index_horizontal(player.player.position.x)
		bz := block_index_horizontal(player.player.position.z)
		spots := [1]Load_Spot{{
			x = bx,
			z = bz,
			radius = player.render_distance,
		}}
		world_unload_far(&server.gen, &server.world, spots[:])
	}
	for key, chunk in server.world.chunks {
		copy := new(Chunk)
		copy.blocks = chunk.blocks
		client.world.chunks[key] = copy
	}
	client_pull(client, render_distance)
}

client_destroy :: proc(client: ^Client) {
	if client.server != nil && client.id != 0 {
		server_leave(client.server, client.id)
	}
	client_link_close(client)
	delete(client.others)
	delete(client.drops)
	delete(client.walks)
	delete(client.tables)
	world_destroy(&client.world)
	client.server = nil
	client.id = 0
}

// Copies the latest server state into this view. The open inventory screen
// stays as this client left it; that is not world state.
client_pull :: proc(client: ^Client, render_distance: int) {
	if client.server == nil {
		return
	}
	player := client.server.players[client.id]
	if player != nil {
		open := client.inventory.open
		suppress := client.inventory.suppress_look
		table := client.inventory.table
		client.player = player.player
		client.inventory = player.inventory
		client.inventory.open = open
		client.inventory.suppress_look = suppress
		client.inventory.table = table
		delete(client.tables)
		client.tables = nil
		for at, grid in client.server.tables {
			client.tables[at] = grid
		}
		apply_open_table(client)
	}
	for change in client.server.world.changes {
		store_block(&client.world, change.x, change.y, change.z, change.block)
	}
	// Columns generated this step, copied from the server after the edits so a
	// chunk that was both mined and generated keeps the server's end state.
	for key in client.server.world.sync_queue {
		src := client.server.world.chunks[key]
		if src == nil {
			continue
		}
		dst := client.world.chunks[key]
		if dst == nil {
			dst = new(Chunk)
			client.world.chunks[key] = dst
		}
		dst.blocks = src.blocks
		dst.dirty = true
		src.queued = false
	}
	clear(&client.server.world.sync_queue)
	client_cull_chunks(client, render_distance)
	clear(&client.drops)
	for drop in client.server.drops {
		append(&client.drops, Drop_View{
			item     = drop.item,
			count    = drop.count,
			position = drop.position,
			age      = drop.age,
			phase    = drop.phase,
		})
	}
	clear(&client.others)
	for id, other in client.server.players {
		if id == client.id {
			continue
		}
		append(&client.others, Remote_View{
			id = id,
			position = other.player.position,
			yaw = other.player.yaw,
			pitch = other.player.pitch,
		})
	}
}

// Forgets chunks past the unload margin. The server sends a column again when
// this player walks back into its render distance.
client_cull_chunks :: proc(client: ^Client, render_distance: int) {
	bx := block_index_horizontal(client.player.position.x)
	bz := block_index_horizontal(client.player.position.z)
	origin := chunk_of(bx, 0, bz)
	drop: [dynamic][3]int
	defer delete(drop)
	limit := unload_radius(render_distance)
	for key, _ in client.world.chunks {
		if !column_in_radius(key.x, key.z, origin.x, origin.z, limit) {
			append(&drop, key)
		}
	}
	for key in drop {
		chunk := client.world.chunks[key]
		delete(chunk.pending)
		free(chunk)
		delete_key(&client.world.chunks, key)
	}
}

// The screen shows the slots of the workbench it was opened on.
apply_open_table :: proc(client: ^Client) {
	if !client.inventory.table {
		return
	}
	if grid, ok := client.tables[client.table_at]; ok {
		client.inventory.craft3 = grid
	} else {
		client.inventory.craft3 = {}
	}
}

// Keys and mouse become a message. Nothing here changes the world.
client_read_input :: proc(player: Player, playing, inventory_open, table: bool, inv: Inventory, drag: ^Drag, clicks: ^Click_Memory, selected: int, move_dt: f32) -> Client_Input {
	input := Client_Input{
		move = {
			dt = move_dt,
			yaw = player.yaw,
			pitch = player.pitch,
			forward = rl.IsKeyDown(.W),
			back = rl.IsKeyDown(.S),
			left = rl.IsKeyDown(.A),
			right = rl.IsKeyDown(.D),
			jump = rl.IsKeyDown(.SPACE),
		},
	}
	if !inventory_open {
		drag^ = {}
		clicks^ = {}
	}
	if playing {
		input.attack = rl.IsMouseButtonPressed(.LEFT)
		input.use = rl.IsMouseButtonPressed(.RIGHT)
		// Scroll up moves toward slot 1, matching the order of the number keys.
		wheel := rl.GetMouseWheelMove()
		if wheel > 0 {
			input.action = .Scroll_Up
		} else if wheel < 0 {
			input.action = .Scroll_Down
		}
		for key, i in HOTBAR_KEYS {
			if rl.IsKeyPressed(key) {
				input.action = .Select
				input.slot = i
			}
		}
		// One from the selected hotbar slot, thrown along the look.
		if rl.IsKeyPressed(.Q) {
			input.action = .Drop
			input.slot = selected
		}
		return input
	}
	if inventory_open {
		mouse := rl.GetMousePosition()
		// The slot under the cursor, or the stack on it when the cursor is elsewhere.
		if rl.IsKeyPressed(.Q) {
			drag^ = {}
			clicks^ = {}
			input.action = .Drop
			if index, ok := inventory_slot_at(mouse, table); ok {
				input.slot = index
			} else {
				input.slot = -1
			}
			return input
		}
		left_down := rl.IsMouseButtonDown(.LEFT)
		right_down := rl.IsMouseButtonDown(.RIGHT)
		left_pressed := rl.IsMouseButtonPressed(.LEFT)
		right_pressed := rl.IsMouseButtonPressed(.RIGHT)
		shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
		if (drag.button == .Left && !left_down) || (drag.button == .Right && !right_down) {
			// The slot under the pointer on the way up still belongs to the drag.
			if index, ok := inventory_slot_at(mouse, table); ok {
				drag_note(drag, inv, index)
			}
			drag_finish(drag, &input, clicks)
			return input
		}
		if drag.button != .None {
			if index, ok := inventory_slot_at(mouse, table); ok {
				drag_note(drag, inv, index)
			}
			return input
		}
		// A stack on the cursor can be spread. The result slot still crafts,
		// and shift-click still moves a whole stack, so neither starts a drag.
		index, on_slot := inventory_slot_at(mouse, table)
		result := on_slot && (index == CRAFT2_RESULT || index == CRAFT3_RESULT)
		if inv.held.count > 0 && !shift && !result && (left_pressed || right_pressed) && !(left_pressed && right_pressed) {
			drag.button = .Left if left_pressed else .Right
			drag.on_slot = on_slot
			drag.origin = index
			drag.outside = !on_slot && !rl.CheckCollisionPointRec(mouse, inventory_layout(true, table).panel)
			// Judged at the press, so a normal double-click still counts after the button comes up.
			if left_pressed && on_slot && left_click_action(clicks, index, inv.held.count) == .Gather {
				drag.gather = true
			}
			if on_slot {
				drag_note(drag, inv, index)
			}
			return input
		}
		if left_pressed || right_pressed {
			if on_slot {
				if left_pressed && shift {
					clicks^ = {}
					input.action = .Shift
				} else if right_pressed && !left_pressed {
					clicks^ = {}
					input.action = .Click_Right
				} else {
					input.action = left_click_action(clicks, index, inv.held.count)
				}
				input.slot = index
			} else if !rl.CheckCollisionPointRec(mouse, inventory_layout(true, table).panel) {
				// Past the panel edge, the stack on the cursor leaves the inventory.
				// Left sends the whole stack, right sends one.
				input.action = .Drop_All if left_pressed else .Drop
				input.slot = -1
			}
		}
	}
	return input
}

drag_note :: proc(drag: ^Drag, inv: Inventory, index: int) {
	if drag.count >= DRAG_MAX || index < 0 || index > CRAFT3_RESULT {
		return
	}
	for i in 0 ..< drag.count {
		if drag.slots[i] == index {
			return
		}
	}
	slot, ok := drag_slot_read(inv, index)
	if !ok {
		return
	}
	if slot.count > 0 && (!item_same(slot.item, inv.held.item) || slot.count >= stack_limit(inv.held.item)) {
		return
	}
	drag.slots[drag.count] = index
	drag.count += 1
}

// Two quick left clicks on one slot. Long enough to be deliberate, short
// enough that a later click still places the stack.
DOUBLE_CLICK :: 0.25

Click_Memory :: struct {
	time:  f64,
	slot:  int,
	armed: bool,
}

// The second click gathers instead of putting the stack back down.
left_click_action :: proc(clicks: ^Click_Memory, slot, held: int) -> Inventory_Action {
	now := rl.GetTime()
	if clicks.armed && clicks.slot == slot && held > 0 && now-clicks.time <= DOUBLE_CLICK {
		clicks^ = {}
		return .Gather
	}
	clicks.armed = true
	clicks.slot = slot
	clicks.time = now
	return .Click_Left
}

// Two or more slots is a spread. One slot, or none, is the click that press
// would have been: place, swap, or drop past the panel.
drag_finish :: proc(drag: ^Drag, input: ^Client_Input, clicks: ^Click_Memory) {
	left := drag.button == .Left
	if drag.count >= 2 {
		clicks^ = {}
		input.action = .Drag_Left if left else .Drag_Right
		n := drag.count
		if n > DRAG_MAX {
			n = DRAG_MAX
		}
		input.drag_n = n
		for i in 0 ..< n {
			input.drag[i] = drag.slots[i]
		}
	} else if drag.on_slot {
		if left && drag.gather {
			input.action = .Gather
		} else if left {
			input.action = .Click_Left
		} else {
			clicks^ = {}
			input.action = .Click_Right
		}
		input.slot = drag.origin
	} else if drag.outside {
		clicks^ = {}
		input.action = .Drop_All if left else .Drop
		input.slot = -1
	}
	drag^ = {}
}
