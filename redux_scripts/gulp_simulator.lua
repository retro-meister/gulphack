local CYCLE_COUNT = 4
local MOVIE_DIR = "/Users/retro/repos/pcsx-redux/movies"
local MOVIES_MOVE = {
    MOVIE_DIR .. "/gulp_phase1.pcsxmv",
    MOVIE_DIR .. "/gulp_phase2.pcsxmv",
    MOVIE_DIR .. "/gulp_phase3.pcsxmv",
    MOVIE_DIR .. "/gulp_phase4.pcsxmv",
}
local MOVIES_NOMOVE = {
    MOVIE_DIR .. "/gulp_phase1_nomove.pcsxmv",
    MOVIE_DIR .. "/gulp_phase2_nomove.pcsxmv",
    MOVIE_DIR .. "/gulp_phase3_nomove.pcsxmv",
    MOVIE_DIR .. "/gulp_phase4_nomove.pcsxmv",
}
local USE_MOVE_MOVIES = true
local AUTO_ADVANCE_CYCLE = false
local AUTO_RESTART_PLAYBACK = true
local RUN_SIMULATIONS = true

local function clampCycle(cycle)
    if cycle < 1 then
        return 1
    end
    if cycle > CYCLE_COUNT then
        return CYCLE_COUNT
    end
    return cycle
end

local RNG_ADDR = 0x8006d144
local RENDER_PATCH_SITES = {
    { addr = 0x80011afc, vanilla = 0x0c0055bf, patch = 0x00000000 },
}
local HEALTH_PATCH_SITES = {
    { addr = 0x8002b118, vanilla = 0x2482ffff, patch = 0x24820000 },
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

local function clampForceDrop(value)
    if value <= 0 then
        return nil
    end
    if value < DROP_TARGET_FIRST then
        return DROP_TARGET_FIRST
    end
    if value > DROP_TARGET_LAST then
        return DROP_TARGET_LAST
    end
    return value
end

local SPYRO_ADDR = 0x80069ff0
local SPYRO_COLOR = 0xFFAA00FF

local GULP_ADDR = 0x801169a0
local GULP_ISOLATE_X = 100000
local GULP_ISOLATE_Z = 10000
local GULP_COLOR = 0xFF00FF00

local CAM_COLOR = 0xFF00FFFF

local EGG_DATA_DROP_X = 0x04
local EGG_DATA_DROP_Y = 0x06
local EGG_DATA_HATCH_TIMER = 0x0a
local EGG_DATA_DROP_ID = 0x0c
local EGG_OUTLINE_COLOR = 0xFF4488FF

local BARREL = "barrel"
local BOMB = "bomb"
local ROCKET = "rocket"

local BIRD_DEFS = {
    { moby = 0x80116a50, data = 0x80120e44, id = 0, color = 0xFF0000FF },
    { moby = 0x801169f8, data = 0x80120c64, id = 1, color = 0xFF00FF00 },
    { moby = 0x80116b00, data = 0x80120e88, id = 2, color = 0xFFFF0000 },
}

local CYCLE_BIRD_PRESETS = {
    {
        { forceDrop = 7, forceWeapon = nil },
        { forceDrop = 5, forceWeapon = nil },
        { forceDrop = nil, forceWeapon = nil },
    },
    {
        { forceDrop = 1, forceWeapon = nil },
        { forceDrop = 14, forceWeapon = nil },
        { forceDrop = nil, forceWeapon = nil },
    },
    {
        { forceDrop = 15, forceWeapon = BARREL },
        { forceDrop = 6, forceWeapon = BOMB },
        { forceDrop = 16, forceWeapon = ROCKET },
    },
    {
        { forceDrop = 25, forceWeapon = ROCKET },
        { forceDrop = 10, forceWeapon = ROCKET },
        { forceDrop = 11, forceWeapon = ROCKET },
    },
}

local BIRDS = {}
for i, def in ipairs(BIRD_DEFS) do
    BIRDS[i] = {
        moby = def.moby,
        data = def.data,
        id = def.id,
        color = def.color,
        forceDrop = nil,
        forceWeapon = nil,
    }
end

local function applyCycleBirdPreset(cycle)
    local preset = CYCLE_BIRD_PRESETS[clampCycle(cycle)]
    if not preset then
        return
    end
    for i, bird in ipairs(BIRDS) do
        local p = preset[i]
        if p then
            if p.forceDrop == nil or p.forceDrop <= 0 then
                bird.forceDrop = nil
            else
                bird.forceDrop = clampForceDrop(p.forceDrop)
            end
            bird.forceWeapon = p.forceWeapon
        end
    end
    print(string.format("Applied bird force preset for cycle %d", clampCycle(cycle)))
end

local function clearBirdForces()
    for _, bird in ipairs(BIRDS) do
        bird.forceDrop = nil
        bird.forceWeapon = nil
    end
    print("Cleared all bird force drops and weapons")
end

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
    isolateGulp = true,
    infiniteHealth = true,
    autoRestartPlayback = true,
    runSimulations = true,
    useMoveMovies = true,
    scale = 1.2,
    sprite = nil,
}

local function movieForCycle(cycle)
    local movies = MAP.useMoveMovies and MOVIES_MOVE or MOVIES_NOMOVE
    return movies[cycle]
end

local VULTURE_MAP_MIN_Z = 20000
local UPDATE_GAME_BP = 0x80011af4
local DROP_TARGET_ROLL_BP = 0x80077498
local DROP_WEAPON_FORCE_BP = 0x800779c4
local DROP_LOCATION_BP = 0x80077448
local VULTURE_RESET_BP = 0x8007742c
local EGG_SPAWN_BP = 0x80077a48
local EGG_HATCH_BP = 0x800781e0

local DROP_IDS = {
    [0x196] = "BARREL",
    [0x197] = "BOMB",
    [0x198] = "ROCKET",
}

local WEAPON_FORCE_MOBY = {
    barrel = 0x196,
    bomb = 0x197,
    rocket = 0x198,
}
local WEAPON_FORCE_KEYS = { 'none', 'barrel', 'bomb', 'rocket' }
local WEAPON_FORCE_COMBO_ITEMS = 'None\0Barrel\0Bomb\0Rocket\0'

local function weaponForceKeyToComboIndex(forceWeapon)
    local lookup = forceWeapon or 'none'
    for i, key in ipairs(WEAPON_FORCE_KEYS) do
        if key == lookup then
            return i - 1
        end
    end
    return 0
end

local function weaponForceComboIndexToKey(comboIndex)
    local key = WEAPON_FORCE_KEYS[comboIndex + 1] or 'none'
    if key == 'none' then
        return nil
    end
    return key
end

local CSV_PATH = "/Users/retro/repos/pcsx-redux/gulp_sweep.csv"
local CSV_HEADER = table.concat({
    "sim_index", "cycle", "perm_index", "rng_seed",
    "bird0_drop", "bird1_drop", "bird2_drop",
    "bird0_weapon", "bird1_weapon", "bird2_weapon",
    "bird0_egg_spawn_frame", "bird1_egg_spawn_frame", "bird2_egg_spawn_frame",
    "bird0_hatch_timer", "bird1_hatch_timer", "bird2_hatch_timer",
    "bird0_hatch_frame", "bird1_hatch_frame", "bird2_hatch_frame",
    "eggs_dropped", "eggs_hatched", "cycle_complete_frame",
    "bird0_egg_x", "bird1_egg_x", "bird2_egg_x",
    "bird0_egg_y", "bird1_egg_y", "bird2_egg_y",
    "bird0_egg_z", "bird1_egg_z", "bird2_egg_z",
    "bird0_spawn_dist", "bird1_spawn_dist", "bird2_spawn_dist",
}, ",")

local MOBY_TO_WEAPON = {
    [0x196] = "barrel",
    [0x197] = "bomb",
    [0x198] = "rocket",
    [0x1bf] = "chicken",
}

local PERM_CACHE = {}

local function getActiveBirdCount(cycle)
    return cycle <= 2 and 2 or 3
end

local function buildPermutationTable(count)
    local result = {}
    local positions = {}
    for i = DROP_TARGET_FIRST, DROP_TARGET_LAST do
        positions[#positions + 1] = i
    end
    local function rec(prefix, available)
        if #prefix == count then
            local tuple = {}
            for j = 1, count do
                tuple[j] = prefix[j]
            end
            result[#result + 1] = tuple
            return
        end
        for i, pos in ipairs(available) do
            local nextAvail = {}
            for j, v in ipairs(available) do
                if j ~= i then
                    nextAvail[#nextAvail + 1] = v
                end
            end
            prefix[#prefix + 1] = pos
            rec(prefix, nextAvail)
            prefix[#prefix] = nil
        end
    end
    rec({}, positions)
    return result
end

local function getPermTable(cycle)
    local k = getActiveBirdCount(cycle)
    if not PERM_CACHE[k] then
        PERM_CACHE[k] = buildPermutationTable(k)
    end
    return PERM_CACHE[k]
end

local function permCountForCycle(cycle)
    return #getPermTable(cycle)
end

local function csvField(value)
    if value == nil or value == "" then
        return ""
    end
    local s = tostring(value)
    if s:find('[,"\n]') then
        return '"' .. s:gsub('"', '""') .. '"'
    end
    return s
end

local function ensureCsvHeader()
    local f = io.open(CSV_PATH, "r")
    if f then
        local first = f:read("*l")
        f:close()
        if first and first ~= "" then
            return true
        end
    end
    f = io.open(CSV_PATH, "w")
    if not f then
        return false, string.format("failed to create CSV: %s", CSV_PATH)
    end
    f:write(CSV_HEADER, "\n")
    f:close()
    return true
end

local function scanCsvResume(cycle)
    local maxSimIndex = -1
    local maxPermIndex = -1
    local f = io.open(CSV_PATH, "r")
    if not f then
        return maxPermIndex, maxSimIndex
    end
    local header = f:read("*l")
    if not header then
        f:close()
        return maxPermIndex, maxSimIndex
    end
    for line in f:lines() do
        local simIndex, lineCycle, permIndex = line:match("^(%d+),(%d+),(%d+),")
        simIndex = tonumber(simIndex)
        lineCycle = tonumber(lineCycle)
        permIndex = tonumber(permIndex)
        if simIndex and simIndex > maxSimIndex then
            maxSimIndex = simIndex
        end
        if lineCycle == cycle and permIndex and permIndex > maxPermIndex then
            maxPermIndex = permIndex
        end
    end
    f:close()
    return maxPermIndex, maxSimIndex
end

local function appendCsvLine(fields)
    local f = io.open(CSV_PATH, "a")
    if not f then
        return false, string.format("failed to append CSV: %s", CSV_PATH)
    end
    local parts = {}
    for i = 1, #fields do
        parts[i] = csvField(fields[i])
    end
    f:write(table.concat(parts, ","), "\n")
    f:close()
    return true
end

local function mobyIdToWeapon(mobyId)
    return MOBY_TO_WEAPON[mobyId] or string.format("0x%03x", mobyId)
end

local function birdRecordField(record, birdId)
    local value = record[birdId]
    if value == nil then
        return ""
    end
    return value
end

local function newRunRecord()
    return {
        drops = {},
        drop_frames = {},
        weapons = {},
        egg_spawn_frames = {},
        hatch_timers = {},
        hatch_frames = {},
        egg_x = {},
        egg_y = {},
        egg_z = {},
        spawn_dist = {},
        cycle_complete_frame = nil,
    }
end

_G.GulpRngLoop = _G.GulpRngLoop or {
    listeners = {},
    loopActive = false,
    patchRngOnLoad = false,
    activeCycle = 1,
    loadedMoviePath = nil,
    bird_count = 0,
    egg_count = 0,
    egg_hatch_count = 0,
    bird_dropped = { [0] = false, [1] = false, [2] = false },
    gameFrame = 0,
    forceDropBreakpoint = nil,
    forceWeaponBreakpoint = nil,
    gameFrameBreakpoint = nil,
    breakpoints = {},
    fixedMapBounds = nil,
    claimedDropTargets = {},
    birdDropTarget = {},
    eggedDropTargets = {},
    eggDataToBird = {},
    simulation_count = 0,
    cycle_spawned = {},
    cycle_egg = {},
    cycle_despawned = {},
    despawn_count = 0,
    bird_despawn_count = {},
    sweepActive = false,
    perm_index = 0,
    perm_count = 0,
    sim_index = 0,
    lastRngSeed = 0,
    runRecord = nil,
    sweepStatusText = "",
    mapWindowOpen = true,
    sweepRecording = false,
    sweepPrevRunSimulations = false,
}

local S = _G.GulpRngLoop

MAP.autoRestartPlayback = AUTO_RESTART_PLAYBACK
MAP.runSimulations = RUN_SIMULATIONS
MAP.useMoveMovies = USE_MOVE_MOVIES
MAP.autoAdvanceCycle = AUTO_ADVANCE_CYCLE
S.activeCycle = clampCycle(S.activeCycle or 1)

S.egg_count = S.egg_count or 0
S.egg_hatch_count = S.egg_hatch_count or 0
if not S.bird_dropped then
    S.bird_dropped = { [0] = false, [1] = false, [2] = false }
end
if not S.birdDropTarget then
    S.birdDropTarget = {}
end
if not S.eggedDropTargets then
    S.eggedDropTargets = {}
end
if not S.eggDataToBird then
    S.eggDataToBird = {}
end
if not S.cycle_spawned then
    S.cycle_spawned = {}
end
if not S.cycle_egg then
    S.cycle_egg = {}
end
if not S.cycle_despawned then
    S.cycle_despawned = {}
end
if not S.bird_despawn_count then
    S.bird_despawn_count = {}
end
S.despawn_count = S.despawn_count or 0
S.simulation_count = S.simulation_count or S.reset_count or 0
S.gameFrame = S.gameFrame or 0
S.sweepActive = S.sweepActive or false
S.perm_index = S.perm_index or 0
S.perm_count = S.perm_count or 0
S.sim_index = S.sim_index or 0
S.lastRngSeed = S.lastRngSeed or 0
S.sweepStatusText = S.sweepStatusText or ""
if S.mapWindowOpen == nil then
    S.mapWindowOpen = true
end
S.sweepRecording = S.sweepRecording or false
S.sweepPrevRunSimulations = S.sweepPrevRunSimulations or false
if not S.runRecord then
    S.runRecord = newRunRecord()
end

local function updateSweepStatus()
    if not S.sweepActive then
        return
    end
    S.sweepStatusText = string.format(
        "Sweeping cycle %d: %d / %d",
        S.activeCycle,
        S.perm_index + 1,
        S.perm_count
    )
end

local function getGameFrame()
    return S.gameFrame
end

local function logSim(msg)
    if not S.sweepActive then
        print(msg)
    end
end

local function applyPermutation(cycle, permIndex)
    applyCycleBirdPreset(cycle)
    local perm = getPermTable(cycle)[permIndex + 1]
    if not perm then
        return false
    end
    local activeCount = getActiveBirdCount(cycle)
    for i, bird in ipairs(BIRDS) do
        if i <= activeCount then
            bird.forceDrop = perm[i]
        else
            bird.forceDrop = nil
        end
    end
    return true
end

local function flushCsvRow()
    local ok, err = ensureCsvHeader()
    if not ok then
        print(err)
        return false
    end
    local perm = getPermTable(S.activeCycle)[S.perm_index + 1]
    local rr = S.runRecord or newRunRecord()
    S.sim_index = S.sim_index + 1
    local fields = {
        S.sim_index,
        S.activeCycle,
        S.perm_index,
        string.format("0x%08x", S.lastRngSeed or 0),
        perm and perm[1] or birdRecordField(rr.drops, 0),
        perm and perm[2] or birdRecordField(rr.drops, 1),
        perm and perm[3] or birdRecordField(rr.drops, 2),
        birdRecordField(rr.weapons, 0),
        birdRecordField(rr.weapons, 1),
        birdRecordField(rr.weapons, 2),
        birdRecordField(rr.egg_spawn_frames, 0),
        birdRecordField(rr.egg_spawn_frames, 1),
        birdRecordField(rr.egg_spawn_frames, 2),
        birdRecordField(rr.hatch_timers, 0),
        birdRecordField(rr.hatch_timers, 1),
        birdRecordField(rr.hatch_timers, 2),
        birdRecordField(rr.hatch_frames, 0),
        birdRecordField(rr.hatch_frames, 1),
        birdRecordField(rr.hatch_frames, 2),
        S.egg_count,
        S.egg_hatch_count,
        rr.cycle_complete_frame or "",
        birdRecordField(rr.egg_x, 0),
        birdRecordField(rr.egg_x, 1),
        birdRecordField(rr.egg_x, 2),
        birdRecordField(rr.egg_y, 0),
        birdRecordField(rr.egg_y, 1),
        birdRecordField(rr.egg_y, 2),
        birdRecordField(rr.egg_z, 0),
        birdRecordField(rr.egg_z, 1),
        birdRecordField(rr.egg_z, 2),
        birdRecordField(rr.spawn_dist, 0),
        birdRecordField(rr.spawn_dist, 1),
        birdRecordField(rr.spawn_dist, 2),
    }
    ok, err = appendCsvLine(fields)
    if not ok then
        print(err)
        return false
    end
    return true
end

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

local function setHealthPatch(enabled)
    for _, site in ipairs(HEALTH_PATCH_SITES) do
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

local function dist2d(x1, y1, x2, y2)
    local dx = x1 - x2
    local dy = y1 - y2
    return math.floor(math.sqrt(dx * dx + dy * dy) + 0.5)
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

local switchActiveCycle
local reloadActiveMovie
local restartPlayback, startPlayback
local startSimulations, stopSimulations
local startCsvSweep, finishCsvSweep, cancelCsvSweep
local registerForceBreakpoints
local registerSimulationBreakpoints
local unregisterForceBreakpoints
local unregisterSimulationBreakpoints

local function drawGulpMapFrame()
    if not S.loopActive then
        return
    end
    imgui.SetNextWindowSize(480, 520, imgui.constant.Cond.FirstUseEver)
    imgui.safe.Begin('Gulp map', S.mapWindowOpen, function()
        local cw, ch = imgui.GetContentRegionAvail()
        local uiSeparators = 5
        local optionsH = imgui.GetFrameHeightWithSpacing() * (8 + #BIRDS)
            + imgui.GetFrameHeightWithSpacing() * 0.5 * uiSeparators
        local mapH = ch - optionsH - 4
        if cw < 32 then
            return
        end
        if mapH < 32 then
            mapH = 32
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
        imgui.SetCursorScreenPos(cx, cy + mapH + 4)
        local simChanged
        if S.sweepActive then
            imgui.BeginDisabled(true)
        end
        simChanged, MAP.runSimulations = imgui.Checkbox('Run simulations', MAP.runSimulations)
        if S.sweepActive then
            imgui.EndDisabled()
        end
        if simChanged and not S.sweepActive then
            if MAP.runSimulations then
                startSimulations()
            else
                stopSimulations()
            end
        end
        imgui.SameLine()
        if S.sweepActive then
            imgui.BeginDisabled(true)
        end
        local prevCycle = S.activeCycle
        imgui.AlignTextToFramePadding()
        imgui.TextUnformatted('Cycle')
        imgui.SameLine()
        local cycleTextW = imgui.CalcTextSize('4')
        imgui.SetNextItemWidth(cycleTextW + imgui.GetFrameHeight() * 2.75)
        local cycleChanged
        cycleChanged, S.activeCycle = imgui.InputInt('##gulp_cycle', S.activeCycle, 1, 1)
        S.activeCycle = clampCycle(S.activeCycle)
        if cycleChanged and S.activeCycle ~= prevCycle and not S.sweepActive then
            switchActiveCycle(S.activeCycle)
        end
        imgui.SameLine()
        if imgui.Button('Load cycle preset') then
            applyCycleBirdPreset(S.activeCycle)
        end
        imgui.SameLine()
        if imgui.Button('Clear forces') then
            clearBirdForces()
        end
        if S.sweepActive then
            imgui.EndDisabled()
        end
        imgui.SameLine()
        if S.sweepActive then
            imgui.BeginDisabled(true)
        end
        if imgui.Button('Write CSV') then
            PCSX.nextTick(startCsvSweep)
        end
        if S.sweepActive then
            imgui.EndDisabled()
        end
        imgui.SameLine()
        if not S.sweepActive then
            imgui.BeginDisabled(true)
        end
        if imgui.Button('Cancel CSV') then
            PCSX.nextTick(cancelCsvSweep)
        end
        if not S.sweepActive then
            imgui.EndDisabled()
        end
        imgui.SameLine()
        if S.sweepActive then
            imgui.BeginDisabled(true)
        end
        local moveMoviesChanged
        moveMoviesChanged, MAP.useMoveMovies = imgui.Checkbox('Move', MAP.useMoveMovies)
        if moveMoviesChanged and not S.sweepActive then
            reloadActiveMovie()
        end
        imgui.SameLine()
        local autoAdvanceChanged
        autoAdvanceChanged, MAP.autoAdvanceCycle = imgui.Checkbox('Auto cycle', MAP.autoAdvanceCycle)
        if S.sweepActive then
            imgui.EndDisabled()
        end
        if S.sweepStatusText ~= "" then
            imgui.TextUnformatted(S.sweepStatusText)
        end
        imgui.Separator()
        if S.sweepActive then
            imgui.BeginDisabled(true)
        end
        local prevAutoRestart = MAP.autoRestartPlayback
        local autoRestartChanged
        autoRestartChanged, MAP.autoRestartPlayback = imgui.Checkbox('Auto-restart', MAP.autoRestartPlayback)
        if autoRestartChanged and MAP.autoRestartPlayback and not prevAutoRestart and S.loopActive and not S.sweepActive then
            restartPlayback("Auto-restart enabled, restarting...")
        end
        if S.sweepActive then
            imgui.EndDisabled()
        end
        imgui.SameLine()
        local renderChanged
        _, MAP.rotateWithCamera = imgui.Checkbox('Rotate with camera', MAP.rotateWithCamera)
        imgui.SameLine()
        renderChanged, MAP.disableRender = imgui.Checkbox('Disable render', MAP.disableRender)
        if renderChanged then
            setRenderPatch(MAP.disableRender)
        end
        imgui.SameLine()
        local healthChanged
        healthChanged, MAP.infiniteHealth = imgui.Checkbox('Infinite health', MAP.infiniteHealth)
        if healthChanged then
            setHealthPatch(MAP.infiniteHealth)
        end
        imgui.SameLine()
        _, MAP.isolateGulp = imgui.Checkbox('Isolate Gulp', MAP.isolateGulp)
        imgui.Separator()
        if S.sweepActive then
            imgui.BeginDisabled(true)
        end
        for i, bird in ipairs(BIRDS) do
            if i > 1 then
                imgui.SameLine()
            end
            imgui.AlignTextToFramePadding()
            imgui.TextUnformatted(string.format('bird %d loc', bird.id))
            imgui.SameLine()
            local forceTextW = imgui.CalcTextSize('25')
            imgui.SetNextItemWidth(forceTextW + imgui.GetFrameHeight() * 2.75)
            local forceUi = bird.forceDrop or 0
            local forceChanged
            forceChanged, forceUi = imgui.InputInt('##bird_force_' .. bird.id, forceUi, 1, 1)
            if forceChanged then
                bird.forceDrop = clampForceDrop(forceUi)
            end
        end
        imgui.Separator()
        for i, bird in ipairs(BIRDS) do
            if i > 1 then
                imgui.SameLine()
            end
            imgui.AlignTextToFramePadding()
            imgui.TextUnformatted(string.format('bird %d drop', bird.id))
            imgui.SameLine()
            local weaponComboW = imgui.CalcTextSize('Rocket')
            imgui.SetNextItemWidth(weaponComboW + imgui.GetFrameHeight() * 1.5)
            local weaponIndex = weaponForceKeyToComboIndex(bird.forceWeapon)
            local weaponChanged
            weaponChanged, weaponIndex = imgui.Combo(
                '##bird_weapon_' .. bird.id,
                weaponIndex,
                WEAPON_FORCE_COMBO_ITEMS
            )
            if weaponChanged then
                bird.forceWeapon = weaponForceComboIndexToKey(weaponIndex)
            end
        end
        if S.sweepActive then
            imgui.EndDisabled()
        end
        imgui.Separator()
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

local function applyHealthPatch()
    if MAP.infiniteHealth then
        setHealthPatch(true)
    end
end

local function restoreHealthPatch()
    setHealthPatch(false)
end

local function patchRng()
    local state = randomRngState()
    S.lastRngSeed = state
    writeRam32(RNG_ADDR, state)
    logSim(string.format("RNG @ 0x%08x set to 0x%08x", RNG_ADDR, state))
end

local function resetRunState()
    S.bird_count = 0
    S.egg_count = 0
    S.egg_hatch_count = 0
    S.fixedMapBounds = nil
    S.claimedDropTargets = {}
    S.birdDropTarget = {}
    S.eggedDropTargets = {}
    S.eggDataToBird = {}
    S.bird_dropped = { [0] = false, [1] = false, [2] = false }
    S.cycle_spawned = {}
    S.cycle_egg = {}
    S.cycle_despawned = {}
    S.despawn_count = 0
    S.bird_despawn_count = {}
    S.gameFrame = 0
    S.runRecord = newRunRecord()
end

local function isolateGulpPosition()
    writeRam32(GULP_ADDR + MOBY_POS_X, GULP_ISOLATE_X)
    writeRam32(GULP_ADDR + MOBY_POS_Z, GULP_ISOLATE_Z)
end

local function onUpdateGameFrame()
    S.gameFrame = S.gameFrame + 1
    if MAP.isolateGulp then
        isolateGulpPosition()
    end
    return true
end

local function teardown()
    restoreRenderPatch()
    restoreHealthPatch()
    unregisterForceBreakpoints()
    unregisterSimulationBreakpoints()
    for _, listener in ipairs(S.listeners) do
        listener:remove()
    end
    S.listeners = {}
    resetRunState()
    DrawImguiFrame = nil
end

local function stopLoop(reason)
    if S.sweepActive then
        finishCsvSweep("CSV sweep stopped (loop stopped)")
    end
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

local function cycleIds(set)
    local ids = {}
    for id, _ in pairs(set) do
        ids[#ids + 1] = tostring(id)
    end
    table.sort(ids)
    return table.concat(ids, ",")
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
        logSim(string.format("ignored invalid forceDrop %d for bird %d", forced, bird.id))
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
    local frame = getGameFrame()
    if roll ~= naturalRoll then
        logSim(string.format(
            "drop roll: bird=%s roll=%d (forced from %d) frame=%d",
            birdLabel, roll, naturalRoll, frame
        ))
    else
        logSim(string.format(
            "drop roll: bird=%s roll=%d frame=%d",
            birdLabel, roll, frame
        ))
    end
    return true
end

local function applyForcedWeaponContents(regs, bird)
    local naturalMoby = regs.v0
    local key = bird and bird.forceWeapon
    if key == nil then
        return naturalMoby, naturalMoby
    end
    local forcedMoby = WEAPON_FORCE_MOBY[key]
    if forcedMoby == nil then
        return naturalMoby, naturalMoby
    end
    regs.v0 = forcedMoby
    return forcedMoby, naturalMoby
end

local function onWeaponContentsForced()
    local regs = PCSX.getRegisters().GPR.n
    local birdData = regs.s2
    local bird = BIRDS_BY_DATA[birdData]
    local mobyId, naturalMoby = applyForcedWeaponContents(regs, bird)
    local birdLabel = birdLabelFromData(birdData)
    local frame = getGameFrame()
    if mobyId ~= naturalMoby then
        logSim(string.format(
            "weapon contents: bird=%s moby=0x%03x (forced from 0x%03x) frame=%d",
            birdLabel, mobyId, naturalMoby, frame
        ))
    else
        logSim(string.format(
            "weapon contents: bird=%s moby=0x%03x frame=%d",
            birdLabel, mobyId, frame
        ))
    end
    if bird then
        S.runRecord.weapons[bird.id] = mobyIdToWeapon(mobyId)
    end
    return true
end

local function onDropLocationSelected()
    local regs = PCSX.getRegisters().GPR.n
    local birdData = regs.s2
    local spawnLoc = regs.s0
    local bird = BIRDS_BY_DATA[birdData]
    if bird then
        S.cycle_spawned[bird.id] = true
        if isDropTargetIndex(spawnLoc) then
            S.claimedDropTargets[spawnLoc] = bird.color
            S.birdDropTarget[bird.id] = spawnLoc
            S.runRecord.drops[bird.id] = spawnLoc
            S.runRecord.drop_frames[bird.id] = getGameFrame()
        end
    end
    S.bird_count = S.bird_count + 1
    local birdLabel = birdLabelFromData(birdData)
    local frame = getGameFrame()
    logSim(string.format(
        "drop target: bird=%s location=%d frame=%d",
        birdLabel, spawnLoc, frame
    ))
    return true
end

startPlayback = function()
    if not MAP.runSimulations then
        return
    end
    local movie = movieForCycle(S.activeCycle)
    logSim(string.format(
        "RNG loop starting: fight cycle %d (simulation count: %d)",
        S.activeCycle,
        S.simulation_count
    ))
    resetRunState()
    S.patchRngOnLoad = true
    PCSX.Movie.stop()
    local ok
    if S.sweepActive or S.loadedMoviePath ~= movie then
        ok = PCSX.Movie.play(movie)
        if ok then
            S.loadedMoviePath = movie
        end
    else
        ok = PCSX.Movie.play()
    end
    if not ok then
        printError(string.format("Movie.play failed: cycle %d %s", S.activeCycle, movie))
        S.wasPlaying = false
        S.loadedMoviePath = nil
        if S.sweepActive then
            finishCsvSweep(string.format("CSV sweep failed: movie play failed cycle %d", S.activeCycle))
        else
            unregisterSimulationBreakpoints()
            MAP.runSimulations = false
            registerForceBreakpoints()
        end
    else
        S.wasPlaying = true
        if S.sweepActive then
            S.sweepRecording = true
        end
    end
end

reloadActiveMovie = function()
    S.wasPlaying = false
    PCSX.Movie.stop()
    S.loadedMoviePath = nil
    print(string.format(
        "Using %s movie for cycle %d: %s",
        MAP.useMoveMovies and "move" or "nomove",
        S.activeCycle,
        movieForCycle(S.activeCycle)
    ))
    if S.loopActive and MAP.runSimulations then
        startPlayback()
    end
end

switchActiveCycle = function(newCycle)
    if S.sweepActive then
        return
    end
    S.activeCycle = clampCycle(newCycle)
    S.wasPlaying = false
    PCSX.Movie.stop()
    S.loadedMoviePath = nil
    S.simulation_count = 0
    print(string.format("Switched to fight cycle %d: %s", S.activeCycle, movieForCycle(S.activeCycle)))
    if S.loopActive and MAP.runSimulations then
        startPlayback()
    end
end

S.switchActiveCycle = switchActiveCycle
S.reloadActiveMovie = reloadActiveMovie
S.applyCycleBirdPreset = applyCycleBirdPreset
S.clearBirdForces = clearBirdForces
S.getGameFrame = getGameFrame

unregisterForceBreakpoints = function()
    if S.gameFrameBreakpoint then
        S.gameFrameBreakpoint:remove()
        S.gameFrameBreakpoint = nil
    end
    if S.forceDropBreakpoint then
        S.forceDropBreakpoint:remove()
        S.forceDropBreakpoint = nil
    end
    if S.forceWeaponBreakpoint then
        S.forceWeaponBreakpoint:remove()
        S.forceWeaponBreakpoint = nil
    end
end

unregisterSimulationBreakpoints = function()
    for _, bp in ipairs(S.breakpoints) do
        bp:remove()
    end
    S.breakpoints = {}
end

stopSimulations = function()
    if S.sweepActive then
        finishCsvSweep("CSV sweep stopped")
        return
    end
    S.wasPlaying = false
    S.patchRngOnLoad = false
    S.loadedMoviePath = nil
    PCSX.Movie.stop()
    unregisterSimulationBreakpoints()
    resetRunState()
    registerForceBreakpoints()
end

startSimulations = function()
    S.loadedMoviePath = nil
    if #S.breakpoints == 0 then
        registerSimulationBreakpoints()
    end
    startPlayback()
end

restartPlayback = function(reason)
    if not MAP.runSimulations then
        return
    end
    if S.sweepActive then
        S.sweepRecording = false
    end
    S.wasPlaying = false
    PCSX.Movie.stop()
    logSim(reason)
    if not MAP.autoRestartPlayback then
        if S.sweepActive then
            finishCsvSweep("CSV sweep stopped (auto-restart disabled)")
        else
            logSim("auto-restart disabled, playback stopped")
        end
        return
    end
    S.simulation_count = S.simulation_count + 1
    PCSX.nextTick(startPlayback)
end

finishCsvSweep = function(message, options)
    if not S.sweepActive then
        return
    end
    options = options or {}
    S.sweepActive = false
    S.sweepRecording = false
    S.wasPlaying = false
    S.patchRngOnLoad = false
    S.loadedMoviePath = nil
    PCSX.Movie.stop()
    unregisterSimulationBreakpoints()
    resetRunState()
    registerForceBreakpoints()
    if options.restoreRunSimulations and S.sweepPrevRunSimulations then
        MAP.runSimulations = true
        registerSimulationBreakpoints()
    else
        MAP.runSimulations = false
    end
    S.sweepStatusText = message
    print(message)
end

startCsvSweep = function()
    if S.sweepActive then
        return
    end
    local cycle = S.activeCycle
    local permCount = permCountForCycle(cycle)
    local maxPermIndex, maxSimIndex = scanCsvResume(cycle)
    local startIndex = maxPermIndex + 1
    if startIndex >= permCount then
        local msg = string.format("Cycle %d already complete (%d permutations)", cycle, permCount)
        S.sweepStatusText = msg
        print(msg)
        return
    end
    local ok, err = ensureCsvHeader()
    if not ok then
        print(err)
        S.sweepStatusText = err
        return
    end
    S.sweepPrevRunSimulations = MAP.runSimulations
    S.sweepActive = true
    S.sweepRecording = false
    S.perm_count = permCount
    S.perm_index = startIndex
    S.sim_index = math.max(maxSimIndex, 0)
    MAP.runSimulations = true
    MAP.autoRestartPlayback = true
    updateSweepStatus()
    print(string.format(
        "CSV sweep starting: cycle %d perm %d / %d -> %s",
        cycle, startIndex + 1, permCount, CSV_PATH
    ))
    resetRunState()
    applyPermutation(cycle, startIndex)
    S.wasPlaying = false
    S.loadedMoviePath = nil
    PCSX.Movie.stop()
    PCSX.pauseEmulator()
    if #S.breakpoints == 0 then
        registerSimulationBreakpoints()
    end
    startPlayback()
end

local function continueCsvSweepAtCycle(cycle)
    while cycle <= CYCLE_COUNT do
        local permCount = permCountForCycle(cycle)
        local maxPermIndex, maxSimIndex = scanCsvResume(cycle)
        local startIndex = maxPermIndex + 1
        if startIndex < permCount then
            S.activeCycle = cycle
            S.perm_count = permCount
            S.perm_index = startIndex
            S.sim_index = math.max(maxSimIndex, S.sim_index)
            applyPermutation(cycle, startIndex)
            updateSweepStatus()
            print(string.format(
                "CSV sweep continuing: cycle %d perm %d / %d -> %s",
                cycle, startIndex + 1, permCount, CSV_PATH
            ))
            resetRunState()
            S.wasPlaying = false
            S.loadedMoviePath = nil
            PCSX.Movie.stop()
            restartPlayback(string.format(
                "CSV sweep cycle %d perm %d / %d", cycle, startIndex + 1, permCount
            ))
            return true
        end
        print(string.format("Cycle %d already complete (%d permutations), skipping", cycle, permCount))
        cycle = cycle + 1
    end
    return false
end

cancelCsvSweep = function()
    if not S.sweepActive then
        return
    end
    finishCsvSweep(string.format(
        "CSV sweep cancelled: cycle %d at perm %d / %d",
        S.activeCycle,
        S.perm_index + 1,
        S.perm_count
    ), { restoreRunSimulations = true })
end

S.startCsvSweep = startCsvSweep
S.cancelCsvSweep = cancelCsvSweep

local function allActiveBirdsDropped(cycle)
    for birdId = 0, getActiveBirdCount(cycle) - 1 do
        if not S.bird_dropped[birdId] then
            return false
        end
    end
    return true
end

local function tryCompleteCycle()
    if not MAP.runSimulations then
        return
    end
    --[[
    if not next(S.cycle_spawned) then
        return
    end
    for id, _ in pairs(S.cycle_spawned) do
        if not S.cycle_despawned[id] then
            return
        end
    end
    local frame = getGameFrame()
    print(string.format(
        "cycle complete: fight cycle %d spawned=%s eggs=%s despawns=%s frame=%d",
        S.activeCycle,
        cycleIds(S.cycle_spawned),
        cycleIds(S.cycle_egg),
        cycleIds(S.cycle_despawned),
        frame
    ))
    restartPlayback("All spawned vultures despawned - reloading")
    --]]
    if not allActiveBirdsDropped(S.activeCycle) then
        return
    end
    local frame = getGameFrame()
    S.runRecord.cycle_complete_frame = frame
    if S.sweepActive then
        if not S.sweepRecording then
            return
        end
        if not flushCsvRow() then
            finishCsvSweep(string.format("CSV sweep failed on cycle %d perm %d", S.activeCycle, S.perm_index + 1))
            return
        end
        S.perm_index = S.perm_index + 1
        if S.perm_index >= S.perm_count then
            local completedCycle = S.activeCycle
            local completeMsg = string.format(
                "Cycle %d sweep complete: %d rows written to %s",
                completedCycle, S.perm_count, CSV_PATH
            )
            print(completeMsg)
            if MAP.autoAdvanceCycle and completedCycle < CYCLE_COUNT then
                if continueCsvSweepAtCycle(completedCycle + 1) then
                    S.sweepStatusText = completeMsg
                    return
                end
                finishCsvSweep(string.format(
                    "All cycles complete through cycle %d: %s", CYCLE_COUNT, CSV_PATH
                ))
                return
            end
            finishCsvSweep(completeMsg)
            return
        end
        updateSweepStatus()
        applyPermutation(S.activeCycle, S.perm_index)
        restartPlayback(string.format("CSV sweep perm %d / %d", S.perm_index + 1, S.perm_count))
        return
    end
    logSim(string.format(
        "cycle complete: fight cycle %d active_birds=%d eggs_dropped=%d frame=%d",
        S.activeCycle,
        getActiveBirdCount(S.activeCycle),
        S.egg_count,
        frame
    ))
    restartPlayback("All active birds dropped - reloading")
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
        S.cycle_egg[bird.id] = true
    end
    markEggDropTarget(eggData, bird and bird.id)
    S.eggDataToBird[eggData] = bird and bird.id or nil
    S.egg_count = S.egg_count + 1
    local frame = getGameFrame()
    local eggX, eggY, eggZ, spawnDist
    if bird then
        local eggMoby = regs.s0
        eggX, eggY, eggZ = readMobyXYZ(eggMoby)
        local targetIdx = S.birdDropTarget[bird.id]
        if targetIdx then
            local pathTable = getDropTargetPathTable()
            if pathTable then
                local target = readDropTargetEntry(pathTable, targetIdx)
                spawnDist = dist2d(eggX, eggY, target.x, target.y)
            end
        end
        S.runRecord.egg_spawn_frames[bird.id] = frame
        S.runRecord.hatch_timers[bird.id] = hatchTimer
        S.runRecord.egg_x[bird.id] = eggX
        S.runRecord.egg_y[bird.id] = eggY
        S.runRecord.egg_z[bird.id] = eggZ
        if spawnDist then
            S.runRecord.spawn_dist[bird.id] = spawnDist
        end
        if not S.runRecord.weapons[bird.id] then
            S.runRecord.weapons[bird.id] = mobyIdToWeapon(dropId)
        end
    end
    if bird and spawnDist then
        logSim(string.format(
            "egg spawn: bird=%s random_delay=%d hatch_timer=%d drop=%s frame=%d pos=(%d,%d,%d) dist=%d",
            birdLabelFromData(birdData), randomDelay, hatchTimer, dropLabel, frame,
            eggX, eggY, eggZ, spawnDist
        ))
    elseif bird then
        logSim(string.format(
            "egg spawn: bird=%s random_delay=%d hatch_timer=%d drop=%s frame=%d pos=(%d,%d,%d)",
            birdLabelFromData(birdData), randomDelay, hatchTimer, dropLabel, frame,
            eggX, eggY, eggZ
        ))
    else
        logSim(string.format(
            "egg spawn: bird=%s random_delay=%d hatch_timer=%d drop=%s frame=%d",
            birdLabelFromData(birdData), randomDelay, hatchTimer, dropLabel, frame
        ))
    end
    tryCompleteCycle()
    return true
end

local function onEggHatched()
    local regs = PCSX.getRegisters().GPR.n
    local eggData = regs.s3
    local birdId = S.eggDataToBird[eggData]
    local birdLabel = birdId ~= nil and tostring(birdId) or string.format("unknown(0x%08x)", eggData)
    local frame = getGameFrame()
    logSim(string.format("egg hatched: bird=%s frame=%d", birdLabel, frame))
    if birdId ~= nil then
        S.runRecord.hatch_frames[birdId] = frame
    end
    S.egg_hatch_count = S.egg_hatch_count + 1
    return true
end

local function onVultureReset()
    local regs = PCSX.getRegisters().GPR.n
    local birdData = regs.s2
    local bird = BIRDS_BY_DATA[birdData]
    local frame = getGameFrame()
    local birdLabel = birdLabelFromData(birdData)

    if not bird or not S.cycle_spawned[bird.id] or S.cycle_despawned[bird.id] then
        return true
    end

    local hadEgg = S.cycle_egg[bird.id]
    local target = S.birdDropTarget[bird.id]
    if hadEgg then
        logSim(string.format("despawn: bird=%s egg=true frame=%d", birdLabel, frame))
    elseif target then
        logSim(string.format("despawn: bird=%s egg=false target=%d frame=%d", birdLabel, target, frame))
    else
        logSim(string.format("despawn: bird=%s egg=false frame=%d", birdLabel, frame))
    end

    if not hadEgg then
        S.despawn_count = S.despawn_count + 1
        S.bird_despawn_count[bird.id] = (S.bird_despawn_count[bird.id] or 0) + 1
    end

    S.cycle_despawned[bird.id] = true
    -- tryCompleteCycle()
    return true
end

registerForceBreakpoints = function()
    if not S.gameFrameBreakpoint then
        S.gameFrameBreakpoint = PCSX.addBreakpoint(
            UPDATE_GAME_BP, 'Exec', 4, '', onUpdateGameFrame, 'gulp updategame frame'
        )
    end
    if not S.forceDropBreakpoint then
        S.forceDropBreakpoint = PCSX.addBreakpoint(
            DROP_TARGET_ROLL_BP, 'Exec', 4, '', onDropTargetRoll, 'gulp drop target roll'
        )
    end
    if not S.forceWeaponBreakpoint then
        S.forceWeaponBreakpoint = PCSX.addBreakpoint(
            DROP_WEAPON_FORCE_BP, 'Exec', 4, '', onWeaponContentsForced, 'gulp weapon contents'
        )
    end
end

registerSimulationBreakpoints = function()
    S.breakpoints = {
        PCSX.addBreakpoint(DROP_LOCATION_BP, 'Exec', 4, '', onDropLocationSelected, 'gulp drop location'),
        PCSX.addBreakpoint(VULTURE_RESET_BP, 'Exec', 4, '', onVultureReset, 'gulp vulture reset'),
        PCSX.addBreakpoint(EGG_SPAWN_BP, 'Exec', 4, '', onEggSpawned, 'gulp egg spawn'),
        PCSX.addBreakpoint(EGG_HATCH_BP, 'Exec', 4, '', onEggHatched, 'gulp egg hatch'),
    }
end

local function registerListeners()
    S.listeners[#S.listeners + 1] = PCSX.Events.createEventListener("ExecutionFlow::SaveStateLoaded", function()
        applyRenderPatch()
        applyHealthPatch()
        if MAP.runSimulations and S.patchRngOnLoad then
            patchRng()
            S.patchRngOnLoad = false
        end
    end)

    S.listeners[#S.listeners + 1] = PCSX.Events.createEventListener("Movie::PlaybackFinished", function()
        if not MAP.runSimulations or not S.loopActive or not S.wasPlaying then return end
        restartPlayback("Movie finished, restarting...")
    end)

    S.listeners[#S.listeners + 1] = PCSX.Events.createEventListener("ExecutionFlow::Reset", function(event)
        if not MAP.runSimulations or not S.loopActive then return end
        if S.sweepActive and not event.hard then return end
        stopLoop(event.hard and "Hard reset, RNG loop stopped" or "Soft reset, RNG loop stopped")
    end)

    S.listeners[#S.listeners + 1] = PCSX.Events.createEventListener("ExecutionFlow::Pause", function(event)
        if not MAP.runSimulations or not S.loopActive or not event.exception then return end
        stopLoop("Emulation exception, RNG loop stopped")
    end)
end

local function main()
    teardown()
    PCSX.Movie.stop()
    S.loadedMoviePath = nil
    S.wasPlaying = false
    S.loopActive = true
    S.mapWindowOpen = true
    applyCycleBirdPreset(S.activeCycle)
    registerMapUi()
    registerListeners()
    registerForceBreakpoints()
    applyRenderPatch()
    applyHealthPatch()
    if MAP.runSimulations then
        registerSimulationBreakpoints()
        print(string.format(
            "RNG movie loop starting: fight cycle %d %s (render %s, infinite health %s, isolate gulp %s, auto-restart %s)",
            S.activeCycle,
            movieForCycle(S.activeCycle),
            MAP.disableRender and "disabled" or "enabled",
            MAP.infiniteHealth and "on" or "off",
            MAP.isolateGulp and "on" or "off",
            MAP.autoRestartPlayback and "on" or "off"
        ))
        startPlayback()
    else
        print(string.format(
            "Gulp map active (simulations off, force drops armed, render %s, infinite health %s, isolate gulp %s)",
            MAP.disableRender and "disabled" or "enabled",
            MAP.infiniteHealth and "on" or "off",
            MAP.isolateGulp and "on" or "off"
        ))
    end
end

S.main = main
main()
