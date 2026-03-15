![Bitcast Renderer](logo.gif)

This guide explains how to use the Bitcast Renderer to render exported bitmap video inside your own Project Zomboid mod.

The renderer reconstructs video frames entirely in Lua and draws them using `drawRect()` calls inside the UI system. This allows video playback in environments where the engine does not support native video decoding.

---

## Renderer File

To use the renderer in your mod, include:

```
media/lua/client/BitcastRenderer.lua
```

This file contains the full bitmap video decoding and rendering implementation. It is the software needed to load the exported files from Bitcast Converter.

---

## Video Data Format

The renderer expects a Lua module that returns a table with the following fields.

### Metadata

```lua
meta = {
    w = 160,
    h = 90,
    fps = 10,
    frame_count = 600
}
```

| Field | Description |
|-------|-------------|
| `w` | encoded video width |
| `h` | encoded video height |
| `fps` | playback frame rate |
| `frame_count` | total frame count |

### Palette

Frames use indexed colors instead of full RGB pixels.

```lua
palette = {
    {0,0,0},
    {255,255,255},
    {255,0,0},
    {0,255,0}
}
```

Each palette index references an RGB color.

### Scanline Dictionary

The dictionary stores run-length encoded scanlines.

```lua
S = {
    "encoded_scanline_1",
    "encoded_scanline_2",
    "encoded_scanline_3"
}
```

Each scanline entry describes one horizontal row of pixels. Frames reference dictionary IDs rather than storing full pixel data.

### Frames

Frames are stored in table `F`.

```lua
F = {
    {12,8,8,19,5},
    false,
    { d = {3,12, 7,5} }
}
```

**Keyframe**
```lua
{12,8,8,19,5}
```
Every row references a scanline dictionary entry.

**Identical Frame**
```lua
false
```
The frame is identical to the previous frame.

**Delta Frame**
```lua
{ d = {3,12, 7,5} }
```
Only specific rows are updated. In this example:
- Row 3 → dictionary entry 12
- Row 7 → dictionary entry 5

All other rows remain unchanged.

---

## Loading Video Data

First require the renderer.

```lua
local BitcastRenderer = require("BitcastRenderer")
```

Then load your exported video module.

```lua
local videoData = require("MyMod/Videos/myvideo")
```

---

## Creating the Player

Create a player instance with the loaded video data.

```lua
local player = BitcastRenderer.new(videoData)

player.loop = true
```

---

## Updating the Player

The player must be updated every frame. Inside your UI panel update function:

```lua
player:update()
```

This advances the frame timing and performs decoding.

---

## Rendering the Frame

Inside your UI panel render function:

```lua
player:render(self, x, y, w, h, nil, 1.0, "contain")
```

| Parameter | Description |
|-----------|-------------|
| `self` | UI panel |
| `x, y` | viewport position |
| `w, h` | viewport size |
| `nil` | optional clip rect |
| `1.0` | alpha multiplier |
| `contain` / `cover` | scaling mode |

---

## Example UI Panel

```lua
MyVideoPanel = ISPanel:derive("MyVideoPanel")


-- Helper function that safely loads a Bitcast video
local function loadBitcastVideo(path)

    local ok, data = pcall(require, path .. "/seg_000")
    if ok then
        return data
    end

    ok, data = pcall(require, path)
    if ok then
        return data
    end

    error("Bitcast video could not be loaded: " .. tostring(path))
end


function MyVideoPanel:initialise()

    ISPanel.initialise(self)

    local BitcastRenderer = require("BitcastRenderer")

    -- Automatically loads the correct Bitcast video file
    local videoData = loadBitcastVideo("MyMod/Videos/myvideo")

    self.player = BitcastRenderer.new(videoData)
    self.player.loop = true

end


function MyVideoPanel:update()

    if self.player then
        self.player:update()
    end

end


function MyVideoPanel:render()

    if self.player then
        self.player:render(self, 0, 0, self.width, self.height, nil, 1.0, "contain")
    end

end


function MyVideoPanel:new(x, y, width, height)

    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self

    return o

end

--Force Trigger on Game Start
Events.OnGameStart.Add(function()

    local panel = MyVideoPanel:new(200, 200, 640, 360)

    panel:initialise()
    panel:instantiate()
    panel:addToUIManager()

end)
```

---

## Rendering Method

The renderer reconstructs frames through the following steps:

```
Frame → Row State → Scanline Decode → Rectangle Runs → drawRect()
```

Each scanline is expanded from run-length encoded pixel runs, and each run is rendered as a horizontal rectangle.

**Example:**

```
[10 pixels color 3]
[6 pixels color 1]
[4 pixels color 7]
```

Becomes:

```lua
drawRect(x, y, 10, 1, color3)
drawRect(x, y,  6, 1, color1)
drawRect(x, y,  4, 1, color7)
```

This avoids expensive per-pixel drawing.

---

## Scaling

Most videos are exported at low resolution such as `160×90` or `320×180`. The renderer scales the frame to the viewport size during rendering.

---

## Performance Notes

The renderer is optimized using:

- Indexed palette colors
- Scanline dictionary reuse
- Run-length encoding
- Delta frame updates
- Rectangle strip rendering

Performance is determined mostly by the number of rectangle strips generated per frame.

### Recommended Export Settings

| Resolution | FPS |
|------------|-----|
| 160×90 | 8–12 fps |
| 320×180 | 8–10 fps |

Higher frame rates or resolutions increase rendering load.

---

## Summary

The Bitcast Renderer provides a lightweight Lua-based video renderer for Project Zomboid that:

- Reconstructs frames from compressed bitmap data
- Uses palette indexing and scanline dictionaries
- Supports delta and keyframe encoding
- Renders frames using efficient rectangle strips

This allows real-time video playback entirely within the game's UI rendering system.
