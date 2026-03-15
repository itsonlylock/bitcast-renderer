-- Simple Bitcast video panel example
-- This shows how to play a Bitcast video inside a UI panel in Project Zomboid.

MyVideoPanel = ISPanel:derive("MyVideoPanel")


-- Bitcast exports may have different layouts:
--
-- 1) Multipart segmented:
--    MyMod/Videos/myvideo/part1/seg_000.lua
--
-- 2) Segmented:
--    MyMod/Videos/myvideo/seg_000.lua
--
-- 3) Single file:
--    MyMod/Videos/myvideo.lua
--
-- This helper tries each format automatically.

local function loadBitcastVideo(path)

    -- Try multipart export
    local ok, data = pcall(require, path .. "/part1/seg_000")
    if ok and data then return data end

    -- Try segmented export
    ok, data = pcall(require, path .. "/seg_000")
    if ok and data then return data end

    -- Try single-file export
    ok, data = pcall(require, path)
    if ok and data then return data end

    error("Bitcast video could not be loaded: " .. tostring(path))
end


function MyVideoPanel:initialise()
    ISPanel.initialise(self)

    -- Load the Bitcast renderer
    local BitcastRenderer = require("BitcastRenderer")

    -- Load video data exported by Bitcast Converter
    local videoData = loadBitcastVideo("MyMod/Videos/myvideo")

    -- Create the video player
    self.player = BitcastRenderer.new(videoData)

    -- Enable looping playback
    self.player.loop = true
end


-- Update runs every game tick
-- The renderer advances the video frame here
function MyVideoPanel:update()
    if self.player then
        self.player:update()
    end
end


-- Render draws the current video frame to the panel
function MyVideoPanel:render()
    if self.player then
        self.player:render(
            self,                -- UI surface
            0,                   -- x
            0,                   -- y
            self.width,          -- width
            self.height,         -- height
            nil,                 -- scale (auto)
            1.0,                 -- alpha
            "contain"            -- scaling mode
        )
    end
end


-- Panel constructor
function MyVideoPanel:new(x, y, width, height)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    return o
end


-- Spawn the panel when the game starts
Events.OnGameStart.Add(function()

    local panel = MyVideoPanel:new(200, 150, 640, 360)

    panel:initialise()
    panel:instantiate()
    panel:addToUIManager()

end)