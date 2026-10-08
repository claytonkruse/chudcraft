# Chudcraft

A voxel game in Odin, using the raylib vendor bindings.

```sh
odin run .                      # play it
odin build . -out:chudcraft.exe # build it
odin check .                    # type check only, no link
```

## Layout

Everything is one `package main`, split by concern:

| File | Owns |
| --- | --- |
| `master.odin` | The window, the frame loop, input, and the HUD |
| `world.odin` | Block data: the `Block` enum, chunk storage, and the world-space API. No raylib |
| `gen.odin` | World generation. Writes only through `set_block`. No raylib |
| `mesh.odin` | Everything GPU: textures, materials, chunk meshes, face culling, draw passes |
| `player.odin` | Movement, collision, and the camera |
| `dpi_windows.odin`, `dpi_other.odin` | Per-platform DPI awareness, which must be claimed before the window exists |

`world.odin` and `gen.odin` deliberately do not import raylib. Keep it that way, so
generation stays testable without a window.

## Test and probe scripts

**Never add a test hook to `main` or the frame loop.** A forgotten hook makes
`odin run .` exit immediately or behave differently from a real session, and tracked
files are easy to leave half-reverted.

Instead, put the whole harness in its own temporary file using an `@(init)` procedure,
which Odin runs before `main`. Nothing in `master.odin` changes, so there is nothing to
revert; deleting the one file removes the harness completely.

An `@(init)` procedure has to be `contextless`, and `os.exit` makes `defer` statements
unreachable, so the body goes in a separate procedure:

```odin
package main

import "base:runtime"
import "core:fmt"
import "core:os"

@(init)
scratch_probe :: proc "contextless" () {
	// Needed because a contextless procedure has no allocator, and set_block allocates.
	context = runtime.default_context()
	scratch_body()
	// Last, because os.exit makes anything after it unreachable, defers included.
	os.exit(0)
}

scratch_body :: proc() {
	world: World
	defer world_destroy(&world)
	generate_world(&world, 1337)

	fmt.printfln("surface at origin = %d", surface_height(&world, 0, 0))
}
```

Build it to its own executable so `chudcraft.exe` is never the probe:
`odin build . -out:scratch.exe && ./scratch.exe`.

The same procedure can open a window and draw, so screenshot probes need no frame-loop
hook either. `renderer_init`, `draw_world`, and `camera_from_player` are all callable
directly:

```odin
rl.InitWindow(1280, 720, "scratch")
defer rl.CloseWindow()
renderer := renderer_init()
defer renderer_destroy(&renderer)

player := Player{position = {-50, 66, -31}, yaw = 3.93, pitch = -0.45}
// Several frames, so the capture is never of the frame that built the meshes.
for _ in 0 ..< 3 {
	rl.BeginDrawing()
	rl.ClearBackground(rl.SKYBLUE)
	rl.BeginMode3D(camera_from_player(player))
	draw_world(&renderer, &world, camera_from_player(player), {0, 0, 0}, nil)
	rl.EndMode3D()
	rl.EndDrawing()
}
rl.TakeScreenshot("scratch.png")
```

Prefer `rl.TakeScreenshot` over any desktop capture tool, which on Windows is
DPI-virtualized and may capture the wrong window.

Delete the probe file, its executable, and any `.png` or `.log` it produced before
finishing. `git status --short` should show only intended changes.

## Conventions that bite

- **A block's position is the center of its bottom face.** X and Z span `i-0.5` to
  `i+0.5`; Y spans `i` to `i+1`. The player uses the same reference point, so
  collision, spawn, and the HUD all agree. The mesher folds the half-block X/Z shift
  into each chunk's `DrawMesh` transform.
- **Split world coordinates with `>>` and `&`, never `/` and `%`.** Odin truncates
  toward zero, which would fold the chunks just below the origin onto the ones above it.
  `chunk_of` and `local_of` exist for this.
- **Chunks are `^Chunk`, not inline values.** The mesher holds onto them across frames,
  and growing the map would move inline values.
- **Mesh arrays must come from `rl.MemAllocator()`,** because `UnloadMesh` frees them
  itself. That is what `clone_for_raylib` is for.
- **`u16` mesh indices fit a 32-chunk's opaque shell.** A leafy chunk does not cull
  faces against other leaves, so that mesh is split before the index count passes
  65535.
- **`UnloadMaterial` also unloads the material's texture and any non-default shader.**
  Do not unload those separately. `renderer_destroy` hands the default shader back
  before unloading, so the shared cutout shader is freed exactly once.
- **Odin needs `#partial switch`** on an enum whose cases are not all listed, even when
  there is a default.
- **Platform-specific code needs a file suffix or a `#+build` tag;** `import` cannot go
  inside a `when`. Do not import `core:sys/windows` here, since it links `user32.lib`
  whose `CloseWindow` collides with raylib's.
