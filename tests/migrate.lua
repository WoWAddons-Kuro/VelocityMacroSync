-- Offline tests for Core/Migrate.lua.  lua5.1 tests\migrate.lua
-- Fake API now has a General tab (sorted by name, like the client) and action slots.
package.path = "./?.lua;" .. package.path

local MAX_ACCT, MAX_CHAR, MAX_SLOT = 120, 18, 120
local W = { general = {}, char = {}, slots = {}, class = "WARRIOR", spells = {}, printed = {} }

MAX_ACCOUNT_MACROS, MAX_CHARACTER_MACROS = MAX_ACCT, MAX_CHAR
WOW_PROJECT_ID, WOW_PROJECT_CLASSIC = 2, 2
function GetBuildInfo() return "1.15.9", "70576", "Oct 22 2026", 11509 end
local function sortGeneral() table.sort(W.general, function(a, b) return a.name < b.name end) end
function GetNumMacros() return #W.general, #W.char end
-- Model the real client: a macro saved with the "?" icon whose body has
-- #showtooltip REPORTS the resolved spell's icon from GetMacroInfo, not the
-- stored "?". Blank the body and it reports the stored icon. That is the
-- trap Macros.StoredIcon exists to step around.
local QM = "INV_MISC_QUESTIONMARK"
local function displayedIcon(m)
	if (m.icon == QM or m.icon == 134400) and m.body ~= "" and m.body:match("#showtooltip") then
		return 999001   -- "the spell's icon right now"
	end
	return m.icon
end
function GetMacroInfo(i)
	local m = (i <= MAX_ACCT) and W.general[i] or W.char[i - MAX_ACCT]
	if m then return m.name, displayedIcon(m), m.body end
end
function GetMacroIndexByName(name)
	for i, m in ipairs(W.general) do if m.name == name then return i end end
	for i, m in ipairs(W.char) do if m.name == name then return MAX_ACCT + i end end
	return 0
end
function CreateMacro(name, icon, body, perChar)
	assert(perChar == true, "migration must only create CHARACTER macros")
	assert(#W.char < MAX_CHAR, "slots full")
	table.insert(W.char, { name = name, icon = icon, body = body }); return MAX_ACCT + #W.char
end
function EditMacro(i, name, icon, body)
	local m = (i <= MAX_ACCT) and W.general[i] or W.char[i - MAX_ACCT]
	assert(m, "EditMacro on empty index " .. i)
	-- Real client: the icon you pass is what gets STORED. If the caller
	-- round-trips a displayed spell icon back in, the "?" is lost for good.
	-- Macros.StoredIcon must therefore never hand us the display value.
	assert(icon ~= 999001, "EditMacro was given the DISPLAYED icon (999001); stored '?' would be destroyed")
	m.name, m.icon, m.body = name, icon, body
	if i <= MAX_ACCT then sortGeneral() end
end
function DeleteMacro() error("ADDON CALLED DeleteMacro - FORBIDDEN") end
-- action bar: slot -> macro NAME (what GetActionText returns)
function HasAction(s) return W.slots[s] ~= nil end
function GetActionInfo(s) if W.slots[s] then return "macro", 0 end end
function GetActionText(s) return W.slots[s] end
local cursor
function PickupMacro(i) local n = GetMacroInfo(i); assert(n, "pickup empty"); cursor = n end
function PlaceAction(s) assert(cursor, "place with empty cursor"); W.slots[s] = cursor end
function ClearCursor() cursor = nil end
function UnitGUID() return "G" end
function UnitName() return "Kuro" end
function UnitClass() return "Warrior", W.class end
function InCombatLockdown() return false end
BOOKTYPE_SPELL = "spell"
function GetNumSpellTabs() return 2 end
function GetSpellTabInfo(tab) if tab == 1 then return "General", "", 0, 0 end return W.class, "", 0, #W.spells end
function GetSpellBookItemName(i) return W.spells[i] end
C_Timer = { After = function(_, f) f() end }
StaticPopupDialogs = {}; function StaticPopup_Show() end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) W.printed[#W.printed + 1] = m end }
function CreateFrame() return { RegisterEvent = function() end, SetScript = function() end } end

local NS = {}
local function load(f) assert(loadfile(f))("VelocityMacroSync", NS) end
for _, f in ipairs { "Core/Util.lua", "Client/Client.lua", "Client/Client_ClassicEra.lua", "Client/Client_Forever.lua", "Client/Client_Retail.lua", "Client/Client_Select.lua", "Core/Macros.lua", "Core/SpellSets.lua", "Core/Classify.lua", "Core/Merge.lua", "Core/Sync.lua", "Core/Migrate.lua" } do load(f) end
NS.db = { classes = {}, chars = {}, classSpells = {}, autoMigrate = false }
local M = NS.Migrate

local function expect(label, got, want)
	if got ~= want then error(label .. "\n  got:  " .. tostring(got) .. "\n  want: " .. tostring(want), 2) end
	print("ok   " .. label)
end
local function general() local t = {} for _, m in ipairs(W.general) do t[#t + 1] = m.name end return table.concat(t, ",") end
local function charTab() local t = {} for _, m in ipairs(W.char) do t[#t + 1] = m.name end return table.concat(t, ",") end
local function addGeneral(name, body, icon) table.insert(W.general, { name = name, icon = icon or 1, body = body }); sortGeneral() end

-- spell sets: warrior knows Charge etc; mage knows Frostbolt
W.spells = { "Charge", "Intercept", "Berserker Stance", "Battle Stance", "Heroic Strike" }
NS.SpellSets.Refresh()
NS.db.classSpells.MAGE = { Frostbolt = true, Blink = true }

-------------------------------------------------------------------- setup
local CHARGE = "#showtooltip\n/targetenemy [noexists,nocombat][dead,nocombat]\n/cast [stance:1,nocombat] Charge; [stance:3,combat] Intercept; [combat] Berserker Stance; Battle Stance"
addGeneral("charge", CHARGE, QM)        -- user left it on "?" so #showtooltip drives the icon
addGeneral("frost", "/cast Frostbolt")
addGeneral("hello", "/say hello")
addGeneral("hs", "/cast Heroic Strike")        -- warrior, but NOT on bars
W.slots[1] = "charge"; W.slots[13] = "charge"; W.slots[2] = "frost"; W.slots[3] = "hello"
expect("setup general", general(), "charge,frost,hello,hs")

-------------------------------------------------------------------- tag format: body preserved, tag after #-header, class recoverable
local tagged = M.TaggedBody("#showtooltip\n/cast Charge", "WARRIOR")
expect("tag goes AFTER #showtooltip, before first command", tagged, "#showtooltip\n#:VMS:WARRIOR\n/cast Charge")
expect("tag with no header goes first", M.TaggedBody("/cast Charge", "WARRIOR"), "#:VMS:WARRIOR\n/cast Charge")
expect("tag after multiple # lines", M.TaggedBody("#showtooltip\n#show Charge\n/cast Charge", "WARRIOR"), "#showtooltip\n#show Charge\n#:VMS:WARRIOR\n/cast Charge")
local base, cls = M.Untag(tagged)
expect("untag recovers body exactly", base, "#showtooltip\n/cast Charge")
expect("untag recovers class", cls, "WARRIOR")
expect("untag of untagged body is identity", (M.Untag("/cast Charge")), "/cast Charge")
local p = M.ParseStub(tagged)
expect("parse: class", p.class, "WARRIOR")
expect("parse: hash is of ORIGINAL body", p.hash, NS.MacroKey("#showtooltip\n/cast Charge"))
-- a body already at the cap cannot take the tag; TaggedBody returns nil and One() renames without it
local fat = string.rep("/say x\n", 36):sub(1, 250)
expect("fat body refuses tag", M.TaggedBody(fat, "WARRIOR"), nil)
expect("IsStub is by NAME alone (tag optional)", M.IsStub("~~vms~001", "/cast x"), true)
expect("plain zz001 is NOT ours", M.IsStubName("zz001"), false)
expect("zzreal is not a stub name", M.IsStubName("zzreal"), false)
expect("first stub name", M.NextStubName(), "~~vms~001")

-------------------------------------------------------------------- Auto: disabled does nothing
expect("auto disabled", M.Auto(), 0)
expect("nothing changed", general(), "charge,frost,hello,hs")

-------------------------------------------------------------------- Auto: enabled, warrior
NS.db.autoMigrate = true
expect("auto moved exactly one", M.Auto(), 1)
expect("char tab has charge", charTab(), "charge")
expect("general: charge became zz001, hs untouched (not on bars), frost/hello untouched", general(), "frost,hello,hs,~~vms~001")
expect("slot 1 now points at class macro", W.slots[1], "charge")
expect("slot 13 too", W.slots[13], "charge")
expect("slot 2 (frost, mage) untouched", W.slots[2], "frost")
expect("slot 3 (hello) untouched", W.slots[3], "hello")
local stub = W.general[4]
local sp = M.ParseStub(stub.body)
expect("migrated general carries class tag", sp.class, "WARRIOR")
expect("migrated general body hashes to the ORIGINAL", sp.hash, NS.MacroKey(CHARGE))
expect("migrated general STILL WORKS: body intact minus tag", sp.body, CHARGE)
expect("tag sits after #showtooltip", stub.body:match("^#showtooltip\n#:VMS:WARRIOR\n") ~= nil, true)
expect("renamed general keeps the user's '?' icon, not the displayed spell icon", stub.icon, QM)
local classCharge
for _, m in ipairs(W.char) do if m.body == CHARGE then classCharge = m end end
expect("class copy ALSO has the user's '?' icon (dynamic #showtooltip preserved)", classCharge.icon, QM)
expect("general count unchanged (nothing deleted)", #W.general, 4)

-------------------------------------------------------------------- Auto again: idempotent
expect("auto again does nothing", M.Auto(), 0)
expect("still one class macro", charTab(), "charge")

-------------------------------------------------------------------- One(): explicit, not gated by bars
local hsIdx = GetMacroIndexByName("hs")
local ok, why = M.One(hsIdx)
expect("explicit migrate of off-bar macro succeeds", ok, true)
expect("char tab now charge,hs", charTab(), "charge,hs")
expect("second stub numbered", general(), "frost,hello,~~vms~001,~~vms~002")

-------------------------------------------------------------------- One(): refuses wrong class / no class / stub
ok, why = M.One(GetMacroIndexByName("frost"))
expect("refuses mage macro on warrior", ok, false)
expect("reason names the class", why, "belongs to MAGE, not WARRIOR")
ok, why = M.One(GetMacroIndexByName("hello"))
expect("refuses no-class-spell macro", ok, false)
expect("reason", why, "no class spell")
ok, why = M.One(GetMacroIndexByName("~~vms~001"))
expect("refuses stub", ok, false)
expect("reason stub", why, "already migrated")

-------------------------------------------------------------------- rule 5: name clash on the page -> migrated copy gets 'Name 2', existing untouched
table.insert(W.char, { name = "slam", icon = 9, body = "/cast Slam" })
addGeneral("slam", "/cast Heroic Strike\n/cast Charge")
ok = M.One(GetMacroIndexByName("slam"))
expect("clash migrate ok", ok, true)
local names = {} for _, m in ipairs(W.char) do if m.name:find("^slam") then names[#names + 1] = m.name .. "=" .. m.body:gsub("\n", "|") end end
table.sort(names)
expect("player's slam kept, migrated is 'slam 2'", table.concat(names, " ; "), "slam 2=/cast Heroic Strike|/cast Charge ; slam=/cast Slam")

-------------------------------------------------------------------- #nosync
addGeneral("secret", "#nosync\n/cast Charge")
W.slots[20] = "secret"
expect("auto skips #nosync even on bars", M.Auto(), 0)
ok, why = M.One(GetMacroIndexByName("secret"))
expect("explicit refuses #nosync", ok, false)
expect("reason nosync", why, "#nosync")

-------------------------------------------------------------------- M5: Remap on "another character of the class"
-- Simulate: this is warrior B logging in. General tab (account-wide) already has the
-- stubs from A; B's bars still reference them by name. Sync has put the class macros
-- on B's page. Remap must re-point B's buttons.
W.char = {}                                            -- fresh page
W.slots = {}
-- Sync gives B the class macros (same bodies). Different NAME for charge on B to prove hash wins.
table.insert(W.char, { name = "Charge!", icon = 1, body = CHARGE })
table.insert(W.char, { name = "hs", icon = 1, body = "/cast Heroic Strike" })
W.slots[1] = "~~vms~001"; W.slots[7] = "~~vms~001"; W.slots[8] = "~~vms~002"
W.slots[9] = "frost"                                  -- not a stub, untouched
local n, unresolved = M.Remap()
expect("remap count", n, 3)
expect("slot 1 -> class macro by HASH despite rename", W.slots[1], "Charge!")
expect("slot 7 too", W.slots[7], "Charge!")
expect("slot 8 -> hs", W.slots[8], "hs")
expect("non-stub slot untouched", W.slots[9], "frost")
expect("no unresolved", #unresolved, 0)
expect("remap idempotent", (M.Remap()), 0)

-------------------------------------------------------------------- M5: migrated macro of ANOTHER class on this bar is ignored
addGeneral("~~vms~003", M.TaggedBody("/cast Frostbolt", "MAGE"))
W.slots[10] = "~~vms~003"
expect("foreign-class migrated macro ignored", (M.Remap()), 0)
expect("foreign migrated macro still on bar", W.slots[10], "~~vms~003")

-------------------------------------------------------------------- M5: unresolved (class macro not synced here yet) warns, leaves it
addGeneral("~~vms~004", M.TaggedBody("/cast Ghost Strike", "WARRIOR"))
W.slots[11] = "~~vms~004"
W.printed = {}
n, unresolved = M.Remap()
expect("unresolved count", #unresolved, 1)
expect("unresolved names the zz entry", unresolved[1], "~~vms~004")
expect("migrated macro left on bar", W.slots[11], "~~vms~004")
local warned = false
for _, l in ipairs(W.printed) do if l:find("Could not find") then warned = true end end
expect("warned", warned, true)

print("\nMIGRATE TESTS PASSED - DeleteMacro was never called")
