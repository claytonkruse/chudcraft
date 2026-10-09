package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"

// A world on disk. Play opens one of these alone; hosting is a choice made
// later, from the pause menu, on the world that is already running.
World_Card :: struct {
	id:        int,
	name:      [33]byte,
	name_len:  int,
	seed:      i64,
	path:      [300]byte,
	path_len:  int,
}

WORLD_DIR     :: "worlds"
WORLD_MAGIC   :: u32(0x44554843)
WORLD_VERSION :: u32(3)
// Chunks were 16 wide through version 2. Those blobs are copied into the 32-chunk
// that contains their blocks.
WORLD_VERSION_CHUNK16 :: u32(2)
OLD_CHUNK :: 16
// Saves from the fixed 16x16 region. Still readable; new saves are version 2.
WORLD_VERSION_REGION :: u32(1)
WORLD_NAME_MAX :: 32
OLD_GROUND :: 16
OLD_MIN :: -8

world_card_name :: proc(card: ^World_Card) -> string {
	return string(card.name[:card.name_len])
}

world_card_path :: proc(card: ^World_Card) -> string {
	return string(card.path[:card.path_len])
}

// The next file name in worlds/. An empty or missing directory is world 1.
world_card_new :: proc(name: string) -> (card: World_Card, ok: bool) {
	if len(name) == 0 || len(name) > WORLD_NAME_MAX {
		return
	}
	card.id = worlds_next_id()
	copy(card.name[:len(name)], name)
	card.name[len(name)] = 0
	card.name_len = len(name)
	card.seed = generate_seed()
	text := fmt.bprintf(card.path[:], "worlds/world-%08d.chud", card.id)
	card.path_len = len(text)
	if card.path_len < len(card.path) {
		card.path[card.path_len] = 0
	}
	return card, true
}

worlds_scan :: proc(cards: ^[dynamic]World_Card) {
	clear(cards)
	handle, err := os.open(WORLD_DIR, os.O_RDONLY)
	if err != nil {
		return
	}
	defer os.close(handle)
	infos, read_err := os.read_directory(handle, -1, context.allocator)
	if read_err != nil {
		return
	}
	defer os.file_info_slice_delete(infos, context.allocator)

	for info in infos {
		if info.type == .Directory {
			continue
		}
		id, parsed := world_file_id(info.name)
		if !parsed {
			continue
		}
		path_buf: [300]byte
		path := fmt.bprintf(path_buf[:], "%s/%s", WORLD_DIR, info.name)
		card, header_ok := world_read_header(path, id)
		if !header_ok {
			continue
		}
		append(cards, card)
	}
	slice.sort_by(cards[:], proc(a, b: World_Card) -> bool {
		return a.id > b.id
	})
}

worlds_next_id :: proc() -> int {
	highest := 0
	handle, err := os.open(WORLD_DIR, os.O_RDONLY)
	if err != nil {
		return 1
	}
	defer os.close(handle)
	infos, read_err := os.read_directory(handle, -1, context.allocator)
	if read_err != nil {
		return 1
	}
	defer os.file_info_slice_delete(infos, context.allocator)
	for info in infos {
		id, parsed := world_file_id(info.name)
		if parsed && id > highest {
			highest = id
		}
	}
	return highest + 1
}

world_file_id :: proc(name: string) -> (id: int, ok: bool) {
	if !strings.has_prefix(name, "world-") || !strings.has_suffix(name, ".chud") {
		return
	}
	digits := name[len("world-"):len(name)-len(".chud")]
	if len(digits) == 0 {
		return
	}
	value := 0
	for digit in digits {
		if digit < '0' || digit > '9' {
			return
		}
		value = value*10 + int(digit-'0')
	}
	if value <= 0 {
		return
	}
	return value, true
}

// Name and seed live at the front, so the list does not have to read every chunk.
world_read_header :: proc(path: string, id: int) -> (card: World_Card, ok: bool) {
	handle, err := os.open(path, os.O_RDONLY)
	if err != nil {
		return
	}
	defer os.close(handle)
	buf: [64]byte
	n, read_err := os.read(handle, buf[:])
	if read_err != nil || n < 9 {
		return
	}
	reader := Reader{b = buf[:n], ok = true}
	if read_u32(&reader) != WORLD_MAGIC || read_u32(&reader) != WORLD_VERSION {
		return
	}
	name_len := int(read_u8(&reader))
	if !reader.ok || name_len <= 0 || name_len > WORLD_NAME_MAX || reader.i+name_len+8 > n {
		return
	}
	copy(card.name[:name_len], reader.b[reader.i:reader.i+name_len])
	card.name[name_len] = 0
	card.name_len = name_len
	reader.i += name_len
	card.seed = read_i64(&reader)
	if !reader.ok {
		return
	}
	card.id = id
	text := fmt.bprintf(card.path[:], "%s", path)
	card.path_len = len(text)
	if card.path_len < len(card.path) {
		card.path[card.path_len] = 0
	}
	return card, true
}

// Writes the running world over card.path. The player id is the one who is leaving.
world_save :: proc(server: ^Server, card: ^World_Card, player_id: u32) -> bool {
	if card.path_len == 0 || server == nil {
		return false
	}
	if err := os.make_directory(WORLD_DIR); err != nil && !os.exists(WORLD_DIR) {
		return false
	}

	buf: [dynamic]u8
	defer delete(buf)
	write_u32(&buf, WORLD_MAGIC)
	write_u32(&buf, WORLD_VERSION)
	append(&buf, u8(card.name_len))
	append(&buf, world_card_name(card))
	write_i64(&buf, server.seed)
	write_f64(&buf, server.world.time)
	write_i64(&buf, transmute(i64)server.drop_rng)
	write_u32(&buf, u32(len(server.gen.columns)))
	for column, _ in server.gen.columns {
		write_i32(&buf, i32(column.x))
		write_i32(&buf, i32(column.y))
	}
	write_u32(&buf, server.next_id)
	write_u32(&buf, player_id)

	player := server.players[player_id]
	append(&buf, 1 if player != nil else 0)
	if player != nil {
		write_player(&buf, player)
	}

	cold_n := 0
	for _, bin in server.world.cold {
		cold_n += len(bin)
	}
	write_u32(&buf, u32(len(server.world.chunks)+cold_n))
	write_saved_chunks(&buf, server.world.chunks)
	for column, bin in server.world.cold {
		for piece in bin {
			write_saved_chunk(&buf, [3]int{column.x, piece.y, column.y}, piece.chunk)
		}
	}

	write_u32(&buf, u32(len(server.tables)))
	for at, grid in server.tables {
		write_i32(&buf, i32(at.x))
		write_i32(&buf, i32(at.y))
		write_i32(&buf, i32(at.z))
		for slot in grid {
			write_saved_slot(&buf, slot)
		}
	}

	write_u32(&buf, u32(len(server.drops)))
	for drop in server.drops {
		write_drop(&buf, drop)
	}

	temp: [320]byte
	temp_text := fmt.bprintf(temp[:], "%s.tmp", world_card_path(card))
	if err := os.write_entire_file(temp_text, buf[:]); err != nil {
		return false
	}
	path := world_card_path(card)
	os.remove(path)
	if rename_err := os.rename(temp_text, path); rename_err != nil {
		os.remove(temp_text)
		return false
	}
	return true
}

world_load :: proc(card: ^World_Card) -> (server: Server, reason: string) {
	data, read_err := os.read_entire_file(world_card_path(card), context.allocator)
	if read_err != nil {
		return {}, "Could not open that world."
	}
	defer delete(data)

	reader := Reader{b = data, ok = true}
	if read_u32(&reader) != WORLD_MAGIC {
		return {}, "Could not open that world."
	}
	version := read_u32(&reader)
	if version != WORLD_VERSION && version != WORLD_VERSION_CHUNK16 && version != WORLD_VERSION_REGION {
		return {}, "Could not open that world."
	}
	name_len := int(read_u8(&reader))
	if !reader.ok || name_len <= 0 || name_len > WORLD_NAME_MAX || reader.i+name_len > len(reader.b) {
		return {}, "Could not open that world."
	}
	reader.i += name_len
	server.seed = read_i64(&reader)
	if reader.ok {
		server.world.spawn_x, server.world.spawn_z = land_spawn(server.seed)
	}
	server.world.time = read_f64(&reader)
	server.drop_rng = transmute(u64)read_i64(&reader)
	if server.drop_rng == 0 {
		server.drop_rng = u64(server.seed) | 1
	}
	world_gen_init(&server.gen)
	if version == WORLD_VERSION_REGION {
		for z in 0 ..< OLD_GROUND {
			for x in 0 ..< OLD_GROUND {
				flag := read_u8(&reader)
				if flag != 0 {
					server.gen.columns[migrate_column(x+OLD_MIN, z+OLD_MIN)] = true
				}
			}
		}
	} else {
		columns := int(read_u32(&reader))
		if !reader.ok || columns < 0 || columns > 1_000_000 {
			server_destroy(&server)
			return {}, "Could not open that world."
		}
		for _ in 0 ..< columns {
			column := [2]int{int(read_i32(&reader)), int(read_i32(&reader))}
			if !reader.ok {
				continue
			}
			if version < WORLD_VERSION {
				column = migrate_column(column.x, column.y)
			}
			server.gen.columns[column] = true
		}
	}
	server.next_id = read_u32(&reader)
	saved_id := read_u32(&reader)
	if !reader.ok {
		server_destroy(&server)
		return {}, "Could not open that world."
	}

	if read_u8(&reader) == 1 {
		player, player_ok := read_player(&reader)
		if !player_ok {
			server_destroy(&server)
			return {}, "Could not open that world."
		}
		if saved_id == 0 {
			saved_id = 1
		}
		if server.next_id < saved_id {
			server.next_id = saved_id
		}
		server.players[saved_id] = player
	}

	chunks := int(read_u32(&reader))
	if !reader.ok || chunks < 0 || chunks > 1_000_000 {
		server_destroy(&server)
		return {}, "Could not open that world."
	}
	for _ in 0 ..< chunks {
		key := [3]int{int(read_i32(&reader)), int(read_i32(&reader)), int(read_i32(&reader))}
		n := size_of([CHUNK_SIZE][CHUNK_SIZE][CHUNK_SIZE]Block)
		if version < WORLD_VERSION {
			n = OLD_CHUNK * OLD_CHUNK * OLD_CHUNK
		}
		if !reader.ok || reader.i+n > len(reader.b) {
			server_destroy(&server)
			return {}, "Could not open that world."
		}
		if version < WORLD_VERSION {
			old: [OLD_CHUNK][OLD_CHUNK][OLD_CHUNK]Block
			mem.copy(&old, raw_data(reader.b[reader.i:]), n)
			reader.i += n
			blit_old_chunk(&server.world, key, old)
			continue
		}
		chunk := new(Chunk)
		mem.copy(&chunk.blocks, raw_data(reader.b[reader.i:]), n)
		reader.i += n
		// Disk blocks win over a fresh generate.
		chunk.edited = true
		chunk.keep = true
		column := [2]int{key.x, key.z}
		bin := server.world.cold[column]
		append(&bin, Cold_Piece{y = key.y, chunk = chunk})
		server.world.cold[column] = bin
	}
	server_settle_chunks(&server)

	tables := int(read_u32(&reader))
	if !reader.ok || tables < 0 || tables > 10000 {
		server_destroy(&server)
		return {}, "Could not open that world."
	}
	for _ in 0 ..< tables {
		at := [3]int{int(read_i32(&reader)), int(read_i32(&reader)), int(read_i32(&reader))}
		grid: [CRAFT3_N]Slot
		for &slot in grid {
			slot = read_saved_slot(&reader)
		}
		if reader.ok {
			server.tables[at] = grid
		}
	}

	drops := int(read_u32(&reader))
	if !reader.ok || drops < 0 || drops > 10000 {
		server_destroy(&server)
		return {}, "Could not open that world."
	}
	for _ in 0 ..< drops {
		append(&server.drops, read_drop(&reader))
	}
	if !reader.ok || reader.i != len(reader.b) {
		server_destroy(&server)
		return {}, "Could not open that world."
	}

	server.world.record = true
	return server, ""
}

// An old column index counts 16-wide chunks. The 32-chunk that covers its first block
// is the column those blocks live in now.
migrate_column :: proc(cx, cz: int) -> [2]int {
	return {(cx * OLD_CHUNK) >> CHUNK_SHIFT, (cz * OLD_CHUNK) >> CHUNK_SHIFT}
}

// Copies one 16-chunk into the 32-chunk that contains its world coordinates.
blit_old_chunk :: proc(world: ^World, old_key: [3]int, blocks: [OLD_CHUNK][OLD_CHUNK][OLD_CHUNK]Block) {
	origin_x := old_key.x * OLD_CHUNK
	origin_y := old_key.y * OLD_CHUNK
	origin_z := old_key.z * OLD_CHUNK
	key := chunk_of(origin_x, origin_y, origin_z)
	local := local_of(origin_x, origin_y, origin_z)
	chunk := world.chunks[key]
	if chunk == nil {
		chunk = new(Chunk)
		world.chunks[key] = chunk
	}
	for x in 0 ..< OLD_CHUNK {
		for y in 0 ..< OLD_CHUNK {
			for z in 0 ..< OLD_CHUNK {
				chunk.blocks[local.x+x][local.y+y][local.z+z] = blocks[x][y][z]
			}
		}
	}
	chunk.edited = true
	chunk.keep = true
}

write_saved_chunk :: proc(buf: ^[dynamic]u8, key: [3]int, chunk: ^Chunk) {
	write_i32(buf, i32(key.x))
	write_i32(buf, i32(key.y))
	write_i32(buf, i32(key.z))
	bytes := mem.slice_ptr(([^]u8)(&chunk.blocks), size_of(chunk.blocks))
	append(buf, ..bytes)
}

write_saved_chunks :: proc(buf: ^[dynamic]u8, chunks: map[[3]int]^Chunk) {
	for key, chunk in chunks {
		write_saved_chunk(buf, key, chunk)
	}
}

write_player :: proc(buf: ^[dynamic]u8, player: ^Server_Player) {
	body := player.player
	write_f32(buf, body.position.x)
	write_f32(buf, body.position.y)
	write_f32(buf, body.position.z)
	write_f32(buf, body.velocity.x)
	write_f32(buf, body.velocity.y)
	write_f32(buf, body.velocity.z)
	write_f32(buf, body.yaw)
	write_f32(buf, body.pitch)
	append(buf, 1 if body.grounded else 0)
	write_i32(buf, i32(player.inventory.selected))
	write_saved_slot(buf, player.inventory.held)
	for slot in player.inventory.slots {
		write_saved_slot(buf, slot)
	}
	for slot in player.inventory.craft2 {
		write_saved_slot(buf, slot)
	}
}

read_player :: proc(reader: ^Reader) -> (player: ^Server_Player, ok: bool) {
	player = new(Server_Player)
	player.player.position.x = read_f32(reader)
	player.player.position.y = read_f32(reader)
	player.player.position.z = read_f32(reader)
	player.player.velocity.x = read_f32(reader)
	player.player.velocity.y = read_f32(reader)
	player.player.velocity.z = read_f32(reader)
	player.player.yaw = read_f32(reader)
	player.player.pitch = read_f32(reader)
	player.player.grounded = read_u8(reader) != 0
	player.inventory.selected = int(read_i32(reader))
	player.inventory.held = read_saved_slot(reader)
	for &slot in player.inventory.slots {
		slot = read_saved_slot(reader)
	}
	for &slot in player.inventory.craft2 {
		slot = read_saved_slot(reader)
	}
	if !reader.ok || player.inventory.selected < 0 || player.inventory.selected >= HOTBAR_SLOTS {
		free(player)
		return nil, false
	}
	return player, true
}

write_saved_slot :: proc(buf: ^[dynamic]u8, slot: Slot) {
	append(buf, u8(slot.item.kind))
	append(buf, u8(slot.item.block))
	write_i32(buf, i32(slot.count))
}

read_saved_slot :: proc(reader: ^Reader) -> Slot {
	kind := read_u8(reader)
	block := read_u8(reader)
	count := int(read_i32(reader))
	if kind > u8(Item_Kind.Iron_Ingot) || block > u8(Block.Oak_Door) || count < 0 {
		reader.ok = false
		return {}
	}
	return {item = {kind = Item_Kind(kind), block = Block(block)}, count = count}
}

write_drop :: proc(buf: ^[dynamic]u8, drop: Drop) {
	write_saved_slot(buf, Slot{item = drop.item, count = drop.count})
	write_f32(buf, drop.position.x)
	write_f32(buf, drop.position.y)
	write_f32(buf, drop.position.z)
	write_f32(buf, drop.velocity.x)
	write_f32(buf, drop.velocity.y)
	write_f32(buf, drop.velocity.z)
	write_f32(buf, drop.delay)
	write_f32(buf, drop.age)
	write_f32(buf, drop.phase)
	append(buf, 1 if drop.grounded else 0)
}

read_drop :: proc(reader: ^Reader) -> Drop {
	slot := read_saved_slot(reader)
	drop := Drop {
		item = slot.item,
		count = slot.count,
		position = {read_f32(reader), read_f32(reader), read_f32(reader)},
		velocity = {read_f32(reader), read_f32(reader), read_f32(reader)},
		delay = read_f32(reader),
		age = read_f32(reader),
		phase = read_f32(reader),
		grounded = read_u8(reader) != 0,
	}
	return drop
}

write_f64 :: proc(buf: ^[dynamic]u8, value: f64) {
	write_i64(buf, transmute(i64)value)
}

read_f64 :: proc(reader: ^Reader) -> f64 {
	return transmute(f64)read_i64(reader)
}
