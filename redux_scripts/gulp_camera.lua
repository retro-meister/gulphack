local ENABLE_HARDCODE_CAMERA = true
local CAMERA_Z_OFFSET = 15000

local GULP_LEVEL_ID = 0x2e
local GAME_STATE_NORMAL = 0

local ADDR_LEVEL_ID = 0x80066f90
local ADDR_GAME_STATE = 0x800681c8

local ADDR_CAMERA_POSITION = 0x80067eac
local ADDR_CAMERA_PITCH_A = 0x80067ec8
local ADDR_CAMERA_PITCH_B = 0x80067eca
local ADDR_CAMERA_YAW = 0x80067ecc
local ADDR_CAMERA_ORBIT_CENTER = 0x80067f00
local ADDR_CAMERA_FIXED_FLAG = 0x80067fc9
local ADDR_CAMERA_FIXED_POSITION = 0x80068064
local ADDR_CAMERA_FIXED_PITCH_A = 0x80068070
local ADDR_CAMERA_FIXED_PITCH_B = 0x80068072
local ADDR_CAMERA_FIXED_YAW = 0x80068074

local ADDR_BIRD0_DATA = 0x80120e44

local GULP_ARENA_CENTER_X = 36864
local GULP_ARENA_CENTER_Y = 40960
local GULP_ARENA_FLOOR_Z = 18944
local GULP_CAMERA_PITCH = 0x400
local GULP_CAMERA_YAW = 0x000

local DROP_TARGET_ENTRIES_OFF = 0x0c
local DROP_TARGET_ENTRY_STRIDE = 0x10
local DROP_TARGET_HOME = 0

local last_error = nil

local function mem_addr(addr)
    return bit.band(addr, 0xffffff)
end

local function read_i32(addr)
    return ffi.cast('int32_t*', PCSX.getMemPtr() + mem_addr(addr))[0]
end

local function read_u8(addr)
    return ffi.cast('uint8_t*', PCSX.getMemPtr() + mem_addr(addr))[0]
end

local function write_i32(addr, value)
    ffi.cast('int32_t*', PCSX.getMemPtr() + mem_addr(addr))[0] = value
end

local function write_i16(addr, value)
    ffi.cast('int16_t*', PCSX.getMemPtr() + mem_addr(addr))[0] = value
end

local function write_u8(addr, value)
    ffi.cast('uint8_t*', PCSX.getMemPtr() + mem_addr(addr))[0] = value
end

local function checkbox(label, value)
    local changed
    local new_value = value
    changed, new_value = imgui.Checkbox(label, value)
    if new_value == nil then
        new_value = value
    end
    return changed, new_value
end

local function slider_int(label, value, min_value, max_value)
    local changed
    local new_value = value
    changed, new_value = imgui.SliderInt(label, value, min_value, max_value)
    if new_value == nil then
        new_value = value
    end
    return changed, new_value
end

local function camera_height()
    return GULP_ARENA_FLOOR_Z + CAMERA_Z_OFFSET
end

local function in_gulp_fight()
    return read_u8(ADDR_LEVEL_ID) == GULP_LEVEL_ID and read_i32(ADDR_GAME_STATE) == GAME_STATE_NORMAL
end

local function get_path_table()
    local path_table = read_i32(ADDR_BIRD0_DATA + 0x0c)
    if path_table == 0 then
        return nil
    end
    return path_table
end

local function read_drop_entry(path_table, index)
    local entry_addr = path_table + DROP_TARGET_ENTRIES_OFF + index * DROP_TARGET_ENTRY_STRIDE
    return read_i32(entry_addr), read_i32(entry_addr + 4)
end

local function get_arena_center()
    local path_table = get_path_table()
    if not path_table then
        return GULP_ARENA_CENTER_X, GULP_ARENA_CENTER_Y
    end
    local x, y = read_drop_entry(path_table, DROP_TARGET_HOME)
    if x == 0 and y == 0 then
        return GULP_ARENA_CENTER_X, GULP_ARENA_CENTER_Y
    end
    return x, y
end

local function apply_hardcoded_camera()
    local center_x, center_y = get_arena_center()
    local height = camera_height()

    write_i32(ADDR_CAMERA_FIXED_POSITION + 0, center_x)
    write_i32(ADDR_CAMERA_FIXED_POSITION + 4, center_y)
    write_i32(ADDR_CAMERA_FIXED_POSITION + 8, height)
    write_i16(ADDR_CAMERA_FIXED_PITCH_A, 0)
    write_i16(ADDR_CAMERA_FIXED_PITCH_B, GULP_CAMERA_PITCH)
    write_i16(ADDR_CAMERA_FIXED_YAW, GULP_CAMERA_YAW)
    write_u8(ADDR_CAMERA_FIXED_FLAG, 1)

    write_i32(ADDR_CAMERA_ORBIT_CENTER + 0, center_x)
    write_i32(ADDR_CAMERA_ORBIT_CENTER + 4, center_y)
    write_i32(ADDR_CAMERA_ORBIT_CENTER + 8, GULP_ARENA_FLOOR_Z)

    write_i32(ADDR_CAMERA_POSITION + 0, center_x)
    write_i32(ADDR_CAMERA_POSITION + 4, center_y)
    write_i32(ADDR_CAMERA_POSITION + 8, height)
    write_i16(ADDR_CAMERA_PITCH_A, 0)
    write_i16(ADDR_CAMERA_PITCH_B, GULP_CAMERA_PITCH)
    write_i16(ADDR_CAMERA_YAW, GULP_CAMERA_YAW)
end

local function restore_camera()
    write_u8(ADDR_CAMERA_FIXED_FLAG, 0)
end

local function draw_settings_window()
    imgui.safe.Begin('Gulp camera', function()
        local changed
        local value

        value = ENABLE_HARDCODE_CAMERA
        changed, value = checkbox('Hardcode camera', value)
        if changed then ENABLE_HARDCODE_CAMERA = value end

        value = CAMERA_Z_OFFSET
        changed, value = slider_int('Camera Z offset', value, 2000, 40000)
        if changed then CAMERA_Z_OFFSET = value end

        if in_gulp_fight() then
            imgui.Text('Gulp fight active')
        else
            imgui.Text('Outside gulp fight')
        end

        if last_error ~= nil then
            imgui.Text('Last error:')
            imgui.TextWrapped(last_error)
        end
    end)
end

local function draw_imgui_frame_impl()
    if ENABLE_HARDCODE_CAMERA and in_gulp_fight() then
        apply_hardcoded_camera()
    elseif ENABLE_HARDCODE_CAMERA then
        restore_camera()
    end

    draw_settings_window()
end

function DrawImguiFrame()
    local ok, err = pcall(draw_imgui_frame_impl)
    if not ok then
        last_error = tostring(err)
        PCSX.log('gulp_camera error: ' .. last_error)
    end
end

PCSX.log('gulp_camera.lua loaded')
