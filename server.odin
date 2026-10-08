package main

// The world, the players, and their inventories live here. A client sends an
// input and copies the result back; it does not write the world. In this
// process that copy is direct. A hosted world sends the same input and the
// same block list across a socket, which is what another player's game joins.

Inventory_Action :: enum u8 {
	None,
	Select,
	Scroll_Up,
	Scroll_Down,
	Click_Left,
	Click_Right,
	Stow,
	Drop,
	Drop_All,
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
// phase and amount are the walk cycle. They are derived on the client from
// how far this player moved since the previous draw, so they are not replicated.
Remote_View :: struct {
	id:               u32,
	position:         [3]f32,
	yaw, pitch:       f32,
	phase, amount:    f32,
}

// Remembers a remote player's stride between draws. The view itself is rebuilt
// every step, which would otherwise restart the animation.
Walk_Cycle :: struct {
	phase, amount: f32,
	x, z:          f32,
	has:           bool,
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
	foci:    [dynamic][3]int,
	drops:   [dynamic]Drop,
	// Pop direction. The low bit is forced on so the generator cannot sit at zero.
	drop_rng: u64,
	// Present only while this process is hosting. Solo play leaves it empty.
	host:    Host_Link,
}

server_start :: proc(seed: i64) -> Server {
	server: Server
	server.seed = seed
	server.drop_rng = u64(seed) | 1
	generate_world(&server.world, seed)
	server.world.record = true
	return server
}

server_destroy :: proc(server: ^Server) {
	host_shutdown(server)
	for _, player in server.players {
		free(player)
	}
	delete(server.players)
	delete(server.foci)
	delete(server.drops)
	world_destroy(&server.world)
}

server_join :: proc(server: ^Server) -> u32 {
	server.next_id += 1
	// A step apart, so two people are not born inside one body.
	x := SPAWN_X + int(server.next_id-1)*2
	player := new(Server_Player)
	player.player = {
		position = {f32(x), f32(surface_height(&server.world, x, SPAWN_Z)), f32(SPAWN_Z)},
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
	drops_advance(&server.drops, &server.world, server.players, f32(frame_dt))
	return grow_advance(&server.world, server.foci[:], frame_dt)
}

server_apply :: proc(server: ^Server, id: u32, input: Client_Input) {
	player := server.players[id]
	if player == nil {
		return
	}
	simulate_player(&player.player, &server.world, input.move)
	server_inventory(server, player, input.action, input.slot)
	if input.attack {
		server_attack(server, player)
	}
	if input.use {
		server_use(server, player)
	}
}

server_inventory :: proc(server: ^Server, player: ^Server_Player, action: Inventory_Action, slot: int) {
	inv := &player.inventory
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
	case .Click_Left, .Click_Right:
		whole := action == .Click_Left
		if slot == CRAFT2_RESULT {
			craft_take(inv.craft2[:], 2, &inv.held, whole)
		} else if slot == CRAFT3_RESULT {
			craft_take(inv.craft3[:], 3, &inv.held, whole)
		} else if stack, ok := inventory_slot_mut(inv, slot); ok {
			if whole {
				inventory_click_left(&inv.held, stack)
			} else {
				inventory_click_right(&inv.held, stack)
			}
		}
	case .Stow:
		// Closing returns whatever was sitting in either crafting grid. A full
		// inventory drops the rest, so the ingredients are not stuck off screen.
		server_empty_grid(server, player, inv.craft2[:])
		server_empty_grid(server, player, inv.craft3[:])
		inventory_stow(inv)
	case .Drop:
		server_drop_item(server, player, slot, false)
	case .Drop_All:
		server_drop_item(server, player, slot, true)
	}
}

// Throws from a slot along the look. Slot -1 is the stack on the cursor.
// whole sends the entire stack; otherwise a single item leaves it.
server_drop_item :: proc(server: ^Server, player: ^Server_Player, slot: int, whole: bool) {
	stack: ^Slot
	if slot == -1 {
		stack = &player.inventory.held
	} else if found, ok := inventory_slot_mut(&player.inventory, slot); ok {
		stack = found
	} else {
		return
	}
	if stack.count <= 0 || item_empty(stack.item) {
		return
	}
	take := stack.count if whole else 1
	item := stack.item
	stack.count -= take
	if stack.count == 0 {
		stack^ = {}
	}
	origin := player.player.position + {0, PLAYER_EYE_HEIGHT - 0.3, 0}
	dir := look_direction(player.player.yaw, player.player.pitch)
	drop_throw(&server.drops, &server.drop_rng, item, take, origin, dir)
}

// Puts a crafting grid back into the inventory, and throws what does not fit.
server_empty_grid :: proc(server: ^Server, player: ^Server_Player, grid: []Slot) {
	for &slot in grid {
		if slot.count <= 0 {
			continue
		}
		left := inventory_add(&player.inventory, slot.item, slot.count)
		if left > 0 {
			origin := player.player.position + {0, PLAYER_EYE_HEIGHT - 0.3, 0}
			dir := look_direction(player.player.yaw, player.player.pitch)
			drop_throw(&server.drops, &server.drop_rng, slot.item, left, origin, dir)
		}
		slot = {}
	}
}

server_attack :: proc(server: ^Server, player: ^Server_Player) {
	hit, x, y, z, _, _, _ := server_ray(server, player)
	if !hit {
		return
	}
	broken := get_block(&server.world, x, y, z)
	if !breakable(broken) {
		return
	}
	set_block(&server.world, x, y, z, .Air)
	drop_spawn(&server.drops, &server.drop_rng, item_block(broken), 1, x, y, z)
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
