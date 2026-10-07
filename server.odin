package main

// The world, the players, and their inventories live here. A client sends an
// input and copies the result back; it does not write the world. Today that
// copy happens in this process. The same input and the same block list are
// what a later connection would send across a socket.

Inventory_Action :: enum u8 {
	None,
	Select,
	Scroll_Up,
	Scroll_Down,
	Click_Left,
	Click_Right,
	Stow,
}

// One frame from one client. Look angles are the client's, because the mouse
// stays on that machine. Everything the angles are used for is checked here.
Client_Input :: struct {
	move:          Move_Input,
	attack, use:   bool,
	action:        Inventory_Action,
	slot:          int,
}

Player_Command :: struct {
	id:    u32,
	input: Client_Input,
}

// Where another player is standing. The client that owns them already has the
// full player; everyone else gets this.
Remote_View :: struct {
	id:               u32,
	position:         [3]f32,
	yaw, pitch:       f32,
}

Server_Player :: struct {
	player:    Player,
	inventory: Inventory,
}

Server :: struct {
	world:   World,
	seed:    i64,
	players: map[u32]^Server_Player,
	next_id: u32,
	// Reused each step so every player's neighborhood is checked once.
	foci: [dynamic][3]int,
}

server_start :: proc(seed: i64) -> Server {
	server: Server
	server.seed = seed
	generate_world(&server.world, seed)
	server.world.record = true
	return server
}

server_destroy :: proc(server: ^Server) {
	for _, player in server.players {
		free(player)
	}
	delete(server.players)
	delete(server.foci)
	world_destroy(&server.world)
}

server_join :: proc(server: ^Server) -> u32 {
	server.next_id += 1
	player := new(Server_Player)
	player.player = {
		position = spawn_position(&server.world),
		grounded = true,
	}
	server.players[server.next_id] = player
	return server.next_id
}

server_leave :: proc(server: ^Server, id: u32) {
	player := server.players[id]
	if player == nil {
		return
	}
	delete_key(&server.players, id)
	free(player)
}

// Applies every command, then advances the world once. Block changes stay on
// the world until the next step so each client can copy them.
server_step :: proc(server: ^Server, commands: []Player_Command, frame_dt: f64) -> Grow_Report {
	clear(&server.world.changes)
	for command in commands {
		server_apply(server, command.id, command.input)
	}
	clear(&server.foci)
	for _, player in server.players {
		append(&server.foci, chunk_of(
			block_index_horizontal(player.player.position.x),
			0,
			block_index_horizontal(player.player.position.z),
		))
	}
	return grow_advance(&server.world, server.foci[:], frame_dt)
}

server_apply :: proc(server: ^Server, id: u32, input: Client_Input) {
	player := server.players[id]
	if player == nil {
		return
	}
	simulate_player(&player.player, &server.world, input.move)
	server_inventory(&player.inventory, input.action, input.slot)
	if input.attack {
		server_attack(server, player)
	}
	if input.use {
		server_use(server, player)
	}
}

server_inventory :: proc(inv: ^Inventory, action: Inventory_Action, slot: int) {
	switch action {
	case .None:
	case .Select:
		if slot >= 0 && slot < HOTBAR_SLOTS {
			inv.selected = slot
		}
	case .Scroll_Up:
		inv.selected = (inv.selected - 1) %% HOTBAR_SLOTS
	case .Scroll_Down:
		inv.selected = (inv.selected + 1) %% HOTBAR_SLOTS
	case .Click_Left:
		if slot >= 0 && slot < INVENTORY_SLOTS {
			inventory_click_left(&inv.held, &inv.slots[slot])
		}
	case .Click_Right:
		if slot >= 0 && slot < INVENTORY_SLOTS {
			inventory_click_right(&inv.held, &inv.slots[slot])
		}
	case .Stow:
		inventory_stow(inv)
	}
}

server_attack :: proc(server: ^Server, player: ^Server_Player) {
	hit, x, y, z, _, _, _ := server_ray(server, player)
	if !hit {
		return
	}
	broken := get_block(&server.world, x, y, z)
	if breakable(broken) && inventory_add(&player.inventory, broken, 1) == 0 {
		set_block(&server.world, x, y, z, .Air)
	}
}

server_use :: proc(server: ^Server, player: ^Server_Player) {
	hit, _, _, _, px, py, pz := server_ray(server, player)
	if !hit {
		return
	}
	inventory_place(&player.inventory, player.player, &server.world, px, py, pz)
}

server_ray :: proc(server: ^Server, player: ^Server_Player) -> (hit: bool, x, y, z, px, py, pz: int) {
	eye := player.player.position + {0, PLAYER_EYE_HEIGHT, 0}
	dir := look_direction(player.player.yaw, player.player.pitch)
	return raycast_block(&server.world, eye, dir, MINE_REACH)
}
