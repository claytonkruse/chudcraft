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
	Shift,
	Stow,
	Drop,
	Drop_All,
	Drag_Left,
	Drag_Right,
	Gather,
	// Opens the 3x3 of the workbench at table_x/y/z.
	Open_Table,
}

// One frame from one client. Look angles are the client's, because the mouse
// stays on that machine. Everything the angles are used for is checked here.
Client_Input :: struct {
	move:          Move_Input,
	attack, use:   bool,
	action:        Inventory_Action,
	slot:          int,
	// Set for a drag. Ignored by every other action.
	drag_n:        int,
	drag:          [DRAG_MAX]int,
	// The workbench Open_Table is aimed at. Ignored by every other action.
	table_x, table_y, table_z: int,
	// Chunks this client keeps loaded. The options screen sets it.
	render_distance: int,
	// A chat line or a command, sent the frame Enter was pressed. Empty otherwise.
	say_n:           int,
	say:             [CHAT_LINE]byte,
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
	// Torso yaw. The head uses yaw, and this lags behind it.
	body:             f32,
	// The hotbar stack in this player's hand.
	held:             Item,
}

// Remembers a remote player's stride between draws. The view itself is rebuilt
// every step, which would otherwise restart the animation.
Walk_Cycle :: struct {
	phase, amount: f32,
	x, z:          f32,
	// Torso yaw. The look yaw is the head, and this follows a step later.
	body:          f32,
	has:           bool,
}

Server_Player :: struct {
	player:    Player,
	inventory: Inventory,
	// Which placed workbench this player is using. The nine slots live on
	// that block, not in the inventory, so closing the screen leaves them there.
	table_open: bool,
	table_at:   [3]int,
	// Chunks kept loaded around this player. Set from their options screen.
	render_distance: int,
	// The block this player is currently digging. Not sent; the client animates
	// its own copy from the same hold.
	mine: Mine,
}

Server :: struct {
	world:   World,
	seed:    i64,
	players: map[u32]^Server_Player,
	next_id: u32,
	// Reused each step so every player's neighborhood is checked once.
	foci:    [dynamic][3]int,
	drops:   [dynamic]Drop,
	// Ingredients sitting on placed workbenches, keyed by the block.
	tables:  map[[3]int][CRAFT3_N]Slot,
	// Pop direction. The low bit is forced on so the generator cannot sit at zero.
	drop_rng: u64,
	// Present only while this process is hosting. Solo play leaves it empty.
	host:    Host_Link,
	// Lines produced this step. Cleared with the block edits, then copied out.
	notes:   [dynamic]Chat_Note,
	// Columns still waiting. The spawn column is filled before anyone joins.
	gen:     World_Gen,
}

server_start :: proc(seed: i64) -> Server {
	server: Server
	server.seed = seed
	server.drop_rng = u64(seed) | 1
	world_gen_init(&server.gen)
	// The column under spawn, so the first frame has ground to stand on.
	// Everyone is born in this column; a later id that walks out of it is filled
	// in server_join. The rest of the render distance follows one column a frame.
	server.world.spawn_x, server.world.spawn_z = land_spawn(seed)
	born := chunk_of(server.world.spawn_x, 0, server.world.spawn_z)
	world_gen_ensure(&server.gen, &server.world, seed, born.x, born.z)
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
	delete(server.tables)
	delete(server.notes)
	world_gen_destroy(&server.gen)
	world_destroy(&server.world)
}

server_join :: proc(server: ^Server, render_distance: int) -> u32 {
	server.next_id += 1
	// A step apart, so two people are not born inside one body.
	x := server.world.spawn_x + int(server.next_id-1)*2
	z := server.world.spawn_z
	// The column has to exist before the feet are planted on it. Play is already
	// recording, so this write is a chunk copy rather than one change per block.
	born := chunk_of(x, 0, z)
	record := server.world.record
	server.world.record = false
	server.world.syncing = record
	world_gen_ensure(&server.gen, &server.world, server.seed, born.x, born.z)
	server.world.syncing = false
	server.world.record = record
	player := new(Server_Player)
	player.render_distance = render_radius(render_distance)
	player.player = {
		position = {f32(x), f32(surface_height(&server.world, x, z)), f32(z)},
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
	clear(&server.notes)
	for command in commands {
		server_apply(server, command.id, command.input)
	}
	clear(&server.foci)
	// Where people are standing, in blocks, so the next column is the one they
	// are about to walk into and not merely the same chunk.
	spots: [32]Load_Spot
	n := 0
	for _, player in server.players {
		bx := block_index_horizontal(player.player.position.x)
		bz := block_index_horizontal(player.player.position.z)
		append(&server.foci, chunk_of(bx, 0, bz))
		if n < len(spots) {
			spots[n] = {x = bx, z = bz, radius = player.render_distance}
			n += 1
		}
	}
	world_gen_advance(&server.gen, &server.world, server.seed, spots[:n], true)
	drops_advance(&server.drops, &server.world, server.players, f32(frame_dt))
	return grow_advance(&server.world, server.foci[:], frame_dt, &server.drops, &server.drop_rng)
}

// After a load: drop columns the players are not near, remember which columns
// are still in memory, and make sure the ground under each player exists.
server_settle_chunks :: proc(server: ^Server) {
	spots: [32]Load_Spot
	n := 0
	for _, player in server.players {
		if n >= len(spots) {
			break
		}
		spots[n] = {
			x = block_index_horizontal(player.player.position.x),
			z = block_index_horizontal(player.player.position.z),
			radius = player.render_distance,
		}
		n += 1
	}
	if n == 0 {
		spots[0] = {radius = RENDER_DISTANCE}
		n = 1
	}
	world_unload_far(&server.gen, &server.world, spots[:n])
	for key, _ in server.world.chunks {
		server.gen.loaded[{key.x, key.z}] = true
	}
	for i in 0 ..< n {
		column := chunk_of(spots[i].x, 0, spots[i].z)
		world_gen_ensure(&server.gen, &server.world, server.seed, column.x, column.z)
	}
}

server_apply :: proc(server: ^Server, id: u32, input: Client_Input) {
	player := server.players[id]
	if player == nil {
		return
	}
	player.render_distance = render_radius(input.render_distance)
	simulate_player(&player.player, &server.world, input.move)
	server_inventory(server, player, input)
	server_mine(server, player, input)
	if input.use {
		server_use(server, player)
	}
	n := input.say_n
	if n > len(input.say) {
		n = len(input.say)
	}
	if n > 0 {
		said := input.say
		server_say(server, id, string(said[:n]))
	}
}

server_inventory :: proc(server: ^Server, player: ^Server_Player, input: Client_Input) {
	inv := &player.inventory
	action := input.action
	slot := input.slot
	// The 3x3 on the player is only a scratch copy of the open table. Clicks
	// change that copy, and it is written back onto the block afterwards.
	// Remember the block that was loaded: Open_Table may aim at a different one.
	loaded_at := player.table_at
	loaded := server_load_table(server, player)
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
			if loaded {
				craft_take(inv.craft3[:], 3, &inv.held, whole)
			}
		} else if !loaded && craft3_slot(slot) {
			// No table is open, so this click must not swallow the cursor stack.
		} else if stack, ok := inventory_slot_mut(inv, slot); ok {
			if whole {
				inventory_click_left(&inv.held, stack)
			} else {
				inventory_click_right(&inv.held, stack)
			}
		}
	case .Shift:
		if loaded || !craft3_slot(slot) {
			inventory_shift(inv, slot)
		}
	case .Stow:
		// The 2x2 belongs to the inventory screen, so closing puts it back.
		// The 3x3 belongs to the workbench and stays on that block.
		server_empty_grid(server, player, inv.craft2[:])
		if inventory_stow(inv) {
			player.table_open = false
		}
	case .Drop:
		server_drop_item(server, player, slot, false)
	case .Drop_All:
		server_drop_item(server, player, slot, true)
	case .Drag_Left, .Drag_Right:
		n := input.drag_n
		if n < 0 || n > DRAG_MAX {
			break
		}
		slots := input.drag
		if !loaded {
			kept := 0
			for i in 0 ..< n {
				if craft3_slot(slots[i]) {
					continue
				}
				slots[kept] = slots[i]
				kept += 1
			}
			n = kept
		}
		inventory_drag(inv, slots[:n], action == .Drag_Left)
	case .Gather:
		inventory_gather(inv)
	case .Open_Table:
		server_open_table(server, player, input.table_x, input.table_y, input.table_z)
	}
	if loaded {
		server_save_table(server, loaded_at, inv.craft3)
	}
	inv.craft3 = {}
}

craft3_slot :: proc(index: int) -> bool {
	return index >= CRAFT3_INDEX && index < CRAFT3_INDEX+CRAFT3_N || index == CRAFT3_RESULT
}

// Copies the open table onto the inventory so the click code can edit it.
// A missing block closes the table; its items were already dropped.
server_load_table :: proc(server: ^Server, player: ^Server_Player) -> bool {
	if !player.table_open {
		return false
	}
	at := player.table_at
	if get_block(&server.world, at.x, at.y, at.z) != .Workbench {
		player.table_open = false
		return false
	}
	player.inventory.craft3 = server.tables[at]
	return true
}

server_save_table :: proc(server: ^Server, at: [3]int, grid: [CRAFT3_N]Slot) {
	for slot in grid {
		if slot.count > 0 && !item_empty(slot.item) {
			server.tables[at] = grid
			return
		}
	}
	delete_key(&server.tables, at)
}

server_open_table :: proc(server: ^Server, player: ^Server_Player, x, y, z: int) {
	if get_block(&server.world, x, y, z) != .Workbench {
		return
	}
	eye := player.player.position + {0, PLAYER_EYE_HEIGHT, 0}
	dx := eye.x - f32(x)
	dy := eye.y - (f32(y) + 0.5)
	dz := eye.z - f32(z)
	// The click lands on a face, so the block center sits a little farther out.
	if dx*dx+dy*dy+dz*dz > 6.5*6.5 {
		return
	}
	player.table_open = true
	player.table_at = {x, y, z}
}

// Breaking the block spills whatever was arranged on it.
server_spill_table :: proc(server: ^Server, x, y, z: int) {
	at := [3]int{x, y, z}
	grid, ok := server.tables[at]
	if !ok {
		return
	}
	for slot in grid {
		if slot.count > 0 && !item_empty(slot.item) {
			drop_spawn(&server.drops, &server.drop_rng, slot.item, slot.count, x, y, z)
		}
	}
	delete_key(&server.tables, at)
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

server_mine :: proc(server: ^Server, player: ^Server_Player, input: Client_Input) {
	hit, x, y, z, _, _, _ := server_ray(server, player)
	tool := equipped_item(&player.inventory)
	advance_mine(&player.mine, &server.world, tool, input.attack, hit, x, y, z, input.move.dt)
	if !player.mine.on || player.mine.time < mine_seconds(get_block(&server.world, x, y, z), tool) {
		return
	}
	broken := get_block(&server.world, x, y, z)
	player.mine = {}
	if broken == .Workbench {
		server_spill_table(server, x, y, z)
	}
	// A door standing on this block falls with it. Remembered before the write,
	// because the settle that follows the break is what takes the door down.
	stood := door_is_lower(get_block(&server.world, x, y+1, z))
	// hear marks this edit so clients play it. The spill above is items, not a break.
	server.world.hear = true
	if block_is_door(broken) {
		door_remove(&server.world, x, y, z)
		server.world.hear = false
		drop_spawn(&server.drops, &server.drop_rng, item_block(.Oak_Door), 1, x, y, z)
		return
	}
	set_block(&server.world, x, y, z, .Air)
	server.world.hear = false
	drop_spawn(&server.drops, &server.drop_rng, block_drop(broken), 1, x, y, z)
	if stood && !block_is_door(get_block(&server.world, x, y+1, z)) {
		drop_spawn(&server.drops, &server.drop_rng, item_block(.Oak_Door), 1, x, y+1, z)
	}
}

server_use :: proc(server: ^Server, player: ^Server_Player) {
	hit, x, y, z, px, py, pz := server_ray(server, player)
	if !hit {
		return
	}
	// Looking at a door swings it. Holding another block does not place through
	// the panel; the empty part of an open door is not a hit, so that still places.
	if block_is_door(get_block(&server.world, x, y, z)) {
		server.world.hear = true
		door_toggle(&server.world, x, y, z)
		server.world.hear = false
		return
	}
	server.world.hear = true
	inventory_place(&player.inventory, player.player, &server.world, px, py, pz)
	server.world.hear = false
}

server_ray :: proc(server: ^Server, player: ^Server_Player) -> (hit: bool, x, y, z, px, py, pz: int) {
	eye := player.player.position + {0, PLAYER_EYE_HEIGHT, 0}
	dir := look_direction(player.player.yaw, player.player.pitch)
	return raycast_block(&server.world, eye, dir, MINE_REACH)
}
