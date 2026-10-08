package main

import "core:c"
import rl "vendor:raylib"

// Ten slots on screen, plus five storage rows behind the inventory screen.
// The hotbar is the front of the array, so a picked-up block lands there first.
HOTBAR_SLOTS    :: 10
STORAGE_ROWS    :: 5
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

// The crafting grid sits to the right of the storage rows. The arrow and the
// result slot share that column. Slot indices past the inventory itself are
// how a click tells the server which grid it landed on.
CRAFT2_N      :: 4
CRAFT3_N      :: 9
CRAFT2_INDEX  :: INVENTORY_SLOTS
CRAFT2_RESULT :: CRAFT2_INDEX + CRAFT2_N
CRAFT3_INDEX  :: CRAFT2_RESULT + 1
CRAFT3_RESULT :: CRAFT3_INDEX + CRAFT3_N
ARROW_W       :: f32(40)
CRAFT_GAP     :: f32(20)

Slot :: struct {
	item:  Item,
	count: int,
}

Inventory :: struct {
	slots:    [INVENTORY_SLOTS]Slot,
	selected: int,
	open:     bool,
	// The 3x3 screen, opened from a placed crafting table. The 2x2 is the
	// inventory screen. Both flags belong to this client; the grids do not.
	table:    bool,
	// The stack on the cursor while the inventory screen is open.
	held:     Slot,
	craft2:   [CRAFT2_N]Slot,
	craft3:   [CRAFT3_N]Slot,
	// Set on the frame the screen opens or closes, for the same reason as Options.
	suppress_look: bool,
}

// Puts as many as it can into existing stacks, then into empty slots.
// Returns whatever did not fit, so a full inventory can leave the stack in the world.
inventory_add :: proc(inv: ^Inventory, item: Item, count: int) -> int {
	if item_empty(item) || count <= 0 {
		return 0
	}
	limit := stack_limit(item)
	left := count
	for &slot in inv.slots {
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
	for &slot in inv.slots {
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

// Right-clicking a placed crafting table. The 3x3 grid is the server's; this
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
	panel_w := PREVIEW_W + PREVIEW_GAP + row_w + CRAFT_GAP + craft_w + ARROW_W + SLOT_SIZE + PANEL_PAD*2
	panel_h := TITLE_H + grid_h + HOTBAR_GAP + SLOT_SIZE + HINT_H
	panel := rl.Rectangle {
		x      = (sw - panel_w) * 0.5,
		y      = (sh - panel_h) * 0.5,
		width  = panel_w,
		height = panel_h,
	}
	layout.panel = panel

	origin_x := panel.x + PANEL_PAD + PREVIEW_W + PREVIEW_GAP
	grid_y := panel.y + TITLE_H
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
	craft_x := origin_x + row_w + CRAFT_GAP
	for row in 0 ..< side {
		for col in 0 ..< side {
			layout.craft[row*side+col] = {
				craft_x + f32(col)*(SLOT_SIZE+SLOT_GAP),
				grid_y + f32(row)*(SLOT_SIZE+SLOT_GAP),
				SLOT_SIZE,
				SLOT_SIZE,
			}
		}
	}
	craft_h := f32(side)*SLOT_SIZE + f32(side-1)*SLOT_GAP
	layout.result = {
		craft_x + craft_w + ARROW_W,
		grid_y + (craft_h-SLOT_SIZE)*0.5,
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

draw_inventory :: proc(font: rl.Font, renderer: ^Renderer, inv: Inventory) {
	layout := inventory_layout(inv.open, inv.table)
	mouse := rl.GetMousePosition()
	if inv.open {
		rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), {0, 0, 0, 140})
		rl.DrawRectangleRec(layout.panel, {24, 24, 24, 235})
		rl.DrawRectangleLinesEx(layout.panel, 2, {80, 80, 80, 255})
		rl.DrawRectangleRec(layout.preview, {14, 14, 14, 200})
		draw_player_preview(renderer, layout.preview, mouse)
		title: cstring = "Crafting Table" if inv.table else "Inventory"
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
			"Click the result to craft    Q to drop    E or Esc to close",
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
	if inv.open && inv.held.count > 0 {
		size := SLOT_SIZE - 8
		dest := rl.Rectangle{mouse.x - size*0.5, mouse.y - size*0.5, size, size}
		draw_item_icon(renderer, inv.held.item, dest)
		draw_stack_count(font, dest, inv.held.count)
	}
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
