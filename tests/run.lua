-- Offline test for Core/Merge.lua + Core/Sync.lua against a fake macro API.
-- Run from the addon folder:  lua5.1 tests\run.lua
package.path = "./?.lua;" .. package.path

-------------------------------------------------------------------- fake client
local MAX_ACCT, MAX_CHAR = 120, 18
local World = { chars = {}, current = nil, printed = {} }

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
function DeleteMacro(i) assert(table.remove(cur().macros, i - MAX_ACCT)) end
function UnitGUID() return cur().guid end
function UnitName() return cur().name end
function UnitClass() return "Mage", cur().class end
function InCombatLockdown() return false end
C_Timer = { After = function() end }
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) World.printed[#World.printed + 1] = m end }
local handlers = {}
function CreateFrame() return { RegisterEvent = function() end, SetScript = function(_, _, f) handlers[#handlers + 1] = f end } end

-------------------------------------------------------------------- load addon
local NS = {}
local function load(file) local f = assert(loadfile(file)); f("VelocityClassMacroSync", NS) end
for _, f in ipairs { "Core/Util.lua", "Client/Client.lua", "Client/Client_ClassicEra.lua", "Client/Client_Forever.lua", "Client/Client_Select.lua", "Core/Macros.lua", "Core/Merge.lua", "Core/Sync.lua" } do load(f) end
NS.db = { classes = {}, chars = {}, debug = false }

-------------------------------------------------------------------- helpers
local function login(guid)
	World.current = guid
	-- simulate a fresh session: reset Sync's session flags by re-running login path
	NS.Sync.Run("login")
end
local function names()
	local t = {}; for _, m in ipairs(cur().macros) do t[#t + 1] = m.name .. "=" .. m.body end; table.sort(t); return table.concat(t, " | ")
end
local function expect(label, got, want)
	if got ~= want then error(label .. "\n  got:  " .. tostring(got) .. "\n  want: " .. tostring(want), 2) end
	print("ok   " .. label)
end
local function addChar(guid, name, macros)
	World.chars[guid] = { guid = guid, name = name, class = "MAGE", macros = macros }
end

-------------------------------------------------------------------- scenario 1: three mages union
addChar("A", "MageA", { { name = "Frost", icon = 1, body = "/cast Frostbolt" } })
addChar("B", "MageB", { { name = "Fire", icon = 2, body = "/cast Fireball" } })
addChar("C", "MageC", { { name = "Blink", icon = 3, body = "/cast Blink" } })
login("A"); login("B"); login("C"); login("A"); login("B")
local all = "Blink=/cast Blink | Fire=/cast Fireball | Frost=/cast Frostbolt"
World.current = "A"; expect("union A", names(), all)
World.current = "B"; expect("union B", names(), all)
World.current = "C"; expect("union C", names(), all)

-------------------------------------------------------------------- scenario 2: edit propagates in place
World.current = "A"
EditMacro(MAX_ACCT + 1, "Frost", 1, "/cast Frostbolt(Rank 2)")
NS.Sync.Run("edit")
login("B")
expect("edit -> B", names(), "Blink=/cast Blink | Fire=/cast Fireball | Frost=/cast Frostbolt(Rank 2)")
expect("edit kept slot count", #cur().macros, 3)

-------------------------------------------------------------------- scenario 3: delete propagates
World.current = "B"
for i, m in ipairs(cur().macros) do if m.name == "Fire" then DeleteMacro(MAX_ACCT + i) break end end
NS.Sync.Run("edit")
login("C")
expect("delete -> C", names(), "Blink=/cast Blink | Frost=/cast Frostbolt(Rank 2)")
login("A")
expect("delete -> A", names(), "Blink=/cast Blink | Frost=/cast Frostbolt(Rank 2)")
expect("class set size", NS.CountTable(NS.db.classes.MAGE), 2)

-------------------------------------------------------------------- scenario 4: first-sync name conflict keeps both
addChar("D", "MageD", { { name = "Frost", icon = 9, body = "/cast Frost Nova" } })
login("D")
expect("conflict keeps both", names(), "Blink=/cast Blink | Frost=/cast Frostbolt(Rank 2) | Frost~2=/cast Frost Nova")
login("A")
expect("renamed reaches A", names(), "Blink=/cast Blink | Frost=/cast Frostbolt(Rank 2) | Frost~2=/cast Frost Nova")

-------------------------------------------------------------------- scenario 5: overflow warns, fills what fits
local big = {}
for i = 1, 18 do big[i] = { name = "M" .. i, icon = i, body = "/say " .. i } end
addChar("E", "MageE", big)
login("E")
expect("E still 18", #cur().macros, 18)
local warned = false
for _, l in ipairs(World.printed) do if l:find("did not fit") then warned = true end end
expect("overflow warned", warned, true)
expect("class set 21", NS.CountTable(NS.db.classes.MAGE), 21)

-------------------------------------------------------------------- scenario 6: idempotent
login("A")                         -- A fills to 18 (class set is 21) and warns
expect("A full", #cur().macros, 18)
World.printed = {}
login("A")
expect("idempotent: only overflow warning", #World.printed, 1)
expect("idempotent: it is the overflow line", World.printed[1]:find("did not fit") ~= nil, true)

print("\nALL TESTS PASSED")
