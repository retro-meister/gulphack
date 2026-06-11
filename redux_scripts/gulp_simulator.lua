local MOVIE = "/Users/retro/repos/pcsx-redux/movies/gulp_phase1.pcsxmv"
local RNG_ADDR = 0x8006d144
local RENDER_PATCH_SITES = {
    { addr = 0x80011afc, vanilla = 0x0c0055bf, patch = 0x00000000 },
}

local MOBY_POS_X = 0x0c
local MOBY_POS_Y = 0x10
local MOBY_POS_Z = 0x14
local MOBY_YAW = 0x46

local SIN_TABLE_ADDR = 0x80061bd8
local CAMERA_POSITION_ADDR = 0x80067eac
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
local SPYRO_COLOR = 0xFFAA00FF

local GULP_ADDR = 0x801169a0
local GULP_COLOR = 0xFF00FF00

local CAM_COLOR = 0xFF00FFFF

local EGG_DATA_DROP_X = 0x04
local EGG_DATA_DROP_Y = 0x06
local EGG_DATA_HATCH_TIMER = 0x0a
local EGG_DATA_DROP_ID = 0x0c
local EGG_OUTLINE_COLOR = 0xFF4488FF

local BIRDS = {
    { moby = 0x80116a50, data = 0x80120e44, id = 0, color = 0xFF0000FF, forceDrop = 7 },
    { moby = 0x801169f8, data = 0x80120c64, id = 1, color = 0xFF00FF00, forceDrop = 5 },
    { moby = 0x80116b00, data = 0x80120e88, id = 2, color = 0xFFFF0000 },
}

local BIRDS_BY_DATA = {}
for _, bird in ipairs(BIRDS) do
    BIRDS_BY_DATA[bird.data] = bird
end

local MAP = {
    worldMinX = -2800,
    worldMaxX = 2800,
    worldMinY = -2800,
    worldMaxY = 2800,
    autoFit = true,
    rotateWithCamera = true,
    disableRender = false,
    scale = 1.2,
    sprite = nil,
}
local VULTURE_MAP_MIN_Z = 20000
local DROP_TARGET_ROLL_BP = 0x80077498
local DROP_LOCATION_BP = 0x80077448
local EGG_SPAWN_BP = 0x80077a48

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
    breakpoints = {},
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
    for _, site in ipairs(RENDER_PATCH_SITES) do
        writeRam32(site.addr, enabled and site.patch or site.vanilla)
    end
end

local function readMobyXYZ(addr, posX, posY, posZ)
    posX = posX or MOBY_POS_X
    posY = posY or MOBY_POS_Y
    posZ = posZ or MOBY_POS_Z
    return readRam32s(addr + posX), readRam32s(addr + posY), readRam32s(addr + posZ)
end

local function readMobyXY(addr, posX, posY)
    posX = posX or MOBY_POS_X
    posY = posY or MOBY_POS_Y
    return readRam32s(addr + posX), readRam32s(addr + posY)
end

local function readMobyYaw(addr, yawOff)
    return readRam8(addr + (yawOff or MOBY_YAW))
end

local function collectBirdPositions()
    local birds = {}
    for _, bird in ipairs(BIRDS) do
        local x, y, z = readMobyXYZ(bird.moby)
        birds[#birds + 1] = {
            id = bird.id,
            color = bird.color,
            x = x,
            y = y,
            z = z,
            yaw = readMobyYaw(bird.moby),
        }
    end
    return birds
end

local function getDropTargetPathTable()
    local pathTable = readRam32(BIRDS[1].data + GULP_VULTURE_PATH_TABLE)
    if pathTable == 0 then
        return nil
    end
    return pathTable
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
    if not pathTable then
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

local function readCameraYaw256()
    return bit.band(bit.rshift(readRam16(CAM_YAW_ADDR), 4), 0xff)
end

local function mapCameraRotationYaw256()
    return bit.band(0x40 - readCameraYaw256(), 0xff)
end

local function readVec3(addr)
    return readRam32s(addr), readRam32s(addr + 4), readRam32s(addr + 8)
end

local function readCameraPos()
    return readVec3(CAMERA_POSITION_ADDR)
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

local function drawMapArrowAtWorld(ctx, x, y, yaw, color, size, label)
    local sx, sy = mapWorldToScreen(x, y, ctx)
    local dirX, dirY = yawToWorldDir(yaw)
    drawMapArrow(sx, sy, dirX, dirY, color, size, label, ctx)
end

local function drawMapMoby(ctx, addr, color, size, label, yawOff, posX, posY)
    local x, y = readMobyXY(addr, posX, posY)
    drawMapArrowAtWorld(ctx, x, y, readMobyYaw(addr, yawOff), color, size, label)
end

local function drawMapCamera(ctx)
    local x, y = readCameraPos()
    drawMapArrowAtWorld(ctx, x, y, readCameraYaw256(), CAM_COLOR, 16, nil)
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
            drawMapArrowAtWorld(ctx, bird.x, bird.y, bird.yaw or 0, bird.color, 14, tostring(bird.id))
        end
    end
end

local function drawGulpMapFrame()
    if not S.loopActive then
        return
    end
    imgui.SetNextWindowSize(480, 520, imgui.constant.Cond.FirstUseEver)
    imgui.safe.Begin('Gulp map', true, function()
        local cw, ch = imgui.GetContentRegionAvail()
        local optionsH = imgui.GetFrameHeightWithSpacing()
        local mapH = ch - optionsH - 4
        if cw < 32 or mapH < 32 then
            return
        end
        local cx, cy = imgui.GetCursorScreenPos()
        imgui.InvisibleButton('gulp_map_canvas', cw, mapH)
        local birds = collectBirdPositions()
        local dropHome, dropTargets = collectDropTargets()
        local minX, minY, maxX, maxY = getMapBounds(dropHome, dropTargets)
        local spyroX, spyroY, spyroZ = readMobyXYZ(SPYRO_ADDR, 0x00, 0x04, 0x08)
        local mapCtx = createMapRenderCtx(minX, minY, maxX, maxY, cx, cy, cw, mapH, spyroX, spyroY)
        drawMapBackground(cx, cy, cw, mapH)
        drawMapDropTargets(dropHome, dropTargets, mapCtx)
        drawMapMarkers(birds, mapCtx)
        drawMapMoby(mapCtx, GULP_ADDR, GULP_COLOR, 18, nil)
        drawMapMoby(mapCtx, SPYRO_ADDR, SPYRO_COLOR, 16, nil, 0x0e, 0x00, 0x04)
        drawMapCamera(mapCtx)
        local renderChanged
        _, MAP.rotateWithCamera = imgui.Checkbox('Rotate with camera', MAP.rotateWithCamera)
        imgui.SameLine()
        renderChanged, MAP.disableRender = imgui.Checkbox('Disable render', MAP.disableRender)
        if renderChanged then
            setRenderPatch(MAP.disableRender)
        end
        local gulpX, gulpY, gulpZ = readMobyXYZ(GULP_ADDR)
        imgui.TextUnformatted(string.format('spyro: x=%d y=%d z=%d', spyroX, spyroY, spyroZ))
        imgui.TextUnformatted(string.format('gulp: x=%d y=%d z=%d', gulpX, gulpY, gulpZ))
        for _, bird in ipairs(birds) do
            imgui.TextUnformatted(string.format('bird %d: x=%d y=%d z=%d', bird.id, bird.x, bird.y, bird.z))
        end
    end)
end

local function registerMapUi()
    DrawImguiFrame = drawGulpMapFrame
end

local function applyRenderPatch()
    if MAP.disableRender then
        setRenderPatch(true)
    end
end

local function restoreRenderPatch()
    setRenderPatch(false)
end

local function patchRng()
    local state = randomRngState()
    writeRam32(RNG_ADDR, state)
    print(string.format("RNG @ 0x%08x set to 0x%08x", RNG_ADDR, state))
end

local function resetRunState()
    S.bird_count = 0
    S.egg_count = 0
    S.fixedMapBounds = nil
    S.claimedDropTargets = {}
    S.birdDropTarget = {}
    S.eggedDropTargets = {}
    S.bird_dropped = { [0] = false, [1] = false, [2] = false }
end

local function teardown()
    restoreRenderPatch()
    for _, bp in ipairs(S.breakpoints) do
        bp:remove()
    end
    S.breakpoints = {}
    for _, listener in ipairs(S.listeners) do
        listener:remove()
    end
    S.listeners = {}
    resetRunState()
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

local function birdLabelFromData(dataAddr)
    local bird = BIRDS_BY_DATA[dataAddr]
    return bird and tostring(bird.id) or string.format("unknown(0x%08x)", dataAddr)
end

local function markEggDropTarget(eggData, birdId)
    local index = birdId ~= nil and S.birdDropTarget[birdId] or nil
    if not index then
        local eggX = readRamI16(eggData + EGG_DATA_DROP_X) * 2
        local eggY = readRamI16(eggData + EGG_DATA_DROP_Y) * 2
        local pathTable = getDropTargetPathTable()
        if pathTable then
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

local function isDropTargetIndex(index)
    return index >= DROP_TARGET_FIRST and index <= DROP_TARGET_LAST
end

local function applyForcedDropRoll(regs, bird)
    local naturalRoll = regs.v0
    local forced = bird and bird.forceDrop
    if forced == nil then
        return naturalRoll, naturalRoll
    end
    if not isDropTargetIndex(forced) then
        print(string.format("ignored invalid forceDrop %d for bird %d", forced, bird.id))
        return naturalRoll, naturalRoll
    end
    regs.v0 = forced
    return forced, naturalRoll
end

local function onDropTargetRoll()
    local regs = PCSX.getRegisters().GPR.n
    local birdData = regs.s2
    local bird = BIRDS_BY_DATA[birdData]
    local roll, naturalRoll = applyForcedDropRoll(regs, bird)
    local birdLabel = birdLabelFromData(birdData)
    local frame = PCSX.Movie.getFrame()
    if roll ~= naturalRoll then
        print(string.format(
            "drop roll: bird=%s roll=%d (forced from %d) frame=%d",
            birdLabel, roll, naturalRoll, frame
        ))
    else
        print(string.format(
            "drop roll: bird=%s roll=%d frame=%d",
            birdLabel, roll, frame
        ))
    end
    return true
end

local function onDropLocationSelected()
    local regs = PCSX.getRegisters().GPR.n
    local birdData = regs.s2
    local spawnLoc = regs.s0
    local bird = BIRDS_BY_DATA[birdData]
    if bird and isDropTargetIndex(spawnLoc) then
        S.claimedDropTargets[spawnLoc] = bird.color
        S.birdDropTarget[bird.id] = spawnLoc
    end
    S.bird_count = S.bird_count + 1
    local birdLabel = birdLabelFromData(birdData)
    local frame = PCSX.Movie.getFrame()
    print(string.format(
        "drop target: bird=%s location=%d frame=%d",
        birdLabel, spawnLoc, frame
    ))
    return true
end

local restartPlayback, startPlayback

startPlayback = function()
    print(string.format("RNG loop starting (simulation count: %d)", S.simulation_count))
    resetRunState()
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
    local birdData = regs.s2
    local randomDelay = regs.v0
    local eggData = regs.s1
    local hatchTimer = readRam16(eggData + EGG_DATA_HATCH_TIMER)
    local dropId = readRam16(eggData + EGG_DATA_DROP_ID)
    local dropLabel = DROP_IDS[dropId] or string.format("0x%03x", dropId)
    local bird = BIRDS_BY_DATA[birdData]
    if bird then
        S.bird_dropped[bird.id] = true
    end
    markEggDropTarget(eggData, bird and bird.id)
    S.egg_count = S.egg_count + 1
    local frame = PCSX.Movie.getFrame()
    print(string.format(
        "egg spawn: bird=%s random_delay=%d hatch_timer=%d drop=%s frame=%d",
        birdLabelFromData(birdData), randomDelay, hatchTimer, dropLabel, frame
    ))
    if S.egg_count == S.bird_count then
        restartPlayback("All tracked birds spawned eggs - reloading")
    end
    return true
end

local function registerBreakpoints()
    S.breakpoints = {
        PCSX.addBreakpoint(DROP_TARGET_ROLL_BP, 'Exec', 4, '', onDropTargetRoll, 'gulp drop target roll'),
        PCSX.addBreakpoint(DROP_LOCATION_BP, 'Exec', 4, '', onDropLocationSelected, 'gulp drop location'),
        PCSX.addBreakpoint(EGG_SPAWN_BP, 'Exec', 4, '', onEggSpawned, 'gulp egg spawn'),
    }
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
    registerBreakpoints()
    applyRenderPatch()
    print(string.format(
        "RNG movie loop starting: %s (render %s)",
        MOVIE,
        MAP.disableRender and "disabled" or "enabled"
    ))
    startPlayback()
end

S.main = main
main()
