-- Offline test for the schema-4 icon repair in VelocityMacroSync.lua.
-- Simulates the saved data the displayed-icon bug produced and checks the
-- ADDON_LOADED migration puts the '?' back on every #showtooltip macro.
--   lua5.1 tests\schema4.lua
package.path = "./?.lua;" .. package.path

-- Minimal fake world: just enough for Util/Macros to load and ADDON_LOADED to fire.
local handlers = {}
local function fakeFrame() return { RegisterEvent = function() end, UnregisterEvent = function() end } end
local frames = {}
function CreateFrame() local fr = fakeFrame(); fr.SetScript = function(_, _, f) handlers[#handlers + 1] = { frame = fr, fn = f } end; return fr end
DEFAULT_CHAT_FRAME = { AddMessage = function() end }
StaticPopupDialogs = {}; function StaticPopup_Show() end
SlashCmdList = {}
function GetNumMacros() return 0, 0 end
function GetMacroInfo() end
function CreateMacro() end
function EditMacro() end

local NS = {}
local function load(f) assert(loadfile(f))("VelocityMacroSync", NS) end
load("Core/Util.lua")
NS.Client = { }    -- Macros.lua only needs the table to exist
load("Core/Macros.lua")
NS.Sync = { ForgetSession = function() end, Run = function() end }

local QM = NS.Macros.QUESTION_MARK
local DYN = "#showtooltip\n/cast Arcane Shot"
local STATIC = "/cast Heroic Strike"
local hDyn, hStatic = NS.MacroKey(DYN), NS.MacroKey(STATIC)

-- The buggy saved data: dynamic macro frozen to a spell icon (132218), static one on the user's icon (9).
VelocityMacroSyncDB = {
	schema = 3,
	classes = {
		HUNTER = { [hDyn] = { name = "arcane", icon = 132218, body = DYN, seq = 1 } },
		WARRIOR = { [hStatic] = { name = "hs", icon = 9, body = STATIC, seq = 2 } },
	},
	chars = {
		A = { class = "HUNTER", snapshot = { [hDyn] = { name = "arcane", icon = 132218 } }, excluded = {} },
		B = { class = "WARRIOR", snapshot = { [hStatic] = { name = "hs", icon = 9 } }, excluded = {} },
	},
}

load("VelocityMacroSync.lua")
for _, h in ipairs(handlers) do h.fn(h.frame, "ADDON_LOADED", "VelocityMacroSync") end

local function expect(label, got, want)
	if got ~= want then error(label .. "\n  got:  " .. tostring(got) .. "\n  want: " .. tostring(want), 2) end
	print("ok   " .. label)
end

expect("schema bumped", VelocityMacroSyncDB.schema, 4)
expect("#showtooltip macro icon repaired to '?'", VelocityMacroSyncDB.classes.HUNTER[hDyn].icon, QM)
expect("static macro icon left alone", VelocityMacroSyncDB.classes.WARRIOR[hStatic].icon, 9)
expect("snapshot for repaired hash cleared so merge re-pushes the icon", VelocityMacroSyncDB.chars.A.snapshot[hDyn], nil)
expect("snapshot for untouched hash kept", VelocityMacroSyncDB.chars.B.snapshot[hStatic] ~= nil, true)

-- Idempotent: running again on schema 4 changes nothing.
VelocityMacroSyncDB.classes.HUNTER[hDyn].icon = 555
for _, h in ipairs(handlers) do h.fn(h.frame, "ADDON_LOADED", "VelocityMacroSync") end
expect("does not re-run on schema 4", VelocityMacroSyncDB.classes.HUNTER[hDyn].icon, 555)

print("\nSCHEMA4 TESTS PASSED")
