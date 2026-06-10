local MOVIE = "/Users/retro/repos/pcsx-redux/movies/gulp_phase1.pcsxmv"
local DISABLE_RENDER = true

local RNG_ADDR = 0x8006d144
local RENDER_PATCH_ADDR = 0x80011afc
local RENDER_PATCH_VANILLA = 0x0c0055bf
local RENDER_PATCH_NOP = 0x00000000

local MOBY_ARRAY_PTR_ADDR = 0x80066f14
local GAME_MOBY_ARRAY_ADDR = 0x801169a0
local MOBY_POOL_END_ADDR = 0x800670bc
local MOBY_STRIDE = 0x58
local MOBY_DATA_PTR = 0x00
local MOBY_TYPE = 0x36
local MOBY_EMPTY_TYPE = 0x407
local MOBY_MAX_SLOTS = 0x100
local MOBY_POS_X = 0x0c
local MOBY_POS_Y = 0x10
local MOBY_POS_Z = 0x14
local MOBY_YAW = 0x46

local SIN_TABLE_ADDR = 0x80061bd8
local CAM_POS_ADDR = 0x80067eb8
local CAM_YAW_ADDR = 0x80067ecc
local SIN_TABLE_SCALE = 4096

local GULP_VULTURE_PATH_TABLE = 0x0c
local DROP_TARGET_ENTRIES_OFF = 0x0c
local DROP_TARGET_ENTRY_STRIDE = 0x10
local DROP_TARGET_POS_X = 0x00
local DROP_TARGET_POS_Y = 0x04
local DROP_TARGET_HOME = 0
local DROP_TARGET_FIRST = 1
local DROP_TARGET_LAST = 25

local SPYRO_ADDR = 0x80069ff0
local SPYRO_POS_X = 0x00
local SPYRO_POS_Y = 0x04
local SPYRO_POS_Z = 0x08
local SPYRO_YAW = 0x0e
local SPYRO_COLOR = 0xFFAA00FF

local GULP_ADDR = 0x801169a0
local GULP_POS_X = 0x0c
local GULP_POS_Y = 0x10
local GULP_POS_Z = 0x14
local GULP_YAW = 0x46
local GULP_COLOR = 0xFF00FF00

local CAM_POS_X = 0x00
local CAM_POS_Y = 0x04
local CAM_POS_Z = 0x08
local CAM_COLOR = 0xFF00FFFF

local EGG_DATA_DROP_X = 0x04
local EGG_DATA_DROP_Y = 0x06
local EGG_OUTLINE_COLOR = 0xFF4488FF

local MOBY_TYPE_NAMES = {
    [0x407] = "(empty)",
    [0x10] = "MOBY_HEART",
    [0x78] = "MOBY_SPARX",
    [0x104] = "MOBY_FLAME",
    [0x146] = "MOBY_SPARK",
    [0x196] = "MOBY_GULP_BARREL",
    [0x197] = "MOBY_GULP_BOMB",
    [0x198] = "MOBY_GULP_ROCKET",
    [0x199] = "MOBY_GULP_VULTURE",
    [0x19e] = "MOBY_GULP_EGG",
    [0x1bf] = "MOBY_CHICKEN",
}
local VULTURE_TYPES = {
    [0x196] = true,
    [0x197] = true,
    [0x198] = true,
    [0x199] = true,
}

local BIRD_VULTURE_DATA = {
    { addr = 0x80120e44, id = 0, color = 0xFF0000FF },
    { addr = 0x80120c64, id = 1, color = 0xFF00FF00 },
    { addr = 0x80120e88, id = 2, color = 0xFFFF0000 },
}

local MAP = {
    enabled = true,
    worldMinX = -2800,
    worldMaxX = 2800,
    worldMinY = -2800,
    worldMaxY = 2800,
    autoFit = true,
    rotateWithCamera = false,
    scale = 1.2,
    sprite = nil,
}
local VULTURE_MAP_MIN_Z = 20000
local DROP_LOCATION_BP = 0x80077448
local EGG_SPAWN_BP = 0x80077a48

local BIRDS = {
    [0x80120e44] = 0,
    [0x80120c64] = 1,
    [0x80120e88] = 2,
}

local DROP_IDS = {
    [0x196] = "BARREL",
    [0x197] = "BOMB",
    [0x198] = "ROCKET",
}

_G.GulpRngLoop = _G.GulpRngLoop or {
    listeners = {},
    loopActive = false,
    patchRngOnLoad = false,
    movieReady = false,
    bird_count = 0,
    egg_count = 0,
    bird_dropped = { [0] = false, [1] = false, [2] = false },
    dropLocationBp = nil,
    eggBp = nil,
    mobyByVultureData = {},
    fixedMapBounds = nil,
    claimedDropTargets = {},
    birdDropTarget = {},
    eggedDropTargets = {},
    simulation_count = 0,
}

local S = _G.GulpRngLoop

S.egg_count = S.egg_count or 0
if not S.bird_dropped then
    S.bird_dropped = { [0] = false, [1] = false, [2] = false }
end
if not S.birdDropTarget then
    S.birdDropTarget = {}
end
if not S.eggedDropTargets then
    S.eggedDropTargets = {}
end
S.simulation_count = S.simulation_count or S.reset_count or 0

local bit = require('bit')

math.randomseed(tonumber(ffi.cast('uint32_t', PCSX.getCPUCycles())))

local memFile

local function mem()
    if not memFile then
        memFile = PCSX.getMemoryAsFile()
    end
    return memFile
end

local function randomRngState()
    return math.random(0, 0xffffffff)
end

local function toNum(v)
    return tonumber(v) or 0
end

local function readRam8(addr)
    return toNum(mem():readU8At(addr))
end

local function readRamI16(addr)
    return toNum(mem():readI16At(addr))
end

local function readRam16(addr)
    return toNum(mem():readU16At(addr))
end

local function readRam32(addr)
    return toNum(mem():readU32At(addr))
end

local function readRam32s(addr)
    return toNum(mem():readI32At(addr))
end

local function writeRam32(addr, value)
    mem():writeU32At(value, addr)
end

local function setRenderPatch(enabled)
    writeRam32(RENDER_PATCH_ADDR, enabled and RENDER_PATCH_NOP or RENDER_PATCH_VANILLA)
end

local function isKusegPtr(addr)
    addr = tonumber(addr)
    if not addr or addr == 0 then
        return false
    end
    return bit.rshift(addr, 24) == 0x80
end

local function mobyTypeTag(typeId)
    return MOBY_TYPE_NAMES[typeId] or ""
end

local function getMobyArrayBase()
    local ptrGlobal = readRam32(MOBY_ARRAY_PTR_ADDR)
    if isKusegPtr(ptrGlobal) then
        local base = readRam32(ptrGlobal)
        if isKusegPtr(base) then
            return base, string.format("mobyArrayPtr -> 0x%08x", ptrGlobal)
        end
    end
    local base = readRam32(GAME_MOBY_ARRAY_ADDR)
    if isKusegPtr(base) then
        return base, "GAME_moby_array@0x801169a0"
    end
    return nil, "unresolved"
end

local function mobyPoolEnd(base)
    local endAddr = readRam32(MOBY_POOL_END_ADDR)
    if not isKusegPtr(endAddr) or endAddr <= base then
        endAddr = base + MOBY_STRIDE * 0x100
    end
    return endAddr
end

local function collectMobyArrayRows()
    local base, source = getMobyArrayBase()
    if not isKusegPtr(base) then
        return source, 0, {}
    end
    local endAddr = mobyPoolEnd(base)
    local slotCount = math.floor((endAddr - base) / MOBY_STRIDE)
    if slotCount < 1 then
        slotCount = MOBY_MAX_SLOTS
    end
    if slotCount > MOBY_MAX_SLOTS then
        slotCount = MOBY_MAX_SLOTS
    end
    local rows = {}
    for i = 0, slotCount - 1 do
        local addr = base + i * MOBY_STRIDE
        local typeId = readRam16(addr + MOBY_TYPE)
        rows[#rows + 1] = {
            index = i,
            addr = addr,
            typeId = typeId,
            tag = mobyTypeTag(typeId),
        }
    end
    return source, base, rows
end

local function getMobyArrayBases()
    local bases, seen = {}, {}
    local function addBase(base)
        if isKusegPtr(base) and not seen[base] then
            seen[base] = true
            bases[#bases + 1] = base
        end
    end
    local base = select(1, getMobyArrayBase())
    addBase(base)
    return bases
end

local function forEachMobySlot(fn)
    for _, base in ipairs(getMobyArrayBases()) do
        local addr = base
        local endAddr = mobyPoolEnd(base)
        while addr < endAddr do
            if fn(addr) then
                return addr
            end
            addr = addr + MOBY_STRIDE
        end
    end
    return nil
end

local function cacheVultureMoby(vultureData, moby)
    if not isKusegPtr(vultureData) or not isKusegPtr(moby) then
        return
    end
    if readRam32(moby + MOBY_DATA_PTR) == vultureData then
        S.mobyByVultureData[vultureData] = moby
    end
end

local function findMobyForVultureData(vultureDataAddr)
    if not isKusegPtr(vultureDataAddr) then
        return nil
    end
    local cached = S.mobyByVultureData[vultureDataAddr]
    if cached and isKusegPtr(cached) and readRam32(cached + MOBY_DATA_PTR) == vultureDataAddr then
        return cached
    end
    return forEachMobySlot(function(addr)
        if readRam32(addr + MOBY_DATA_PTR) == vultureDataAddr then
            S.mobyByVultureData[vultureDataAddr] = addr
            return true
        end
    end)
end

local function birdStyleForData(vultureData)
    for _, entry in ipairs(BIRD_VULTURE_DATA) do
        if entry.addr == vultureData then
            return entry.id, entry.color
        end
    end
    local birdId = BIRDS[vultureData]
    if birdId ~= nil then
        for _, entry in ipairs(BIRD_VULTURE_DATA) do
            if entry.id == birdId then
                return entry.id, entry.color
            end
        end
    end
    return nil, 0xFFFFFFFF
end

local function collectBirdPositions()
    local birds, seenMoby = {}, {}

    local function addBird(moby, vultureData)
        if not isKusegPtr(moby) or seenMoby[moby] then
            return
        end
        seenMoby[moby] = true
        local id, color = birdStyleForData(vultureData)
        birds[#birds + 1] = {
            id = id ~= nil and id or #birds,
            color = color,
            x = readRam32s(moby + MOBY_POS_X),
            y = readRam32s(moby + MOBY_POS_Y),
            z = readRam32s(moby + MOBY_POS_Z),
            yaw = readRam8(moby + MOBY_YAW),
        }
    end

    for _, entry in ipairs(BIRD_VULTURE_DATA) do
        local moby = S.mobyByVultureData[entry.addr] or findMobyForVultureData(entry.addr)
        if moby then
            addBird(moby, entry.addr)
        end
    end

    forEachMobySlot(function(addr)
        if VULTURE_TYPES[readRam16(addr + MOBY_TYPE)] then
            addBird(addr, readRam32(addr + MOBY_DATA_PTR))
        end
    end)

    return birds
end

local function getDropTargetPathTable()
    for _, entry in ipairs(BIRD_VULTURE_DATA) do
        local pathTable = readRam32(entry.addr + GULP_VULTURE_PATH_TABLE)
        if isKusegPtr(pathTable) then
            return pathTable
        end
    end
    return nil
end

local function readDropTargetEntry(pathTable, index)
    local entryAddr = pathTable + DROP_TARGET_ENTRIES_OFF + index * DROP_TARGET_ENTRY_STRIDE
    return {
        index = index,
        x = readRam32s(entryAddr + DROP_TARGET_POS_X),
        y = readRam32s(entryAddr + DROP_TARGET_POS_Y),
    }
end

local function collectDropTargets()
    local pathTable = getDropTargetPathTable()
    if not isKusegPtr(pathTable) then
        return nil, {}
    end
    local tableCount = readRam16(pathTable)
    local home = readDropTargetEntry(pathTable, DROP_TARGET_HOME)
    home.home = true
    local last = DROP_TARGET_LAST
    if tableCount > 0 and tableCount - 1 < last then
        last = tableCount - 1
    end
    local targets = {}
    for i = DROP_TARGET_FIRST, last do
        targets[#targets + 1] = readDropTargetEntry(pathTable, i)
    end
    return home, targets
end

local function extendBounds(minX, minY, maxX, maxY, x, y)
    if minX == nil then
        return x, y, x, y
    end
    if x < minX then minX = x end
    if y < minY then minY = y end
    if x > maxX then maxX = x end
    if y > maxY then maxY = y end
    return minX, minY, maxX, maxY
end

local function computeDropTargetBounds(dropHome, dropTargets)
    local minX, minY, maxX, maxY
    if dropHome then
        minX, minY, maxX, maxY = extendBounds(minX, minY, maxX, maxY, dropHome.x, dropHome.y)
    end
    for _, t in ipairs(dropTargets) do
        minX, minY, maxX, maxY = extendBounds(minX, minY, maxX, maxY, t.x, t.y)
    end
    if minX == nil then
        return nil
    end
    local spanX = math.max(maxX - minX, 512)
    local spanY = math.max(maxY - minY, 512)
    local padX = math.floor(spanX * 0.25)
    local padY = math.floor(spanY * 0.25)
    return minX - padX, minY - padY, maxX + padX, maxY + padY
end

local function getMapBounds(dropHome, dropTargets)
    if S.fixedMapBounds then
        local b = S.fixedMapBounds
        return b.minX, b.minY, b.maxX, b.maxY
    end
    if MAP.autoFit and (dropHome or #dropTargets > 0) then
        local minX, minY, maxX, maxY = computeDropTargetBounds(dropHome, dropTargets)
        if minX then
            S.fixedMapBounds = { minX = minX, minY = minY, maxX = maxX, maxY = maxY }
            return minX, minY, maxX, maxY
        end
    end
    return MAP.worldMinX, MAP.worldMinY, MAP.worldMaxX, MAP.worldMaxY
end

local function worldToScreen(x, y, minX, minY, maxX, maxY, cx, cy, cw, ch)
    local u = (x - minX) / (maxX - minX)
    local v = (y - minY) / (maxY - minY)
    return cx + (1 - u) * cw, cy + v * ch
end

local function readCameraYaw256()
    return bit.band(bit.rshift(readRam16(CAM_YAW_ADDR), 4), 0xff)
end

local function mapCameraRotationYaw256()
    return bit.band(0x40 - readCameraYaw256(), 0xff)
end

local function readCameraPos()
    return readRam32s(CAM_POS_ADDR + CAM_POS_X), readRam32s(CAM_POS_ADDR + CAM_POS_Y), readRam32s(CAM_POS_ADDR + CAM_POS_Z)
end

local function sinCos256(yaw)
    local idx = bit.band(yaw, 0xff)
    return readRamI16(SIN_TABLE_ADDR + idx * 2), readRamI16(SIN_TABLE_ADDR + bit.band(idx + 0x40, 0xff) * 2)
end

local function rotateWorldXY(x, y, pivotX, pivotY, yaw)
    local dx, dy = x - pivotX, y - pivotY
    local sinA, cosA = sinCos256(yaw)
    local rx = (dx * cosA - dy * sinA) / SIN_TABLE_SCALE
    local ry = (dx * sinA + dy * cosA) / SIN_TABLE_SCALE
    return pivotX + rx, pivotY + ry
end

local function rotateWorldDir(dirX, dirY, yaw)
    local sinA, cosA = sinCos256(yaw)
    return (dirX * cosA - dirY * sinA) / SIN_TABLE_SCALE, (dirX * sinA + dirY * cosA) / SIN_TABLE_SCALE
end

local function worldDirToScreenDir(dirX, dirY)
    local len = math.sqrt(dirX * dirX + dirY * dirY)
    if len < 1 then
        return 0, -1
    end
    return dirX / len, -dirY / len
end

local function createMapRenderCtx(minX, minY, maxX, maxY, cx, cy, cw, ch, spyroX, spyroY)
    local spanX = maxX - minX
    local spanY = maxY - minY
    local rotate = MAP.rotateWithCamera
    local centerX = (minX + maxX) / 2
    local centerY = (minY + maxY) / 2
    if rotate then
        centerX = spyroX
        centerY = spyroY
    end
    return {
        minX = minX,
        minY = minY,
        maxX = maxX,
        maxY = maxY,
        cx = cx,
        cy = cy,
        cw = cw,
        ch = ch,
        spanX = spanX,
        spanY = spanY,
        centerX = centerX,
        centerY = centerY,
        scale = MAP.scale,
        rotate = rotate,
        camYaw = rotate and mapCameraRotationYaw256() or nil,
    }
end

local function mapWorldToScreen(x, y, ctx)
    local spanX = ctx.spanX / ctx.scale
    local spanY = ctx.spanY / ctx.scale
    if ctx.rotate then
        x, y = rotateWorldXY(x, y, ctx.centerX, ctx.centerY, ctx.camYaw)
        local sx = ctx.cx + ctx.cw * 0.5 + (x - ctx.centerX) / spanX * ctx.cw
        local sy = ctx.cy + ctx.ch * 0.5 - (y - ctx.centerY) / spanY * ctx.ch
        return sx, sy
    end
    local midX = (ctx.minX + ctx.maxX) * 0.5
    local midY = (ctx.minY + ctx.maxY) * 0.5
    local sx = ctx.cx + ctx.cw * 0.5 + (midX - x) / spanX * ctx.cw
    local sy = ctx.cy + ctx.ch * 0.5 + (y - midY) / spanY * ctx.ch
    return sx, sy
end

local function mapWorldDirToScreen(dirX, dirY, ctx)
    if ctx.rotate then
        dirX, dirY = rotateWorldDir(dirX, dirY, ctx.camYaw)
        return worldDirToScreenDir(dirX, dirY)
    end
    local u, v = worldDirToScreenDir(dirX, dirY)
    return -u, -v
end

local function drawMapBackground(cx, cy, cw, ch)
    local sprite = MAP.sprite
    if sprite and sprite.textureId then
        imgui.DrawList_AddImage(
            sprite.textureId,
            cx, cy, cx + cw, cy + ch,
            0, 0, 1, 1,
            sprite.tint or 0xFFFFFFFF
        )
        return
    end
    imgui.DrawList_AddRectFilled(cx, cy, cx + cw, cy + ch, 0xFF181818, 0, 0)
    imgui.DrawList_AddRect(cx, cy, cx + cw, cy + ch, 0xFF404040, 0, 0, 1)
end

local function birdColorFromAddr(birdAddr)
    for _, entry in ipairs(BIRD_VULTURE_DATA) do
        if entry.addr == birdAddr then
            return entry.color
        end
    end
    local birdId = BIRDS[birdAddr]
    if birdId ~= nil then
        for _, entry in ipairs(BIRD_VULTURE_DATA) do
            if entry.id == birdId then
                return entry.color
            end
        end
    end
    return nil
end

local function drawMapDropTarget(target, ctx)
    local sx, sy = mapWorldToScreen(target.x, target.y, ctx)
    local scale = ctx.scale
    local claimColor = not target.home and S.claimedDropTargets[target.index]
    local fill, border, text, label, half
    if target.home then
        fill = 0xAA66AAFF
        border = 0xFF3040C0
        text = 0xFFD0D8FF
        label = 'H'
        half = 4 * scale
    elseif claimColor then
        fill = claimColor
        border = 0xFF000000
        text = 0xFFFFFFFF
        label = tostring(target.index)
        half = 7 * scale
    else
        fill = 0xAAFFCC44
        border = 0xFF806010
        text = 0xFFFFE8A0
        label = tostring(target.index)
        half = 4 * scale
    end
    imgui.DrawList_AddRectFilled(sx - half, sy - half, sx + half, sy + half, fill, 2, 0)
    imgui.DrawList_AddRect(sx - half, sy - half, sx + half, sy + half, border, 2, 0, 1.5 * scale)
    if not target.home and S.eggedDropTargets[target.index] then
        local outlineHalf = half + 3 * scale
        imgui.DrawList_AddRect(
            sx - outlineHalf, sy - outlineHalf, sx + outlineHalf, sy + outlineHalf,
            EGG_OUTLINE_COLOR, 0, 0, 2.5 * scale
        )
    end
    imgui.DrawList_AddText(sx + half + 2 * scale, sy - 7 * scale, text, label, nil)
end

local function yawToWorldDir(yaw)
    local idx = bit.band(yaw, 0xff)
    local dirX = readRamI16(SIN_TABLE_ADDR + bit.band(idx + 0x40, 0xff) * 2)
    local dirY = readRamI16(SIN_TABLE_ADDR + idx * 2)
    return dirX, dirY
end

local function drawMapArrow(sx, sy, dirX, dirY, color, size, label, ctx)
    size = size * ctx.scale
    local u, v = mapWorldDirToScreen(dirX, dirY, ctx)
    local px, py = -v, u
    local halfW = size * 0.55
    local tipX = sx + u * size
    local tipY = sy + v * size
    imgui.DrawList_AddTriangleFilled(
        tipX, tipY,
        sx + px * halfW, sy + py * halfW,
        sx - px * halfW, sy - py * halfW,
        color
    )
    if label then
        imgui.DrawList_AddText(sx + size + 4 * ctx.scale, sy - 8 * ctx.scale, 0xFFFFFFFF, label, nil)
    end
end

local function readSpyroPos()
    local base = SPYRO_ADDR
    return readRam32s(base + SPYRO_POS_X), readRam32s(base + SPYRO_POS_Y), readRam32s(base + SPYRO_POS_Z)
end

local function readGulpPos()
    return readRam32s(GULP_ADDR + GULP_POS_X), readRam32s(GULP_ADDR + GULP_POS_Y), readRam32s(GULP_ADDR + GULP_POS_Z)
end

local function drawMapGulp(ctx)
    local x, y = readGulpPos()
    local sx, sy = mapWorldToScreen(x, y, ctx)
    local dirX, dirY = yawToWorldDir(readRam8(GULP_ADDR + GULP_YAW))
    drawMapArrow(sx, sy, dirX, dirY, GULP_COLOR, 18, nil, ctx)
end

local function drawMapSpyro(ctx)
    local x, y = readSpyroPos()
    local sx, sy = mapWorldToScreen(x, y, ctx)
    local dirX, dirY = yawToWorldDir(readRam8(SPYRO_ADDR + SPYRO_YAW))
    drawMapArrow(sx, sy, dirX, dirY, SPYRO_COLOR, 16, nil, ctx)
end

local function drawMapCamera(ctx)
    local x, y = readCameraPos()
    local sx, sy = mapWorldToScreen(x, y, ctx)
    local dirX, dirY = yawToWorldDir(readCameraYaw256())
    drawMapArrow(sx, sy, dirX, dirY, CAM_COLOR, 16, nil, ctx)
end

local function drawMapDropTargets(dropHome, targets, ctx)
    if dropHome then
        drawMapDropTarget(dropHome, ctx)
    end
    for _, target in ipairs(targets) do
        drawMapDropTarget(target, ctx)
    end
end

local function drawMapMarkers(birds, ctx)
    for _, bird in ipairs(birds) do
        if bird.z >= VULTURE_MAP_MIN_Z then
            local sx, sy = mapWorldToScreen(bird.x, bird.y, ctx)
            local dirX, dirY = yawToWorldDir(bird.yaw or 0)
            drawMapArrow(sx, sy, dirX, dirY, bird.color, 14, tostring(bird.id), ctx)
        end
    end
end

local function drawMobyArrayFrame()
    imgui.SetNextWindowSize(520, 640, imgui.constant.Cond.FirstUseEver)
    imgui.safe.Begin('Moby array', true, function()
        local ptrGlobal = readRam32(MOBY_ARRAY_PTR_ADDR)
        local gameArrayPtr = readRam32(GAME_MOBY_ARRAY_ADDR)
        local source, base, rows = collectMobyArrayRows()
        imgui.TextUnformatted(string.format('mobyArrayPtr@0x80066f14 = 0x%08x', ptrGlobal))
        if isKusegPtr(ptrGlobal) then
            imgui.TextUnformatted(string.format('  -> 0x%08x = 0x%08x', ptrGlobal, readRam32(ptrGlobal)))
        end
        imgui.TextUnformatted(string.format('GAME_moby_array@0x801169a0 = 0x%08x', gameArrayPtr))
        if not isKusegPtr(base) then
            imgui.TextUnformatted('moby array base unresolved')
            return
        end
        imgui.TextUnformatted(string.format('source: %s', source))
        imgui.TextUnformatted(string.format('base: 0x%08x  stride: 0x%x  slots: %d', base, MOBY_STRIDE, #rows))
        imgui.Separator()
        imgui.TextUnformatted(string.format('%-5s %-10s %-6s %s', 'idx', 'address', 'type', 'tag'))
        imgui.BeginChild('moby_array_list', 0, 0, false)
        for _, row in ipairs(rows) do
            local tag = row.tag
            if tag == '' then
                tag = row.typeId == MOBY_EMPTY_TYPE and '(empty)' or '-'
            end
            imgui.TextUnformatted(string.format(
                '[%3d] 0x%08x  0x%03x  %s',
                row.index, row.addr, row.typeId, tag
            ))
        end
        imgui.EndChild()
    end)
end

local function drawGulpMapFrame()
    if not S.loopActive or not MAP.enabled then
        return
    end
    imgui.SetNextWindowSize(480, 520, imgui.constant.Cond.FirstUseEver)
    imgui.safe.Begin('Gulp map', true, function()
        _, MAP.rotateWithCamera = imgui.Checkbox('Rotate with camera', MAP.rotateWithCamera)
        local cw, ch = imgui.GetContentRegionAvail()
        if cw < 32 or ch < 32 then
            return
        end
        local cx, cy = imgui.GetCursorScreenPos()
        imgui.InvisibleButton('gulp_map_canvas', cw, ch)
        local birds = collectBirdPositions()
        local dropHome, dropTargets = collectDropTargets()
        local minX, minY, maxX, maxY = getMapBounds(dropHome, dropTargets)
        local spyroX, spyroY, spyroZ = readSpyroPos()
        local mapCtx = createMapRenderCtx(minX, minY, maxX, maxY, cx, cy, cw, ch, spyroX, spyroY)
        drawMapBackground(cx, cy, cw, ch)
        drawMapDropTargets(dropHome, dropTargets, mapCtx)
        drawMapMarkers(birds, mapCtx)
        drawMapGulp(mapCtx)
        drawMapSpyro(mapCtx)
        drawMapCamera(mapCtx)
        imgui.SetCursorScreenPos(cx, cy + ch + 4)
        local gulpX, gulpY, gulpZ = readGulpPos()
        imgui.TextUnformatted(string.format('spyro: x=%d y=%d z=%d', spyroX, spyroY, spyroZ))
        imgui.TextUnformatted(string.format('gulp: x=%d y=%d z=%d', gulpX, gulpY, gulpZ))
        if #birds == 0 then
            imgui.TextUnformatted('no vulture mobys')
        else
            for _, bird in ipairs(birds) do
                imgui.TextUnformatted(string.format('bird %d: x=%d y=%d z=%d', bird.id, bird.x, bird.y, bird.z))
            end
        end
    end)
end

local function drawImguiFrame()
    drawMobyArrayFrame()
    drawGulpMapFrame()
end

local function registerMapUi()
    DrawImguiFrame = drawImguiFrame
end

local function applyRenderPatch()
    if not DISABLE_RENDER then
        return
    end
    setRenderPatch(true)
end

local function restoreRenderPatch()
    setRenderPatch(false)
end

local function patchRng()
    local state = randomRngState()
    writeRam32(RNG_ADDR, state)
    print(string.format("RNG @ 0x%08x set to 0x%08x", RNG_ADDR, state))
end

local function teardown()
    restoreRenderPatch()
    if S.dropLocationBp then
        S.dropLocationBp:remove()
        S.dropLocationBp = nil
    end
    if S.eggBp then
        S.eggBp:remove()
        S.eggBp = nil
    end
    for _, listener in ipairs(S.listeners) do
        listener:remove()
    end
    S.listeners = {}
    S.mobyByVultureData = {}
    S.fixedMapBounds = nil
    S.claimedDropTargets = {}
    S.birdDropTarget = {}
    S.eggedDropTargets = {}
    DrawImguiFrame = nil
end

local function stopLoop(reason)
    S.loopActive = false
    S.wasPlaying = false
    S.patchRngOnLoad = false
    PCSX.Movie.stop()
    teardown()
    if reason then
        print(reason)
    else
        print("RNG movie loop stopped")
    end
end

S.stopLoop = stopLoop
S.Map = MAP

local function birdLabelFromAddr(birdAddr)
    local birdId = BIRDS[birdAddr]
    return birdId ~= nil and tostring(birdId) or string.format("unknown(0x%08x)", birdAddr)
end

local function resetBirdDropped()
    S.bird_dropped = { [0] = false, [1] = false, [2] = false }
end

local function markEggDropTarget(eggData, birdId)
    local index = birdId ~= nil and S.birdDropTarget[birdId] or nil
    if not index then
        local eggX = readRamI16(eggData + EGG_DATA_DROP_X) * 2
        local eggY = readRamI16(eggData + EGG_DATA_DROP_Y) * 2
        local pathTable = getDropTargetPathTable()
        if isKusegPtr(pathTable) then
            for i = DROP_TARGET_FIRST, DROP_TARGET_LAST do
                local target = readDropTargetEntry(pathTable, i)
                if target.x == eggX and target.y == eggY then
                    index = i
                    break
                end
            end
        end
    end
    if index then
        S.eggedDropTargets[index] = true
    end
end

local function onDropLocationSelected()
    local regs = PCSX.getRegisters().GPR.n
    local birdAddr = regs.s2
    local spawnLoc = regs.s0
    cacheVultureMoby(birdAddr, regs.s4)
    local color = birdColorFromAddr(birdAddr)
    local birdId = BIRDS[birdAddr]
    if color and spawnLoc >= DROP_TARGET_FIRST and spawnLoc <= DROP_TARGET_LAST then
        S.claimedDropTargets[spawnLoc] = color
    end
    if birdId ~= nil and spawnLoc >= DROP_TARGET_FIRST and spawnLoc <= DROP_TARGET_LAST then
        S.birdDropTarget[birdId] = spawnLoc
    end
    S.bird_count = S.bird_count + 1
    local birdLabel = birdLabelFromAddr(birdAddr)
    local frame = PCSX.Movie.getFrame()
    print(string.format(
        "drop target: bird=%s location=%d frame=%d",
        birdLabel, spawnLoc, frame
    ))
    return true
end

local function registerDropLocationBreakpoint()
    S.dropLocationBp = PCSX.addBreakpoint(DROP_LOCATION_BP, 'Exec', 4, '', onDropLocationSelected, 'gulp drop location')
end

local restartPlayback, startPlayback

startPlayback = function()
    print(string.format("RNG loop starting (simulation count: %d)", S.simulation_count))
    S.bird_count = 0
    S.egg_count = 0
    S.mobyByVultureData = {}
    S.fixedMapBounds = nil
    S.claimedDropTargets = {}
    S.birdDropTarget = {}
    S.eggedDropTargets = {}
    resetBirdDropped()
    S.patchRngOnLoad = true
    local ok
    if not S.movieReady then
        ok = PCSX.Movie.play(MOVIE)
        S.movieReady = ok
    else
        ok = PCSX.Movie.play()
    end
    if not ok then
        printError("Movie.play failed: " .. MOVIE)
        stopLoop()
    else
        S.wasPlaying = true
    end
end

restartPlayback = function(reason)
    S.wasPlaying = false
    PCSX.Movie.stop()
    print(reason)
    S.simulation_count = S.simulation_count + 1
    PCSX.nextTick(startPlayback)
end

local function onEggSpawned()
    local regs = PCSX.getRegisters().GPR.n
    local birdAddr = regs.s2
    cacheVultureMoby(birdAddr, regs.s4)
    local randomDelay = regs.v0
    local eggData = regs.s1
    local hatchTimer = readRam16(eggData + 0xa)
    local dropId = readRam16(eggData + 0xc)
    local dropLabel = DROP_IDS[dropId] or string.format("0x%03x", dropId)
    local birdId = BIRDS[birdAddr]
    if birdId ~= nil then
        S.bird_dropped[birdId] = true
    end
    markEggDropTarget(eggData, birdId)
    S.egg_count = S.egg_count + 1
    local frame = PCSX.Movie.getFrame()
    print(string.format(
        "egg spawn: bird=%s random_delay=%d hatch_timer=%d drop=%s frame=%d",
        birdLabelFromAddr(birdAddr), randomDelay, hatchTimer, dropLabel, frame
    ))
    if S.egg_count == S.bird_count then
        restartPlayback("All tracked birds spawned eggs - reloading")
    end
    return true
end

local function registerEggSpawnBreakpoint()
    S.eggBp = PCSX.addBreakpoint(EGG_SPAWN_BP, 'Exec', 4, '', onEggSpawned, 'gulp egg spawn')
end

local function registerListeners()
    S.listeners[#S.listeners + 1] = PCSX.Events.createEventListener("ExecutionFlow::SaveStateLoaded", function()
        applyRenderPatch()
        if S.patchRngOnLoad then
            patchRng()
            S.patchRngOnLoad = false
        end
    end)

    S.listeners[#S.listeners + 1] = PCSX.Events.createEventListener("Movie::PlaybackFinished", function()
        if not S.loopActive or not S.wasPlaying then return end
        restartPlayback("Movie finished, restarting...")
    end)

    S.listeners[#S.listeners + 1] = PCSX.Events.createEventListener("ExecutionFlow::Reset", function(event)
        if not S.loopActive then return end
        stopLoop(event.hard and "Hard reset, RNG loop stopped" or "Soft reset, RNG loop stopped")
    end)

    S.listeners[#S.listeners + 1] = PCSX.Events.createEventListener("ExecutionFlow::Pause", function(event)
        if not S.loopActive or not event.exception then return end
        stopLoop("Emulation exception, RNG loop stopped")
    end)
end

local function main()
    teardown()
    PCSX.Movie.stop()
    S.wasPlaying = false
    S.loopActive = true
    registerMapUi()
    registerListeners()
    registerDropLocationBreakpoint()
    registerEggSpawnBreakpoint()
    applyRenderPatch()
    print(string.format(
        "RNG movie loop starting: %s (render %s)",
        MOVIE,
        DISABLE_RENDER and "draw skipped, vsync kept" or "enabled"
    ))
    startPlayback()
end

S.main = main
main()
