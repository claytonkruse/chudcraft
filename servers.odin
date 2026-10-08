package main

import "core:os"

// One address the join screen can dial again. The list lives in its own file,
// apart from the saved worlds.
Server_Entry :: struct {
	name:         [33]byte,
	name_len:     int,
	address:      [64]byte,
	address_len:  int,
}

SERVERS_FILE    :: "servers.chud"
SERVERS_TEMP    :: "servers.chud.tmp"
SERVERS_MAGIC   :: u32(0x52565253)
SERVERS_VERSION :: u32(1)
SERVER_NAME_MAX :: 32
SERVER_ADDR_MAX :: 63
SERVERS_MAX     :: 64

server_entry_name :: proc(entry: ^Server_Entry) -> string {
	return string(entry.name[:entry.name_len])
}

server_entry_address :: proc(entry: ^Server_Entry) -> string {
	return string(entry.address[:entry.address_len])
}

server_entry_from :: proc(name, address: string) -> (entry: Server_Entry, ok: bool) {
	if len(name) == 0 || len(name) > SERVER_NAME_MAX {
		return
	}
	if len(address) == 0 || len(address) > SERVER_ADDR_MAX {
		return
	}
	copy(entry.name[:len(name)], name)
	entry.name[len(name)] = 0
	entry.name_len = len(name)
	copy(entry.address[:len(address)], address)
	entry.address[len(address)] = 0
	entry.address_len = len(address)
	return entry, true
}

// Missing file is an empty list. A bad file is an empty list too, so a corrupt
// save cannot block the title screen.
servers_load :: proc(list: ^[dynamic]Server_Entry) {
	clear(list)
	data, err := os.read_entire_file(SERVERS_FILE, context.allocator)
	if err != nil {
		return
	}
	defer delete(data)

	reader := Reader{b = data, ok = true}
	if read_u32(&reader) != SERVERS_MAGIC || read_u32(&reader) != SERVERS_VERSION {
		return
	}
	count := int(read_u32(&reader))
	if !reader.ok || count < 0 || count > SERVERS_MAX {
		return
	}
	for _ in 0 ..< count {
		entry, ok := read_server_entry(&reader)
		if !ok {
			clear(list)
			return
		}
		append(list, entry)
	}
}

servers_save :: proc(list: []Server_Entry) -> bool {
	buf: [dynamic]u8
	defer delete(buf)
	write_u32(&buf, SERVERS_MAGIC)
	write_u32(&buf, SERVERS_VERSION)
	write_u32(&buf, u32(len(list)))
	for &entry in list {
		append(&buf, u8(entry.name_len))
		append(&buf, server_entry_name(&entry))
		append(&buf, u8(entry.address_len))
		append(&buf, server_entry_address(&entry))
	}
	if err := os.write_entire_file(SERVERS_TEMP, buf[:]); err != nil {
		return false
	}
	os.remove(SERVERS_FILE)
	if rename_err := os.rename(SERVERS_TEMP, SERVERS_FILE); rename_err != nil {
		os.remove(SERVERS_TEMP)
		return false
	}
	return true
}

// Newest first. A failed write puts the list back the way it was.
servers_add :: proc(list: ^[dynamic]Server_Entry, entry: Server_Entry) -> bool {
	if len(list) >= SERVERS_MAX {
		return false
	}
	inserted, _ := inject_at(list, 0, entry)
	if !inserted {
		return false
	}
	if !servers_save(list[:]) {
		ordered_remove(list, 0)
		return false
	}
	return true
}

servers_remove :: proc(list: ^[dynamic]Server_Entry, index: int) -> bool {
	if index < 0 || index >= len(list) {
		return false
	}
	kept := list[index]
	ordered_remove(list, index)
	if !servers_save(list[:]) {
		inject_at(list, index, kept)
		return false
	}
	return true
}

read_server_entry :: proc(reader: ^Reader) -> (entry: Server_Entry, ok: bool) {
	name_len := int(read_u8(reader))
	if !reader.ok || name_len <= 0 || name_len > SERVER_NAME_MAX || reader.i+name_len > len(reader.b) {
		reader.ok = false
		return
	}
	copy(entry.name[:name_len], reader.b[reader.i:reader.i+name_len])
	entry.name[name_len] = 0
	entry.name_len = name_len
	reader.i += name_len

	address_len := int(read_u8(reader))
	if !reader.ok || address_len <= 0 || address_len > SERVER_ADDR_MAX || reader.i+address_len > len(reader.b) {
		reader.ok = false
		return
	}
	copy(entry.address[:address_len], reader.b[reader.i:reader.i+address_len])
	entry.address[address_len] = 0
	entry.address_len = address_len
	reader.i += address_len
	return entry, true
}
