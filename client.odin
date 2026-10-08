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
}

client_connect :: proc(client: ^Client, server: ^Server) {
	client.server = server
	client.id = server_join(server)
	client.seed = server.seed
	for key, chunk in server.world.chunks {
		copy := new(Chunk)
		copy.blocks = chunk.blocks
		client.world.chunks[key] = copy
	}
	client_pull(client)
}

client_destroy :: proc(client: ^Client) {
	if client.server != nil && client.id != 0 {
		server_leave(client.server, client.id)
	}
	delete(client.others)
	delete(client.drops)
	world_destroy(&client.world)
	client.server = nil
	client.id = 0
}

// Copies the latest server state into this view. The open inventory screen
// stays as this client left it; that is not world state.
client_pull :: proc(client: ^Client) {
	if client.server == nil {
		return
	}
	player := client.server.players[client.id]
	if player != nil {
		open := client.inventory.open
		suppress := client.inventory.suppress_look
		client.player = player.player
		client.inventory = player.inventory
		client.inventory.open = open
		client.inventory.suppress_look = suppress
	}
	for change in client.server.world.changes {
		store_block(&client.world, change.x, change.y, change.z, change.block)
	}
	clear(&client.drops)
	for drop in client.server.drops {
		append(&client.drops, Drop_View{
			block    = drop.block,
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

// Keys and mouse become a message. Nothing here changes the world.
client_read_input :: proc(player: Player, playing, inventory_open: bool, selected: int, move_dt: f32) -> Client_Input {
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
		// The slot under the cursor, or the stack on it when the cursor is elsewhere.
		if rl.IsKeyPressed(.Q) {
			input.action = .Drop
			if index, ok := inventory_slot_at(rl.GetMousePosition()); ok {
				input.slot = index
			} else {
				input.slot = -1
			}
			return input
		}
		left := rl.IsMouseButtonPressed(.LEFT)
		right := rl.IsMouseButtonPressed(.RIGHT)
		if left || right {
			mouse := rl.GetMousePosition()
			index, ok := inventory_slot_at(mouse)
			if ok {
				input.action = .Click_Right if right && !left else .Click_Left
				input.slot = index
			} else if !rl.CheckCollisionPointRec(mouse, inventory_layout(true).panel) {
				// Past the panel edge, the stack on the cursor leaves the inventory.
				// Left sends the whole stack, right sends one.
				input.action = .Drop_All if left else .Drop
				input.slot = -1
			}
		}
	}
	return input
}
