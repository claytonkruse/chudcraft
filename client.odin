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
client_read_input :: proc(player: Player, playing, inventory_open: bool, move_dt: f32) -> Client_Input {
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
		return input
	}
	if inventory_open {
		left := rl.IsMouseButtonPressed(.LEFT)
		right := rl.IsMouseButtonPressed(.RIGHT)
		if left || right {
			index, ok := inventory_slot_at(rl.GetMousePosition())
			if ok {
				input.action = .Click_Right if right && !left else .Click_Left
				input.slot = index
			}
		}
	}
	return input
}
