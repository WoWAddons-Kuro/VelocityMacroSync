-- Offline test for Core/Merge.lua + Core/Sync.lua against a fake macro API.
-- Run from the addon folder:  lua5.1 tests\run.lua
package.path = "./?.lua;" .. package.path

-------------------------------------------------------------------- fake client
local MAX_ACCT, MAX_CHAR = 120, 18
local World = { chars = {}, current = nil, printed = {}, deletes = 0 }
local function cur() return World.chars[World.current] end

MAX_ACCOUNT_MACROS, MAX_CHARACTER_MACROS = MAX_ACCT, MAX_CHAR
WOW_PROJECT_ID, WOW_PROJECT_CLASSIC = 2, 2
function GetNumMacros() return 0, #cur().macros end
function GetMacroInfo(i) local m = cur().macros[i - MAX_ACCT]; if m then return m.name, m.icon, m.body end end
function CreateMacro(name, icon, body, perChar)
	assert(perChar == true); assert(#cur().macros < MAX_CHAR, "slots full")
	table.insert(cur().macros, { name = name, icon = icon, body = body }); return MAX_ACCT + #cur().macros
end
function EditMacro(i, name, icon, body) local m = assert(cur().macros[i - MAX_ACCT]); m.name, m.icon, m.body = name, icon, body end
-- The ADDON must never call this. The PLAYER does, via playerDelete below.
function DeleteMacro() error("ADDON CALLED DeleteMacro - FORBIDDEN") end
local function playerDelete(name)
	for i, m in ipairs(cur().macros) do if m.name == name then table.remove(cur().macros, i) return end end
	error("no macro " .. name)
end
function UnitGUID() return cur().guid end
function UnitName() return cur().name end
function UnitClass() return "Warrior", cur().class end
function InCombatLockdown() return false end
local timers = {}
C_Timer = { After = function(_, f) timers[#timers + 1] = f end }
local function flushTimers() local t = timers; timers = {}; for _, f in ipairs(t) do f() end end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) World.printed[#World.printed + 1] = m end }
function CreateFrame() return { RegisterEvent = function() end, SetScript = function() end } end

-------------------------------------------------------------------- load addon
local NS = {}
local function load(file) local f = assert(loadfile(file)); f("VelocityMacroSync", NS) end
for _, f in ipairs { "Core/Util.lua", "Client/Client.lua", "Client/Client_ClassicEra.lua", "Client/Client_Forever.lua", "Client/Client_Select.lua", "Core/Macros.lua", "Core/Merge.lua", "Core/Sync.lua" } do load(f) end
NS.db = { classes = {}, chars = {}, debug = false }
assert(NS.Macros.Delete == nil, "Macros.Delete must not exist")

-------------------------------------------------------------------- helpers
local function login(guid) World.current = guid; NS.Sync.Run("login"); flushTimers() end
local function edit() NS.Sync.Run("edit"); flushTimers() end
local function names()
	local t = {}; for _, m in ipairs(cur().macros) do t[#t + 1] = m.name .. "=" .. m.body end; table.sort(t); return table.concat(t, " | ")
end
local function expect(label, got, want)
	if got ~= want then error(label .. "\n  got:  " .. tostring(got) .. "\n  want: " .. tostring(want), 2) end
	print("ok   " .. label)
end
local function addChar(guid, name, macros) World.chars[guid] = { guid = guid, name = name, class = "WARRIOR", macros = macros } end

-------------------------------------------------------------------- 1: the bug report. char1 adds Charge; fresh char2 must receive it
addChar("W1", "Warr1", {})
addChar("W2", "Warr2", {})
login("W1")
CreateMacro("Charge", 1, "/cast Charge", true); edit()
login("W2")
expect("fresh char receives Charge", names(), "Charge=/cast Charge")
login("W1")
expect("W1 still has Charge", names(), "Charge=/cast Charge")

-------------------------------------------------------------------- 2: three-way union
addChar("A", "MA", { { name = "Frost", icon = 1, body = "/cast Frostbolt" } })
addChar("B", "MB", { { name = "Fire", icon = 2, body = "/cast Fireball" } })
addChar("C", "MC", { { name = "Blink", icon = 3, body = "/cast Blink" } })
login("A"); login("B"); login("C"); login("A"); login("B")
local all = "Blink=/cast Blink | Charge=/cast Charge | Fire=/cast Fireball | Frost=/cast Frostbolt"
World.current = "A"; expect("union A", names(), all)
World.current = "B"; expect("union B", names(), all)
World.current = "C"; expect("union C", names(), all)

-------------------------------------------------------------------- 3: edit propagates in place
World.current = "A"
for i, m in ipairs(cur().macros) do if m.name == "Frost" then EditMacro(MAX_ACCT + i, "Frost", 1, "/cast Frostbolt(Rank 2)") end end
edit()
login("B")
expect("edit -> B", names(), "Blink=/cast Blink | Charge=/cast Charge | Fire=/cast Fireball | Frost=/cast Frostbolt(Rank 2)")
expect("edit kept slot count", #cur().macros, 4)

-------------------------------------------------------------------- 4: player delete = tombstone here ONLY; others keep it; never recreated here
World.current = "B"
playerDelete("Fire"); edit()
expect("B lost Fire by its own hand", names(), "Blink=/cast Blink | Charge=/cast Charge | Frost=/cast Frostbolt(Rank 2)")
login("B")
expect("B: Fire NOT recreated", names(), "Blink=/cast Blink | Charge=/cast Charge | Frost=/cast Frostbolt(Rank 2)")
login("C")
expect("C still has Fire", names():find("Fire=") ~= nil, true)
login("A")
expect("A still has Fire", names():find("Fire=") ~= nil, true)
expect("class set unchanged", NS.db.classes.WARRIOR[NS.MacroKey("Fire", "/cast Fireball")] ~= nil, true)
expect("B tombstoned", NS.db.chars.B.excluded[NS.MacroKey("Fire", "/cast Fireball")], true)

-------------------------------------------------------------------- 5: first-sync fork keeps both
addChar("D", "MD", { { name = "Frost", icon = 9, body = "/cast Frost Nova" } })
login("D")
expect("fork keeps both on D", names():find("Frost~2=/cast Frost Nova") ~= nil and names():find("Frost=/cast Frostbolt%(Rank 2%)") ~= nil, true)
login("A")
expect("renamed reaches A", names():find("Frost~2=/cast Frost Nova") ~= nil, true)

-------------------------------------------------------------------- 6: overflow fills what fits and warns
local big = {}
for i = 1, 18 do big[i] = { name = "M" .. i, icon = i, body = "/say " .. i } end
addChar("E", "ME", big)
login("E")
expect("E still 18", #cur().macros, 18)
local warned = false
for _, l in ipairs(World.printed) do if l:find("did not fit") then warned = true end end
expect("overflow warned", warned, true)

-------------------------------------------------------------------- 7: idempotent
login("C"); World.printed = {}; login("C")
local onlyOverflow = true
for _, l in ipairs(World.printed) do if not l:find("did not fit") then onlyOverflow = false end end
expect("idempotent: silent", #World.printed, 0)

print("\nALL TESTS PASSED - DeleteMacro was never called")
