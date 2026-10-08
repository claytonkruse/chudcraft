package main

// Anything a slot can hold. Blocks stay in the world enum; sticks and tools
// never occupy a cell, so they are not blocks.
Item_Kind :: enum u8 {
	None,
	Block,
	Stick,
	Wood_Shovel,
	Wood_Pickaxe,
	Stone_Shovel,
	Stone_Pickaxe,
}

Item :: struct {
	kind:  Item_Kind,
	block: Block,
}

item_block :: proc(block: Block) -> Item {
	return {kind = .Block, block = block}
}

item_empty :: proc(item: Item) -> bool {
	return item.kind == .None || (item.kind == .Block && item.block == .Air)
}

item_same :: proc(a, b: Item) -> bool {
	if a.kind != b.kind {
		return false
	}
	if a.kind == .Block {
		return a.block == b.block
	}
	return a.kind != .None
}

// Tools stay at one per slot. Everything else uses the normal stack.
stack_limit :: proc(item: Item) -> int {
	#partial switch item.kind {
	case .None:
		return 0
	case .Wood_Shovel, .Wood_Pickaxe, .Stone_Shovel, .Stone_Pickaxe:
		return 1
	}
	return STACK_MAX
}

item_name :: proc(item: Item) -> cstring {
	switch item.kind {
	case .None:
		return ""
	case .Stick:
		return "Stick"
	case .Wood_Shovel:
		return "Wooden Shovel"
	case .Wood_Pickaxe:
		return "Wooden Pickaxe"
	case .Stone_Shovel:
		return "Stone Shovel"
	case .Stone_Pickaxe:
		return "Stone Pickaxe"
	case .Block:
		return block_name(item.block)
	}
	return ""
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
	case .Oak_Planks:
		return "Oak Planks"
	case .Workbench:
		return "Workbench"
	case .Air:
		return ""
	}
	return ""
}

// A shaped recipe. The pattern's bounding box is what has to match, so a stick
// column can sit in any column of the grid. Tools are three tall and only fit
// the workbench. Stone tools use stone blocks; this world has no cobblestone.
Recipe :: struct {
	w, h:  int,
	cells: [9]Item,
	out:   Item,
	count: int,
}

LOG :: Item {
	kind  = .Block,
	block = .Oak_Log,
}
PLANK :: Item {
	kind  = .Block,
	block = .Oak_Planks,
}
ROCK :: Item {
	kind  = .Block,
	block = .Stone,
}
STICK_ITEM :: Item {
	kind = .Stick,
}
WORKBENCH :: Item {
	kind  = .Block,
	block = .Workbench,
}

RECIPES :: [?]Recipe {
	{w = 1, h = 1, cells = {0 = LOG}, out = PLANK, count = 4},
	{w = 1, h = 2, cells = {0 = PLANK, 1 = PLANK}, out = STICK_ITEM, count = 4},
	{w = 2, h = 2, cells = {0 = PLANK, 1 = PLANK, 2 = PLANK, 3 = PLANK}, out = WORKBENCH, count = 1},
	{w = 1, h = 3, cells = {0 = PLANK, 1 = STICK_ITEM, 2 = STICK_ITEM}, out = {kind = .Wood_Shovel}, count = 1},
	{
		w = 3, h = 3,
		cells = {0 = PLANK, 1 = PLANK, 2 = PLANK, 4 = STICK_ITEM, 7 = STICK_ITEM},
		out = {kind = .Wood_Pickaxe}, count = 1,
	},
	{w = 1, h = 3, cells = {0 = ROCK, 1 = STICK_ITEM, 2 = STICK_ITEM}, out = {kind = .Stone_Shovel}, count = 1},
	{
		w = 3, h = 3,
		cells = {0 = ROCK, 1 = ROCK, 2 = ROCK, 4 = STICK_ITEM, 7 = STICK_ITEM},
		out = {kind = .Stone_Pickaxe}, count = 1,
	},
}

// The ingredients currently arranged in a square grid, row-major.
// width is 2 for the inventory grid and 3 for the workbench.
craft_match :: proc(grid: []Slot, width: int) -> (item: Item, count: int) {
	if width <= 0 || len(grid) < width*width {
		return {}, 0
	}
	min_c, min_r := width, width
	max_c, max_r := -1, -1
	for row in 0 ..< width {
		for col in 0 ..< width {
			if grid[row*width+col].count <= 0 {
				continue
			}
			min_c = min(min_c, col)
			max_c = max(max_c, col)
			min_r = min(min_r, row)
			max_r = max(max_r, row)
		}
	}
	if max_c < 0 {
		return {}, 0
	}
	w := max_c - min_c + 1
	h := max_r - min_r + 1
	for recipe in RECIPES {
		if recipe.w != w || recipe.h != h {
			continue
		}
		if recipe_fits(grid, width, recipe, min_c, min_r) {
			return recipe.out, recipe.count
		}
	}
	return {}, 0
}

recipe_fits :: proc(grid: []Slot, width: int, recipe: Recipe, origin_c, origin_r: int) -> bool {
	for ry in 0 ..< recipe.h {
		for rx in 0 ..< recipe.w {
			want := recipe.cells[ry*recipe.w+rx]
			slot := grid[(origin_r+ry)*width+origin_c+rx]
			if item_empty(want) {
				if slot.count > 0 {
					return false
				}
				continue
			}
			if slot.count <= 0 || !item_same(slot.item, want) {
				return false
			}
		}
	}
	return true
}

// Moves the result onto the cursor and spends one of each ingredient per craft.
// whole keeps going until the ingredients or the stack run out.
craft_take :: proc(grid: []Slot, width: int, held: ^Slot, whole: bool) {
	item, count := craft_match(grid, width)
	if count <= 0 || item_empty(item) {
		return
	}
	if held.count > 0 && !item_same(held.item, item) {
		return
	}
	room := stack_limit(item) - held.count
	if room < count {
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
	times := 1
	if whole {
		times = min(available, room/count)
	}
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
	held.item = item
	held.count += times * count
}
