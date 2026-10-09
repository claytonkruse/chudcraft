package main

import "core:c"
import rl "vendor:raylib"

// Ten slots on screen, plus four storage rows behind the inventory screen.
// The hotbar is the front of the array, so a picked-up block lands there first.
HOTBAR_SLOTS    :: 10
STORAGE_ROWS    :: 4
INVENTORY_SLOTS :: HOTBAR_SLOTS * (STORAGE_ROWS + 1)
STACK_MAX       :: 64

SLOT_SIZE  :: f32(64)
SLOT_GAP   :: f32(4)
PANEL_PAD  :: f32(16)
// A wider gap than the storage rows, so the hotbar stays a separate row.
HOTBAR_GAP :: f32(14)
TITLE_H    :: f32(42)
HINT_H     :: f32(34)
HOTBAR_SCREEN_MARGIN :: f32(14)

// 1 through 9 select the first nine hotbar slots. 0 selects the tenth.
HOTBAR_KEYS := [HOTBAR_SLOTS]rl.KeyboardKey {
	.ONE, .TWO, .THREE, .FOUR, .FIVE, .SIX, .SEVEN, .EIGHT, .NINE, .ZERO,
}

// The Steve preview sits to the left of the storage rows.
PREVIEW_W   :: f32(150)
PREVIEW_GAP :: f32(12)

// The crafting grid sits above the storage rows. Slot indices past the
// inventory itself are how a click tells the server which grid it landed on.
CRAFT2_N      :: 4
CRAFT3_N      :: 9
CRAFT2_INDEX  :: INVENTORY_SLOTS
CRAFT2_RESULT :: CRAFT2_INDEX + CRAFT2_N
CRAFT3_INDEX  :: CRAFT2_RESULT + 1
CRAFT3_RESULT :: CRAFT3_INDEX + CRAFT3_N
// Every placeable slot. A drag remembers the ones the pointer crossed.
DRAG_MAX      :: INVENTORY_SLOTS + CRAFT2_N + CRAFT3_N
ARROW_W       :: f32(40)
CRAFT_GAP     :: f32(20)

// A button held with a stack on the cursor. Released as one click when the
// pointer never reaches a second slot.
Drag_Button :: enum u8 {
	None,
	Left,
	Right,
}

Drag :: struct {
	button:  Drag_Button,
	slots:   [DRAG_MAX]int,
	count:   int,
	origin:  int,
	on_slot: bool,
	outside: bool,
	// Set when this press was the second click of a double-click.
	gather:  bool,
}

Slot :: struct {
	item:  Item,
	count: int,
}

Inventory :: struct {
	slots:    [INVENTORY_SLOTS]Slot,
	selected: int,
	open:     bool,
	// The 3x3 screen, opened from a placed workbench. The 2x2 is the
	// inventory screen. Both flags belong to this client; the grids do not.
	table:    bool,
	// The stack on the cursor while the inventory screen is open.
	held:     Slot,
	craft2:   [CRAFT2_N]Slot,
	// The 3x3 of the workbench this screen is showing. The slots themselves
	// stay on that block; this is the copy the screen edits.
	craft3:   [CRAFT3_N]Slot,
	// Set on the frame the screen opens or closes, for the same reason as Options.
	suppress_look: bool,
}

// Puts as many as it can into existing stacks, then into empty slots.
// Returns whatever did not fit, so a full inventory can leave the stack in the world.
inventory_add :: proc(inv: ^Inventory, item: Item, count: int) -> int {
	return inventory_add_slots(inv.slots[:], item, count)
}

// Fills matching stacks in this range, then empty slots. The leftover is what
// did not fit, so a shift-click can aim at the hotbar or the storage rows alone.
inventory_add_slots :: proc(slots: []Slot, item: Item, count: int) -> int {
	if item_empty(item) || count <= 0 {
		return 0
	}
	limit := stack_limit(item)
	left := count
	for &slot in slots {
		if !item_same(slot.item, item) || slot.count <= 0 || slot.count >= limit {
			continue
		}
		take := min(left, limit-slot.count)
		slot.count += take
		left -= take
		if left == 0 {
			return 0
		}
	}
	for &slot in slots {
		if slot.count > 0 {
			continue
		}
		take := min(left, limit)
		slot.item = item
		slot.count = take
		left -= take
		if left == 0 {
			return 0
		}
	}
	return left
}

// How many of this item the range can still take.
inventory_room :: proc(slots: []Slot, item: Item) -> int {
	if item_empty(item) {
		return 0
	}
	limit := stack_limit(item)
	room := 0
	for slot in slots {
		if slot.count > 0 && item_same(slot.item, item) && slot.count < limit {
			room += limit - slot.count
		} else if slot.count <= 0 {
			room += limit
		}
	}
	return room
}

// Shift-click. The hotbar and the storage rows trade stacks. A crafted result
// fills the hotbar first and uses the storage rows for what does not fit.
inventory_shift :: proc(inv: ^Inventory, index: int) {
	storage := inv.slots[HOTBAR_SLOTS:]
	hotbar := inv.slots[:HOTBAR_SLOTS]
	if index == CRAFT2_RESULT {
		inventory_shift_craft(inv.craft2[:], 2, hotbar, storage)
		return
	}
	if index == CRAFT3_RESULT {
		inventory_shift_craft(inv.craft3[:], 3, hotbar, storage)
		return
	}
	src, ok := inventory_slot_mut(inv, index)
	if !ok || src.count <= 0 {
		return
	}
	dest := storage
	if index >= HOTBAR_SLOTS && index < INVENTORY_SLOTS {
		dest = hotbar
	}
	left := inventory_add_slots(dest, src.item, src.count)
	if left <= 0 {
		src^ = {}
		return
	}
	src.count = left
}

// Crafts as many times as the hotbar and the storage rows can hold together.
// The hotbar is filled first. Leftover ingredients stay in the grid.
inventory_shift_craft :: proc(grid: []Slot, width: int, hotbar, storage: []Slot) {
	item, count := craft_match(grid, width)
	if count <= 0 || item_empty(item) {
		return
	}
	available := 0
	first := true
	for slot in grid {
		if slot.count <= 0 {
			continue
		}
		if first {
			available = slot.count
			first = false
		} else {
			available = min(available, slot.count)
		}
	}
	if available <= 0 {
		return
	}
	room := inventory_room(hotbar, item) + inventory_room(storage, item)
	times := min(available, room/count)
	if times <= 0 {
		return
	}
	for &slot in grid {
		if slot.count <= 0 {
			continue
		}
		slot.count -= times
		if slot.count <= 0 {
			slot = {}
		}
	}
	left := inventory_add_slots(hotbar, item, times*count)
	inventory_add_slots(storage, item, left)
}

inventory_click_left :: proc(held, slot: ^Slot) {
	if held.count == 0 {
		held^ = slot^
		slot^ = {}
		return
	}
	if slot.count == 0 {
		slot^ = held^
		held^ = {}
		return
	}
	if item_same(slot.item, held.item) {
		limit := stack_limit(held.item)
		take := min(held.count, limit-slot.count)
		slot.count += take
		held.count -= take
		if held.count == 0 {
			held^ = {}
		}
		return
	}
	held^, slot^ = slot^, held^
}

// Half a stack onto an empty cursor, or one item from the cursor onto a stack.
inventory_click_right :: proc(held, slot: ^Slot) {
	if held.count == 0 {
		if slot.count == 0 {
			return
		}
		take := (slot.count + 1) / 2
		held.item = slot.item
		held.count = take
		slot.count -= take
		if slot.count == 0 {
			slot^ = {}
		}
		return
	}
	if slot.count == 0 {
		slot.item = held.item
		slot.count = 1
		held.count -= 1
		if held.count == 0 {
			held^ = {}
		}
		return
	}
	if !item_same(slot.item, held.item) || slot.count >= stack_limit(held.item) {
		return
	}
	slot.count += 1
	held.count -= 1
	if held.count == 0 {
		held^ = {}
	}
}

// The placeable slot behind an index. The crafting result is not one of these.
drag_slot_read :: proc(inv: Inventory, index: int) -> (slot: Slot, ok: bool) {
	if index >= 0 && index < INVENTORY_SLOTS {
		return inv.slots[index], true
	}
	if index >= CRAFT2_INDEX && index < CRAFT2_INDEX+CRAFT2_N {
		return inv.craft2[index-CRAFT2_INDEX], true
	}
	if index >= CRAFT3_INDEX && index < CRAFT3_INDEX+CRAFT3_N {
		return inv.craft3[index-CRAFT3_INDEX], true
	}
	return {}, false
}

Drag_Plan :: struct {
	index: [DRAG_MAX]int,
	give:  [DRAG_MAX]int,
	n:     int,
}

// evenly splits the cursor stack so the amounts placed differ by at most one.
// A slot that is full, or holds something else, is skipped. Right-drag places
// one item in each slot in the order the pointer crossed them.
inventory_drag_plan :: proc(inv: Inventory, indices: []int, evenly: bool) -> Drag_Plan {
	plan: Drag_Plan
	if inv.held.count <= 0 || item_empty(inv.held.item) {
		return plan
	}
	seen: [CRAFT3_RESULT + 1]bool
	room: [DRAG_MAX]int
	for index in indices {
		if index < 0 || index > CRAFT3_RESULT || seen[index] || plan.n >= DRAG_MAX {
			continue
		}
		seen[index] = true
		slot, ok := drag_slot_read(inv, index)
		if !ok {
			continue
		}
		limit := stack_limit(inv.held.item)
		space := limit
		if slot.count > 0 {
			if !item_same(slot.item, inv.held.item) {
				continue
			}
			space = limit - slot.count
		}
		if space <= 0 {
			continue
		}
		plan.index[plan.n] = index
		room[plan.n] = space
		plan.n += 1
	}
	if plan.n == 0 {
		return plan
	}
	if !evenly {
		left := inv.held.count
		for i in 0 ..< plan.n {
			if left <= 0 {
				break
			}
			plan.give[i] = 1
			left -= 1
		}
		return plan
	}
	// One item at a time, always to a slot that has room and has received the
	// least so far. Earlier slots win a tie, so a remainder lands on them.
	left := inv.held.count
	for left > 0 {
		best := -1
		least := max(int)
		for i in 0 ..< plan.n {
			if plan.give[i] >= room[i] || plan.give[i] >= least {
				continue
			}
			least = plan.give[i]
			best = i
		}
		if best < 0 {
			break
		}
		plan.give[best] += 1
		left -= 1
	}
	return plan
}

inventory_drag :: proc(inv: ^Inventory, indices: []int, evenly: bool) {
	plan := inventory_drag_plan(inv^, indices, evenly)
	for i in 0 ..< plan.n {
		if plan.give[i] <= 0 || inv.held.count <= 0 {
			continue
		}
		slot, ok := inventory_slot_mut(inv, plan.index[i])
		if !ok {
			continue
		}
		limit := stack_limit(inv.held.item)
		if slot.count > 0 && !item_same(slot.item, inv.held.item) {
			continue
		}
		space := limit - slot.count
		give := min(plan.give[i], space, inv.held.count)
		if give <= 0 {
			continue
		}
		if slot.count == 0 {
			slot.item = inv.held.item
		}
		slot.count += give
		inv.held.count -= give
	}
	if inv.held.count <= 0 {
		inv.held = {}
	}
}

// Pulls every matching stack in the inventory onto the cursor, stopping at the
// stack limit. Crafting grids are left alone; those are not inventory slots.
inventory_gather :: proc(inv: ^Inventory) {
	if inv.held.count <= 0 || item_empty(inv.held.item) {
		return
	}
	limit := stack_limit(inv.held.item)
	for &slot in inv.slots {
		if inv.held.count >= limit {
			return
		}
		if slot.count <= 0 || !item_same(slot.item, inv.held.item) {
			continue
		}
		take := min(slot.count, limit-inv.held.count)
		slot.count -= take
		inv.held.count += take
		if slot.count == 0 {
			slot = {}
		}
	}
}

// True when the cursor stack is back in the inventory. A full inventory keeps
// the stack on the cursor, and the screen stays open so the blocks are not lost.
inventory_stow :: proc(inv: ^Inventory) -> bool {
	if inv.held.count == 0 {
		return true
	}
	left := inventory_add(inv, inv.held.item, inv.held.count)
	if left > 0 {
		inv.held.count = left
		return false
	}
	inv.held = {}
	return true
}

// The cursor and the open flag are the client's. The stack on the cursor is the
// server's, so closing asks the server to stow before this hides the screen.
inventory_open_screen :: proc(inv: ^Inventory) {
	if inv.open && !inv.table {
		return
	}
	inv.open = true
	inv.table = false
	inv.suppress_look = true
	rl.EnableCursor()
}

// Right-clicking a placed workbench. The 3x3 grid is the server's; this
// only decides which one the screen draws.
inventory_open_table :: proc(inv: ^Inventory) {
	if inv.open && inv.table {
		return
	}
	inv.open = true
	inv.table = true
	inv.suppress_look = true
	rl.EnableCursor()
}

inventory_close_screen :: proc(inv: ^Inventory) {
	if !inv.open {
		return
	}
	inv.open = false
	inv.table = false
	inv.suppress_look = true
	rl.DisableCursor()
}

// What the player is holding in the world. Placement spends this stack; the
// cursor stack is only the drag while the inventory screen is open.
equipped_item :: proc(inv: ^Inventory) -> Item {
	slot := inv.slots[inv.selected]
	if slot.count <= 0 {
		return {}
	}
	return slot.item
}

// One block from the selected hotbar slot, into an empty cell the player is not occupying.
// Sticks and tools are not blocks, so they stay in the hand.
inventory_place :: proc(inv: ^Inventory, player: Player, world: ^World, x, y, z: int) {
	slot := &inv.slots[inv.selected]
	if slot.count <= 0 || slot.item.kind != .Block || slot.item.block == .Air {
		return
	}
	if get_block(world, x, y, z) != .Air {
		return
	}
	// A sapling only roots in dirt or grass. Anywhere else it would sit forever.
	if slot.item.block == .Oak_Sapling {
		ground := get_block(world, x, y-1, z)
		if ground != .Dirt && ground != .Grass {
			return
		}
	}
	// A door takes the cell above as well, and refuses a spot the panel would
	// share with the body. The item is one door, not two blocks.
	if slot.item.block == .Oak_Door {
		if !door_place(world, player, x, y, z) {
			return
		}
		slot.count -= 1
		if slot.count == 0 {
			slot^ = {}
		}
		return
	}
	if block_solid(slot.item.block) && player_overlaps_block(player, x, y, z) {
		return
	}
	set_block(world, x, y, z, slot.item.block)
	slot.count -= 1
	if slot.count == 0 {
		slot^ = {}
	}
}

// A click index, or nil when the index is the result slot or not a slot at all.
inventory_slot_mut :: proc(inv: ^Inventory, index: int) -> (slot: ^Slot, ok: bool) {
	if index >= 0 && index < INVENTORY_SLOTS {
		return &inv.slots[index], true
	}
	if index >= CRAFT2_INDEX && index < CRAFT2_INDEX+CRAFT2_N {
		return &inv.craft2[index-CRAFT2_INDEX], true
	}
	if index >= CRAFT3_INDEX && index < CRAFT3_INDEX+CRAFT3_N {
		return &inv.craft3[index-CRAFT3_INDEX], true
	}
	return nil, false
}

Inventory_Layout :: struct {
	panel:        rl.Rectangle,
	slots:        [INVENTORY_SLOTS]rl.Rectangle,
	preview:      rl.Rectangle,
	craft:        [CRAFT3_N]rl.Rectangle,
	craft_side:   int,
	result:       rl.Rectangle,
	result_index: int,
}

inventory_layout :: proc(open, table: bool) -> Inventory_Layout {
	sw := f32(rl.GetScreenWidth())
	sh := f32(rl.GetScreenHeight())
	row_w := f32(HOTBAR_SLOTS)*SLOT_SIZE + f32(HOTBAR_SLOTS-1)*SLOT_GAP
	layout: Inventory_Layout

	if !open {
		x := (sw - row_w) * 0.5
		y := sh - SLOT_SIZE - HOTBAR_SCREEN_MARGIN
		for i in 0 ..< HOTBAR_SLOTS {
			layout.slots[i] = {x + f32(i)*(SLOT_SIZE+SLOT_GAP), y, SLOT_SIZE, SLOT_SIZE}
		}
		return layout
	}

	grid_h := f32(STORAGE_ROWS)*SLOT_SIZE + f32(STORAGE_ROWS-1)*SLOT_GAP
	side := 3 if table else 2
	craft_w := f32(side)*SLOT_SIZE + f32(side-1)*SLOT_GAP
	craft_h := craft_w
	panel_w := PREVIEW_W + PREVIEW_GAP + row_w + PANEL_PAD*2
	panel_h := TITLE_H + craft_h + CRAFT_GAP + grid_h + HOTBAR_GAP + SLOT_SIZE + HINT_H
	panel := rl.Rectangle {
		x      = (sw - panel_w) * 0.5,
		y      = (sh - panel_h) * 0.5,
		width  = panel_w,
		height = panel_h,
	}
	layout.panel = panel

	origin_x := panel.x + PANEL_PAD + PREVIEW_W + PREVIEW_GAP
	craft_y := panel.y + TITLE_H
	grid_y := craft_y + craft_h + CRAFT_GAP
	layout.preview = {panel.x + PANEL_PAD, grid_y, PREVIEW_W, grid_h}
	for row in 0 ..< STORAGE_ROWS {
		for col in 0 ..< HOTBAR_SLOTS {
			index := HOTBAR_SLOTS + row*HOTBAR_SLOTS + col
			layout.slots[index] = {
				origin_x + f32(col)*(SLOT_SIZE+SLOT_GAP),
				grid_y + f32(row)*(SLOT_SIZE+SLOT_GAP),
				SLOT_SIZE,
				SLOT_SIZE,
			}
		}
	}
	hotbar_y := grid_y + grid_h + HOTBAR_GAP
	for col in 0 ..< HOTBAR_SLOTS {
		layout.slots[col] = {
			origin_x + f32(col)*(SLOT_SIZE+SLOT_GAP),
			hotbar_y,
			SLOT_SIZE,
			SLOT_SIZE,
		}
	}

	layout.craft_side = side
	// Centered over the storage rows, so the grid reads as its own band.
	craft_x := origin_x + (row_w-(craft_w+ARROW_W+SLOT_SIZE))*0.5
	for row in 0 ..< side {
		for col in 0 ..< side {
			layout.craft[row*side+col] = {
				craft_x + f32(col)*(SLOT_SIZE+SLOT_GAP),
				craft_y + f32(row)*(SLOT_SIZE+SLOT_GAP),
				SLOT_SIZE,
				SLOT_SIZE,
			}
		}
	}
	layout.result = {
		craft_x + craft_w + ARROW_W,
		craft_y + (craft_h-SLOT_SIZE)*0.5,
		SLOT_SIZE,
		SLOT_SIZE,
	}
	layout.result_index = CRAFT3_RESULT if table else CRAFT2_RESULT
	return layout
}

inventory_slot_at :: proc(mouse: rl.Vector2, table: bool) -> (index: int, ok: bool) {
	layout := inventory_layout(true, table)
	for i in 0 ..< INVENTORY_SLOTS {
		if rl.CheckCollisionPointRec(mouse, layout.slots[i]) {
			return i, true
		}
	}
	base := CRAFT3_INDEX if table else CRAFT2_INDEX
	cells := layout.craft_side * layout.craft_side
	for i in 0 ..< cells {
		if rl.CheckCollisionPointRec(mouse, layout.craft[i]) {
			return base + i, true
		}
	}
	if rl.CheckCollisionPointRec(mouse, layout.result) {
		return layout.result_index, true
	}
	return 0, false
}

// What a slot index currently shows. The result index is the recipe, not a stack.
inventory_slot_view :: proc(inv: Inventory, index: int) -> (slot: Slot, ok: bool) {
	if index >= 0 && index < INVENTORY_SLOTS {
		return inv.slots[index], true
	}
	if index >= CRAFT2_INDEX && index < CRAFT2_INDEX+CRAFT2_N {
		return inv.craft2[index-CRAFT2_INDEX], true
	}
	if index == CRAFT2_RESULT {
		grid := inv.craft2
		item, count := craft_match(grid[:], 2)
		if count <= 0 {
			return {}, true
		}
		return Slot{item = item, count = count}, true
	}
	if index >= CRAFT3_INDEX && index < CRAFT3_INDEX+CRAFT3_N {
		return inv.craft3[index-CRAFT3_INDEX], true
	}
	if index == CRAFT3_RESULT {
		grid := inv.craft3
		item, count := craft_match(grid[:], 3)
		if count <= 0 {
			return {}, true
		}
		return Slot{item = item, count = count}, true
	}
	return {}, false
}

draw_inventory :: proc(font: rl.Font, renderer: ^Renderer, inv: Inventory, drag: Drag, player: Player, cycle: Walk_Cycle) {
	layout := inventory_layout(inv.open, inv.table)
	mouse := rl.GetMousePosition()
	if inv.open {
		rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), {0, 0, 0, 140})
		rl.DrawRectangleRec(layout.panel, {24, 24, 24, 235})
		rl.DrawRectangleLinesEx(layout.panel, 2, {80, 80, 80, 255})
		rl.DrawRectangleRec(layout.preview, {14, 14, 14, 200})
		held: Item
		slot := inv.slots[inv.selected]
		if slot.count > 0 {
			held = slot.item
		}
		draw_player_preview(renderer, layout.preview, mouse, player.yaw, cycle.body, cycle.phase, cycle.amount, held)
		title: cstring = "Workbench" if inv.table else "Inventory"
		rl.DrawTextEx(font, title, {layout.panel.x + PANEL_PAD, layout.panel.y + 12}, HUD_SIZE, HUD_SPACING, rl.WHITE)
		if index, hovered := inventory_slot_at(mouse, inv.table); hovered {
			if slot, ok := inventory_slot_view(inv, index); ok && slot.count > 0 {
				name := item_name(slot.item)
				nw := rl.MeasureTextEx(font, name, HUD_SIZE, HUD_SPACING).x
				rl.DrawTextEx(
					font,
					name,
					{layout.panel.x + layout.panel.width - PANEL_PAD - nw, layout.panel.y + 12},
					HUD_SIZE,
					HUD_SPACING,
					rl.WHITE,
				)
			}
		}
		rl.DrawTextEx(
			font,
			"Shift-click to move    Click result to craft    Q to drop    E or Esc",
			{layout.panel.x + PANEL_PAD, layout.panel.y + layout.panel.height - 26},
			HUD_SIZE,
			HUD_SPACING,
			{160, 160, 160, 255},
		)
		draw_craft_grid(font, renderer, inv, layout, mouse)
	}

	limit := INVENTORY_SLOTS if inv.open else HOTBAR_SLOTS
	for i in 0 ..< limit {
		hovered := inv.open && rl.CheckCollisionPointRec(mouse, layout.slots[i])
		draw_slot(font, renderer, layout.slots[i], inv.slots[i], i == inv.selected, hovered)
	}

	if !inv.open {
		draw_selected_name(font, inv, layout)
	}
	// The cursor hotspot is the point of the arrow. The stack is centered on that
	// point, so it stays on the tip instead of hanging off the tail.
	if inv.open && drag.button != .None && drag.count >= 2 {
		draw_drag_preview(font, renderer, inv, drag, layout)
	}
	if inv.open && inv.held.count > 0 {
		size := SLOT_SIZE - 8
		dest := rl.Rectangle{mouse.x - size*0.5, mouse.y - size*0.5, size, size}
		draw_item_icon(renderer, inv.held.item, dest)
		draw_stack_count(font, dest, inv.held.count)
	}
}

// What a left or right drag will drop into each slot when the button comes up.
draw_drag_preview :: proc(font: rl.Font, renderer: ^Renderer, inv: Inventory, drag: Drag, layout: Inventory_Layout) {
	slots := drag.slots
	plan := inventory_drag_plan(inv, slots[:drag.count], drag.button == .Left)
	for i in 0 ..< plan.n {
		if plan.give[i] <= 0 {
			continue
		}
		rect, ok := layout_slot_rect(layout, plan.index[i], inv.table)
		if !ok {
			continue
		}
		rl.DrawRectangleLinesEx(rect, 2, {220, 190, 90, 255})
		slot, _ := drag_slot_read(inv, plan.index[i])
		if slot.count <= 0 {
			pad: f32 = 4
			draw_item_icon(renderer, inv.held.item, {rect.x + pad, rect.y + pad, rect.width - pad*2, rect.height - pad*2})
			draw_stack_count(font, rect, plan.give[i])
		} else {
			text := rl.TextFormat("+%d", c.int(plan.give[i]))
			draw_slot_text(font, text, rect.x+4, rect.y+3, 16, {240, 210, 120, 255})
		}
	}
}

layout_slot_rect :: proc(layout: Inventory_Layout, index: int, table: bool) -> (rect: rl.Rectangle, ok: bool) {
	if index >= 0 && index < INVENTORY_SLOTS {
		return layout.slots[index], true
	}
	base := CRAFT3_INDEX if table else CRAFT2_INDEX
	cells := layout.craft_side * layout.craft_side
	if index >= base && index < base+cells {
		return layout.craft[index-base], true
	}
	return {}, false
}

draw_craft_grid :: proc(font: rl.Font, renderer: ^Renderer, inv: Inventory, layout: Inventory_Layout, mouse: rl.Vector2) {
	side := layout.craft_side
	cells := side * side
	for i in 0 ..< cells {
		slot: Slot
		if inv.table {
			slot = inv.craft3[i]
		} else {
			slot = inv.craft2[i]
		}
		hovered := rl.CheckCollisionPointRec(mouse, layout.craft[i])
		draw_slot(font, renderer, layout.craft[i], slot, false, hovered)
	}
	item: Item
	count: int
	if inv.table {
		grid := inv.craft3
		item, count = craft_match(grid[:], 3)
	} else {
		grid := inv.craft2
		item, count = craft_match(grid[:], 2)
	}
	preview: Slot
	if count > 0 {
		preview = {item = item, count = count}
	}
	hovered := rl.CheckCollisionPointRec(mouse, layout.result)
	draw_slot(font, renderer, layout.result, preview, false, hovered)

	label: cstring = ">"
	size: f32 = 28
	gap_left := layout.craft[side-1].x + SLOT_SIZE
	gap_right := layout.result.x
	tw := rl.MeasureTextEx(font, label, size, 0).x
	tx := (gap_left + gap_right - tw) * 0.5
	ty := layout.result.y + (SLOT_SIZE-size)*0.5
	rl.DrawTextEx(font, label, {tx, ty}, size, 0, {180, 180, 180, 255})
}

draw_selected_name :: proc(font: rl.Font, inv: Inventory, layout: Inventory_Layout) {
	slot := inv.slots[inv.selected]
	if slot.count <= 0 {
		return
	}
	text := item_name(slot.item)
	width := rl.MeasureTextEx(font, text, HUD_SIZE, HUD_SPACING).x
	row_left := layout.slots[0].x
	row_right := layout.slots[HOTBAR_SLOTS-1].x + SLOT_SIZE
	x := (row_left + row_right - width) * 0.5
	y := layout.slots[0].y - HUD_SIZE - 4
	draw_hud_text(font, text, c.int(x), c.int(y), rl.WHITE)
}

draw_slot :: proc(font: rl.Font, renderer: ^Renderer, rect: rl.Rectangle, slot: Slot, selected, hovered: bool) {
	bg := rl.Color{36, 36, 36, 220}
	if hovered {
		bg = {64, 64, 64, 230}
	}
	rl.DrawRectangleRec(rect, bg)
	if slot.count > 0 {
		pad: f32 = 4
		draw_item_icon(renderer, slot.item, {rect.x + pad, rect.y + pad, rect.width - pad*2, rect.height - pad*2})
		draw_stack_count(font, rect, slot.count)
	}
	border := rl.Color{72, 72, 72, 255}
	if selected {
		border = rl.WHITE
	}
	rl.DrawRectangleLinesEx(rect, 2, border)
}

draw_stack_count :: proc(font: rl.Font, rect: rl.Rectangle, count: int) {
	if count <= 1 {
		return
	}
	text := rl.TextFormat("%d", c.int(count))
	size: f32 = 16
	cw := rl.MeasureTextEx(font, text, size, 0).x
	draw_slot_text(font, text, rect.x+rect.width-cw-4, rect.y+rect.height-size-3, size, rl.WHITE)
}

draw_slot_text :: proc(font: rl.Font, text: cstring, x, y, size: f32, color: rl.Color) {
	rl.DrawTextEx(font, text, {x + 1, y + 1}, size, 0, rl.BLACK)
	rl.DrawTextEx(font, text, {x, y}, size, 0, color)
}
