package main

import "core:c"
import "core:math"
import "core:os"
import rl "vendor:raylib"

// One block is a meter. Sound covers that distance at the real speed, so a
// wall a few blocks away comes back as a slap and a ravine comes back as an echo.
SOUND_SPEED :: 343.0
// Past this, a path is dropped. Farther than a shout carries in these mountains.
SOUND_REACH :: 40.0
// Inverse square is measured against this distance, then clamped, so a footstep
// under the listener is loud and a shout across a field is still a shout.
SOUND_REF :: 5.0
// Air eats a little energy per block on top of the spread.
SOUND_AIR :: 0.02
// Indirect rays. The direct path is one visibility ray and does not come out of this budget.
SOUND_RAYS :: 10
SOUND_BOUNCES :: 2
// How many paths of one event are worth a voice. The quietest lose.
SOUND_KEEP :: 6

SAMPLE_RATE :: 44100
// Frames per device buffer. Two of these sit in the queue, which is the latency
// every sound shares before its own travel time is added.
MIX_FRAMES :: 512
SOUND_VOICES :: 24

// The window that is playing. One process, one device, one pair of ears.
ears: ^Sound_Engine

Clip :: enum {
	Step_Grass,
	Step_Dirt,
	Step_Sand,
	Step_Gravel,
	Step_Stone,
	Step_Wood,
	Step_Leaf,
	Step_Wet,
	Break_Grass,
	Break_Dirt,
	Break_Sand,
	Break_Gravel,
	Break_Stone,
	Break_Wood,
	Break_Leaf,
	Land,
	Land_Big,
	Jump,
	Splash,
	Click,
}

Voice :: struct {
	on:            bool,
	clip:          Clip,
	which:         int,
	pos:           f32,
	rate:          f32,
	left, right:   f32,
	// How fast the one-pole follows the sample. Small is muffled.
	tone:          f32,
	lp:            f32,
	delay:         int,
}

// Stride memory so a step, a landing, and a splash each fire once.
Step_Mem :: struct {
	phase:    f32,
	y, peak:  f32,
	grounded: bool,
	wet:      bool,
	has:      bool,
}

Sound_Engine :: struct {
	ready:  bool,
	stream: rl.AudioStream,
	// Each clip is a handful of recordings. A play picks one, so a step is not the same hit twice.
	clips:  [Clip][dynamic][]f32,
	voices: [SOUND_VOICES]Voice,
	mix:    [MIX_FRAMES * 2]f32,
	pcm:    [MIX_FRAMES * 2]i16,
	ear:    [3]f32,
	yaw:    f32,
	rng:    u64,
	steps:  map[u32]Step_Mem,
}

Arrival :: struct {
	delay:  f32,
	volume: f32,
	pan:    f32,
	dull:   f32,
	rate:   f32,
	clip:   Clip,
}

// What a solid does with a ray that hits it. reflect is the energy kept.
// mirror is the chance the bounce is a reflection instead of a scatter.
Sound_Surface :: struct {
	reflect: f32,
	mirror:  f32,
}

Walk :: struct {
	hit:       bool,
	traveled:  f32,
	transmit:  f32,
	point:     [3]f32,
	normal:    [3]f32,
	block:     Block,
}

sound_init :: proc() -> Sound_Engine {
	engine: Sound_Engine
	engine.rng = 1
	engine.steps = make(map[u32]Step_Mem)
	// The size is read when the stream is created, so it has to be set first.
	rl.SetAudioStreamBufferSizeDefault(MIX_FRAMES)
	rl.InitAudioDevice()
	if !rl.IsAudioDeviceReady() {
		return engine
	}
	engine.stream = rl.LoadAudioStream(SAMPLE_RATE, 16, 2)
	if !rl.IsAudioStreamValid(engine.stream) {
		rl.CloseAudioDevice()
		return engine
	}
	// Recordings live under assets/sounds. A missing file falls back to a tone,
	// so the game still runs before those stand-ins have been copied in.
	for clip in Clip {
		load_clip(&engine, clip)
		if len(engine.clips[clip]) == 0 {
			append(&engine.clips[clip], synthesize(clip))
		}
	}
	rl.SetMasterVolume(1)
	rl.SetAudioStreamVolume(engine.stream, 1)
	rl.PlayAudioStream(engine.stream)
	engine.ready = true
	for _ in 0 ..< 4 {
		sound_mix(&engine)
	}
	return engine
}

sound_destroy :: proc(engine: ^Sound_Engine) {
	if engine == nil {
		return
	}
	for clip in Clip {
		for samples in engine.clips[clip] {
			delete(samples)
		}
		delete(engine.clips[clip])
	}
	delete(engine.steps)
	if !engine.ready {
		return
	}
	rl.StopAudioStream(engine.stream)
	rl.UnloadAudioStream(engine.stream)
	rl.CloseAudioDevice()
	engine.ready = false
}

// Ears sit just under the eyes. The camera in third person is not where you hear from.
sound_listen :: proc(player: Player) {
	if ears == nil {
		return
	}
	ears.ear = player.position + {0, PLAYER_EYE_HEIGHT - 0.12, 0}
	ears.yaw = player.yaw
}

// Menus are not a place in the world, so a click is not traced.
sound_ui :: proc() {
	if ears == nil {
		return
	}
	sound_voice(ears, .Click, 0, 0.4, 0, 0, 1)
}

sound_mix :: proc(engine: ^Sound_Engine) {
	if engine == nil || !engine.ready {
		return
	}
	// A hitch can owe the device more than one buffer.
	for _ in 0 ..< 6 {
		if !rl.IsAudioStreamProcessed(engine.stream) {
			break
		}
		sound_render(engine)
		rl.UpdateAudioStream(engine.stream, &engine.pcm[0], MIX_FRAMES)
	}
}

// A player edit, after the cell has taken its new shape. old is what it was.
sound_changed :: proc(world: ^World, x, y, z: int, old, block: Block, audible: bool) {
	if ears == nil || !ears.ready || !audible || old == block {
		return
	}
	origin := [3]f32{f32(x), f32(y) + 0.5, f32(z)}
	// Opening and closing stay on the door. A place is air becoming a door, and
	// that falls through to the wood recording below.
	if block_is_door(old) && block_is_door(block) {
		if door_is_open(old) == door_is_open(block) {
			return
		}
		rate: f32 = 0.85
		if door_is_open(block) {
			rate = 1.2
		}
		sound_emit(ears, world, origin, .Break_Wood, 0.4, rate)
		return
	}
	if block == .Air {
		if old == .Air || old == .Water {
			return
		}
		sound_emit(ears, world, origin, break_clip(old), 0.9, 1)
		return
	}
	if old != .Air && old != .Water {
		return
	}
	sound_emit(ears, world, origin, place_clip(block), 0.62, 1)
}

sound_strike :: proc(engine: ^Sound_Engine, world: ^World, x, y, z: int) {
	block := get_block(world, x, y, z)
	if block == .Air {
		return
	}
	origin := [3]f32{f32(x), f32(y) + 0.5, f32(z)}
	// The hit is the step recording, quieter. The break is a separate clip.
	sound_emit(engine, world, origin, step_clip(block), 0.34, 1)
}

// Footsteps, landings, jumps, and splashes for everyone this window can see.
sound_bodies :: proc(engine: ^Sound_Engine, world: ^World, self: Player, self_id: u32, others: []Remote_View, walks: map[u32]Walk_Cycle) {
	if engine == nil || !engine.ready {
		return
	}
	engine.ear = self.position + {0, PLAYER_EYE_HEIGHT - 0.12, 0}
	engine.yaw = self.yaw

	keep: [NET_MAX_PLAYERS]u32
	kn := 0
	keep[0] = self_id
	kn = 1
	_, wet, _, _ := body_in_water(world, self.position, f32(world.time))
	sound_stride(engine, world, self_id, self.position, self.grounded, self.velocity.y, wet, walks[self_id], true)

	for other in others {
		if kn < len(keep) {
			keep[kn] = other.id
			kn += 1
		}
		_, owet, _, _ := body_in_water(world, other.position, f32(world.time))
		planted := foot_planted(world, other.position)
		sound_stride(engine, world, other.id, other.position, planted, 0, owet, walks[other.id], false)
	}

	stale: [NET_MAX_PLAYERS]u32
	sn := 0
	for id, _ in engine.steps {
		found := false
		for i in 0 ..< kn {
			if keep[i] == id {
				found = true
				break
			}
		}
		if !found && sn < len(stale) {
			stale[sn] = id
			sn += 1
		}
	}
	for i in 0 ..< sn {
		delete_key(&engine.steps, stale[i])
	}
}

sound_stride :: proc(engine: ^Sound_Engine, world: ^World, id: u32, pos: [3]f32, grounded: bool, vy: f32, wet: bool, cycle: Walk_Cycle, local: bool) {
	mem := engine.steps[id]
	if !mem.has {
		engine.steps[id] = {phase = cycle.phase, y = pos.y, peak = pos.y, grounded = grounded, wet = wet, has = true}
		return
	}

	swimming := wet && !grounded
	landed := grounded && !mem.grounded
	left := mem.grounded && !grounded

	if left && !wet {
		jumped := false
		if local {
			jumped = vy > 4
		} else {
			jumped = pos.y > mem.y + 0.05
		}
		if jumped {
			sound_emit(engine, world, pos, .Jump, 0.22, 1)
		}
	}
	if landed && !wet {
		drop := mem.peak - pos.y
		if drop > 0.45 {
			loud := clamp(0.35+drop*0.45, 0.35, 1.1)
			clip: Clip = .Land
			if drop > 3.5 {
				clip = .Land_Big
			}
			sound_emit(engine, world, pos, clip, loud, 1)
		}
	}
	if wet && !mem.wet {
		loud: f32 = 0.5
		if mem.peak-pos.y > 0.4 {
			loud = 0.95
		}
		sound_emit(engine, world, pos, .Splash, loud, 1)
	}

	crossed := math.sin(mem.phase)*math.sin(cycle.phase) < 0
	if crossed && grounded && !swimming && !landed && cycle.amount > 0.28 && cycle.has {
		block := ground_block(world, pos)
		if wet {
			sound_emit(engine, world, pos, .Step_Wet, 0.4, 1)
		} else {
			sound_emit(engine, world, pos, step_clip(block), 0.48, 1)
		}
	}

	peak := mem.peak
	if grounded {
		peak = pos.y
	} else if pos.y > peak {
		peak = pos.y
	}
	engine.steps[id] = {phase = cycle.phase, y = pos.y, peak = peak, grounded = grounded, wet = wet, has = true}
}

foot_planted :: proc(world: ^World, pos: [3]f32) -> bool {
	x := block_index_horizontal(pos.x)
	z := block_index_horizontal(pos.z)
	y := block_index_vertical(pos.y - 0.08)
	if !block_solid(get_block(world, x, y, z)) {
		return false
	}
	top := f32(y + 1)
	return pos.y >= top-0.05 && pos.y <= top+0.25
}

ground_block :: proc(world: ^World, pos: [3]f32) -> Block {
	x := block_index_horizontal(pos.x)
	z := block_index_horizontal(pos.z)
	y := block_index_vertical(pos.y - 0.08)
	return get_block(world, x, y, z)
}

step_clip :: proc(block: Block) -> Clip {
	if block_is_door(block) {
		return .Step_Wood
	}
	#partial switch block {
	case .Grass:
		return .Step_Grass
	case .Dirt:
		return .Step_Dirt
	case .Sand:
		return .Step_Sand
	case .Gravel:
		return .Step_Gravel
	case .Oak_Log, .Oak_Planks, .Workbench:
		return .Step_Wood
	case .Oak_Leaves, .Oak_Sapling:
		return .Step_Leaf
	case .Water:
		return .Splash
	}
	return .Step_Stone
}

break_clip :: proc(block: Block) -> Clip {
	if block_is_door(block) {
		return .Break_Wood
	}
	#partial switch block {
	case .Grass:
		return .Break_Grass
	case .Dirt:
		return .Break_Dirt
	case .Sand:
		return .Break_Sand
	case .Gravel:
		return .Break_Gravel
	case .Oak_Log, .Oak_Planks, .Workbench:
		return .Break_Wood
	case .Oak_Leaves, .Oak_Sapling:
		return .Break_Leaf
	}
	return .Break_Stone
}

// Placing uses the same recording as breaking that block. The call is quieter.
place_clip :: proc(block: Block) -> Clip {
	return break_clip(block)
}

// Trace every path from source to the ear and schedule the ones that arrive.
sound_emit :: proc(engine: ^Sound_Engine, world: ^World, source: [3]f32, clip: Clip, loudness, rate: f32) {
	if engine == nil || !engine.ready || loudness <= 0 {
		return
	}
	ear := engine.ear
	delta := ear - source
	dist := vec_len(delta)
	if dist > SOUND_REACH {
		return
	}

	arrivals: [SOUND_KEEP]Arrival
	n := 0
	push :: proc(arrivals: ^[SOUND_KEEP]Arrival, n: ^int, arrival: Arrival) {
		if arrival.volume < 0.02 {
			return
		}
		if n^ < SOUND_KEEP {
			arrivals[n^] = arrival
			n^ += 1
			return
		}
		quiet := 0
		for i in 1 ..< SOUND_KEEP {
			if arrivals[i].volume < arrivals[quiet].volume {
				quiet = i
			}
		}
		if arrival.volume > arrivals[quiet].volume {
			arrivals[quiet] = arrival
		}
	}

	if dist < 0.35 {
		push(&arrivals, &n, Arrival{volume = loudness, rate = rate, clip = clip})
	} else if ok, transmit := path_clear(world, source, ear); ok {
		path := max(dist, 0.35)
		push(&arrivals, &n, Arrival{
			delay = path / SOUND_SPEED,
			volume = loudness * transmit * spread(path),
			pan = pan_of(engine.yaw, ear, source),
			dull = dull_of(transmit, path),
			rate = rate,
			clip = clip,
		})
	}

	// The head is a small target. A ray left to find it on its own would miss,
	// and a footstep would flicker. Each bounce still walks the world. From the
	// hit, a second ray asks whether the ear can see that point.
	share := 1 / f32(SOUND_RAYS)
	for _ in 0 ..< SOUND_RAYS {
		dir := unit_sphere(&engine.rng)
		energy := share
		pos := source
		traveled: f32
		through: f32 = 1
		for _ in 0 ..< SOUND_BOUNCES {
			room := SOUND_REACH - traveled
			if room < 0.5 || energy < 0.025 {
				break
			}
			walk := acoustic_walk(world, pos, dir, room, true, &engine.rng)
			if !walk.hit {
				break
			}
			surf := surface_of(walk.block)
			point := walk.point + walk.normal*0.04
			// The ground under a footstep is the direct path again. Skip it.
			if vec_len(walk.point-source) >= 0.85 {
				if ok, transmit := path_clear(world, point, ear); ok {
					leg := vec_len(ear - point)
					path := traveled + walk.traveled + leg
					kept := energy * surf.reflect * through * walk.transmit * transmit
					push(&arrivals, &n, Arrival{
						delay = path / SOUND_SPEED,
						volume = loudness * kept * spread(path),
						pan = pan_of(engine.yaw, ear, point),
						dull = dull_of(transmit*walk.transmit, path),
						rate = rate,
						clip = clip,
					})
				}
			}
			energy *= surf.reflect
			through *= walk.transmit
			mirror := dir - walk.normal*(2*dotf(dir, walk.normal))
			if drop_range(&engine.rng, 0, 1) < surf.mirror {
				dir = normf(mirror)
			} else {
				dir = hemisphere(&engine.rng, walk.normal)
			}
			pos = point
			traveled += walk.traveled
		}
	}

	// Two copies a few milliseconds apart comb-filter. Fold them into one.
	for i in 0 ..< n {
		if arrivals[i].volume <= 0 {
			continue
		}
		for j in i + 1 ..< n {
			if arrivals[j].volume <= 0 {
				continue
			}
			if abs(arrivals[i].delay-arrivals[j].delay) > 0.012 {
				continue
			}
			a := arrivals[i].volume
			b := arrivals[j].volume
			arrivals[i].volume = math.sqrt(a*a + b*b)
			arrivals[i].pan = (arrivals[i].pan + arrivals[j].pan) * 0.5
			arrivals[j].volume = 0
		}
	}

	// One pitch for every path of this event, so the echo is the same hit heard late.
	jitter := 0.94 + drop_range(&engine.rng, 0, 0.12)
	for i in 0 ..< n {
		arrival := arrivals[i]
		if arrival.volume <= 0 {
			continue
		}
		sound_voice(engine, arrival.clip, arrival.delay, arrival.volume, arrival.pan, arrival.dull, arrival.rate*jitter)
	}
}

sound_voice :: proc(engine: ^Sound_Engine, clip: Clip, delay, volume, pan, dull, rate: f32) {
	if volume <= 0 || rate <= 0 {
		return
	}
	slot := -1
	quiet := f32(1e9)
	quiet_at := 0
	for i in 0 ..< SOUND_VOICES {
		voice := &engine.voices[i]
		if !voice.on {
			slot = i
			break
		}
		amp := voice.left*voice.left + voice.right*voice.right
		if amp < quiet {
			quiet = amp
			quiet_at = i
		}
	}
	if slot < 0 {
		slot = quiet_at
	}
	bank := engine.clips[clip]
	if len(bank) == 0 {
		return
	}
	which := 0
	if len(bank) > 1 {
		which = int(drop_range(&engine.rng, 0, f32(len(bank))))
		if which >= len(bank) {
			which = len(bank) - 1
		}
	}
	// Equal power. Center is both channels, not a hole between them.
	theta := (clamp(pan, -1, 1) + 1) * 0.25 * math.PI
	tone := 0.16 + (1-clamp(dull, 0, 1))*0.8
	engine.voices[slot] = {
		on    = true,
		clip  = clip,
		which = which,
		rate  = rate,
		left  = volume * math.cos(theta),
		right = volume * math.sin(theta),
		tone  = tone,
		delay = int(max(delay, 0) * SAMPLE_RATE),
	}
}

sound_render :: proc(engine: ^Sound_Engine) {
	for i in 0 ..< MIX_FRAMES*2 {
		engine.mix[i] = 0
	}
	for &voice in engine.voices {
		if !voice.on {
			continue
		}
		bank := engine.clips[voice.clip]
		if voice.which < 0 || voice.which >= len(bank) {
			voice.on = false
			continue
		}
		clip := bank[voice.which]
		last := len(clip) - 1
		if last < 1 {
			voice.on = false
			continue
		}
		for i in 0 ..< MIX_FRAMES {
			if voice.delay > 0 {
				voice.delay -= 1
				continue
			}
			idx := int(voice.pos)
			if idx >= last {
				voice.on = false
				break
			}
			frac := voice.pos - f32(idx)
			sample := clip[idx]*(1-frac) + clip[idx+1]*frac
			voice.lp += voice.tone * (sample - voice.lp)
			engine.mix[i*2] += voice.lp * voice.left
			engine.mix[i*2+1] += voice.lp * voice.right
			voice.pos += voice.rate
		}
	}
	for i in 0 ..< MIX_FRAMES*2 {
		sample := clamp(engine.mix[i], -1, 1)
		engine.pcm[i] = i16(sample * 32767)
	}
}

// Direct visibility. A solid stops the ray. Leaves and water only thin it.
// The solid a sound starts inside is the block that made the sound, so the
// ray is allowed to leave that cell.
path_clear :: proc(world: ^World, from, to: [3]f32) -> (ok: bool, transmit: f32) {
	delta := to - from
	dist := vec_len(delta)
	if dist < 0.3 {
		return true, 1
	}
	walk := acoustic_walk(world, from, delta, dist-0.12, false, nil)
	if walk.hit {
		return false, 0
	}
	return true, walk.transmit
}

// One bounce along dir, and how loud that reflection is at the ear.
// The event tracer shoots many of these and keeps the ones that arrive.
path_bounce :: proc(world: ^World, source, ear, dir: [3]f32) -> f32 {
	walk := acoustic_walk(world, source, dir, SOUND_REACH, true, nil)
	if !walk.hit {
		return 0
	}
	point := walk.point + walk.normal*0.04
	ok, transmit := path_clear(world, point, ear)
	if !ok {
		return 0
	}
	path := walk.traveled + vec_len(ear-point)
	return surface_of(walk.block).reflect * walk.transmit * transmit * spread(path)
}

// Grid walk. X and Z are shifted by half a block, the same frame the break ray uses,
// so a cell is a block. bounce lets a water surface throw the ray back.
acoustic_walk :: proc(world: ^World, origin, dir: [3]f32, max_dist: f32, bounce: bool, rng: ^u64) -> Walk {
	result := Walk{transmit = 1, normal = {0, 1, 0}}
	length := vec_len(dir)
	if length < 1e-6 || max_dist <= 0 {
		return result
	}
	direction := dir / length
	pos := [3]f32{origin.x + 0.5, origin.y, origin.z + 0.5}
	cell := [3]int{int(math.floor(pos.x)), int(math.floor(pos.y)), int(math.floor(pos.z))}
	// Leaves stop a body and still let a ray through, thinned. A hedge is not a wall.
	start_solid := sound_blocks(get_block(world, cell.x, cell.y, cell.z))

	step, t_max, t_delta: [3]f32
	for axis in 0 ..< 3 {
		if direction[axis] > 0 {
			step[axis] = 1
			t_delta[axis] = 1 / direction[axis]
			t_max[axis] = (f32(int(math.floor(pos[axis]))+1) - pos[axis]) * t_delta[axis]
		} else if direction[axis] < 0 {
			step[axis] = -1
			t_delta[axis] = 1 / -direction[axis]
			t_max[axis] = (pos[axis] - f32(int(math.floor(pos[axis])))) * t_delta[axis]
		} else {
			step[axis] = 0
			t_delta[axis] = 1e30
			t_max[axis] = 1e30
		}
	}

	traveled: f32
	entered_axis := 0
	entered_sign: f32
	prev := get_block(world, cell.x, cell.y, cell.z)
	for i in 0 ..< 96 {
		if traveled > max_dist {
			break
		}
		if !(i == 0 && start_solid) {
			block := get_block(world, cell.x, cell.y, cell.z)
			if sound_blocks(block) {
				result.hit = true
				result.traveled = traveled
				result.point = origin + direction*traveled
				result.normal = face_normal(entered_axis, entered_sign, direction)
				result.block = block
				return result
			}
			if bounce && block == .Water && prev != .Water && rng != nil && drop_range(rng, 0, 1) < 0.6 {
				result.hit = true
				result.traveled = traveled
				result.point = origin + direction*traveled
				result.normal = face_normal(entered_axis, entered_sign, direction)
				result.block = .Water
				return result
			}
			if block == .Oak_Leaves {
				result.transmit *= 0.68
			} else if block == .Water {
				result.transmit *= 0.84
			}
			if result.transmit < 0.05 {
				break
			}
			prev = block
		}

		axis := 0
		if t_max.y < t_max.x {
			axis = 1
		}
		if t_max.z < t_max[axis] {
			axis = 2
		}
		if step[axis] == 0 {
			break
		}
		// The ear sits on this segment. Entering another cell would be past it.
		if t_max[axis] >= max_dist {
			result.traveled = max_dist
			return result
		}
		entered_axis = axis
		entered_sign = -step[axis]
		cell[axis] += int(step[axis])
		traveled = t_max[axis]
		t_max[axis] += t_delta[axis]
	}
	result.traveled = traveled
	return result
}

// Solids stop a ray. Leaves do not: they only soak up energy on the way through.
sound_blocks :: proc(block: Block) -> bool {
	// A shut door is a wall. An open one leaves the gap, and the ray uses the cell.
	if block_is_door(block) {
		return !door_is_open(block)
	}
	return block_solid(block) && block != .Oak_Leaves
}

face_normal :: proc(axis: int, sign: f32, direction: [3]f32) -> [3]f32 {
	if sign == 0 {
		return -direction
	}
	normal: [3]f32
	normal[axis] = sign
	return normal
}

surface_of :: proc(block: Block) -> Sound_Surface {
	if block_is_door(block) {
		return {0.46, 0.22}
	}
	#partial switch block {
	case .Grass:
		return {0.2, 0.04}
	case .Dirt:
		return {0.28, 0.08}
	case .Oak_Log, .Oak_Planks, .Workbench:
		return {0.46, 0.22}
	case .Oak_Leaves:
		return {0.12, 0}
	case .Water:
		return {0.62, 0.9}
	}
	return {0.74, 0.5}
}

spread :: proc(distance: f32) -> f32 {
	d := max(distance, 0.35)
	s := SOUND_REF / d
	return min(s*s, 1.35) * f32(math.exp(f64(-SOUND_AIR*d)))
}

dull_of :: proc(transmit, distance: f32) -> f32 {
	return clamp((1-transmit)*0.9+distance*0.012, 0, 1)
}

pan_of :: proc(yaw: f32, ear, from: [3]f32) -> f32 {
	horiz := [3]f32{from.x - ear.x, 0, from.z - ear.z}
	h := vec_len(horiz)
	if h < 0.001 {
		return 0
	}
	right := [3]f32{math.cos(yaw), 0, -math.sin(yaw)}
	return clamp(dotf(horiz/h, right)*0.9, -1, 1)
}

unit_sphere :: proc(rng: ^u64) -> [3]f32 {
	z := drop_range(rng, -1, 1)
	angle := drop_range(rng, 0, math.TAU)
	ring := math.sqrt(max(0, 1-z*z))
	return {ring * math.cos(angle), z, ring * math.sin(angle)}
}

hemisphere :: proc(rng: ^u64, normal: [3]f32) -> [3]f32 {
	dir := unit_sphere(rng)
	if dotf(dir, normal) < 0 {
		dir = -dir
	}
	return dir
}

vec_len :: proc(v: [3]f32) -> f32 {
	return math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
}

dotf :: proc(a, b: [3]f32) -> f32 {
	return a.x*b.x + a.y*b.y + a.z*b.z
}

normf :: proc(v: [3]f32) -> [3]f32 {
	length := vec_len(v)
	if length < 1e-6 {
		return {0, 1, 0}
	}
	return v / length
}

// Development stand-ins from a local Minecraft install. Not part of the game
// that ships. Replace the directory before distributing.
load_clip :: proc(engine: ^Sound_Engine, clip: Clip) {
	for path in clip_paths(clip) {
		samples := decode_ogg(path)
		if len(samples) < 2 {
			delete(samples)
			continue
		}
		append(&engine.clips[clip], samples)
	}
}

clip_paths :: proc(clip: Clip) -> []string {
	#partial switch clip {
	case .Step_Grass:
		return STEP_GRASS[:]
	case .Step_Dirt:
		return STEP_DIRT[:]
	case .Step_Sand:
		return STEP_SAND[:]
	case .Step_Gravel:
		return STEP_GRAVEL[:]
	case .Step_Stone:
		return STEP_STONE[:]
	case .Step_Wood:
		return STEP_WOOD[:]
	case .Step_Leaf:
		return STEP_LEAF[:]
	case .Step_Wet:
		return STEP_WET[:]
	case .Break_Grass:
		return BREAK_GRASS[:]
	case .Break_Dirt:
		return BREAK_DIRT[:]
	case .Break_Sand:
		return BREAK_SAND[:]
	case .Break_Gravel:
		return BREAK_GRAVEL[:]
	case .Break_Stone:
		return BREAK_STONE[:]
	case .Break_Wood:
		return BREAK_WOOD[:]
	case .Break_Leaf:
		return BREAK_LEAF[:]
	case .Land:
		return LAND[:]
	case .Land_Big:
		return LAND_BIG[:]
	case .Splash:
		return SPLASH[:]
	case .Click:
		return CLICK[:]
	}
	return nil
}

@(rodata)
STEP_GRASS := [?]string{"assets/sounds/step/grass1.ogg", "assets/sounds/step/grass2.ogg", "assets/sounds/step/grass3.ogg", "assets/sounds/step/grass4.ogg", "assets/sounds/step/grass5.ogg", "assets/sounds/step/grass6.ogg"}
@(rodata)
STEP_DIRT := [?]string{"assets/sounds/block/rooted_dirt/step1.ogg", "assets/sounds/block/rooted_dirt/step2.ogg", "assets/sounds/block/rooted_dirt/step3.ogg", "assets/sounds/block/rooted_dirt/step4.ogg", "assets/sounds/block/rooted_dirt/step5.ogg", "assets/sounds/block/rooted_dirt/step6.ogg"}
@(rodata)
STEP_SAND := [?]string{"assets/sounds/step/sand1.ogg", "assets/sounds/step/sand2.ogg", "assets/sounds/step/sand3.ogg", "assets/sounds/step/sand4.ogg", "assets/sounds/step/sand5.ogg"}
@(rodata)
STEP_GRAVEL := [?]string{"assets/sounds/step/gravel1.ogg", "assets/sounds/step/gravel2.ogg", "assets/sounds/step/gravel3.ogg", "assets/sounds/step/gravel4.ogg"}
@(rodata)
STEP_STONE := [?]string{"assets/sounds/step/stone1.ogg", "assets/sounds/step/stone2.ogg", "assets/sounds/step/stone3.ogg", "assets/sounds/step/stone4.ogg", "assets/sounds/step/stone5.ogg", "assets/sounds/step/stone6.ogg"}
@(rodata)
STEP_WOOD := [?]string{"assets/sounds/step/wood1.ogg", "assets/sounds/step/wood2.ogg", "assets/sounds/step/wood3.ogg", "assets/sounds/step/wood4.ogg", "assets/sounds/step/wood5.ogg", "assets/sounds/step/wood6.ogg"}
@(rodata)
STEP_LEAF := [?]string{"assets/sounds/block/azalea_leaves/step1.ogg", "assets/sounds/block/azalea_leaves/step2.ogg", "assets/sounds/block/azalea_leaves/step3.ogg", "assets/sounds/block/azalea_leaves/step4.ogg", "assets/sounds/block/azalea_leaves/step5.ogg"}
@(rodata)
STEP_WET := [?]string{"assets/sounds/step/wet_grass1.ogg", "assets/sounds/step/wet_grass2.ogg", "assets/sounds/step/wet_grass3.ogg", "assets/sounds/step/wet_grass4.ogg", "assets/sounds/step/wet_grass5.ogg", "assets/sounds/step/wet_grass6.ogg"}
@(rodata)
BREAK_GRASS := [?]string{"assets/sounds/dig/grass1.ogg", "assets/sounds/dig/grass2.ogg", "assets/sounds/dig/grass3.ogg", "assets/sounds/dig/grass4.ogg"}
@(rodata)
BREAK_DIRT := [?]string{"assets/sounds/block/rooted_dirt/break1.ogg", "assets/sounds/block/rooted_dirt/break2.ogg", "assets/sounds/block/rooted_dirt/break3.ogg", "assets/sounds/block/rooted_dirt/break4.ogg"}
@(rodata)
BREAK_SAND := [?]string{"assets/sounds/dig/sand1.ogg", "assets/sounds/dig/sand2.ogg", "assets/sounds/dig/sand3.ogg", "assets/sounds/dig/sand4.ogg"}
@(rodata)
BREAK_GRAVEL := [?]string{"assets/sounds/dig/gravel1.ogg", "assets/sounds/dig/gravel2.ogg", "assets/sounds/dig/gravel3.ogg", "assets/sounds/dig/gravel4.ogg"}
@(rodata)
BREAK_STONE := [?]string{"assets/sounds/dig/stone1.ogg", "assets/sounds/dig/stone2.ogg", "assets/sounds/dig/stone3.ogg", "assets/sounds/dig/stone4.ogg"}
@(rodata)
BREAK_WOOD := [?]string{"assets/sounds/dig/wood1.ogg", "assets/sounds/dig/wood2.ogg", "assets/sounds/dig/wood3.ogg", "assets/sounds/dig/wood4.ogg"}
@(rodata)
BREAK_LEAF := [?]string{"assets/sounds/block/azalea_leaves/break1.ogg", "assets/sounds/block/azalea_leaves/break2.ogg", "assets/sounds/block/azalea_leaves/break3.ogg", "assets/sounds/block/azalea_leaves/break4.ogg", "assets/sounds/block/azalea_leaves/break5.ogg", "assets/sounds/block/azalea_leaves/break6.ogg", "assets/sounds/block/azalea_leaves/break7.ogg"}
@(rodata)
LAND := [?]string{"assets/sounds/damage/fallsmall.ogg"}
@(rodata)
LAND_BIG := [?]string{"assets/sounds/damage/fallbig.ogg"}
@(rodata)
SPLASH := [?]string{"assets/sounds/liquid/splash.ogg", "assets/sounds/liquid/splash2.ogg"}
@(rodata)
CLICK := [?]string{"assets/sounds/random/click.ogg"}

decode_ogg :: proc(path: string) -> []f32 {
	bytes, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return nil
	}
	defer delete(bytes)
	wave := rl.LoadWaveFromMemory(".ogg", raw_data(bytes), c.int(len(bytes)))
	if !rl.IsWaveValid(wave) {
		return nil
	}
	defer rl.UnloadWave(wave)
	raw := rl.LoadWaveSamples(wave)
	if raw == nil {
		return nil
	}
	defer rl.UnloadWaveSamples(raw)

	frames := int(wave.frameCount)
	channels := int(wave.channels)
	rate := int(wave.sampleRate)
	if frames < 2 || channels < 1 || rate < 1 {
		return nil
	}
	out_n := max(int(f64(frames)*f64(SAMPLE_RATE)/f64(rate)), 2)
	out := make([]f32, out_n)
	for i in 0 ..< out_n {
		src := f32(i) * f32(rate) / f32(SAMPLE_RATE)
		i0 := int(src)
		if i0 >= frames-1 {
			out[i] = frame_mono(raw, frames-1, channels)
			continue
		}
		frac := src - f32(i0)
		a := frame_mono(raw, i0, channels)
		b := frame_mono(raw, i0+1, channels)
		out[i] = a*(1-frac) + b*frac
	}
	return out
}

frame_mono :: proc(raw: [^]f32, frame, channels: int) -> f32 {
	sum: f32
	for c in 0 ..< channels {
		sum += raw[frame*channels+c]
	}
	return sum / f32(channels)
}

Tone :: struct {
	seconds:  f32,
	noise:    f32,
	tone_hz:  f32,
	tone:     f32,
	click_hz: f32,
	click:    f32,
	decay:    f32,
	// 0 is a thud. 1 lets the noise stay bright.
	bright:   f32,
	salt:     u32,
}

recipe_of :: proc(clip: Clip) -> Tone {
	#partial switch clip {
	case .Step_Grass:
		return {0.09, 0.9, 0, 0, 0, 0, 26, 0.18, 1}
	case .Step_Dirt:
		return {0.08, 0.55, 95, 0.45, 0, 0, 30, 0.16, 2}
	case .Step_Stone:
		return {0.055, 0.35, 0, 0, 1680, 0.75, 48, 0.55, 3}
	case .Step_Wood:
		return {0.1, 0.22, 190, 0.7, 380, 0.2, 22, 0.3, 4}
	case .Step_Leaf:
		return {0.11, 1, 0, 0, 2400, 0.08, 18, 0.75, 5}
	case .Break_Grass, .Break_Dirt, .Break_Sand, .Break_Leaf:
		return {0.16, 0.9, 120, 0.25, 0, 0, 12, 0.22, 6}
	case .Break_Stone, .Break_Gravel:
		return {0.18, 0.55, 0, 0, 860, 0.6, 11, 0.4, 7}
	case .Break_Wood:
		return {0.14, 0.35, 150, 0.55, 420, 0.35, 14, 0.28, 8}
	case .Land, .Land_Big:
		return {0.14, 0.4, 72, 0.9, 0, 0, 14, 0.14, 10}
	case .Jump:
		return {0.045, 0.35, 0, 0, 0, 0, 42, 0.7, 11}
	case .Splash:
		return {0.2, 1, 0, 0, 0, 0, 10, 0.32, 12}
	}
	return {0.025, 0.1, 880, 0.55, 1760, 0.2, 70, 0.8, 14}
}

synthesize :: proc(clip: Clip) -> []f32 {
	recipe := recipe_of(clip)
	count := max(int(recipe.seconds*SAMPLE_RATE), 8)
	samples := make([]f32, count)
	low: f32
	peak: f32
	for i in 0 ..< count {
		t := f32(i) / SAMPLE_RATE
		env := f32(math.exp(f64(-t * recipe.decay)))
		if t < 0.003 {
			env *= t / 0.003
		}
		white := hash_noise(i, recipe.salt)
		// bright is the cutoff. A grass step stays in the lowpass; a tick does not.
		coef := clamp(0.04+recipe.bright*0.9, 0.04, 0.98)
		low += coef * (white - low)
		sample := low*recipe.noise + math.sin(math.TAU*recipe.tone_hz*t)*recipe.tone
		if recipe.click > 0 {
			sample += math.sin(math.TAU*recipe.click_hz*t) * recipe.click * f32(math.exp(f64(-t*recipe.decay*4)))
		}
		sample *= env
		samples[i] = sample
		peak = max(peak, abs(sample))
	}
	if peak > 1e-4 {
		scale := 0.9 / peak
		for &sample in samples {
			sample *= scale
		}
	}
	return samples
}

hash_noise :: proc(i: int, salt: u32) -> f32 {
	n := u32(i) + salt*1013
	n ~= n << 13
	n ~= n >> 17
	n ~= n << 5
	return f32(n)/4294967295 * 2 - 1
}
