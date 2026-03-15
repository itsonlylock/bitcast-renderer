-- File: media/lua/client/TVVHS/FX/BitmapVideoPlayer.lua
-- Plays Lua-exported indexed+RLE bitmap videos inside the TV/VHS viewport.
--
-- Supported export format:
--
-- 1.) Bitcast compact format (scanline dictionary + frame refs):
--   data.meta = { w=?, h=?, fps=?, frame_count=?, palette_size=? }
--   data.palette = { {r,g,b}, ... } -- 0-255 ints, 1-indexed palette
--   data.S = { "<base64 rle bytes>", ... } OR data.S = { {byte,byte,...}, ... } OR data.S = { {count,idx,count,idx,...}, ... }
--   data.F = { frame1, frame2, ... } where each frame is one of:
--       false                  => identical to previous frame
--       { d = {row,id,...} }   => delta frame; only listed rows are updated
--       { id,id,id,... }       => full keyframe; one dictionary ID per row
--   RLE bytes decode to pairs: (count, paletteIndex), paletteIndex 0 = transparent.

local Player = {}
Player.__index = Player

local function nowMs()
    if _G.getTimestampMs then return _G.getTimestampMs() end
    return math.floor(os.clock() * 1000)
end

local function clamp(n, a, b)
    n = tonumber(n)
    if n == nil then return a end
    if n < a then return a end
    if n > b then return b end
    return n
end

local function normalizePalette(pal)
    local out = {}
    if type(pal) ~= "table" then return out end
    for i = 1, #pal do
        local c = pal[i]
        if type(c) == "table" then
            local r = (tonumber(c[1]) or 0) / 255
            local g = (tonumber(c[2]) or 0) / 255
            local b = (tonumber(c[3]) or 0) / 255
            local a = (tonumber(c[4]) or 255) / 255
            out[i] = { r = r, g = g, b = b, a = a }
        end
    end
    return out
end

local function intersectRect(ax, ay, aw, ah, bx, by, bw, bh)
    local x1 = math.max(ax, bx)
    local y1 = math.max(ay, by)
    local x2 = math.min(ax + aw, bx + bw)
    local y2 = math.min(ay + ah, by + bh)
    local w = x2 - x1
    local h = y2 - y1
    if w <= 0 or h <= 0 then return nil end
    return x1, y1, w, h
end

-- Base64 decode to byte array (0..255).
-- Accepts standard base64 alphabet with optional '=' padding.
local _b64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local _b64Index = nil

local function ensureB64Index()
    if _b64Index then return end
    _b64Index = {}
    for i = 1, #_b64Alphabet do
        _b64Index[_b64Alphabet:byte(i)] = i - 1
    end
    _b64Index[string.byte("=")] = -1
end

local function b64DecodeToBytes(s)
    if type(s) ~= "string" or s == "" then return {} end
    ensureB64Index()

    local out = {}
    local len = #s
    local i = 1

    while i <= len do
        local a = s:byte(i); i = i + 1
        local b = s:byte(i); i = i + 1
        local c = s:byte(i); i = i + 1
        local d = s:byte(i); i = i + 1

        if not a or not b then break end

        local va = _b64Index[a]
        local vb = _b64Index[b]
        local vc = c and _b64Index[c] or -1
        local vd = d and _b64Index[d] or -1

        if va == nil or vb == nil then break end
        if vc == nil then vc = -1 end
        if vd == nil then vd = -1 end

        local n = va * 262144 + vb * 4096 + (math.max(vc, 0) * 64) + math.max(vd, 0)

        local b1 = math.floor(n / 65536) % 256
        local b2 = math.floor(n / 256) % 256
        local b3 = n % 256

        out[#out + 1] = b1
        if vc ~= -1 then out[#out + 1] = b2 end
        if vd ~= -1 then out[#out + 1] = b3 end
    end

    return out
end

local function bytesToRuns(bytes)
    local runs = {}
    if type(bytes) ~= "table" or #bytes < 2 then return runs end
    local i = 1
    while i < #bytes do
        local count = tonumber(bytes[i]) or 0
        local idx = tonumber(bytes[i + 1]) or 0
        runs[#runs + 1] = count
        runs[#runs + 1] = idx
        i = i + 2
    end
    return runs
end

local function tableLooksLikeRunsOrBytes(t)
    if type(t) ~= "table" then return false end
    if #t < 2 then return false end
    if (#t % 2) ~= 0 then return false end
    if type(t[1]) ~= "number" then return false end
    if type(t[2]) ~= "number" then return false end
    return true
end

-- =========================
-- Live perf counters
-- =========================

function Player:_perfReset()
    local t = nowMs()
    self._perfLastMs = t
    self._perfFrameAdds = 0
    self._perfRenderCalls = 0
    self.liveFps = 0
    self.renderFps = 0
end

function Player:_perfTick()
    local t = nowMs()
    local last = self._perfLastMs or t
    local dt = t - last
    if dt < 0 then dt = 0 end

    if dt >= 1000 then
        local secs = dt / 1000.0
        local fa = tonumber(self._perfFrameAdds) or 0
        local rc = tonumber(self._perfRenderCalls) or 0

        self.liveFps = math.floor((fa / secs) * 10 + 0.5) / 10
        self.renderFps = math.floor((rc / secs) * 10 + 0.5) / 10

        self._perfFrameAdds = 0
        self._perfRenderCalls = 0
        self._perfLastMs = t
    end
end

function Player.new(data)
    local self = setmetatable({}, Player)
    self.loop = true
    self.playing = true
    self.frame = 1
    self._accumMs = 0
    self._lastMs = nowMs()
    self.alphaMul = 1.0
    self:_perfReset()
    self:setData(data)
    return self
end

function Player:setData(data)
    self.data = (type(data) == "table") and data or { meta = {}, palette = {}, frames = {} }

    self.meta = self.data.meta or {}
    self.pal = normalizePalette(self.data.palette or {})

    self.w = tonumber(self.meta.w) or 0
    self.h = tonumber(self.meta.h) or 0
    self.fps = clamp(self.meta.fps or 10, 1, 30)

    self.msPerFrame = math.floor(1000 / (self.fps > 0 and self.fps or 10))
    if self.msPerFrame < 1 then self.msPerFrame = 100 end

    self._pf = false
    self.frames = nil
    self.frameCount = 1

    self._prime = nil

    if type(self.data.frames) == "table" and #self.data.frames > 0 then
        self.frames = self.data.frames
        self.frameCount = tonumber(self.meta.frame_count) or (#self.frames)
        if (self.frameCount or 0) < 1 then self.frameCount = #self.frames end
        if (self.frameCount or 0) < 1 then self.frameCount = 1 end
        self._pf = false
    elseif type(self.data.F) == "table" then
        self._pf = true
        self._pfF = self.data.F

        if type(self.data.S) == "table" then
            self._pfS = self.data.S
        elseif type(self.data.shared) == "table" and type(self.data.shared.S) == "table" then
            self._pfS = self.data.shared.S
        else
            self._pfS = nil
        end

        if type(self._pfS) ~= "table" then
            self._pf = false
            self.frames = {}
            self.frameCount = tonumber(self.meta.frame_count) or 1
            return
        end

        self._pfScanCache = {}
        self._pfActiveIds = {}
        self._pfAppliedFrame = 0
        self.frameCount = tonumber(self.meta.frame_count) or (#self._pfF)
        if (self.frameCount or 0) < 1 then self.frameCount = #self._pfF end
        if (self.frameCount or 0) < 1 then self.frameCount = 1 end

        self:_pfRebuildToFrame(1)
    else
        self.frames = {}
        self.frameCount = tonumber(self.meta.frame_count) or 1
        if (self.frameCount or 0) < 1 then self.frameCount = 1 end
        self._pf = false
    end

    self.frame = clamp(self.frame or 1, 1, self.frameCount)
    self._accumMs = 0
    self._lastMs = nowMs()
    self:_perfReset()

    if self._pf then
        self:_pfRebuildToFrame(self.frame)
    end
end

function Player:play()
    self.playing = true
    self._lastMs = nowMs()
end

function Player:pause()
    self.playing = false
end

function Player:stop()
    self.playing = false
    self.frame = 1
    self._accumMs = 0
    if self._pf then
        self:_pfRebuildToFrame(1)
    end
    self._prime = nil
    self:_perfReset()
end

function Player:seekFrame(n)
    n = tonumber(n) or 1
    self.frame = clamp(math.floor(n), 1, self.frameCount or 1)
    self._accumMs = 0
    self._lastMs = nowMs()
    if self._pf then
        self:_pfRebuildToFrame(self.frame)
    end
    self._prime = nil
end

function Player:update()
    if not self.playing then
        self:_perfTick()
        return
    end

    local t = nowMs()
    local dt = t - (self._lastMs or t)
    self._lastMs = t

    if dt < 0 then dt = 0 end
    if dt > 250 then dt = 250 end

    self._accumMs = (self._accumMs or 0) + dt

    while self._accumMs >= self.msPerFrame do
        self._accumMs = self._accumMs - self.msPerFrame
        self.frame = (self.frame or 1) + 1
        self._perfFrameAdds = (self._perfFrameAdds or 0) + 1

        if self.frame > (self.frameCount or 1) then
            if self.loop then
                self.frame = 1
                if self._pf then
                    self:_pfRebuildToFrame(1)
                end
            else
                self.frame = self.frameCount
                self.playing = false
                break
            end
        end

        if self._pf then
            self:_pfApplyFrame(self.frame)
        end
    end

    self:_perfTick()
end

-- =========================
-- PixelForge v2 helpers
-- =========================

function Player:_pfDecodeScanlineRuns(id0)
    if not self._pfScanCache then self._pfScanCache = {} end
    local cached = self._pfScanCache[id0]
    if cached then return cached end

    local entry = nil
    if type(self._pfS) == "table" then
        entry = self._pfS[id0 + 1]
    end

    if type(entry) == "table" then
        if tableLooksLikeRunsOrBytes(entry) then
            local runs = {}
            for i = 1, #entry do
                runs[i] = tonumber(entry[i]) or 0
            end
            self._pfScanCache[id0] = runs
            return runs
        end

        local emptyT = {}
        self._pfScanCache[id0] = emptyT
        return emptyT
    end

    if type(entry) ~= "string" or entry == "" then
        local empty = {}
        self._pfScanCache[id0] = empty
        return empty
    end

    local bytes = b64DecodeToBytes(entry)
    local runs = bytesToRuns(bytes)

    self._pfScanCache[id0] = runs
    return runs
end

function Player:_pfResetActive()
    self._pfActiveIds = {}
    self._pfAppliedFrame = 0
    for y = 1, (self.h or 0) do
        self._pfActiveIds[y] = 0
    end
end

function Player:_pfApplyFrame(frameIndex)
    if not self._pf then return end
    if type(self._pfF) ~= "table" then return end
    if (self.h or 0) <= 0 then return end

    frameIndex = tonumber(frameIndex) or 1
    if frameIndex < 1 then frameIndex = 1 end
    if frameIndex > (self.frameCount or 1) then frameIndex = self.frameCount or 1 end

    local applied = tonumber(self._pfAppliedFrame) or 0
    if applied ~= frameIndex - 1 then
        self:_pfRebuildToFrame(frameIndex)
        return
    end

    local fr = self._pfF[frameIndex]

    -- false / nil => identical to previous frame
    if fr == false or fr == nil then
        self._pfAppliedFrame = frameIndex
        return
    end

    if type(fr) ~= "table" then
        self._pfAppliedFrame = frameIndex
        return
    end

    -- Delta frame:
    -- { d = { row, dictId, row, dictId, ... } }
    if type(fr.d) == "table" then
        local d = fr.d
        local i = 1
        while i < #d do
            local row = tonumber(d[i])
            local id0 = tonumber(d[i + 1])

            if row and id0 and row >= 1 and row <= self.h and id0 >= 0 then
                self._pfActiveIds[row] = id0
            end

            i = i + 2
        end

        self._pfAppliedFrame = frameIndex
        return
    end

    -- Full keyframe:
    -- plain table indexed by row, each value = dictionary ID
    for y = 1, self.h do
        local v = fr[y]
        if v ~= nil then
            local n = tonumber(v)
            if n ~= nil and n >= 0 then
                self._pfActiveIds[y] = n
            end
        end
    end

    self._pfAppliedFrame = frameIndex
end

function Player:_pfRebuildToFrame(targetFrame)
    if not self._pf then return end
    self:_pfResetActive()

    targetFrame = tonumber(targetFrame) or 1
    targetFrame = clamp(targetFrame, 1, self.frameCount or 1)

    for f = 1, targetFrame do
        local fr = self._pfF and self._pfF[f] or nil

        -- false / nil => identical to previous frame
        if fr == false or fr == nil then
            -- keep previous active rows
        elseif type(fr) == "table" and type(fr.d) == "table" then
            -- Delta frame
            local d = fr.d
            local i = 1
            while i < #d do
                local row = tonumber(d[i])
                local id0 = tonumber(d[i + 1])

                if row and id0 and row >= 1 and row <= self.h and id0 >= 0 then
                    self._pfActiveIds[row] = id0
                end

                i = i + 2
            end
        elseif type(fr) == "table" then
            -- Full keyframe
            for y = 1, self.h do
                local v = fr[y]
                if v ~= nil then
                    local n = tonumber(v)
                    if n ~= nil and n >= 0 then
                        self._pfActiveIds[y] = n
                    end
                end
            end
        end

        self._pfAppliedFrame = f
    end
end

-- =========================
-- Priming (warm cache without spikes)
-- =========================

function Player:prime(frameIndex, maxLines)
    if not self._pf then
        self._prime = nil
        return true
    end

    frameIndex = tonumber(frameIndex) or 1
    frameIndex = clamp(frameIndex, 1, self.frameCount or 1)

    maxLines = tonumber(maxLines) or 12
    if maxLines < 1 then maxLines = 1 end
    if maxLines > 64 then maxLines = 64 end

    if not self._prime or self._prime.frame ~= frameIndex then
        self._prime = { frame = frameIndex, y = 1 }
    end

    if (tonumber(self._pfAppliedFrame) or 0) ~= frameIndex then
        self:_pfRebuildToFrame(frameIndex)
    end

    local y = tonumber(self._prime.y) or 1
    if y < 1 then y = 1 end

    local h = tonumber(self.h) or 0
    if h <= 0 then
        self._prime = nil
        return true
    end

    local toY = y + maxLines - 1
    if toY > h then toY = h end

    for yy = y, toY do
        local id0 = (self._pfActiveIds and self._pfActiveIds[yy]) or 0
        id0 = tonumber(id0) or 0
        self:_pfDecodeScanlineRuns(id0)
    end

    if toY >= h then
        self._prime = nil
        return true
    end

    self._prime.y = toY + 1
    return false
end

-- =========================
-- Render
-- =========================

function Player:render(ui, x, y, w, h, scale, alphaMul, mode)
    if not ui or type(ui) ~= "table" then return end
    if not ui.drawRect then return end
    if self.w <= 0 or self.h <= 0 then return end
    if w <= 0 or h <= 0 then return end

    self._perfRenderCalls = (self._perfRenderCalls or 0) + 1
    self:_perfTick()

    local aMul = clamp(alphaMul or self.alphaMul or 1.0, 0, 1)

    mode = tostring(mode or "contain")
    if mode ~= "cover" then mode = "contain" end

    -- Fractional scaling support so smaller source videos can fill non-integer viewports.
    if scale == nil then
        local sx = w / self.w
        local sy = h / self.h

        if mode == "cover" then
            scale = math.max(sx, sy)
        else
            scale = math.min(sx, sy)
        end
    end

    scale = tonumber(scale) or 1.0
    if scale <= 0 then scale = 0.01 end
    if scale > 16 then scale = 16 end

    local drawW = self.w * scale
    local drawH = self.h * scale

    local ox = x + (w - drawW) / 2
    local oy = y + (h - drawH) / 2

    if self._pf then
        if (tonumber(self._pfAppliedFrame) or 0) ~= (tonumber(self.frame) or 1) then
            self:_pfRebuildToFrame(self.frame or 1)
        end

        for yy = 1, self.h do
            local id0 = self._pfActiveIds and self._pfActiveIds[yy] or 0
            if id0 == nil then id0 = 0 end
            id0 = tonumber(id0) or 0

            local runs = self:_pfDecodeScanlineRuns(id0)
            if type(runs) == "table" and #runs > 0 then
                local px = 0
                local i = 1

                local rowY1 = oy + ((yy - 1) * scale)
                local rowY2 = oy + (yy * scale)
                local rowY = math.floor(rowY1 + 0.5)
                local rowH = math.floor(rowY2 + 0.5) - rowY
                if rowH < 1 then rowH = 1 end

                if rowY + rowH >= y and rowY <= (y + h) then
                    while i <= #runs do
                        local count = tonumber(runs[i]) or 0
                        local idx = tonumber(runs[i + 1]) or 0

                        if count > 0 then
                            if idx ~= 0 then
                                local c = self.pal[idx]
                                if c then
                                    local a = (c.a or 1.0) * aMul
                                    if a > 0 then
                                        local rx1 = ox + (px * scale)
                                        local rx2 = ox + ((px + count) * scale)
                                        local rx = math.floor(rx1 + 0.5)
                                        local rw = math.floor(rx2 + 0.5) - rx
                                        if rw < 1 then rw = 1 end

                                        local ix, iy, iw, ih = intersectRect(rx, rowY, rw, rowH, x, y, w, h)
                                        if ix then
                                            ui:drawRect(ix, iy, iw, ih, a, c.r, c.g, c.b)
                                        end
                                    end
                                end
                            end
                            px = px + count
                        end

                        i = i + 2
                        if px >= self.w then break end
                    end
                end
            end
        end

        return
    end

    local frame = self.frames and self.frames[self.frame or 1] or nil
    if type(frame) ~= "table" then return end

    for yy = 1, self.h do
        local runs = frame[yy]
        if type(runs) == "table" then
            local px = 0
            local i = 1

            local rowY1 = oy + ((yy - 1) * scale)
            local rowY2 = oy + (yy * scale)
            local rowY = math.floor(rowY1 + 0.5)
            local rowH = math.floor(rowY2 + 0.5) - rowY
            if rowH < 1 then rowH = 1 end

            if rowY + rowH >= y and rowY <= (y + h) then
                while i <= #runs do
                    local count = tonumber(runs[i]) or 0
                    local idx = tonumber(runs[i + 1]) or 0

                    if count > 0 then
                        if idx ~= 0 then
                            local c = self.pal[idx]
                            if c then
                                local a = (c.a or 1.0) * aMul
                                if a > 0 then
                                    local rx1 = ox + (px * scale)
                                    local rx2 = ox + ((px + count) * scale)
                                    local rx = math.floor(rx1 + 0.5)
                                    local rw = math.floor(rx2 + 0.5) - rx
                                    if rw < 1 then rw = 1 end

                                    local ix, iy, iw, ih = intersectRect(rx, rowY, rw, rowH, x, y, w, h)
                                    if ix then
                                        ui:drawRect(ix, iy, iw, ih, a, c.r, c.g, c.b)
                                    end
                                end
                            end
                        end
                        px = px + count
                    end

                    i = i + 2
                    if px >= self.w then break end
                end
            end
        end
    end
end

return Player
