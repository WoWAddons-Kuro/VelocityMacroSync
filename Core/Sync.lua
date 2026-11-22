-- Velocity Macro Sync: orchestration. Runs the merge when the macro list is
-- available, applies it, and keeps the class set current as the player edits.
--
-- HARD RULES (see Core/Merge.lua): the addon never deletes a macro from the
-- page and never removes anything from the class set. A player deletion is
-- recorded as a per-character tombstone only.
--
-- SavedVariables layout (VelocityMacroSyncDB):
--   classes[CLASS]   = { [key] = {name, icon, body} }   shared set per class, append-only
--   chars[guid]      = { class=, name=, snapshot = { [key] = icon }, excluded = { [key] = true } }
--   debug            = bool
local ADDON, NS = ...
local Client, Macros, Merge = NS.Client, NS.Macros, NS.Merge

local Sync = {}
NS.Sync = Sync

local frame = CreateFrame("Frame")
local inWorld = false
local synced = false       -- first merge of this session done
local applying = false     -- our own writes are in flight; ignore UPDATE_MACROS
local applyToken = 0
local pendingCombat = false

local function ClassSet()
	local class = Client.PlayerClass()
	NS.db.classes[class] = NS.db.classes[class] or {}
	return NS.db.classes[class], class
end

local function CharRecord()
	local key = Client.PlayerKey()   -- GUID, always
	local rec = NS.db.chars[key]
	if not rec then
		rec = { snapshot = nil, excluded = {} }
		NS.db.chars[key] = rec
	end
	rec.excluded = rec.excluded or {}
	rec.class = Client.PlayerClass()
	rec.name = Client.PlayerDisplayName()
	return rec
end

local function TakeSnapshot(rec)
	local snap = {}
	for _, m in ipairs(Macros.ReadCharacter()) do
		snap[NS.MacroKey(m.name, m.body)] = m.icon or false
	end
	rec.snapshot = snap
end

-- Applies a plan. Returns the entries actually created and the names that did not fit.
local function Apply(plan, classSet, rec)
	local created, overflow = {}, {}
	applying = true

	for _, key in ipairs(plan.tombstone) do
		NS.Debug("tombstone " .. key:gsub("\1", " / "))
		rec.excluded[key] = true
	end
	for _, e in ipairs(plan.classAdd) do
		NS.Debug("class += " .. e.name)
		NS.db.seq = (NS.db.seq or 0) + 1
		classSet[NS.MacroKey(e.name, e.body)] = { name = e.name, icon = e.icon, body = e.body, seq = NS.db.seq }
	end
	for _, e in ipairs(plan.localEdit) do
		NS.Debug("page edit " .. e.oldName .. (e.oldName ~= e.name and (" -> " .. e.name) or ""))
		Macros.Edit(e.index, e.name, e.icon, e.body)
	end
	for _, c in ipairs(plan.localCreate) do
		if Macros.FreeSlots() <= 0 then
			overflow[#overflow + 1] = c.name
		else
			NS.Debug("page += " .. c.name)
			if Macros.Create(c.name, c.icon, c.body) then created[#created + 1] = c end
		end
	end

	-- UPDATE_MACROS for our own writes fires after we return; hold the guard
	-- through that burst so we do not re-merge a half-settled list.
	applyToken = applyToken + 1
	local token = applyToken
	C_Timer.After(1, function() if applyToken == token then applying = false end end)
	return created, overflow
end

local function Names(list)
	local t = {}
	for _, e in ipairs(list) do t[#t + 1] = e.name end
	return table.concat(t, ", ")
end

-- The merge proper. Idempotent.
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
	local plan = Merge.Plan(rec.snapshot, rec.excluded, localList, classSet)

	if Merge.IsEmpty(plan) then
		if not rec.snapshot then TakeSnapshot(rec) end
		NS.Debug("sync (" .. reason .. "): nothing to do")
		synced = true
		return 0
	end

	local created, overflow = Apply(plan, classSet, rec)
	TakeSnapshot(rec)
	synced = true
	-- Names that did not fit are reported once per session, not on every re-merge.
	Sync.overflowReported = Sync.overflowReported or {}
	local newOverflow = {}
	for _, n in ipairs(overflow) do
		if not Sync.overflowReported[n] then Sync.overflowReported[n] = true; newOverflow[#newOverflow + 1] = n end
	end

	-- In-session edits are the player's own actions; only announce under debug.
	local Say = (reason == "edit") and NS.Debug or NS.Print
	local classLabel = (UnitClass("player")) or class
	local function plural(n) return n == 1 and "" or "s" end
	if #created > 0 then
		Say(string.format("Added %d %s macro%s from your other characters: %s", #created, classLabel, plural(#created), Names(created)))
	end
	if #plan.localEdit > 0 then
		Say(string.format("Updated %d macro%s edited on another character: %s", #plan.localEdit, plural(#plan.localEdit), Names(plan.localEdit)))
	end
	if #plan.classAdd > 0 then
		Say(string.format("Sharing %d new macro%s with your other %s characters: %s", #plan.classAdd, plural(#plan.classAdd), classLabel, Names(plan.classAdd)))
	end
	if #plan.tombstone > 0 then
		Say(string.format("%d macro%s you deleted here will stay off this character (other characters keep %s)", #plan.tombstone, plural(#plan.tombstone), #plan.tombstone == 1 and "it" or "them"))
	end
	if #newOverflow > 0 then
		NS.Warn(string.format("%d macro%s did not fit (%d character slots): %s", #newOverflow, plural(#newOverflow), Client.MaxCharacterMacros(), table.concat(newOverflow, ", ")))
	end
	return #created + #plan.localEdit + #plan.classAdd + #plan.tombstone
end

frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("UPDATE_MACROS")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_ENTERING_WORLD" then
		inWorld = true
		C_Timer.After(1, function() if not synced then Sync.Run("login") end end)
	elseif event == "UPDATE_MACROS" then
		if not inWorld or applying then return end
		Sync.Run(synced and "edit" or "login")
	elseif event == "PLAYER_REGEN_ENABLED" then
		if pendingCombat then
			pendingCombat = false
			Sync.Run("post-combat")
		end
	end
end)

function Sync.Status()
	local classSet, class = ClassSet()
	local rec = CharRecord()
	local localList = Macros.ReadCharacter()
	NS.Print(string.format("%s (%s) on %s client", rec.name, class, Client.flavour))
	NS.Print(string.format("character page: %d/%d used, class set: %d macros, excluded here: %d, snapshot: %s, synced this session: %s",
		#localList, Client.MaxCharacterMacros(), NS.CountTable(classSet), NS.CountTable(rec.excluded),
		rec.snapshot and NS.CountTable(rec.snapshot) .. " entries" or "none (first sync pending)",
		synced and "yes" or "no"))
	local others = {}
	for guid, r in pairs(NS.db.chars) do
		if r.class == class and guid ~= Client.PlayerKey() then others[#others + 1] = r.name or guid end
	end
	if #others > 0 then NS.Print("other " .. class .. " characters: " .. table.concat(others, ", ")) end
end

-- Forget this character's snapshot AND tombstones: next sync pulls everything in the class set.
function Sync.ResetCharacter()
	local rec = CharRecord()
	rec.snapshot = nil
	rec.excluded = {}
	synced = false
	NS.Print("this character will pull every macro in the class set on the next sync (/cms sync)")
end

-- Wipe the class set record (the ONLY place the set shrinks, and only by explicit command).
-- Pages are untouched; every character re-contributes its macros at next login.
function Sync.ResetClass()
	local _, class = ClassSet()
	NS.db.classes[class] = {}
	for _, r in pairs(NS.db.chars) do
		if r.class == class then r.snapshot = nil; r.excluded = {} end
	end
	synced = false
	NS.Print(class .. " class set cleared; nothing was removed from any character page. Every " .. class .. " re-shares its macros at next login")
end
