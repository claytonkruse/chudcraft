package main

import "core:fmt"
import "core:mem"
import "core:net"

// How another game joins this one. The host listens, and a joining client
// speaks the same inputs the local client already produces. Block changes,
// drops, and where everyone is standing go back the other way.
//
// Chunks that exist at the moment of joining are sent then. Columns that stream
// in afterwards are sent whole, and the cells that change during play are the
// list the server already records for its own client.

// 27015 is already taken on a lot of Windows machines, by Steam and by Apple's
// mobile-device service, so hosting there always looks like the port is ours.
NET_PORT        :: 43720
NET_PORT_TRIES  :: 16
NET_VERSION     :: u32(6)
NET_MAX_PLAYERS :: 8
// A chunk message is a few kilobytes. Anything larger is a broken peer.
NET_MAX_MESSAGE :: 8 * 1024 * 1024
// One megabyte, so the opening world does not dribble out in tiny packets.
NET_BUFFER      :: 1 << 20

Wire :: enum u8 {
	Join = 1,
	Welcome,
	Chunk,
	Ready,
	Input,
	State,
	Deny,
}

Deny_Reason :: enum u8 {
	Version = 1,
	Full    = 2,
}

// Bytes waiting to be parsed or sent. head is how much of data is already done,
// so a partial socket write does not have to slide the rest down every time.
Stream :: struct {
	data: [dynamic]u8,
	head: int,
}

// One accepted connection. id stays 0 until the Join message checks out.
Remote_Peer :: struct {
	socket:  net.TCP_Socket,
	id:      u32,
	playing: bool,
	dead:    bool,
	inbox:   Stream,
	out:     Stream,
}

// The listening socket and the people who joined it. Empty unless hosting.
Host_Link :: struct {
	listener:  net.TCP_Socket,
	listening: bool,
	peers:     [dynamic]^Remote_Peer,
	// "192.168.1.5:43720", for the HUD. Empty when nobody can join.
	join_at:   [64]byte,
	port:      int,
	// True when join_at is a LAN address, so the HUD can also offer localhost.
	lan:       bool,
}

// The socket a joining client reads. The host's own client does not have one.
Client_Link :: struct {
	socket: net.TCP_Socket,
	inbox:  Stream,
	out:    Stream,
	ready:  bool,
	failed: bool,
	reason: [160]byte,
}

host_listen :: proc(server: ^Server) -> string {
	for offset in 0 ..< NET_PORT_TRIES {
		port := NET_PORT + offset
		socket, err := net.listen_tcp(net.Endpoint{address = net.IP4_Any, port = port})
		if err != nil {
			if port_taken(err) {
				continue
			}
			return "Could not host. The port could not be opened."
		}
		if block_err := net.set_blocking(socket, false); block_err != .None {
			net.close(socket)
			return "Could not host. The port could not be opened."
		}
		widen_socket(socket)
		server.host.listener = socket
		server.host.listening = true
		server.host.port = port
		remember_join_address(server, port)
		return ""
	}
	return "Could not host. A free port could not be found."
}

// Closes the listener and every joiner. Safe when this process was not hosting.
host_shutdown :: proc(server: ^Server) {
	if server.host.listening {
		net.close(server.host.listener)
		server.host.listening = false
		server.host.listener = {}
	}
	for peer in server.host.peers {
		retire_peer(server, peer)
	}
	delete(server.host.peers)
	server.host.join_at[0] = 0
	server.host.lan = false
	server.host.port = 0
}

// Accepts new people and reads the inputs they have sent. Commands land in
// the same list as the host's own input, and the step that follows applies both.
host_pump :: proc(server: ^Server, commands: ^[dynamic]Player_Command) {
	if !server.host.listening {
		return
	}
	for {
		socket, _, err := net.accept_tcp(server.host.listener)
		if err == .Would_Block || err == .Timeout {
			break
		}
		if err != nil {
			break
		}
		net.set_blocking(socket, false)
		widen_socket(socket)
		peer := new(Remote_Peer)
		peer.socket = socket
		append(&server.host.peers, peer)
	}

	for peer in server.host.peers {
		if peer.dead {
			continue
		}
		peer_recv(peer)
		peer_parse(server, peer, commands)
		peer_flush(peer)
		// A joiner who never reads would keep every snapshot. Drop them.
		if stream_pending(&peer.out) > NET_MAX_MESSAGE {
			peer.dead = true
		}
	}

	kept := 0
	for peer in server.host.peers {
		if !peer.dead {
			server.host.peers[kept] = peer
			kept += 1
			continue
		}
		retire_peer(server, peer)
	}
	resize(&server.host.peers, kept)
}

// One snapshot after the step, so every change from that step is still recorded.
host_broadcast :: proc(server: ^Server) {
	if !server.host.listening {
		return
	}
	for peer in server.host.peers {
		if peer.dead || !peer.playing {
			continue
		}
		// Edits first, then any column that streamed in this step, so the chunk
		// wins where it also contains those edits.
		write_message(&peer.out, .State, server, peer)
		for key in server.world.sync_queue {
			chunk := server.world.chunks[key]
			if chunk == nil {
				continue
			}
			write_chunk(&peer.out, key, chunk)
		}
		peer_flush(peer)
	}
}

write_chunk :: proc(out: ^Stream, key: [3]int, chunk: ^Chunk) {
	start := message_begin(out, .Chunk)
	write_i32(&out.data, i32(key.x))
	write_i32(&out.data, i32(key.y))
	write_i32(&out.data, i32(key.z))
	bytes := mem.slice_ptr(([^]u8)(&chunk.blocks), size_of(chunk.blocks))
	append(&out.data, ..bytes)
	message_end(out, start)
}

// Opens a connection and asks to join. The world arrives over later pumps.
// A failure string is empty on success.
client_dial :: proc(client: ^Client, address: string) -> string {
	target_buf: [96]byte
	target := dial_target(address, target_buf[:])
	socket, err := net.dial_tcp(target)
	if err != nil {
		return dial_failure(err)
	}
	net.set_blocking(socket, false)
	widen_socket(socket)

	link := new(Client_Link)
	link.socket = socket
	client.link = link
	start := message_begin(&link.out, .Join)
	write_u32(&link.out.data, NET_VERSION)
	message_end(&link.out, start)
	peer_flush_link(link)
	if link.failed {
		client_link_close(client)
		return "Lost the connection to the host."
	}
	return ""
}

client_link_close :: proc(client: ^Client) {
	link := client.link
	if link == nil {
		return
	}
	net.close(link.socket)
	delete(link.inbox.data)
	delete(link.out.data)
	free(link)
	client.link = nil
}

// Reads whatever has arrived. True once the world and the first snapshot are in.
client_link_pump :: proc(client: ^Client) -> bool {
	link := client.link
	if link == nil || link.failed {
		return false
	}
	link_recv(link)
	link_parse(client)
	stream_compact(&link.inbox)
	if link.failed {
		return false
	}
	return link.ready
}

client_send_input :: proc(client: ^Client, input: Client_Input) -> bool {
	link := client.link
	if link == nil || link.failed {
		return false
	}
	start := message_begin(&link.out, .Input)
	write_input(&link.out.data, input)
	message_end(&link.out, start)
	peer_flush_link(link)
	return !link.failed
}

port_taken :: proc(err: net.Network_Error) -> bool {
	if bind, ok := err.(net.Bind_Error); ok {
		return bind == .Address_In_Use
	}
	if listen, ok := err.(net.Listen_Error); ok {
		return listen == .Address_In_Use
	}
	return false
}

dial_failure :: proc(err: net.Network_Error) -> string {
	dial, ok := err.(net.Dial_Error)
	if !ok {
		return "Could not join that host."
	}
	switch dial {
	case .Refused:
		return "Nothing is hosting at that address."
	case .Timeout, .Host_Unreachable, .Network_Unreachable:
		return "Could not reach that host."
	case .None, .Insufficient_Resources, .Invalid_Argument, .Broadcast_Not_Supported,
	     .Already_Connected, .Already_Connecting, .Address_In_Use, .Reset,
	     .Would_Block, .Interrupted, .Port_Required, .Unknown:
		return "Could not join that host."
	case:
		return "Could not join that host."
	}
}

remember_join_address :: proc(server: ^Server, port: int) {
	best: net.IP4_Address
	best_score := 0
	ifaces, iface_err := net.enumerate_interfaces()
	defer net.destroy_interfaces(ifaces)
	if iface_err == .None {
		for iface in ifaces {
			if .Loopback in iface.link.state {
				continue
			}
			for lease in iface.unicast {
				ip, ok := lease.address.(net.IP4_Address)
				if !ok || ip == {} || ip == net.IP4_Loopback {
					continue
				}
				score := 1
				if ip[0] == 192 && ip[1] == 168 {
					score = 3
				} else if ip[0] == 10 || (ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31) {
					score = 2
				}
				if score > best_score {
					best = ip
					best_score = score
				}
			}
		}
	}
	if best_score == 0 {
		best = net.IP4_Loopback
	}
	text := fmt.bprintf(server.host.join_at[:], "%d.%d.%d.%d:%d", int(best[0]), int(best[1]), int(best[2]), int(best[3]), port)
	if len(text) >= len(server.host.join_at) {
		server.host.join_at[0] = 0
		return
	}
	server.host.join_at[len(text)] = 0
	server.host.lan = best != net.IP4_Loopback
}

dial_target :: proc(address: string, buf: []byte) -> string {
	start, end := 0, len(address)
	for start < end && address[start] == ' ' {
		start += 1
	}
	for end > start && address[end-1] == ' ' {
		end -= 1
	}
	trimmed := address[start:end]
	colon := false
	for c in trimmed {
		if c == ':' {
			colon = true
			break
		}
	}
	if colon {
		return trimmed
	}
	return fmt.bprintf(buf, "%s:%d", trimmed, NET_PORT)
}

widen_socket :: proc(socket: net.TCP_Socket) {
	net.set_option(socket, .Send_Buffer_Size, i32(NET_BUFFER))
	net.set_option(socket, .Receive_Buffer_Size, i32(NET_BUFFER))
}

retire_peer :: proc(server: ^Server, peer: ^Remote_Peer) {
	peer_flush(peer)
	net.close(peer.socket)
	if peer.id != 0 {
		server_leave(server, peer.id)
	}
	delete(peer.inbox.data)
	delete(peer.out.data)
	free(peer)
}

peer_recv :: proc(peer: ^Remote_Peer) {
	buf: [16 * 1024]byte
	for {
		n, err := net.recv_tcp(peer.socket, buf[:])
		if n > 0 {
			append(&peer.inbox.data, ..buf[:n])
		}
		if err == .Would_Block || err == .Timeout {
			return
		}
		if err != nil || n == 0 {
			peer.dead = true
			return
		}
	}
}

link_recv :: proc(link: ^Client_Link) {
	buf: [16 * 1024]byte
	for {
		n, err := net.recv_tcp(link.socket, buf[:])
		if n > 0 {
			append(&link.inbox.data, ..buf[:n])
		}
		if err == .Would_Block || err == .Timeout {
			return
		}
		if err != nil || n == 0 {
			link.failed = true
			if link.reason[0] == 0 {
				put_text(link.reason[:], "Lost the connection to the host.")
			}
			return
		}
	}
}

peer_flush :: proc(peer: ^Remote_Peer) {
	flush_socket(peer.socket, &peer.out, &peer.dead, nil)
}

peer_flush_link :: proc(link: ^Client_Link) {
	flush_socket(link.socket, &link.out, &link.failed, &link.reason)
}

flush_socket :: proc(socket: net.TCP_Socket, out: ^Stream, dead: ^bool, reason: ^[160]byte) {
	for stream_pending(out) > 0 {
		n, err := net.send_tcp(socket, stream_bytes(out))
		if n > 0 {
			out.head += n
		}
		if err == .Would_Block || err == .Timeout {
			break
		}
		if err != nil || n <= 0 {
			dead^ = true
			if reason != nil && reason[0] == 0 {
				put_text(reason[:], "Lost the connection to the host.")
			}
			break
		}
	}
	stream_compact(out)
}

peer_parse :: proc(server: ^Server, peer: ^Remote_Peer, commands: ^[dynamic]Player_Command) {
	inbox := &peer.inbox
	for {
		kind, payload, ok, bad := next_message(inbox)
		if bad {
			peer.dead = true
			return
		}
		if !ok {
			break
		}
		switch kind {
		case .Join:
			if peer.id != 0 {
				peer.dead = true
				return
			}
			reader := Reader{b = payload, ok = true}
			version := read_u32(&reader)
			if !reader.ok || reader.i != len(payload) {
				peer.dead = true
				return
			}
			if version != NET_VERSION {
				refuse(peer, .Version)
				return
			}
			if len(server.players) >= NET_MAX_PLAYERS {
				refuse(peer, .Full)
				return
			}
			peer.id = server_join(server)
			start := message_begin(&peer.out, .Welcome)
			write_u32(&peer.out.data, NET_VERSION)
			write_u32(&peer.out.data, peer.id)
			write_i64(&peer.out.data, server.seed)
			message_end(&peer.out, start)
			for key, chunk in server.world.chunks {
				write_chunk(&peer.out, key, chunk)
			}
			// The snapshot is the world as it stands now, including this person,
			// so they are standing on the ground before the next frame arrives.
			write_message(&peer.out, .Ready, server, peer)
			peer.playing = true
		case .Input:
			if !peer.playing || peer.id == 0 {
				continue
			}
			reader := Reader{b = payload, ok = true}
			input := read_input(&reader)
			if !reader.ok || reader.i != len(payload) {
				peer.dead = true
				return
			}
			append(commands, Player_Command{id = peer.id, input = input})
		case .Welcome, .Chunk, .Ready, .State, .Deny:
			peer.dead = true
			return
		case:
			peer.dead = true
			return
		}
	}
	stream_compact(inbox)
}

refuse :: proc(peer: ^Remote_Peer, reason: Deny_Reason) {
	start := message_begin(&peer.out, .Deny)
	append(&peer.out.data, u8(reason))
	message_end(&peer.out, start)
	peer.dead = true
}

link_parse :: proc(client: ^Client) {
	link := client.link
	inbox := &link.inbox
	for !link.failed {
		kind, payload, ok, bad := next_message(inbox)
		if bad {
			fail_link(link, "The host sent something this game does not understand.")
			return
		}
		if !ok {
			break
		}
		switch kind {
		case .Welcome:
			reader := Reader{b = payload, ok = true}
			version := read_u32(&reader)
			id := read_u32(&reader)
			seed := read_i64(&reader)
			if !reader.ok || reader.i != len(payload) || version != NET_VERSION || id == 0 {
				fail_link(link, "This host is running a different version of Chudcraft.")
				return
			}
			client.id = id
			client.seed = seed
		case .Chunk:
			reader := Reader{b = payload, ok = true}
			x := int(read_i32(&reader))
			y := int(read_i32(&reader))
			z := int(read_i32(&reader))
			n := size_of([CHUNK_SIZE][CHUNK_SIZE][CHUNK_SIZE]Block)
			if !reader.ok || reader.i+n != len(payload) || len(client.world.chunks) > 20000 {
				fail_link(link, "The host sent something this game does not understand.")
				return
			}
			key := [3]int{x, y, z}
			chunk := client.world.chunks[key]
			if chunk == nil {
				chunk = new(Chunk)
				client.world.chunks[key] = chunk
			}
			mem.copy(&chunk.blocks, raw_data(payload[reader.i:]), n)
			chunk.dirty = true
		case .Ready, .State:
			if !apply_state(client, payload) {
				fail_link(link, "The host sent something this game does not understand.")
				return
			}
			if kind == .Ready {
				link.ready = true
			}
		case .Deny:
			if len(payload) != 1 {
				fail_link(link, "The host refused the connection.")
				return
			}
			switch Deny_Reason(payload[0]) {
			case .Version:
				fail_link(link, "This host is running a different version of Chudcraft.")
			case .Full:
				fail_link(link, "That world is full.")
			case:
				fail_link(link, "The host refused the connection.")
			}
			return
		case .Join, .Input:
			fail_link(link, "The host sent something this game does not understand.")
			return
		case:
			fail_link(link, "The host sent something this game does not understand.")
			return
		}
	}
}

apply_state :: proc(client: ^Client, payload: []u8) -> bool {
	reader := Reader{b = payload, ok = true}
	player := &client.player
	player.position.x = read_f32(&reader)
	player.position.y = read_f32(&reader)
	player.position.z = read_f32(&reader)
	player.velocity.x = read_f32(&reader)
	player.velocity.y = read_f32(&reader)
	player.velocity.z = read_f32(&reader)
	// Look stays on this machine. The angles were sent with the input, and
	// writing the echo back would throw away the mouse movement since then.
	_ = read_f32(&reader)
	_ = read_f32(&reader)
	player.grounded = read_u8(&reader) != 0

	open := client.inventory.open
	suppress := client.inventory.suppress_look
	table := client.inventory.table
	client.inventory.selected = int(read_i32(&reader))
	client.inventory.held = read_slot(&reader)
	for i in 0 ..< INVENTORY_SLOTS {
		client.inventory.slots[i] = read_slot(&reader)
	}
	for i in 0 ..< CRAFT2_N {
		client.inventory.craft2[i] = read_slot(&reader)
	}
	client.inventory.open = open
	client.inventory.suppress_look = suppress
	client.inventory.table = table

	tables := int(read_u32(&reader))
	if !reader.ok || tables < 0 || tables > 100000 {
		return false
	}
	delete(client.tables)
	client.tables = nil
	for _ in 0 ..< tables {
		at := [3]int{int(read_i32(&reader)), int(read_i32(&reader)), int(read_i32(&reader))}
		grid: [CRAFT3_N]Slot
		for i in 0 ..< CRAFT3_N {
			grid[i] = read_slot(&reader)
		}
		if reader.ok {
			client.tables[at] = grid
		}
	}
	apply_open_table(client)

	others := int(read_u32(&reader))
	if !reader.ok || others < 0 || others > NET_MAX_PLAYERS {
		return false
	}
	clear(&client.others)
	for _ in 0 ..< others {
		append(&client.others, Remote_View{
			id = read_u32(&reader),
			position = {read_f32(&reader), read_f32(&reader), read_f32(&reader)},
			yaw = read_f32(&reader),
			pitch = read_f32(&reader),
		})
	}

	drops := int(read_u32(&reader))
	if !reader.ok || drops < 0 || drops > 100000 {
		return false
	}
	clear(&client.drops)
	for _ in 0 ..< drops {
		append(&client.drops, Drop_View{
			item = read_item(&reader),
			count = int(read_i32(&reader)),
			position = {read_f32(&reader), read_f32(&reader), read_f32(&reader)},
			age = read_f32(&reader),
			phase = read_f32(&reader),
		})
	}

	changes := int(read_u32(&reader))
	if !reader.ok || changes < 0 || changes > 100000 {
		return false
	}
	for _ in 0 ..< changes {
		x := int(read_i32(&reader))
		y := int(read_i32(&reader))
		z := int(read_i32(&reader))
		block := read_block(&reader)
		if !reader.ok {
			return false
		}
		store_block(&client.world, x, y, z, block)
	}
	return reader.ok && reader.i == len(payload)
}

write_message :: proc(out: ^Stream, kind: Wire, server: ^Server, peer: ^Remote_Peer) {
	start := message_begin(out, kind)
	write_state(&out.data, server, peer.id)
	message_end(out, start)
}

write_state :: proc(buf: ^[dynamic]u8, server: ^Server, self: u32) {
	player := server.players[self]
	body := player.player
	write_f32(buf, body.position.x)
	write_f32(buf, body.position.y)
	write_f32(buf, body.position.z)
	write_f32(buf, body.velocity.x)
	write_f32(buf, body.velocity.y)
	write_f32(buf, body.velocity.z)
	write_f32(buf, body.yaw)
	write_f32(buf, body.pitch)
	append(buf, u8(1) if body.grounded else 0)
	write_i32(buf, i32(player.inventory.selected))
	write_slot(buf, player.inventory.held)
	for slot in player.inventory.slots {
		write_slot(buf, slot)
	}
	for slot in player.inventory.craft2 {
		write_slot(buf, slot)
	}
	write_u32(buf, u32(len(server.tables)))
	for at, grid in server.tables {
		write_i32(buf, i32(at.x))
		write_i32(buf, i32(at.y))
		write_i32(buf, i32(at.z))
		for slot in grid {
			write_slot(buf, slot)
		}
	}

		others := 0
	for id, _ in server.players {
		if id != self {
			others += 1
		}
	}
	write_u32(buf, u32(others))
	for id, other in server.players {
		if id == self {
			continue
		}
		write_u32(buf, id)
		write_f32(buf, other.player.position.x)
		write_f32(buf, other.player.position.y)
		write_f32(buf, other.player.position.z)
		write_f32(buf, other.player.yaw)
		write_f32(buf, other.player.pitch)
	}

	write_u32(buf, u32(len(server.drops)))
	for drop in server.drops {
		write_item(buf, drop.item)
		write_i32(buf, i32(drop.count))
		write_f32(buf, drop.position.x)
		write_f32(buf, drop.position.y)
		write_f32(buf, drop.position.z)
		write_f32(buf, drop.age)
		write_f32(buf, drop.phase)
	}

	write_u32(buf, u32(len(server.world.changes)))
	for change in server.world.changes {
		write_i32(buf, i32(change.x))
		write_i32(buf, i32(change.y))
		write_i32(buf, i32(change.z))
		append(buf, u8(change.block))
	}
}

write_input :: proc(buf: ^[dynamic]u8, input: Client_Input) {
	write_f32(buf, input.move.dt)
	write_f32(buf, input.move.yaw)
	write_f32(buf, input.move.pitch)
	flags: u8
	if input.move.forward do flags |= 1
	if input.move.back do flags |= 2
	if input.move.left do flags |= 4
	if input.move.right do flags |= 8
	if input.move.jump do flags |= 16
	if input.attack do flags |= 32
	if input.use do flags |= 64
	append(buf, flags)
	append(buf, u8(input.action))
	write_i32(buf, i32(input.slot))
	if input.action == .Drag_Left || input.action == .Drag_Right {
		n := input.drag_n
		if n < 0 {
			n = 0
		}
		if n > DRAG_MAX {
			n = DRAG_MAX
		}
		append(buf, u8(n))
		for i in 0 ..< n {
			write_i32(buf, i32(input.drag[i]))
		}
	}
	if input.action == .Open_Table {
		write_i32(buf, i32(input.table_x))
		write_i32(buf, i32(input.table_y))
		write_i32(buf, i32(input.table_z))
	}
}

read_input :: proc(reader: ^Reader) -> Client_Input {
	input: Client_Input
	input.move.dt = read_f32(reader)
	input.move.yaw = read_f32(reader)
	input.move.pitch = read_f32(reader)
	flags := read_u8(reader)
	input.move.forward = flags & 1 != 0
	input.move.back = flags & 2 != 0
	input.move.left = flags & 4 != 0
	input.move.right = flags & 8 != 0
	input.move.jump = flags & 16 != 0
	input.attack = flags & 32 != 0
	input.use = flags & 64 != 0
	action := read_u8(reader)
	if action > u8(Inventory_Action.Open_Table) {
		reader.ok = false
	}
	input.action = Inventory_Action(action)
	input.slot = int(read_i32(reader))
	if input.action == .Drag_Left || input.action == .Drag_Right {
		n := int(read_u8(reader))
		if n > DRAG_MAX {
			reader.ok = false
			return input
		}
		input.drag_n = n
		for i in 0 ..< n {
			input.drag[i] = int(read_i32(reader))
		}
	}
	if input.action == .Open_Table {
		input.table_x = int(read_i32(reader))
		input.table_y = int(read_i32(reader))
		input.table_z = int(read_i32(reader))
	}
	return input
}

write_slot :: proc(buf: ^[dynamic]u8, slot: Slot) {
	write_item(buf, slot.item)
	write_i32(buf, i32(slot.count))
}

read_slot :: proc(reader: ^Reader) -> Slot {
	return {item = read_item(reader), count = int(read_i32(reader))}
}

write_item :: proc(buf: ^[dynamic]u8, item: Item) {
	append(buf, u8(item.kind))
	block: Block = .Air
	if item.kind == .Block {
		block = item.block
	}
	append(buf, u8(block))
}

read_item :: proc(reader: ^Reader) -> Item {
	kind_raw := read_u8(reader)
	block_raw := read_u8(reader)
	if kind_raw > u8(Item_Kind.Stone_Pickaxe) {
		reader.ok = false
		return {}
	}
	kind := Item_Kind(kind_raw)
	if kind != .Block {
		return {kind = kind}
	}
	if block_raw > u8(Block.Workbench) {
		reader.ok = false
		return {}
	}
	return {kind = .Block, block = Block(block_raw)}
}

read_block :: proc(reader: ^Reader) -> Block {
	raw := read_u8(reader)
	if raw > u8(Block.Workbench) {
		reader.ok = false
		return .Air
	}
	return Block(raw)
}

message_begin :: proc(out: ^Stream, kind: Wire) -> int {
	start := len(out.data)
	write_u32(&out.data, 0)
	append(&out.data, u8(kind))
	return start
}

message_end :: proc(out: ^Stream, start: int) {
	size := u32(len(out.data) - start - 4)
	out.data[start] = u8(size)
	out.data[start+1] = u8(size >> 8)
	out.data[start+2] = u8(size >> 16)
	out.data[start+3] = u8(size >> 24)
}

// The size covers the kind byte and the payload after it. bad is a header that
// cannot be a real message, which is different from a message that has not all
// arrived yet.
next_message :: proc(inbox: ^Stream) -> (kind: Wire, payload: []u8, ok, bad: bool) {
	pending := stream_bytes(inbox)
	if len(pending) < 4 {
		return
	}
	size := u32(pending[0]) | u32(pending[1])<<8 | u32(pending[2])<<16 | u32(pending[3])<<24
	if size < 1 || int(size) > NET_MAX_MESSAGE {
		bad = true
		return
	}
	if len(pending) < 4+int(size) {
		return
	}
	kind = Wire(pending[4])
	payload = pending[5:][:size-1]
	inbox.head += 4 + int(size)
	ok = true
	return
}

Reader :: struct {
	b:  []u8,
	i:  int,
	ok: bool,
}

read_u8 :: proc(reader: ^Reader) -> u8 {
	if reader.i >= len(reader.b) {
		reader.ok = false
		return 0
	}
	value := reader.b[reader.i]
	reader.i += 1
	return value
}

read_u32 :: proc(reader: ^Reader) -> u32 {
	if reader.i+4 > len(reader.b) {
		reader.ok = false
		return 0
	}
	b := reader.b[reader.i:]
	reader.i += 4
	return u32(b[0]) | u32(b[1])<<8 | u32(b[2])<<16 | u32(b[3])<<24
}

read_i32 :: proc(reader: ^Reader) -> i32 {
	return transmute(i32)read_u32(reader)
}

read_i64 :: proc(reader: ^Reader) -> i64 {
	lo := u64(read_u32(reader))
	hi := u64(read_u32(reader))
	return transmute(i64)(lo | hi<<32)
}

read_f32 :: proc(reader: ^Reader) -> f32 {
	return transmute(f32)read_u32(reader)
}

write_u32 :: proc(buf: ^[dynamic]u8, value: u32) {
	append(buf, u8(value), u8(value>>8), u8(value>>16), u8(value>>24))
}

write_i32 :: proc(buf: ^[dynamic]u8, value: i32) {
	write_u32(buf, transmute(u32)value)
}

write_i64 :: proc(buf: ^[dynamic]u8, value: i64) {
	bits := transmute(u64)value
	write_u32(buf, u32(bits))
	write_u32(buf, u32(bits>>32))
}

write_f32 :: proc(buf: ^[dynamic]u8, value: f32) {
	write_u32(buf, transmute(u32)value)
}

stream_pending :: proc(stream: ^Stream) -> int {
	return len(stream.data) - stream.head
}

stream_bytes :: proc(stream: ^Stream) -> []u8 {
	return stream.data[stream.head:]
}

stream_compact :: proc(stream: ^Stream) {
	if stream.head == 0 {
		return
	}
	if stream.head >= len(stream.data) {
		clear(&stream.data)
		stream.head = 0
		return
	}
	if stream.head < 64*1024 && stream.head*2 < len(stream.data) {
		return
	}
	n := len(stream.data) - stream.head
	for i in 0 ..< n {
		stream.data[i] = stream.data[stream.head+i]
	}
	resize(&stream.data, n)
	stream.head = 0
}

fail_link :: proc(link: ^Client_Link, reason: string) {
	link.failed = true
	if link.reason[0] == 0 {
		put_text(link.reason[:], reason)
	}
}

put_text :: proc(dst: []byte, text: string) {
	n := min(len(dst)-1, len(text))
	copy(dst[:n], text)
	dst[n] = 0
}
