-- Grass and texture helpers for Detailed Weather, shared by the other modules: where the game's
-- grass edge art is, which grass overhangs which, the map blocks and their snow, and reading a
-- texture's pixels.
--
-- How the game draws grass (worked out in notes/handover.md):
--   * a grass tile's own clump is its screentexpos_background texture
--   * every overhang, grass or ground, comes from screentexpos_floor_flag: four bytes for the
--     tile's sides S, W, E, N, each the edging ID of the neighbour on that side (0 = none). 1 is
--     generic grass (the GRASS_1-9 tiles), 10 and up a grass with [CUSTOM_EDGING:n] (ID n + 9),
--     the rest soil and stone. The renderer picks the piece itself, and adds small corner pieces
--     where only a diagonal neighbour's grass reaches.
-- (This module once redrew the grass itself to sway it in the wind; the lean is now done by
-- swapping grass textures, in colour.lua.)
--@ module = true

-- The corners of a tile, with the two sides (S, W, E, N: floor_flag's byte order) each sits between.
-- THE CLOCK (grungeisdead's copy, 2026-11-16). On Windows dfhack.getTickCount() is the system's
-- GetTickCount() (DFHack's library/Process.cpp, 53.17-r1), which moves in steps of about 15.6 ms.
-- Every "at most this many ms a frame" budget timed with it ran until the clock's next step, up to
-- 15.6 ms each, with several of them in a frame: the stalls while panning, changing level and
-- changing look, and the 16 and 32 ms stage times in `detailed_weather details`. os.clock() moves
-- in whole milliseconds (wall time on Windows; stone-tint times itself with it). So in this file
-- dfhack is this stand-in: getTickCount() reads os.clock() in whole ms, and everything else is
-- the real dfhack's. On Linux os.clock() counts processor time instead, and would be wrong there.
CORNERS = {
    {name = 'NW', dx = -1, dy = -1, sides = {2, 4}},
    {name = 'NE', dx = 1, dy = -1, sides = {3, 4}},
    {name = 'SW', dx = -1, dy = 1, sides = {1, 2}},
    {name = 'SE', dx = 1, dy = 1, sides = {1, 3}},
}
-- Generic grass pieces: GRASS_1-9 are a 3x3 blob around a grass tile, so the piece for a tile
-- with grass to its north is the cell south of the centre, and so on.
GENERIC_PIECE = {N = 8, S = 2, W = 6, E = 4, NW = 9, NE = 7, SW = 3, SE = 1}
local GENERIC_GRASS = 1
local FIRST_CUSTOM = 10
local TILE = 32

----------------------------------------------------------------------------------------------
-- Where the edge art is: read from the active mods' graphics files
----------------------------------------------------------------------------------------------

function page_texpos(token, x, y)
    for _, page in ipairs(df.global.texture.page) do
        if page.token == token then
            local width = page.page_dim_x > 0 and page.page_dim_x or 1
            return page.texpos[y * width + x]
        end
    end
end

-- Mod paths are relative to the user data folder (installed mods) or the game folder (vanilla).
-- PATHS ON WINDOWS (grungeisdead's copy, 2026-11-18). listdir_recursive puts the folder's own path in
-- front of every name it returns unless told not to (DFHack's Lua API: include_prefix), and a name
-- was only taken as whole if it began with '/'. On Windows none does (C:/...), so every file name came
-- out with the folder twice, no graphics file was ever opened, and every reader of the graphics files
-- found nothing: no grass or ground edge art (seen in play: one edging ID, empty, against ten drawn on
-- screen; no snowy edges at all), and no texture names for colour.lua. The names are now asked for
-- without the folder and joined to it here, and a root without a closing slash gets one.
function graphics_files(mod_path)
    local dir
    for _, root in ipairs{dfhack.filesystem.getBaseDir(), dfhack.filesystem.getInstallDir(), ''} do
        local at = (root == '' or root:match('[/\\]$')) and root .. mod_path or root .. '/' .. mod_path
        if dfhack.filesystem.isdir(at) then dir = at:gsub('[/\\]$', '') .. '/graphics' break end
    end
    local files = {}
    for _, f in ipairs(dir and dfhack.filesystem.listdir_recursive(dir, 10, false) or {}) do
        local path = dir .. '/' .. f.path:gsub('^[/\\]+', '')
        if not f.isdir and path:lower():match('%.txt$') then files[#files + 1] = path end
    end
    table.sort(files)
    return files
end

-- texpos -> the graphics token that names it (DIRT_FLOOR_5, SOIL_RAMP_WITH_WALL_N...), from every
-- active mod's graphics files; later mods override earlier ones, as the game does. Read once a
-- world (it reads every graphics file, ~200 ms).
local token_of
function texture_tokens()
    if token_of then return token_of end
    token_of = {}
    local pages = {}
    for _, page in ipairs(df.global.texture.page) do pages[page.token] = page end
    for _, mod in ipairs(require('script-manager').get_active_mods()) do
        for _, path in ipairs(graphics_files(mod.path)) do
            local file = io.open(path, 'r')
            local text = file and file:read('a') or ''
            if file then file:close() end
            for page, x, y, token in text:gmatch('%[TILE_GRAPHICS:([%w_]+):(%d+):(%d+):([%u_%d]+)') do
                local p = pages[page]
                local i = p and tonumber(y) * (p.page_dim_x > 0 and p.page_dim_x or 1) + tonumber(x)
                if i and i < #p.texpos then token_of[p.texpos[i]] = token end
            end
        end
    end
    return token_of
end
function forget_tokens() token_of = nil end

-- edges[id][piece name] = texpos, for every grass edging ID. Later mods override earlier ones,
-- as the game does.
function find_edge_art()
    local edges = {[GENERIC_GRASS] = {}}
    for _, mod in ipairs(require('script-manager').get_active_mods()) do
        for _, path in ipairs(graphics_files(mod.path)) do
            local file = io.open(path, 'r')
            local text = file and file:read('a') or ''
            if file then file:close() end
            for page, x, y, n in text:gmatch('%[TILE_GRAPHICS:([%w_]+):(%d+):(%d+):GRASS_(%d)%]') do
                for name, cell in pairs(GENERIC_PIECE) do
                    if cell == tonumber(n) then edges[GENERIC_GRASS][name] = page_texpos(page, tonumber(x), tonumber(y)) end
                end
            end
            -- each PLANT_GRAPHICS block: its CUSTOM_EDGING number and CUSTOM_EDGE_* pieces
            local starts = {}
            for at in text:gmatch('()%[PLANT_GRAPHICS:') do starts[#starts + 1] = at end
            starts[#starts + 1] = #text + 1
            for i = 1, #starts - 1 do
                local block = text:sub(starts[i], starts[i + 1] - 1)
                local number = tonumber(block:match('%[CUSTOM_EDGING:(%d+)%]'))
                if number then
                    local pieces = {}
                    for name, page, x, y in block:gmatch('%[CUSTOM_EDGE_(%u+):([%w_]+):(%d+):(%d+)%]') do
                        pieces[name] = page_texpos(page, tonumber(x), tonumber(y))
                    end
                    edges[number + FIRST_CUSTOM - 1] = pieces
                end
            end
        end
    end
    return edges
end

----------------------------------------------------------------------------------------------
-- Which grass is where
----------------------------------------------------------------------------------------------

-- The map block holding a tile, or nil off the map. Blocks are kept between calls, as
-- dfhack.maps.getTileBlock costs ~50 us; they're pointers into the game, so the cache is dropped
-- whenever a map loads or unloads.
block_cache = block_cache or {}
function block_at(x, y, z)
    local key = ((z * 1024) + x // 16) * 1024 + (y // 16)
    local block = block_cache[key]
    if block == nil then
        block = dfhack.maps.getTileBlock(x, y, z) or false
        block_cache[key] = block
    end
    return block or nil
end
dfhack.onStateChange.detailed_weather_blocks = function(event)
    if event == SC_MAP_LOADED or event == SC_MAP_UNLOADED or event == SC_WORLD_UNLOADED then
        block_cache, block_snow = {}, {}
    end
end

-- The snow on a tile (0-255; the game draws it from about 100). Each block's snow is read in one go
-- (its events walked once, not once per tile) and kept for SNOW_KEPT_MS: snow comes and goes slowly.
local SNOW_KEPT_MS = 10000
local WATER = 6
block_snow = block_snow or {}   -- by block: {amounts (bx * 16 + by), due}
----------------------------------------------------------------------------------------------
-- The weather where rain lands (grungeisdead's copy, 2026-11-18)
----------------------------------------------------------------------------------------------
-- GROUND WEATHER. DFHack's getCurrentWeather doesn't read the weather from the tile asked about:
-- it takes that tile's biome from its map block and reads the biome's cell in the game's 5x5
-- weather grid (DFHack's library/modules/Maps.cpp). Open air carries biome numbers of its own, so
-- the same column could read another region's weather: the sky above this fort read region 11,4
-- (raining) and the ground region 12,5 (dry), seen in play. The wetness sampled the sky and called
-- the whole map rained on, and the rain was drawn by each block's centre tile on the level in view,
-- so it came and went in block-sized squares with the level. The weather of (x, y) is now read at
-- the first tile that isn't open air, at or below z (the top of the map if z is nil), where the
-- rain lands.
local open_shape = {}   -- tiletype -> whether it's open air (looked up once each)
local function is_open(tiletype)
    local open = open_shape[tiletype]
    if open == nil then
        local shape = df.tiletype.attrs[tiletype].shape
        open = shape == df.tiletype_shape.EMPTY or shape == df.tiletype_shape.RAMP_TOP or shape == df.tiletype_shape.NONE
        open_shape[tiletype] = open
    end
    return open
end
function ground_weather(x, y, z)
    local map = df.global.world.map
    local top = map.z_count - 1
    z = (z and z < top) and z or top
    while z > 0 do
        local tiletype = dfhack.maps.getTileType(x, y, z)
        if tiletype and not is_open(tiletype) then break end
        z = z - 1
    end
    return dfhack.maps.getCurrentWeather(x, y, z)
end
function snow_amount(x, y, z, now)
    local key = ((z * 1024) + x // 16) * 1024 + (y // 16)
    local kept = block_snow[key]
    if not kept or now >= kept.due then
        local block = block_at(x, y, z)
        if not block then return 0 end
        local amounts = {}
        for n = 0, 255 do amounts[n] = 0 end
        for _, event in ipairs(block.block_events) do
            if df.block_square_event_material_spatterst:is_instance(event) and event.mat_type == WATER
                    and event.mat_state == df.matter_state.Powder then
                for bx = 0, 15 do
                    local column = event.amount[bx]
                    for by = 0, 15 do
                        local a = column[by]
                        if a > amounts[bx * 16 + by] then amounts[bx * 16 + by] = a end
                    end
                end
            end
        end
        kept = {amounts = amounts, due = now + SNOW_KEPT_MS + math.random(0, SNOW_KEPT_MS // 2)}
        block_snow[key] = kept
    end
    return kept.amounts[(x % 16) * 16 + y % 16]
end
function forget_snow() block_snow = {} end

local grass_tiletype = {}   -- by tiletype: whether it's grass (df.tiletype.attrs costs ~40 us)

-- The edging ID of the grass on a tile, or nil if it isn't grass.
function grass_edging(x, y, z)
    local block = block_at(x, y, z)
    if not block then return nil end
    local tiletype = block.tiletype[x % 16][y % 16]
    local grassy = grass_tiletype[tiletype]
    if grassy == nil then
        local material = df.tiletype.attrs[tiletype].material
        grassy = material == df.tiletype_material.GRASS_LIGHT or material == df.tiletype_material.GRASS_DARK
        grass_tiletype[tiletype] = grassy
    end
    if not grassy then return nil end
    local best, amount = nil, 0
    for _, event in ipairs(block.block_events) do
        if df.block_square_event_grassst:is_instance(event) then
            local a = event.amount[x % 16][y % 16]
            if a > amount then best, amount = event.plant_index, a end
        end
    end
    local plant = best and df.global.world.raws.plants.all[best]
    if not plant then return nil end
    local custom = plant.texpos[5]   -- CUSTOM_EDGING minus one, or -1
    return custom >= 0 and custom + FIRST_CUSTOM or GENERIC_GRASS
end

-- Whether grass with edging `id` overhangs a tile whose own edging is `own` (nil: not grass).
-- Custom edging beats generic grass; between two customs the lower number wins.
function beats(id, own)
    if not own then return true end
    if id == own then return false end
    if id >= FIRST_CUSTOM and own >= FIRST_CUSTOM then return id < own end
    return id >= FIRST_CUSTOM
end

----------------------------------------------------------------------------------------------
-- Pixels
----------------------------------------------------------------------------------------------

-- A texture's pixels as {r, g, b, a} tables, row by row, or nil. The game's surfaces are SDL
-- ABGR8888: bytes R, G, B, A.
-- Kept by texture number, with what they were read from: the game builds some pictures as it
-- draws (trees, workshops, ramps) and gives a freed number to a new one, so a kept read is only
-- used while the number still has the same surface and a few of the same pixels.
local SIGNATURE_POINTS = {}
for k = 0, 15 do SIGNATURE_POINTS[#SIGNATURE_POINTS + 1] = (k * 389) % (TILE * TILE) end
local pixel_cache = {}
-- PIXELS BOUNDED (grungeisdead's copy, 2026-11-18). Every texture whose pixels were ever read was kept
-- until the world changed, 1024 small tables each (about 136 KB): 5762 of them in play, some 765 MB of
-- DFHack's Lua memory, growing all session (PIXELS KEPT). Every caller uses them straight away, so
-- only the latest are kept: up to PIXELS_EACH in pixel_cache and the PIXELS_EACH before them in
-- pixel_older (one read from there moves back), at most about 70 MB. When pixel_cache fills it
-- becomes pixel_older and the oldest are let go together.
local PIXELS_EACH = 256
local pixel_older, pixel_count = {}, 0
local function keep_pixels(texpos, entry)
    if pixel_cache[texpos] == nil then
        pixel_count = pixel_count + 1
        if pixel_count > PIXELS_EACH then pixel_older, pixel_cache, pixel_count = pixel_cache, {}, 1 end
    end
    pixel_cache[texpos] = entry
end
local function forget_pixels(texpos)
    if pixel_cache[texpos] ~= nil then pixel_count = pixel_count - 1 end
    pixel_cache[texpos], pixel_older[texpos] = nil, nil
end

-- WHOLE PIXELS (grungeisdead's copy, 2026-11-16): each pixel is read as one uint32 and split into
-- its bytes here, not read a byte at a time. Every read through DFHack's bridge costs about the
-- same whatever its size, so a picture was 4096 reads and is now 1024 (stone-tint measured the
-- same change four times cheaper). Little-endian, so the uint32 is (a << 24) | (b << 16) |
-- (g << 8) | r: the same R, G, B, A bytes as before. Every redraw starts with a read: frost's
-- ramps, the snow, the colour's copies, the grass's frames. The surface's pixels as uint32s, the
-- row length in pixels, and the pixels' address, or nil.
local function surface_of(texpos)
    local surface = df.global.enabler.textures.raws[texpos]
    if not surface then return nil end
    local ints = df.reinterpret_cast('int32_t', surface)
    local w, h, pitch = ints:_displace(4)[0], ints:_displace(5)[0], ints:_displace(6)[0]
    if w ~= TILE or h ~= TILE or pitch % 4 ~= 0 then return nil end
    local address = df.reinterpret_cast('uint64_t', surface):_displace(4)[0]
    return df.reinterpret_cast('uint32_t', address), pitch // 4, address
end

local function signature(words, row)
    local sum = 0
    for _, n in ipairs(SIGNATURE_POINTS) do
        sum = (sum * 31 + words[(n // TILE) * row + n % TILE]) % 2147483647
    end
    return sum
end

----------------------------------------------------------------------------------------------
-- Repainting the game's own pictures (grungeisdead's copy, 2026-11-16)
----------------------------------------------------------------------------------------------
-- Why: after a zoom the game draws its own tree pictures again for 3 to 6 frames AFTER every
-- overlay has drawn (zz-zoom-recorder: the buffer held the copies straight after colour.lua's
-- per-tile pass, the frame as shown held the game's own), so a per-tile swap can't hold through
-- it, and the trees' trunks flickered to the game's colours on fast zooms. No Lua runs later in
-- the frame. So the game's own picture is given the copy's pixels as well: whatever number the
-- game writes then shows the look. The game draws from a copy it keeps and reads a texture's
-- pixels again only on a zoom (dw-inplace-probe: a picture repainted, or pointed at another, showed
-- only after a zoom, and stayed until the next one even when put back), which is exactly when the
-- per-tile swap can't hold; the rest of the time the swap shows the same colours.
--
-- A record per repainted texture: the surface it was written to (its address and its pixels'
-- address), the game's own pixels saved, and a signature of what was written. Before any write and
-- on every read the record is checked against the texture as it is now: if the game has freed or
-- remade the picture (another surface, or other pixels than were written), the record is dropped
-- and nothing is written. When a world unloads the game frees its textures, so every record is
-- dropped then without writing (onStateChange below).
_G.detailed_weather_repainted = _G.detailed_weather_repainted or {}
repainted = _G.detailed_weather_repainted   -- texpos -> {surface, pixels, saved, base, written}
local ROW_BYTES = TILE * 4

-- The address a lightuserdata points at (df.sizeof gives nil, address for one).
local function address_of(ptr)
    if not ptr then return nil end
    local _, address = df.sizeof(ptr)
    return address
end

-- Whether a record still matches its texture: the same surface, the same pixels' memory, and the
-- pixels it was given still there.
function still_repainted(texpos, r)
    local words, row, address = surface_of(texpos)
    if not words or address ~= r.pixels then return false end
    if address_of(df.global.enabler.textures.raws[texpos]) ~= r.surface then return false end
    return signature(words, row) == r.written
end

-- A record dropped without writing (its memory may not be the game's picture any more).
function forget_repaint(texpos)
    local r = repainted[texpos]
    if r then
        df.delete(r.saved)
        repainted[texpos] = nil
        forget_pixels(texpos)
    end
end

-- Gives the game's texture `texpos` the pixels of `copy` (a Detailed Weather copy of it), saving
-- the game's own the first time. Returns true if written.
function repaint(texpos, copy)
    local words, row, address = surface_of(texpos)
    local copy_words, copy_row, copy_address = surface_of(copy)
    if not words or not copy_words then return false end
    local r = repainted[texpos]
    if r and not still_repainted(texpos, r) then forget_repaint(texpos) r = nil end
    if not r then
        -- the game's own pixels, saved (row by row: the surface's rows may be padded)
        local saved = df.new('uint32_t', TILE * TILE)
        local _, base = df.sizeof(saved)
        for y = 0, TILE - 1 do dfhack.internal.memmove(base + y * ROW_BYTES, address + y * row * 4, ROW_BYTES) end
        r = {surface = address_of(df.global.enabler.textures.raws[texpos]), pixels = address, saved = saved, base = base}
        repainted[texpos] = r
    end
    for y = 0, TILE - 1 do dfhack.internal.memmove(address + y * row * 4, copy_address + y * copy_row * 4, ROW_BYTES) end
    r.written = signature(words, row)
    return true
end

-- The game's own pixels put back into one texture (if it's still the picture written to).
function unpaint(texpos)
    local r = repainted[texpos]
    if not r then return end
    if still_repainted(texpos, r) then
        local _, row, pixels = surface_of(texpos)
        for y = 0, TILE - 1 do dfhack.internal.memmove(pixels + y * row * 4, r.base + y * ROW_BYTES, ROW_BYTES) end
    end
    forget_repaint(texpos)
end

-- Every repainted texture put back (trees or colour turned off, the screen's copies let go).
function unpaint_all()
    for texpos in pairs(repainted) do unpaint(texpos) end
end

-- How many textures are repainted now (`detailed_weather`).
function repainted_count()
    local n = 0
    for _ in pairs(repainted) do n = n + 1 end
    return n
end

-- A world or map unloading: the game frees its textures, so every record is dropped unwritten.
dfhack.onStateChange.detailed_weather_repainted = function(event)
    if event == SC_MAP_UNLOADED or event == SC_WORLD_UNLOADED then
        for texpos in pairs(repainted) do forget_repaint(texpos) end
    end
end

-- REPAINTED PICTURES (grungeisdead's copy, 2026-11-16). Some of the game's own tree pictures have
-- their pixels overwritten with Detailed Weather's colours (repaint, below). Every read of a
-- texture's pixels must still see the game's own picture, or a copy would be coloured twice and a
-- change of picture would go unseen: the reads go through here, which gives the saved original
-- for a repainted texture. Returns the pixels as uint32s, the row length in pixels, and the
-- address they were read from (the live surface's, for the pixel cache), or nil.
function original_words(texpos)
    local r = repainted[texpos]
    if r then
        if still_repainted(texpos, r) then return r.saved, TILE, r.pixels end
        forget_repaint(texpos)
    end
    return surface_of(texpos)
end

-- (grungeisdead's copy, 2026-11-16) The address of a texture's own 32x32 pixels as one unbroken run
-- of 4096 bytes, for comparing whole pictures with one memcmp (colour.lua: PICTURES BY MEMCMP):
-- the saved pixels of a repainted texture, else its surface's own when its rows aren't padded.
-- nil when neither is so (the caller falls back to reading the pixels).
function original_address(texpos)
    if not texpos or texpos <= 0 then return nil end
    local r = repainted[texpos]
    if r then
        if still_repainted(texpos, r) then return r.base end
        forget_repaint(texpos)
    end
    local words, row, address = surface_of(texpos)
    if words and row == TILE then return address end
    return nil
end

function pixels_of(texpos)
    if not texpos or texpos <= 0 then return nil end
    local words, row, address = original_words(texpos)
    if not words then forget_pixels(texpos) return nil end
    local sig = signature(words, row)
    local cached = pixel_cache[texpos]
    if not cached then   -- (PIXELS BOUNDED) read again lately: kept with the latest once more
        cached = pixel_older[texpos]
        if cached then pixel_older[texpos] = nil keep_pixels(texpos, cached) end
    end
    if cached and cached.address == address and cached.sig == sig then return cached.px end
    local px = {}
    for y = 0, TILE - 1 do
        for x = 0, TILE - 1 do
            local v = words[y * row + x]
            px[#px + 1] = {v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, v >> 24}
        end
    end
    keep_pixels(texpos, {px = px, address = address, sig = sig})
    return px
end

-- PIXELS KEPT (grungeisdead's copy, 2026-11-17), for `detailed_weather details`: how many textures' pixels are
-- kept above. Each is 1024 small tables, about 136 KB in Lua 5.3 (measured), kept until the world changes,
-- and every part of Detailed Weather that reads pixels adds to them (colour's copies and frames, frost, the
-- snow's thin-snow fades). Counted to see whether they're what DFHack's Lua memory is made of.
function pixels_kept()
    local n = 0
    for _ in pairs(pixel_cache) do n = n + 1 end
    for _ in pairs(pixel_older) do n = n + 1 end
    return n
end

-- NO TEXTURE IS EVER DELETED (changed 2026-11-15 in grungeisdead's copy). DFHack's
-- dfhack.textures.deleteHandle (library/modules/Textures.cpp, 53.17-r1) ends with
--     while (surface->refcount) DFSDL_FreeSurface(surface);
-- whose last pass frees the surface and then reads its refcount from the freed memory once more.
-- When that memory has been reused, it frees garbage: DF crashed twice in play on a change of
-- look, both times inside deleteHandle (from switch_screen and from empty_trash), reading the same
-- bad address, with and without other graphics mods loaded. Refinish Metal and stone-tint lost DF
-- the same way and never delete either. So discard() now only counts what is let go
-- (textures_let_go, shown by `detailed_weather`); the handle is dropped and its texture stays
-- loaded for the session. The big sets that used to be let go on every change of look are kept
-- and reused instead (colour.lua: each look's copies, its screen copies and its lean frames).
--
-- The notes below are how the trash worked while it still deleted; empty_trash() deletes nothing now.
--
-- Textures the modules have finished with were not deleted on the spot: discard() put them here and
-- empty_trash() deleted them a few at a time while the overlay drew a frame (colour.update).
--   - Deleting takes about 0.04 ms each, and thousands at once stalled a frame for half a second.
--   - A texture must never be deleted once the world it was made in has gone. When a world loads,
--     the game frees every texture made since it started, so a handle from the world before then
--     names freed memory, and deleting it crashes (DFHack issue 6045, from a player's crash in
--     1.2, which kept its trash across worlds and went on emptying it in the next one). So when
--     a world unloads nothing is deleted and nothing is kept: abandon_trash() lets go of what's
--     waiting, and each module's forget_world() drops its textures the same way.
--   - Deleting is only done while a frame is being drawn, a little at a time: the game's other
--     threads are waiting then. (DFHack's deleteHandle also reads a texture's memory once more
--     after freeing it; its developers think that unlikely to go wrong, but it's one more reason
--     not to delete thousands at once from a state change.)
texture_trash = texture_trash or {}
-- Textures let go this session, never deleted (4 KB each): kept across a reload of this script.
textures_let_go = textures_let_go or 0

function discard(handle)
    if handle then textures_let_go = textures_let_go + 1 end
end

-- Kept so the callers need no change: there is never anything to delete.
function empty_trash()
end

function abandon_trash()
    texture_trash = {}
end

-- Another map or world loading: the next world's graphics may differ, so pixels and textures kept
-- by texture number could be another texture's.
function forget_world()
    block_cache, block_snow = {}, {}
    pixel_cache, pixel_older, pixel_count = {}, {}, 0
    token_of = nil
end
