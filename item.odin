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
	Wood_Axe,
	Stone_Axe,
	Iron_Shovel,
	Iron_Pickaxe,
	Iron_Axe,
	Iron_Ingot,
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
	case .Wood_Shovel, .Wood_Pickaxe, .Wood_Axe,
	     .Stone_Shovel, .Stone_Pickaxe, .Stone_Axe,
	     .Iron_Shovel, .Iron_Pickaxe, .Iron_Axe:
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
	case .Wood_Axe:
		return "Wooden Axe"
	case .Stone_Shovel:
		return "Stone Shovel"
	case .Stone_Pickaxe:
		return "Stone Pickaxe"
	case .Stone_Axe:
		return "Stone Axe"
	case .Iron_Shovel:
		return "Iron Shovel"
	case .Iron_Pickaxe:
		return "Iron Pickaxe"
	case .Iron_Axe:
		return "Iron Axe"
	case .Iron_Ingot:
		return "Iron Ingot"
	case .Block:
		return block_name(item.block)
	}
	return ""
}

block_name :: proc(block: Block) -> cstring {
	if block_is_door(block) {
		return "Oak Door"
	}
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
	case .Oak_Sapling:
		return "Oak Sapling"
	case .Sand:
		return "Sand"
	case .Gravel:
		return "Gravel"
	case .Oak_Planks:
		return "Oak Planks"
	case .Workbench:
		return "Workbench"
	case .Oak_Door:
		return "Oak Door"
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
INGOT :: Item {
	kind = .Iron_Ingot,
}
WORKBENCH :: Item {
	kind  = .Block,
	block = .Workbench,
}
DOOR :: Item {
	kind  = .Block,
	block = .Oak_Door,
}

RECIPES :: [?]Recipe {
	{w = 1, h = 1, cells = {0 = LOG}, out = PLANK, count = 4},
	{w = 1, h = 2, cells = {0 = PLANK, 1 = PLANK}, out = STICK_ITEM, count = 4},
	{w = 2, h = 2, cells = {0 = PLANK, 1 = PLANK, 2 = PLANK, 3 = PLANK}, out = WORKBENCH, count = 1},
	{w = 2, h = 3, cells = {0 = PLANK, 1 = PLANK, 2 = PLANK, 3 = PLANK, 4 = PLANK, 5 = PLANK}, out = DOOR, count = 3},
	{w = 1, h = 3, cells = {0 = PLANK, 1 = STICK_ITEM, 2 = STICK_ITEM}, out = {kind = .Wood_Shovel}, count = 1},
	{
		w = 3, h = 3,
		cells = {0 = PLANK, 1 = PLANK, 2 = PLANK, 4 = STICK_ITEM, 7 = STICK_ITEM},
		out = {kind = .Wood_Pickaxe}, count = 1,
	},
	{w = 2, h = 3, cells = {0 = PLANK, 1 = PLANK, 2 = PLANK, 3 = STICK_ITEM, 5 = STICK_ITEM}, out = {kind = .Wood_Axe}, count = 1},
	{w = 1, h = 3, cells = {0 = ROCK, 1 = STICK_ITEM, 2 = STICK_ITEM}, out = {kind = .Stone_Shovel}, count = 1},
	{
		w = 3, h = 3,
		cells = {0 = ROCK, 1 = ROCK, 2 = ROCK, 4 = STICK_ITEM, 7 = STICK_ITEM},
		out = {kind = .Stone_Pickaxe}, count = 1,
	},
	{w = 2, h = 3, cells = {0 = ROCK, 1 = ROCK, 2 = ROCK, 3 = STICK_ITEM, 5 = STICK_ITEM}, out = {kind = .Stone_Axe}, count = 1},
	{w = 1, h = 3, cells = {0 = INGOT, 1 = STICK_ITEM, 2 = STICK_ITEM}, out = {kind = .Iron_Shovel}, count = 1},
	{
		w = 3, h = 3,
		cells = {0 = INGOT, 1 = INGOT, 2 = INGOT, 4 = STICK_ITEM, 7 = STICK_ITEM},
		out = {kind = .Iron_Pickaxe}, count = 1,
	},
	{w = 2, h = 3, cells = {0 = INGOT, 1 = INGOT, 2 = INGOT, 3 = STICK_ITEM, 5 = STICK_ITEM}, out = {kind = .Iron_Axe}, count = 1},
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

// How long the equipped tool has been working on one block. The swing is only
// for the view; the server breaks the block when time reaches mine_seconds.
Mine :: struct {
	on:        bool,
	x, y, z:   int,
	time:      f32,
	swing:     f32,
	tool:      Item,
}

// One punch of the arm, independent of how long the block takes.
MINE_SWING :: f32(0.35)

Tool_Class :: enum {
	None,
	Shovel,
	Pickaxe,
	Axe,
}

tool_class :: proc(item: Item) -> Tool_Class {
	#partial switch item.kind {
	case .Wood_Shovel, .Stone_Shovel, .Iron_Shovel:
		return .Shovel
	case .Wood_Pickaxe, .Stone_Pickaxe, .Iron_Pickaxe:
		return .Pickaxe
	case .Wood_Axe, .Stone_Axe, .Iron_Axe:
		return .Axe
	}
	return .None
}

// Wood, stone, then iron. A tool only spends this speed on the blocks it is for.
tool_speed :: proc(item: Item) -> f32 {
	#partial switch item.kind {
	case .Wood_Shovel, .Wood_Pickaxe, .Wood_Axe:
		return 2
	case .Stone_Shovel, .Stone_Pickaxe, .Stone_Axe:
		return 4
	case .Iron_Shovel, .Iron_Pickaxe, .Iron_Axe:
		return 6
	}
	return 1
}

preferred_tool :: proc(block: Block) -> Tool_Class {
	if block_is_door(block) {
		return .Axe
	}
	switch block {
	case .Grass, .Dirt, .Sand, .Gravel:
		return .Shovel
	case .Stone, .Coal_Ore, .Iron_Ore, .Gold_Ore:
		return .Pickaxe
	case .Oak_Log, .Oak_Planks, .Oak_Leaves, .Oak_Sapling, .Workbench, .Oak_Door:
		return .Axe
	case .Air, .Bedrock, .Water:
		return .None
	}
	return .None
}

block_hardness :: proc(block: Block) -> f32 {
	if block_is_door(block) {
		return 3
	}
	switch block {
	case .Grass, .Dirt, .Sand:
		return 0.5
	case .Gravel:
		return 0.6
	case .Oak_Leaves, .Oak_Sapling:
		return 0.2
	case .Stone:
		return 1.5
	case .Coal_Ore, .Iron_Ore, .Gold_Ore:
		return 3
	case .Oak_Log, .Oak_Planks:
		return 2
	case .Workbench:
		return 2.5
	case .Oak_Door:
		return 3
	case .Air, .Bedrock, .Water:
		return 0
	}
	return 0
}

// Seconds of holding the button. Stone and ore stay slow unless a pickaxe is
// out; everything else uses the hand, and the matching tool shortens that.
mine_seconds :: proc(block: Block, tool: Item) -> f32 {
	hard := block_hardness(block)
	if hard <= 0 {
		return 1
	}
	want := preferred_tool(block)
	if want == .Pickaxe && tool_class(tool) != .Pickaxe {
		return hard * 5
	}
	speed: f32 = 1
	if want != .None && tool_class(tool) == want {
		speed = tool_speed(tool)
	}
	return hard * 1.5 / speed
}

// What a broken block leaves behind. Iron ore gives the ingot the iron tools need.
// Grass drops dirt, so the placed block does not keep its grass cap.
block_drop :: proc(block: Block) -> Item {
	if block_is_door(block) {
		return item_block(.Oak_Door)
	}
	if block == .Iron_Ore {
		return {kind = .Iron_Ingot}
	}
	if block == .Grass {
		return item_block(.Dirt)
	}
	return item_block(block)
}

// holding is the left button this frame. Looking at a different block, or a
// different tool, starts the timer over.
advance_mine :: proc(mine: ^Mine, world: ^World, tool: Item, holding, hit: bool, x, y, z: int, dt: f32) {
	block := Block.Air
	if hit {
		block = get_block(world, x, y, z)
	}
	if !holding || !hit || !breakable(block) {
		mine^ = {}
		return
	}
	// item_same reports two empty hands as different, which restarted the timer
	// every frame and kept a bare hand from ever finishing a block.
	same := item_same(mine.tool, tool) || (item_empty(mine.tool) && item_empty(tool))
	if !mine.on || mine.x != x || mine.y != y || mine.z != z || !same {
		mine^ = {on = true, x = x, y = y, z = z, tool = tool}
	}
	mine.time += dt
	mine.swing += dt / MINE_SWING
	for mine.swing >= 1 {
		mine.swing -= 1
	}
}
