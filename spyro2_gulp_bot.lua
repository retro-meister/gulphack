
--Choose for Bird #1 or Bird #2
local BIRD = 1
--From 2047 to -2048, -1 at a time, inverse the numbers to do on the opposite rotation (-2048, 2047, 1)
--This will only give relevant results if you choose the good rotation
local ANGLE_DEB = 2047
local ANGLE_FIN = -2048
local ANGLE_MOV = -1
--A savestate 3 or 4 frames (60 FPS) before the first bird spawns
savestate.loadslot(7)
local IDMIN = 0

local function GET_TIME(BIRD, ID, TMAX)

	savestate.load("gulp_birds_bot2")
	F1 = emu.framecount()
	
	while memory.read_s8(ID_ADD)~=ID do
		savestate.load("gulp_birds_bot2")
		memory.write_u32_le(0x06D144, math.floor(math.random()*65536*65536))
		memory.write_u32_le(XFREEZE_ADD, XFREEZE_VAL)
		memory.write_u32_le(YFREEZE_ADD, YFREEZE_VAL)
		memory.write_u32_le(0x116B0C, XFREEZE_VAL3)
		memory.write_u32_le(0x116B10, YFREEZE_VAL3)
		emu.frameadvance()
		XPOS = memory.read_u32_le(XBIRD_ADD)
		YPOS = memory.read_u32_le(YBIRD_ADD)
		while memory.read_s8(ID_ADD)<=0 do
			memory.write_u32_le(XFREEZE_ADD, XFREEZE_VAL)
			memory.write_u32_le(YFREEZE_ADD, YFREEZE_VAL)
			memory.write_u32_le(0x116B0C, XFREEZE_VAL3)
			memory.write_u32_le(0x116B10, YFREEZE_VAL3)
			emu.frameadvance()
		end
	end
	
	while (memory.read_s16_le(0x11E9BA)<=119 or memory.read_s16_le(0x11E9BA)>=221)
	and (memory.read_s16_le(0x11E9D2)<=119 or memory.read_s16_le(0x11E9D2)>=221) 
	and (memory.read_s16_le(0x11E9EA)<=119 or memory.read_s16_le(0x11E9EA)>=221) 
	and (emu.framecount()-F1)<=TMAX
	do
		memory.write_u32_le(XFREEZE_ADD, XFREEZE_VAL)
		memory.write_u32_le(YFREEZE_ADD, YFREEZE_VAL)
		memory.write_u32_le(0x116B0C, XFREEZE_VAL3)
		memory.write_u32_le(0x116B10, YFREEZE_VAL3)
		emu.frameadvance()
	end
	
	F2 = emu.framecount()

	return F2-F1

end

local function has_value (tab, val)
    for index, value in ipairs(tab) do
        if value == val then
            return true
        end
    end

    return false
end


local F1 = 0
local F2 = 0
local ID = 0
local MF = 0
local MF2 = 0
local abc = 0
local i = 0
local j = 0
local k = 0
local XPOS = 0
local YPOS = 0

local RES = 0

local LISTPOS = {0}
local INDEX = 1

-- savestate.load("gulp_birds_x3")

--Gulp
memory.write_s32_le(0x1169AC, 36864)
memory.write_s32_le(0x1169B0, 18000) --18000 50000
memory.write_s32_le(0x1169B4, 17920)
--Spyro
memory.write_s32_le(0x69FF0, 36864)
memory.write_s32_le(0x69FF4, 46954) --46954 30000
memory.write_s32_le(0x69FF8, 18278)
savestate.save("gulp_birds_bot")

if BIRD==1 then

	XFREEZE_ADD = 0x116A04
	YFREEZE_ADD = 0x116A08
	ID_ADD = 0x116A99
	XBIRD_ADD = 0x116A5C
	YBIRD_ADD = 0x116A60
	
elseif BIRD==2 then

	XFREEZE_ADD = 0x116A5C
	YFREEZE_ADD = 0x116A60
	ID_ADD = 0x116A41
	XBIRD_ADD = 0x116A04
	YBIRD_ADD = 0x116A08
	
end



for k=ANGLE_DEB, ANGLE_FIN, ANGLE_MOV do --4094

	local CAMANGLE = k ---2047 + k*1
	
	-- savestate.loadslot(4)
	savestate.load("gulp_birds_bot")
	memory.write_s16_le(0x067F28, CAMANGLE)

	for abc=1, 4 do
		emu.frameadvance()
	end
	
	savestate.save("gulp_birds_bot2")
	
	if BIRD==1 then
		XPOS = memory.read_u32_le(0x116A5C)
		YPOS = memory.read_u32_le(0x116A60)
		emu.frameadvance()
		emu.frameadvance()
		XFREEZE_VAL = memory.read_u32_le(0x116A04)
		YFREEZE_VAL = memory.read_u32_le(0x116A08)
		XFREEZE_VAL3 = memory.read_u32_le(0x116B0C)
		YFREEZE_VAL3 = memory.read_u32_le(0x116B10)
	elseif BIRD==2 then
		XFREEZE_VAL = memory.read_u32_le(0x116A5C)
		YFREEZE_VAL = memory.read_u32_le(0x116A60)
		emu.frameadvance()
		emu.frameadvance()
		XPOS = memory.read_u32_le(0x116A04)
		YPOS = memory.read_u32_le(0x116A08)
		XFREEZE_VAL3 = memory.read_u32_le(0x116B0C)
		YFREEZE_VAL3 = memory.read_u32_le(0x116B10)
	end
	
	savestate.load("gulp_birds_bot2")
	
	if IDMIN==0 then
		TMIN = 1000
		for ID=8, 25 do
			
			RES = GET_TIME(BIRD, ID, TMIN)
			-- print(CAMANGLE .. "," .. ID .. "," .. RES .. "," .. RES .. "," .. XPOS*100000+YPOS)
			if RES<TMIN then
				TMIN = RES
				IDMIN = ID
			end
		end
		-- LISTPOS[INDEX] = XPOS*100000+YPOS
		-- INDEX = INDEX + 1
	end

	if has_value(LISTPOS, XPOS*100000+YPOS)==false then

		LISTPOS[INDEX] = XPOS*100000+YPOS
		INDEX = INDEX + 1
		
		RES = GET_TIME(BIRD, IDMIN, 1000)
		if RES>300 then
			TMIN = 1000
			IDMIN = 0
			for ID=8, 25 do
				
				RES = GET_TIME(BIRD, ID, TMIN)
				if RES<TMIN then
					TMIN = RES
					IDMIN = ID
				end
			end

		end
		print(CAMANGLE .. "," .. IDMIN .. "," .. RES .. "," .. RES .. "," .. XPOS*100000+YPOS)
		
	end

	
	

end

