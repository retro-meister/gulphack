-- CONFIGURATION
DISABLE_GAME_RENDER = false

-- GLOBALS
bp_list = {}
frame_count = 0
start_counting = false
vulture_count = 0
egg_count = 0
rng_seed = 0

vultures = {}
checkpoint_state = nil
rng_seed_addr = 0x8006d144
game_render_addr = 0x80011afc

egg_types = {
    [0x196] = 'BARREL',
    [0x197] = 'BOMB',
    [0x198] = 'ROCKET',
}

local function hex(value)
    return string.format('0x%08x', tonumber(value))
end

local function read_u16(addr)
    local mem_addr = bit.band(addr, 0xFFFFFF)
    return ffi.cast('uint16_t*', PCSX.getMemPtr() + mem_addr)[0]
end

local function read_u32(addr)
    local mem_addr = bit.band(addr, 0xFFFFFF)
    return ffi.cast('uint32_t*', PCSX.getMemPtr() + mem_addr)[0]
end

local function write_u32(addr, value)
    local mem_addr = bit.band(addr, 0xFFFFFF)
    ffi.cast('uint32_t*', PCSX.getMemPtr() + mem_addr)[0] = value
end

local function reset_state(reset_breakpoint_list)
    frame_count = 0
    start_counting = false
    vulture_count = 0
    egg_count = 0
    vultures = {}

    if DISABLE_GAME_RENDER then
        write_u32(game_render_addr, 0x0)
    else
        write_u32(game_render_addr, 0x0C0047A7)
    end

    if reset_breakpoint_list then
        bp_list = {}
        rng_seed = read_u32(rng_seed_addr)
        checkpoint_state = PCSX.createSaveState()
        PCSX.log(string.format('Created savestate with RNG seed %s', hex(rng_seed)))
    end
end

local function log(message)
    PCSX.log(message)
end

local function frame_callback(address, width, cause)
    if start_counting then
        frame_count = frame_count + 1
    end
    return true
end

local function spawn_decision_callback(address, width, cause)
    local regs = PCSX.getRegisters()
    local spawn_index = regs.GPR.n.s0
    local vulture_addr = regs.GPR.n.s2

    vulture_count = vulture_count + 1

    vultures[vulture_addr] = {
        spawn_index = spawn_index,
        address = vulture_addr,
        spawned_frame = frame_count,
    }

    if start_counting == false then
        start_counting = true
        log('Frame counting started')
        log(string.format('RNG seed: %s', hex(rng_seed)))
    end

    log(string.format(
        'Egg spawn decision: spawn_index=%d, vulture_addr=%s, frame_count=%d, vulture_count=%d',
        spawn_index,
        hex(vulture_addr),
        frame_count,
        vulture_count
    ))
    return true
end

local function drop_delay_callback(address, width, cause)
    local regs = PCSX.getRegisters()
    local vulture_addr = regs.GPR.n.s2
    local drop_delay = regs.GPR.n.v0
    local egg_data = regs.GPR.n.s1
    local hatch_timer = read_u16(egg_data + 0xA)
    local drop_id = read_u16(egg_data + 0xC)
    local drop_name = egg_types[drop_id] or 'UNKNOWN'
    local vulture = vultures[vulture_addr]

    egg_count = egg_count + 1

    if vulture ~= nil then
        vulture.drop_frame = frame_count
        vulture.drop_delay = drop_delay
        vulture.egg_data = egg_data
        vulture.hatch_timer = hatch_timer
        vulture.drop_id = drop_id
        vulture.drop_name = drop_name

        log(string.format(
            'Vulture drop: vulture_addr=%s, spawn_index=%d, spawned_frame=%d, current_frame=%d, drop_delay=%d, egg_data=%s, hatch_timer=%d, drop_name=%s, egg_count=%d, vulture_count=%d',
            hex(vulture_addr),
            vulture.spawn_index,
            vulture.spawned_frame,
            frame_count,
            drop_delay,
            hex(egg_data),
            hatch_timer,
            drop_name,
            egg_count,
            vulture_count
        ))

    else
        log(string.format(
            'Error: untracked vulture drop data, vulture_addr=%s, egg_count=%d, vulture_count=%d',
            hex(vulture_addr),
            egg_count,
            vulture_count
        ))
    end

    if egg_count == vulture_count then
        log('All tracked vultures spawned eggs; loading checkpoint savestate')
        rng_seed = read_u32(rng_seed_addr)
        reset_state(false)

        if checkpoint_state ~= nil then
            PCSX.loadSaveState(checkpoint_state)
            write_u32(rng_seed_addr, rng_seed)
        else
            log('Error: no checkpoint savestate available to load')
        end
    end

    return true
end

local function add_breakpoint(addr, description, callback)
    bp = PCSX.addBreakpoint(addr, 'Exec', 4, description, callback)
    table.insert(bp_list, bp)
    bp:enable()

    if bp:isEnabled() then
        log(string.format("Exec breakpoint at %s: %s enabled.", hex(addr), description))
    end
end

local function add_breakpoints()
    add_breakpoint(0x80011af4, 'Gulp frame counter', frame_callback)
    add_breakpoint(0x80077448, 'Gulp vulture egg spawn decision', spawn_decision_callback)
    add_breakpoint(0x80077a48, 'Gulp vulture egg drop data', drop_delay_callback)
end

local function main()
    reset_state(true)
    add_breakpoints()
end

main()
