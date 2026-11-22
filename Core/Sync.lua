-- Class Macro Sync: orchestration. Listens for the macro list becoming
-- available, runs the merge, applies it, and keeps the class set current as
-- the player edits macros during the session.
--
-- SavedVariables layout (VelocityClassMacroSyncDB):
--   classes[CLASS]   = { [key] = {name, icon, body} }   shared set per class
--   chars[guid]      = { class=, name=, snapshot = { [key] = icon } }
--   debug            = bool
local ADDON, NS = ...
local Client, Macros, Merge = NS.Client, NS.Macros, NS.Merge

local Sync = {}
NS.Sync = Sync

local frame = CreateFrame("Frame")
local inWorld = false
local synced = false       -- first merge of this session done
local applying = false     -- our own writes are in flight; ignore UPDATE_MACROS
local pendingCombat = false

local function ClassSet()
	local class = Client.PlayerClass()
	NS.db.classes[class] = NS.db.classes[class] or {}
	return NS.db.classes[class], class
end

local function CharRecord()
	local key = Client.PlayerKey()
	local rec = NS.db.chars[key]
	if not rec then
		rec = { snapshot = nil }
		NS.db.chars[key] = rec
	end
	rec.class = Client.PlayerClass()
	rec.name = Client.PlayerDisplayName()
	return rec
end

-- Record what the character tab holds right now as this character's snapshot.
local function TakeSnapshot(rec)
	local snap = {}
	for _, m in ipairs(Macros.ReadCharacter()) do
		snap[NS.MacroKey(m.name, m.body)] = m.icon or false
	end
	rec.snapshot = snap
end

-- Applies a plan. Returns number of changes made and a list of macros that
-- did not fit.
local function Apply(plan, classSet)
	local changes, overflow = 0, {}
	applying = true

	for _, key in ipairs(plan.classRemove) do
		local e = classSet[key]
		NS.Debug("class -= " .. (e and e.name or key))
		classSet[key] = nil
		changes = changes + 1
	end
	for _, e in ipairs(plan.classAdd) do
		NS.Debug("class += " .. e.name)
		classSet[NS.MacroKey(e.name, e.body)] = { name = e.name, icon = e.icon, body = e.body }
		changes = changes + 1
	end
	for _, c in ipairs(plan.classIcon) do
		if classSet[c.key] then classSet[c.key].icon = c.icon end
	end

	for _, d in ipairs(plan.localDelete) do
		NS.Debug("local -= " .. d.name)
		if Macros.Delete(d.index) then changes = changes + 1 end
	end
	for _, e in ipairs(plan.localEdit) do
		NS.Debug("local edit " .. e.oldName .. (e.oldName ~= e.name and (" -> " .. e.name) or ""))
		if Macros.Edit(e.index, e.name, e.icon, e.body) then changes = changes + 1 end
	end
	for _, c in ipairs(plan.localCreate) do
		if Macros.FreeSlots() <= 0 then
			overflow[#overflow + 1] = c.name
		else
			NS.Debug("local += " .. c.name)
			if Macros.Create(c.name, c.icon, c.body) then changes = changes + 1 end
		end
	end

	applying = false
	return changes, overflow
end

-- The merge proper. Safe to call repeatedly; no-op when nothing differs.
function Sync.Run(reason)
	if InCombatLockdown() then
		pendingCombat = true
		NS.Debug("in combat, deferring sync")
		return
	end
	if not Client.PlayerKey() then return end

	local classSet, class = ClassSet()
	local rec = CharRecord()
	local localList = Macros.ReadCharacter()
	local plan = Merge.Plan(rec.snapshot, localList, classSet)

	if Merge.IsEmpty(plan) then
		if not rec.snapshot then TakeSnapshot(rec) end
		NS.Debug("sync (" .. reason .. "): nothing to do")
		synced = true
		return 0
	end

	local changes, overflow = Apply(plan, classSet)
	TakeSnapshot(rec)
	synced = true

	if changes > 0 then
		NS.Print(string.format("%s: %d change%s (+%d/-%d local, class set now %d)",
			class, changes, changes == 1 and "" or "s",
			#plan.localCreate + #plan.localEdit, #plan.localDelete, NS.CountTable(classSet)))
	end
	if #overflow > 0 then
		NS.Warn(string.format("%d macro%s did not fit (%d character slots): %s",
			#overflow, #overflow == 1 and "" or "s", Client.MaxCharacterMacros(), table.concat(overflow, ", ")))
	end
	return changes
end

-- Called on every UPDATE_MACROS after the first sync: capture the player's
-- in-session edits into the class set so logout needs no extra work.
local function OnMacrosChanged()
	if applying or not synced then return end
	Sync.Run("edit")
end

frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("UPDATE_MACROS")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_ENTERING_WORLD" then
		inWorld = true
		-- Macros may already be loaded; UPDATE_MACROS may or may not fire again.
		C_Timer.After(1, function() if not synced then Sync.Run("login") end end)
	elseif event == "UPDATE_MACROS" then
		if not inWorld then return end
		if not synced then
			Sync.Run("login")
		else
			OnMacrosChanged()
		end
	elseif event == "PLAYER_REGEN_ENABLED" then
		if pendingCombat then
			pendingCombat = false
			Sync.Run("post-combat")
		end
	end
end)

-- Status for the slash command.
function Sync.Status()
	local classSet, class = ClassSet()
	local rec = CharRecord()
	local localList = Macros.ReadCharacter()
	NS.Print(string.format("%s (%s) on %s client", rec.name, class, Client.flavour))
	NS.Print(string.format("character tab: %d/%d used, class set: %d macros, snapshot: %s, synced this session: %s",
		#localList, Client.MaxCharacterMacros(), NS.CountTable(classSet),
		rec.snapshot and NS.CountTable(rec.snapshot) .. " entries" or "none (first sync pending)",
		synced and "yes" or "no"))
	local others = {}
	for guid, r in pairs(NS.db.chars) do
		if r.class == class and guid ~= Client.PlayerKey() then others[#others + 1] = r.name or guid end
	end
	if #others > 0 then NS.Print("other " .. class .. " characters: " .. table.concat(others, ", ")) end
end

-- Forget this character's snapshot so the next sync is a plain union again.
function Sync.ResetCharacter()
	local rec = CharRecord()
	rec.snapshot = nil
	synced = false
	NS.Print("snapshot cleared; run /cms sync to re-union with the class set")
end

-- Wipe the class set (all characters re-union on next login).
function Sync.ResetClass()
	local _, class = ClassSet()
	NS.db.classes[class] = {}
	for _, r in pairs(NS.db.chars) do
		if r.class == class then r.snapshot = nil end
	end
	synced = false
	NS.Print(class .. " class set wiped; every " .. class .. " re-unions at next login")
end
