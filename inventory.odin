package main

import "core:c"
import rl "vendor:raylib"

// Nine slots on screen, plus three storage rows behind the inventory screen.
// The hotbar is the front of the array, so a mined block lands there first.
HOTBAR_SLOTS    :: 9
STORAGE_ROWS    :: 3
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

HOTBAR_KEYS := [HOTBAR_SLOTS]rl.KeyboardKey {
	.ONE, .TWO, .THREE, .FOUR, .FIVE, .SIX, .SEVEN, .EIGHT, .NINE,
}

Slot :: struct {
	block: Block,
	count: int,
}

Inventory :: struct {
	slots:    [INVENTORY_SLOTS]Slot,
	selected: int,
	open:     bool,
	// The stack on the cursor while the inventory screen is open.
	held:     Slot,
	// Set on the frame the screen opens or closes, for the same reason as Options.
	suppress_look: bool,
}

// Puts as many as it can into existing stacks, then into empty slots.
// Returns whatever did not fit, so a full inventory can leave the block in the world.
inventory_add :: proc(inv: ^Inventory, block: Block, count: int) -> int {
	if block == .Air || count <= 0 {
		return 0
	}
	left := count
	for &slot in inv.slots {
		if slot.block != block || slot.count <= 0 || slot.count >= STACK_MAX {
			continue
		}
		take := min(left, STACK_MAX - slot.count)
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
		take := min(left, STACK_MAX)
		slot.block = block
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
	if slot.block == held.block {
		take := min(held.count, STACK_MAX - slot.count)
		slot.count += take
		held.count -= take
		if held.count == 0 {
			held.block = .Air
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
		held.block = slot.block
		held.count = take
		slot.count -= take
		if slot.count == 0 {
			slot.block = .Air
		}
		return
	}
	if slot.count == 0 {
		slot.block = held.block
		slot.count = 1
		held.count -= 1
		if held.count == 0 {
			held.block = .Air
		}
		return
	}
	if slot.block != held.block || slot.count >= STACK_MAX {
		return
	}
	slot.count += 1
	held.count -= 1
	if held.count == 0 {
		held.block = .Air
	}
}

// True when the cursor stack is back in the inventory. A full inventory keeps
// the stack on the cursor, and the screen stays open so the blocks are not lost.
inventory_stow :: proc(inv: ^Inventory) -> bool {
	if inv.held.count == 0 {
		return true
	}
	left := inventory_add(inv, inv.held.block, inv.held.count)
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
	if inv.open {
		return
	}
	inv.open = true
	inv.suppress_look = true
	rl.EnableCursor()
}

inventory_close_screen :: proc(inv: ^Inventory) {
	if !inv.open {
		return
	}
	inv.open = false
	inv.suppress_look = true
	rl.DisableCursor()
}

// One block from the selected hotbar slot, into an empty cell the player is not occupying.
inventory_place :: proc(inv: ^Inventory, player: Player, world: ^World, x, y, z: int) {
	slot := &inv.slots[inv.selected]
	if slot.count <= 0 || slot.block == .Air {
		return
	}
	if get_block(world, x, y, z) != .Air {
		return
	}
	if block_solid(slot.block) && player_overlaps_block(player, x, y, z) {
		return
	}
	set_block(world, x, y, z, slot.block)
	slot.count -= 1
	if slot.count == 0 {
		slot.block = .Air
	}
}

Inventory_Layout :: struct {
	panel: rl.Rectangle,
	slots: [INVENTORY_SLOTS]rl.Rectangle,
}

inventory_layout :: proc(open: bool) -> Inventory_Layout {
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
	panel_w := row_w + PANEL_PAD*2
	panel_h := TITLE_H + grid_h + HOTBAR_GAP + SLOT_SIZE + HINT_H
	panel := rl.Rectangle {
		x      = (sw - panel_w) * 0.5,
		y      = (sh - panel_h) * 0.5,
		width  = panel_w,
		height = panel_h,
	}
	layout.panel = panel

	origin_x := panel.x + PANEL_PAD
	grid_y := panel.y + TITLE_H
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
	return layout
}

inventory_slot_at :: proc(mouse: rl.Vector2) -> (index: int, ok: bool) {
	layout := inventory_layout(true)
	for i in 0 ..< INVENTORY_SLOTS {
		if rl.CheckCollisionPointRec(mouse, layout.slots[i]) {
			return i, true
		}
	}
	return 0, false
}

draw_inventory :: proc(font: rl.Font, renderer: ^Renderer, inv: Inventory) {
	layout := inventory_layout(inv.open)
	mouse := rl.GetMousePosition()
	if inv.open {
		rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), {0, 0, 0, 140})
		rl.DrawRectangleRec(layout.panel, {24, 24, 24, 235})
		rl.DrawRectangleLinesEx(layout.panel, 2, {80, 80, 80, 255})
		rl.DrawTextEx(font, "Inventory", {layout.panel.x + PANEL_PAD, layout.panel.y + 12}, HUD_SIZE, HUD_SPACING, rl.WHITE)
		if index, hovered := inventory_slot_at(mouse); hovered && inv.slots[index].count > 0 {
			name := block_name(inv.slots[index].block)
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
		rl.DrawTextEx(
			font,
			"E or Esc to close",
			{layout.panel.x + PANEL_PAD, layout.panel.y + layout.panel.height - 26},
			HUD_SIZE,
			HUD_SPACING,
			{160, 160, 160, 255},
		)
	}

	limit := INVENTORY_SLOTS if inv.open else HOTBAR_SLOTS
	for i in 0 ..< limit {
		hovered := inv.open && rl.CheckCollisionPointRec(mouse, layout.slots[i])
		draw_slot(font, renderer, layout.slots[i], inv.slots[i], i == inv.selected, hovered)
	}

	if !inv.open {
		draw_selected_name(font, inv, layout)
	}
	// The cursor hotspot is the point of the arrow. The block is centered on that
	// point, so it stays on the tip instead of hanging off the tail.
	if inv.open && inv.held.count > 0 {
		size := SLOT_SIZE - 8
		dest := rl.Rectangle{mouse.x - size*0.5, mouse.y - size*0.5, size, size}
		draw_block_icon(renderer, inv.held.block, dest)
		draw_stack_count(font, dest, inv.held.count)
	}
}

draw_selected_name :: proc(font: rl.Font, inv: Inventory, layout: Inventory_Layout) {
	slot := inv.slots[inv.selected]
	if slot.count <= 0 {
		return
	}
	text := block_name(slot.block)
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
		draw_block_icon(renderer, slot.block, {rect.x + pad, rect.y + pad, rect.width - pad*2, rect.height - pad*2})
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

block_name :: proc(block: Block) -> cstring {
	switch block {
	case .Grass:
		return "Grass"
	case .Dirt:
		return "Dirt"
	case .Stone:
		return "Stone"
	case .Bedrock:
		return "Bedrock"
	case .Coal_Ore:
		return "Coal Ore"
	case .Iron_Ore:
		return "Iron Ore"
	case .Gold_Ore:
		return "Gold Ore"
	case .Water:
		return "Water"
	case .Oak_Log:
		return "Oak Log"
	case .Oak_Leaves:
		return "Oak Leaves"
	case .Air:
		return ""
	}
	return ""
}
