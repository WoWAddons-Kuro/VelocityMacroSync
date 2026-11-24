-- Offline test for Core/Merge.lua + Core/Sync.lua against a fake macro API.
-- Run from the addon folder:  lua5.1 tests\run.lua
package.path = "./?.lua;" .. package.path

-------------------------------------------------------------------- fake client
local MAX_ACCT, MAX_CHAR = 120, 18
local World = { chars = {}, current = nil, printed = {}, deletes = 0 }
local function cur() return World.chars[World.current] end

MAX_ACCOUNT_MACROS, MAX_CHARACTER_MACROS = MAX_ACCT, MAX_CHAR
WOW_PROJECT_ID, WOW_PROJECT_CLASSIC = 2, 2
function GetBuildInfo() return "1.15.9", "70576", "Oct 22 2026", 11509 end
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
function UnitNameUnmodified() return cur().name end
time, date = os.time, os.date
function UnitClass() return "Warrior", cur().class end
function InCombatLockdown() return false end
-- Fake spellbook: tab 1 = General (skipped), tab 2 = class spells for the current char.
BOOKTYPE_SPELL = "spell"
function GetNumSpellTabs() return 2 end
function GetSpellTabInfo(tab)
	if tab == 1 then return "General", "", 0, 2 end
	return cur().class, "", 2, #(cur().spells or {})
end
function GetSpellBookItemName(i) if i <= 2 then return ({ "Attack", "Shoot" })[i] end return (cur().spells or {})[i - 2] end
local timers = {}
C_Timer = { After = function(_, f) timers[#timers + 1] = f end }
local function flushTimers() local t = timers; timers = {}; for _, f in ipairs(t) do f() end end
StaticPopupDialogs = {}; function StaticPopup_Show() end; DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) World.printed[#World.printed + 1] = m end }
function CreateFrame() return { RegisterEvent = function() end, SetScript = function() end } end

-------------------------------------------------------------------- load addon
local NS = {}
local function load(file) local f = assert(loadfile(file)); f("VelocityMacroSync", NS) end
for _, f in ipairs { "Core/Util.lua", "Client/Client.lua", "Client/Client_ClassicEra.lua", "Client/Client_Forever.lua", "Client/Client_Retail.lua", "Client/Client_Select.lua", "Core/Macros.lua", "Core/SpellSets.lua", "Core/Merge.lua", "Core/Sync.lua" } do load(f) end
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

-------------------------------------------------------------------- 3: body edit on A. B's own "Frost" is NEVER touched; the new body arrives beside it under a free name
-------------------------------------------------------------------- 2b: THE TYPO FIX. Edit a shared macro's body in place -> class set has ONE entry, not two
addChar("P1", "Priest1", {})
addChar("P2", "Priest2", {})
World.chars.P1.class = "PRIEST"; World.chars.P2.class = "PRIEST"
login("P1")
CreateMacro("swp", 1, "#showtooltip\n/startattack\n/cast Shadow Word Pain", true); edit()   -- typo: no colon
local function priestSet()
	local t = {}
	for _, e in pairs(NS.db.classes.PRIEST or {}) do t[#t + 1] = e.name .. "=" .. e.body:gsub("\n", "|") end
	table.sort(t); return table.concat(t, " ;; ")
end
expect("typo version shared", priestSet(), "swp=#showtooltip|/startattack|/cast Shadow Word Pain")
-- fix the typo IN PLACE on the same macro (same name, new body)
for i, m in ipairs(cur().macros) do if m.name == "swp" then EditMacro(MAX_ACCT + i, "swp", 1, "#showtooltip\n/startattack\n/cast Shadow Word: Pain") end end
edit()
expect("class set has ONE swp, the fixed one (not a fork)", priestSet(), "swp=#showtooltip|/startattack|/cast Shadow Word: Pain")
expect("P1 page has exactly one swp", (function() local n = 0 for _, m in ipairs(cur().macros) do if m.name == "swp" then n = n + 1 end end return n end)(), 1)
expect("P1 has NO tombstone for the typo body (it was an edit, not a delete)", #NS.Sync.ExcludedHere(), 0)
-- the other priest picks up the fix in place, not as a second macro
login("P2")
expect("P2 got the fixed body", names(), "swp=#showtooltip\n/startattack\n/cast Shadow Word: Pain")
login("P1")
expect("P1 unchanged after round trip", (function() local n = 0 for _, m in ipairs(cur().macros) do if m.name == "swp" then n = n + 1 end end return n end)(), 1)

-------------------------------------------------------------------- 2c: empty macros are never shared
World.current = "P1"
CreateMacro("New Macro", 1, "", true); edit()
expect("empty body NOT in class set", priestSet():find("New Macro") == nil, true)
CreateMacro("blank2", 1, "   \n  ", true); edit()
expect("whitespace-only body NOT in class set", priestSet():find("blank2") == nil, true)
login("P2")
expect("P2 did not receive the empty macros", names():find("New Macro") == nil and names():find("blank2") == nil, true)

-------------------------------------------------------------------- 2d: typo fix on one char while another has the old body -> that char is EDITED in place, not given a sibling
-- P2 currently has the fixed swp. Edit it AGAIN on P1 to a third body; P2 must end with one swp, the newest.
World.current = "P1"
for i, m in ipairs(cur().macros) do if m.name == "swp" then EditMacro(MAX_ACCT + i, "swp", 1, "#showtooltip\n/cast Shadow Word: Pain\n/startattack") end end
edit()
login("P2")
local swpCount, swpBody = 0, nil
for _, m in ipairs(cur().macros) do if m.name == "swp" then swpCount = swpCount + 1; swpBody = m.body end end
expect("P2 still has exactly one swp", swpCount, 1)
expect("P2's swp is the newest body", swpBody, "#showtooltip\n/cast Shadow Word: Pain\n/startattack")
expect("P2 has no tombstones from the edits", #NS.Sync.ExcludedHere(), 0)
expect("class set still ONE swp", priestSet(), "swp=#showtooltip|/cast Shadow Word: Pain|/startattack")

-------------------------------------------------------------------- 3: body edit on A propagates IN PLACE to B (same macro, new text) - never a sibling
World.current = "A"
for i, m in ipairs(cur().macros) do if m.name == "Frost" then EditMacro(MAX_ACCT + i, "Frost", 1, "/cast Frostbolt(Rank 2)") end end
edit()
login("B")
expect("edit -> B edits B's Frost in place, ONE Frost", names(), "Blink=/cast Blink | Charge=/cast Charge | Fire=/cast Fireball | Frost=/cast Frostbolt(Rank 2)")
local frostEntries = 0
for _, e in pairs(NS.db.classes.WARRIOR) do if e.name == "Frost" then frostEntries = frostEntries + 1 end end
expect("class set has exactly ONE Frost after the edit", frostEntries, 1)
login("A")
expect("A: old Frost body NOT recreated (edited away here)", names():find("Frost=/cast Frostbolt |") == nil and names():find("Frostbolt(Rank 2)", 1, true) ~= nil, true)

-------------------------------------------------------------------- 4: player delete = tombstone here ONLY; others keep it; never recreated here
World.current = "B"
playerDelete("Fire"); edit()
expect("B lost Fire by its own hand", names():find("Fire=") == nil, true)
login("B")
expect("B: Fire NOT recreated", names():find("Fire=") == nil, true)
login("C")
expect("C still has Fire", names():find("Fire=") ~= nil, true)
login("A")
expect("A still has Fire", names():find("Fire=") ~= nil, true)
expect("class set unchanged", NS.db.classes.WARRIOR[NS.MacroKey("/cast Fireball")] ~= nil, true)
expect("B tombstoned", NS.db.chars.B.excluded[NS.MacroKey("/cast Fireball")], true)

-------------------------------------------------------------------- 4b: tombstone is visible and restorable
World.current = "B"
local ex = NS.Sync.ExcludedHere()
expect("B sees one excluded", #ex, 1)
expect("excluded is Fire", ex[1].name, "Fire")
expect("excluded carries body", ex[1].body, "/cast Fireball")
local ok = NS.Sync.Restore(ex[1].hash)
flushTimers()
expect("restore ok", ok, true)
expect("B has Fire again", names():find("Fire=/cast Fireball") ~= nil, true)
expect("tombstone cleared", NS.db.chars.B.excluded[NS.MacroKey("/cast Fireball")], nil)
expect("B sees none excluded now", #NS.Sync.ExcludedHere(), 0)
expect("restore of non-excluded refuses", (NS.Sync.Restore("00000000")), false)

-------------------------------------------------------------------- 5: THE BUG. rename on one char must propagate, never fork into Name~2
World.current = "A"
for i, m in ipairs(cur().macros) do if m.name == "Charge" then EditMacro(MAX_ACCT + i, "charge", m.icon, m.body) end end
edit()
expect("A renamed Charge -> charge", names():find("charge=/cast Charge") ~= nil and names():find("Charge=") == nil, true)
login("C")
expect("rename reaches C in place", names():find("charge=/cast Charge") ~= nil and names():find("Charge=") == nil, true)
login("A")
expect("A unchanged after round trip", names():find("charge=/cast Charge") ~= nil and names():find("Charge=") == nil, true)
local tilde = false
for _, ch in pairs(World.chars) do for _, m in ipairs(ch.macros) do if m.name:find("~") then tilde = true end end end
expect("NO ~N names anywhere", tilde, false)
local chargeCount = 0
for _, m in ipairs(cur().macros) do if m.body == "/cast Charge" then chargeCount = chargeCount + 1 end end
expect("exactly one Charge macro on A", chargeCount, 1)

addChar("D", "MD", { { name = "Frosty", icon = 9, body = "/cast Frostbolt(Rank 2)" } })
login("D")
local rank2 = 0
for _, m in ipairs(cur().macros) do if m.body == "/cast Frostbolt(Rank 2)" then rank2 = rank2 + 1 end end
expect("D: exactly one macro with that body", rank2, 1)
expect("D: no ~N", names():find("~") == nil, true)

-------------------------------------------------------------------- 5c: THE RULE. player makes a NEW "charge" with a different body: it stays "charge"
addChar("F", "MF", {})
login("F")                                               -- F receives the shared "charge"
expect("F got shared charge", names():find("charge=/cast Charge") ~= nil, true)
-- The client fires UPDATE_MACROS per operation, so a merge runs after the delete
-- (tombstoning the old body) BEFORE the create is seen. That is what separates
-- "deleted it and made a new one" from "edited it": the tombstone in between.
playerDelete("charge"); edit()                          -- player removes it... (merge: tombstone)
CreateMacro("charge", 5, "/cast Charge\n/startattack", true)  -- ...and makes their OWN "charge"
edit()
local function chargeNamesOn()
	local t = {}
	for _, m in ipairs(cur().macros) do if m.name:lower():find("^charge") then t[#t + 1] = m.name .. "=" .. m.body:gsub("\n", "\\n") end end
	table.sort(t); return table.concat(t, " | ")
end
expect("F: player's macro is still called charge, and it is the only charge", chargeNamesOn(), "charge=/cast Charge\\n/startattack")
login("F")
expect("F: still just that one charge after relogin (old body tombstoned here)", chargeNamesOn(), "charge=/cast Charge\\n/startattack")
-- the new body is shared; on A (which has the old "charge") it must arrive under a different name, A's own charge untouched
login("A")
local aOld, aNew = false, false
for _, m in ipairs(cur().macros) do
	if m.name == "charge" and m.body == "/cast Charge" then aOld = true end
	if m.body == "/cast Charge\n/startattack" then aNew = (m.name ~= "charge") end
end
expect("A: own charge untouched", aOld, true)
expect("A: incoming different-body charge got a free name", aNew, true)
tilde = false
for _, ch in pairs(World.chars) do for _, m in ipairs(ch.macros) do if m.name:find("~") then tilde = true end end end
expect("still NO ~N anywhere", tilde, false)

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

-------------------------------------------------------------------- 8: THE NAG. "?" icon spelled 134400 by GetMacroInfo (Forever) vs INV_MISC_QUESTIONMARK in the class set
-- Reproduces the live SavedVariables: class entry (old build) holds the string,
-- page+snapshot hold the fileID. Must plan NOTHING, and must stay silent on relogin.
addChar("DR1", "Druid1", { { name = "claw", icon = 134400, body = "#showtooltip\n/cast Claw\n/startattack\n" } })
World.chars.DR1.class = "DRUID"
NS.db.classes.DRUID = { [NS.MacroKey("#showtooltip\n/cast Claw\n/startattack\n")] = { name = "claw", icon = "INV_MISC_QUESTIONMARK", body = "#showtooltip\n/cast Claw\n/startattack\n", seq = 5 } }
NS.db.chars.DR1 = { class = "DRUID", excluded = {}, snapshot = { [NS.MacroKey("#showtooltip\n/cast Claw\n/startattack\n")] = { name = "claw", icon = 134400 } } }
World.printed = {}
login("DR1")
expect("icon spelling: no 'Updated' nag", (function() for _, l in ipairs(World.printed) do if l:find("Updated") then return l end end return nil end)(), nil)
expect("icon spelling: page icon untouched", cur().macros[1].icon, 134400)
World.printed = {}; login("DR1")
expect("icon spelling: second login silent", #World.printed, 0)
expect("snapshot now carries class seq", NS.db.chars.DR1.snapshot[NS.MacroKey("#showtooltip\n/cast Claw\n/startattack\n")].seq, 5)

-------------------------------------------------------------------- 9: idempotence guard: same seq => never a localEdit even if an encoding quirk slips through
-- Simulate GetMacroInfo returning yet another spelling (lowercase path) that the page keeps echoing back.
local clawHash = NS.MacroKey("#showtooltip\n/cast Claw\n/startattack\n")
cur().macros[1].icon = "interface\\icons\\inv_misc_questionmark"
NS.db.chars.DR1.snapshot[clawHash].icon = "interface\\icons\\inv_misc_questionmark"
World.printed = {}; login("DR1")
expect("guard: alt spelling silent", #World.printed, 0)

-------------------------------------------------------------------- 10: provenance. A real attr change elsewhere bumps seq, follows, and names the editor
addChar("DR2", "Druid2", {})
World.chars.DR2.class = "DRUID"
login("DR2")
expect("DR2 received claw", names(), "claw=#showtooltip\n/cast Claw\n/startattack\n")
EditMacro(MAX_ACCT + 1, "Claw!", 134400, cur().macros[1].body); edit()
local e = NS.db.classes.DRUID[clawHash]
expect("attr change bumped seq", e.seq > 5, true)
expect("attr change stamped by", e.by, "Druid2")
expect("attr change stamped mtime", type(e.mtime), "number")
World.printed = {}; login("DR1")
expect("DR1 followed rename", cur().macros[1].name, "Claw!")
expect("message names the editor", (function() for _, l in ipairs(World.printed) do if l:find("edited on Druid2") then return true end end return false end)(), true)
World.printed = {}; login("DR1")
expect("provenance: relogin silent", #World.printed, 0)

print("\nALL TESTS PASSED - DeleteMacro was never called")
