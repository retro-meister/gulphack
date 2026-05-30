local PATCH_EVERY_FRAME = false

local default_config = {
    -- eggData->hatchTimer = RandomRangeInclusive(min, max)
    egg_hatch_timer_min = 0x78,
    egg_hatch_timer_max = 0xdc,

    -- vultureData->dropDelay = RandomRangeInclusive(min, max)
    -- After this time has elapsed, the vulture can drop an egg when it gets within the distance and angle thresholds
    vulture_drop_delay_min = 0x50,
    vulture_drop_delay_max = 0xb4,

    -- vultureData->approachTimer initial value.
    -- After this time has elapsed, the vulture drops the distance threshold requirement to drop an egg
    vulture_approach_timer_initial = 0x03e8,

    -- Drop condition gates.
    vulture_drop_angle_threshold = 0x20,
    vulture_drop_distance_threshold = 0x708,
    vulture_drop_population_gate = 6,

    -- Random egg contents only, used when weaponMode is not 0, 1, or 2.
    -- randomRoll is RandomRangeInclusive(0, 100).
    random_rocket_lower = 81,
    random_bomb_upper_exclusive = 41,
}

local custom_config = {
    -- eggData->hatchTimer = RandomRangeInclusive(min, max)
    egg_hatch_timer_min = 0x78,
    egg_hatch_timer_max = 0x78,

    -- vultureData->dropDelay = RandomRangeInclusive(min, max)
    vulture_drop_delay_min = 0x50,
    vulture_drop_delay_max = 0x50,

    -- vultureData->approachTimer initial value.
    vulture_approach_timer_initial = 500,

    -- Drop condition gates.
    vulture_drop_angle_threshold = 0x40,
    vulture_drop_distance_threshold = 0x708,
    vulture_drop_population_gate = 6,

    -- Random egg contents only, used when weaponMode is not 0, 1, or 2.
    -- randomRoll is RandomRangeInclusive(0, 100).
    random_rocket_lower = 81,
    random_bomb_upper_exclusive = 41,
}

local config = custom_config

local ADDR = {
    egg_hatch_min_li = 0x800779c8,       -- li a0, 0x78
    egg_hatch_max_li = 0x800779d0,       -- li a1, 0xdc
    vulture_delay_min_li = 0x80077a24,   -- li a0, 0x50
    vulture_delay_max_li = 0x80077a30,   -- li a1, 0xb4
    approach_timer_li = 0x800772a0,      -- li v0, 0x3e8
    angle_threshold_slti = 0x80077804,   -- slti v0, v0, 0x20
    distance_threshold_slti = 0x800777c0, -- slti v0, v0, 0x708
    population_gate_slti = 0x80077618,   -- slti v0, s0, 0x6
    random_rocket_lower_slti = 0x8007799c, -- slti v0, randomRoll, 0x51
    random_bomb_upper_slti = 0x800779a4,   -- slti v0, randomRoll, 0x29
}

local mem = PCSX.getMemoryAsFile()
local applied_once = false

local function imm16(value, name)
    assert(type(value) == "number", name .. " must be a number")
    assert(value >= 0 and value <= 0x7fff,
        string.format("%s out of range for these signed-immediate patches: 0x%x", name, value))
    return value
end

local function addiu(rt, rs, imm)
    return 0x24000000 + rs * 0x200000 + rt * 0x10000 + imm16(imm, "addiu immediate")
end

local function slti(rt, rs, imm)
    return 0x28000000 + rs * 0x200000 + rt * 0x10000 + imm16(imm, "slti immediate")
end

local function write32(address, value)
    mem:writeU32At(value, address)
end

local function patch()
    -- RandomRangeInclusive(min, max) argument patches.
    write32(ADDR.egg_hatch_min_li, addiu(4, 0, config.egg_hatch_timer_min))       -- a0
    write32(ADDR.egg_hatch_max_li, addiu(5, 0, config.egg_hatch_timer_max))       -- a1
    write32(ADDR.vulture_delay_min_li, addiu(4, 0, config.vulture_drop_delay_min)) -- a0
    write32(ADDR.vulture_delay_max_li, addiu(5, 0, config.vulture_drop_delay_max)) -- a1

    -- Vulture drop-condition tuning.
    write32(ADDR.approach_timer_li, addiu(2, 0, config.vulture_approach_timer_initial)) -- v0
    write32(ADDR.angle_threshold_slti, slti(2, 2, config.vulture_drop_angle_threshold))
    write32(ADDR.distance_threshold_slti, slti(2, 2, config.vulture_drop_distance_threshold))
    write32(ADDR.population_gate_slti, slti(2, 16, config.vulture_drop_population_gate))

    -- Random egg contents thresholds.
    write32(ADDR.random_rocket_lower_slti, slti(2, 23, config.random_rocket_lower))
    write32(ADDR.random_bomb_upper_slti, slti(2, 23, config.random_bomb_upper_exclusive))

    if not applied_once then
        applied_once = true
        print(string.format(
            "Gulp patches applied: egg hatch %d..%d, vulture delay %d..%d, approach %d, angle <%d, distance <%d, population <%d, random bomb <%d, rocket >=%d",
            config.egg_hatch_timer_min,
            config.egg_hatch_timer_max,
            config.vulture_drop_delay_min,
            config.vulture_drop_delay_max,
            config.vulture_approach_timer_initial,
            config.vulture_drop_angle_threshold,
            config.vulture_drop_distance_threshold,
            config.vulture_drop_population_gate,
            config.random_bomb_upper_exclusive,
            config.random_rocket_lower
        ))
    end
end

patch()

function DrawImguiFrame()
    if PATCH_EVERY_FRAME then
        patch()
    end
end
