-- Velocity Macro Sync: General -> Class macro migration.
--
-- Moves a General-tab macro that belongs to this character's class into the
-- character tab (where Sync shares it with the class), re-points this
-- character's bar buttons at the new macro, and converts the general macro
-- into an inert STUB in place with EditMacro. The stub keeps every other
-- character's button references alive until they log in and remap (M5).
--
-- HARD RULES (00_VelocityMacroSync.md): nothing here deletes a macro, ever.
-- The stub IS the user's general macro, renamed and rewritten.
--
-- Two entry points:
--   Migrate.One(generalIndex)  explicit, from the settings page; not gated by
--                              autoMigrate or by bar placement.
--   Migrate.Auto()             login path; only if db.autoMigrate, and only
--                              general macros that are on this character's bars.
local ADDON, NS = ...
local Client, Macros, Classify, SpellSets = NS.Client, NS.Macros, NS.Classify, NS.SpellSets

local Migrate = {}
NS.Migrate = Migrate

Migrate.STUB_ICON = 134400                     -- INV_Misc_QuestionMark
Migrate.MARKER = "#VelocityMacroSync-migrated v1"

-- Stub body / parse. Hash goes before the name because names may contain spaces.
function Migrate.StubBody(class, hash, originalName)
	return string.format("%s %s %s %s", Migrate.MARKER, class, hash, originalName)
end

function Migrate.ParseStub(body)
	if not body then return nil end
	local class, hash, name = body:match("^#VelocityMacroSync%-migrated v1 (%u+) (%x+) (.+)$")
	if class then return { class = class, hash = hash, name = name } end
	return nil
end

function Migrate.IsStubName(name)
	return name ~= nil and name:match("^zz%d+$") ~= nil
end

function Migrate.IsStub(name, body)
	return Migrate.IsStubName(name) and Migrate.ParseStub(body) ~= nil
end

-- General-tab macros as { index, name, icon, body }. Indices 1..MaxAccountMacros.
function Migrate.ReadGeneral()
	local numGeneral = Client.GetNumMacros()
	local list = {}
	for i = 1, (numGeneral or 0) do
		local name, icon, body = Client.GetMacroInfo(i)
		if name then list[#list + 1] = { index = i, name = name, icon = icon, body = body or "" } end
	end
	return list
end

-- Next free zz### name: highest existing + 1 (scanned, never stored).
function Migrate.NextStubName(generalList)
	local max = 0
	for _, m in ipairs(generalList or Migrate.ReadGeneral()) do
		local n = m.name:match("^zz(%d+)$")
		if n then max = math.max(max, tonumber(n)) end
	end
	return string.format("zz%03d", max + 1)
end

-- Classifier verdict for a general macro (uses the live spell sets).
function Migrate.VerdictFor(body)
	return Classify.Verdict(body, SpellSets.ClassesFor)
end

-- Action slots on this character that hold the general macro named `name`.
local function SlotsHolding(name)
	local slots = {}
	for slot = 1, Client.MaxActionSlot() do
		if Client.ActionSlotMacroName(slot) == name then slots[#slots + 1] = slot end
	end
	return slots
end

-- Find the character-tab macro with this body, or create it. Returns its
-- index and the name it ended up with, or nil + reason.
local function FindOrCreateClassMacro(name, icon, body)
	local hash = NS.MacroKey(body)
	for _, m in ipairs(Macros.ReadCharacter()) do
		if NS.MacroKey(m.body) == hash then return m.index, m.name end
	end
	if Macros.FreeSlots() <= 0 then return nil, "character tab is full" end
	-- Product rule 5: never rename the player's macro. If the name is held on
	-- the page by a different body, the migrated copy takes a suffixed name.
	local taken = Macros.NamesInUse(Macros.ReadCharacter())
	local finalName = name
	if taken[finalName] then
		local n = 2
		repeat
			local suffix = " " .. n
			local base = name
			if #base + #suffix > 16 then base = base:sub(1, 16 - #suffix) end
			finalName = base .. suffix
			n = n + 1
		until not taken[finalName]
	end
	local idx = Macros.Create(finalName, icon, body)
	if not idx then return nil, "CreateMacro failed" end
	return idx, finalName
end

-- Migrate one general macro by index. Returns true, or false + reason.
-- Caller is responsible for the combat gate.
function Migrate.One(generalIndex, opts)
	opts = opts or {}
	local name, icon, body = Client.GetMacroInfo(generalIndex)
	if not name then return false, "no macro at that index" end
	if Migrate.IsStub(name, body) then return false, "already migrated" end

	local verdict = Migrate.VerdictFor(body)
	local myClass = Client.PlayerClass()
	if verdict.class ~= myClass then
		return false, verdict.class and ("belongs to " .. verdict.class .. ", not " .. myClass) or Classify.Describe(verdict)
	end

	local slots = SlotsHolding(name)
	if opts.requireOnBars and #slots == 0 then return false, "not on this character's bars" end

	local classIndex, classNameOrErr = FindOrCreateClassMacro(name, icon, body)
	if not classIndex then return false, classNameOrErr end

	-- Re-point this character's buttons at the class macro.
	for _, slot in ipairs(slots) do
		Client.PlaceMacroInSlot(classIndex, slot)
	end

	-- Convert the general macro to a stub IN PLACE. Resolve the index by name
	-- right now: creating the class macro did not renumber General, but be
	-- defensive about it anyway.
	local liveIndex = Client.GetMacroIndexByName(name)
	if not liveIndex or liveIndex == 0 or liveIndex > Client.MaxAccountMacros() then liveIndex = generalIndex end
	local stubName = Migrate.NextStubName()
	local ok = Macros.Edit(liveIndex, stubName, Migrate.STUB_ICON, Migrate.StubBody(myClass, NS.MacroKey(body), name))
	if not ok then return false, "EditMacro failed converting to stub" end

	NS.Print(string.format("Moved \"%s\" to your %s macros%s; %d bar button%s updated. General copy is now stub %s.",
		name, (UnitClass("player")) or myClass,
		classNameOrErr ~= name and (" as \"" .. classNameOrErr .. "\"") or "",
		#slots, #slots == 1 and "" or "s", stubName))
	return true
end

-- Login path. Only general macros on this character's bars, only if enabled.
function Migrate.Auto()
	if not (NS.db and NS.db.autoMigrate) then return 0 end
	if InCombatLockdown() then return 0 end
	local myClass = Client.PlayerClass()
	local onBars = {}
	for slot = 1, Client.MaxActionSlot() do
		local n = Client.ActionSlotMacroName(slot)
		if n then onBars[n] = true end
	end
	-- Snapshot the list first: each migration renames one entry and re-sorts.
	local candidates = {}
	for _, m in ipairs(Migrate.ReadGeneral()) do
		if onBars[m.name] and not Migrate.IsStub(m.name, m.body) and Migrate.VerdictFor(m.body).class == myClass then
			candidates[#candidates + 1] = m.name
		end
	end
	local moved = 0
	for _, name in ipairs(candidates) do
		local idx = Client.GetMacroIndexByName(name)
		if idx and idx > 0 and idx <= Client.MaxAccountMacros() then
			local ok, why = Migrate.One(idx, { requireOnBars = true })
			if ok then moved = moved + 1 else NS.Debug("auto-migrate skipped " .. name .. ": " .. tostring(why)) end
		end
	end
	return moved
end

-- Login remap sweep. Runs after Sync.Run so the class macros are already on
-- this page. For every bar button that holds a stub of THIS class, find the
-- class macro on the page (by body hash, falling back to original name) and
-- put it in the slot. Stubs of other classes are left alone. Idempotent.
-- Returns remapped count and a list of stub names that could not resolve.
function Migrate.Remap()
	if InCombatLockdown() then return 0, {} end
	local myClass = Client.PlayerClass()
	local page = Macros.ReadCharacter()
	local byHash, byName = {}, {}
	for _, m in ipairs(page) do
		byHash[NS.MacroKey(m.body)] = m.index
		byName[m.name] = byName[m.name] or m.index
	end
	local stubBodies = {}   -- stub name -> parsed payload (read once per stub)
	local function payloadFor(stubName)
		if stubBodies[stubName] == nil then
			local idx = Client.GetMacroIndexByName(stubName)
			local body
			if idx and idx > 0 then local _, _, b = Client.GetMacroInfo(idx); body = b end
			stubBodies[stubName] = Migrate.ParseStub(body) or false
		end
		return stubBodies[stubName] or nil
	end

	local remapped, unresolved, seenUnresolved = 0, {}, {}
	for slot = 1, Client.MaxActionSlot() do
		local name = Client.ActionSlotMacroName(slot)
		if name and Migrate.IsStubName(name) then
			local p = payloadFor(name)
			if p and p.class == myClass then
				local target = byHash[p.hash] or byName[p.name]
				if target then
					Client.PlaceMacroInSlot(target, slot)
					remapped = remapped + 1
				elseif not seenUnresolved[name] then
					seenUnresolved[name] = true
					unresolved[#unresolved + 1] = p.name
				end
			end
		end
	end
	if remapped > 0 then
		NS.Print(string.format("Re-pointed %d bar button%s from migrated General macros to your %s macros.",
			remapped, remapped == 1 and "" or "s", (UnitClass("player")) or myClass))
	end
	if #unresolved > 0 then
		NS.Warn("Could not find the class macro for: " .. table.concat(unresolved, ", ") .. " (not synced to this character yet?)")
	end
	return remapped, unresolved
end
