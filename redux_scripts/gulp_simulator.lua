local MOVIE = "/Users/retro/repos/pcsx-redux/movies/gulp_phase1.pcsxmv"
local TARGET_FRAME = nil

local RNG_ADDR = 0x8006d144
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
}

local S = _G.GulpRngLoop

S.egg_count = S.egg_count or 0
if not S.bird_dropped then
    S.bird_dropped = { [0] = false, [1] = false, [2] = false }
end

math.randomseed(tonumber(ffi.cast('uint32_t', PCSX.getCPUCycles())))

local function randomRngState()
    return math.random(0, 0xffffffff)
end

local function ramOffset(addr)
    return bit.band(addr, 0x1fffff)
end

local function readRam16(addr)
    return ffi.cast('uint16_t*', PCSX.getMemPtr() + ramOffset(addr))[0]
end

local function patchRng()
    local state = randomRngState()
    local ptr = ffi.cast('uint32_t*', PCSX.getMemPtr() + ramOffset(RNG_ADDR))
    ptr[0] = state
    print(string.format("RNG @ 0x%08x set to 0x%08x", RNG_ADDR, state))
end

local function teardown()
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

local function birdLabelFromAddr(birdAddr)
    local birdId = BIRDS[birdAddr]
    return birdId ~= nil and tostring(birdId) or string.format("unknown(0x%08x)", birdAddr)
end

local function resetBirdDropped()
    S.bird_dropped = { [0] = false, [1] = false, [2] = false }
end

local function onDropLocationSelected()
    local regs = PCSX.getRegisters().GPR.n
    local birdAddr = regs.s2
    local spawnLoc = regs.s0
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
    S.bird_count = 0
    S.egg_count = 0
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
    PCSX.nextTick(startPlayback)
end

local function onEggSpawned()
    local regs = PCSX.getRegisters().GPR.n
    local birdAddr = regs.s2
    local randomDelay = regs.v0
    local eggData = regs.s1
    local hatchTimer = readRam16(eggData + 0xa)
    local dropId = readRam16(eggData + 0xc)
    local dropLabel = DROP_IDS[dropId] or string.format("0x%03x", dropId)
    local birdId = BIRDS[birdAddr]
    if birdId ~= nil then
        S.bird_dropped[birdId] = true
    end
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
        if S.patchRngOnLoad then
            patchRng()
            S.patchRngOnLoad = false
        end
    end)

    S.listeners[#S.listeners + 1] = PCSX.Events.createEventListener("Movie::PlaybackFinished", function()
        if not S.loopActive or not S.wasPlaying then return end
        if TARGET_FRAME then return end
        restartPlayback("Movie finished, restarting...")
    end)

    S.listeners[#S.listeners + 1] = PCSX.Events.createEventListener("Movie::Frame", function(event)
        if not S.loopActive or not S.wasPlaying then return end
        if not TARGET_FRAME then return end
        if event.index >= TARGET_FRAME then
            restartPlayback(string.format("Hit frame %d, restarting...", TARGET_FRAME))
        end
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
    registerListeners()
    registerDropLocationBreakpoint()
    registerEggSpawnBreakpoint()
    print("RNG movie loop starting: " .. MOVIE)
    startPlayback()
end

S.main = main
main()
