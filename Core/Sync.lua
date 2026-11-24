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

-- Provenance on a class entry: who wrote it and when. DISPLAY / DIAGNOSTIC
-- ONLY. mtime is never used to decide who wins (client clocks are not
-- trustworthy); seq remains the ordering authority.
local function Stamp(entry)
	entry.by = Client.PlayerDisplayName()
	entry.mtime = time()
	return entry
end

-- Snapshot = what this page holds now, plus the class entry's seq each macro
-- was reconciled against (Merge's idempotence guard). Icons canonical.
local function TakeSnapshot(rec, classSet)
	local snap = {}
	for _, m in ipairs(Macros.ReadCharacter()) do
		local hash = NS.MacroKey(m.body)
		local c = classSet and classSet[hash]
		snap[hash] = { name = m.name, icon = NS.CanonIcon(m.icon), seq = c and c.seq or nil }
	end
	rec.snapshot = snap
end

-- Applies a plan. Returns the entries actually created and the names that did not fit.
local function Apply(plan, classSet, rec)
	local created, overflow = {}, {}
	applying = true

	for _, key in ipairs(plan.tombstone) do
		NS.Debug("tombstone " .. key)
		rec.excluded[key] = true
	end
	for _, e in ipairs(plan.classAdd) do
		NS.Debug("class += " .. e.name)
		NS.db.seq = (NS.db.seq or 0) + 1
		classSet[NS.MacroKey(e.body)] = Stamp({ name = e.name, icon = NS.CanonIcon(e.icon), body = e.body, seq = NS.db.seq })
	end
	-- A body EDIT on a shared macro. This is the one place the class set is
	-- not append-only: the old body is replaced by the new one, because they
	-- are the SAME macro (same name, the player just changed its text). The
	-- old hash is recorded in db.superseded[oldHash] = newHash so that when
	-- another character logs in still holding the old body, Merge recognises
	-- it as stale and EditMacro's it in place to the new body, rather than
	-- re-sharing the old text as a brand-new macro. Other characters'
	-- tombstones on the old hash are cleared: that body no longer exists.
	for _, r in ipairs(plan.classReplace) do
		local old = classSet[r.oldHash]
		NS.Debug("class edit " .. (old and old.name or r.oldHash) .. " -> new body")
		local newHash = NS.MacroKey(r.entry.body)
		classSet[r.oldHash] = nil
		NS.db.seq = (NS.db.seq or 0) + 1
		classSet[newHash] = Stamp({ name = r.entry.name, icon = NS.CanonIcon(r.entry.icon), body = r.entry.body, seq = NS.db.seq })
		NS.db.superseded = NS.db.superseded or {}
		-- Collapse chains: anything that pointed at the old hash now points at the new one.
		for h, target in pairs(NS.db.superseded) do if target == r.oldHash then NS.db.superseded[h] = newHash end end
		NS.db.superseded[r.oldHash] = newHash
		for _, other in pairs(NS.db.chars) do
			if other.excluded then other.excluded[r.oldHash] = nil end
		end
	end
	for _, a in ipairs(plan.classAttr) do
		local e = classSet[a.hash]
		if e then
			NS.Debug("class attr " .. e.name .. " -> " .. a.name)
			e.name = a.name; e.icon = NS.CanonIcon(a.icon)
			-- An attribute change IS a change: bump seq so siblings' snapshots go stale and they follow it.
			NS.db.seq = (NS.db.seq or 0) + 1
			e.seq = NS.db.seq; Stamp(e)
		end
	end
	for _, e in ipairs(plan.localEdit) do
		NS.Debug("page edit -> " .. e.name)
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
	local plan = Merge.Plan(rec.snapshot, rec.excluded, localList, classSet, NS.db.superseded)

	if Merge.IsEmpty(plan) then
		-- Always retake: records the current class seq per macro (the idempotence guard needs it after upgrades too).
		TakeSnapshot(rec, classSet)
		NS.Debug("sync (" .. reason .. "): nothing to do")
		synced = true
		return 0
	end

	local created, overflow = Apply(plan, classSet, rec)
	TakeSnapshot(rec, classSet)
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
		for _, c in ipairs(created) do
			if c.classRename then
				Say(string.format("  \"%s\" was named \"%s\" elsewhere; you already have a different \"%s\" here so it was left alone", c.name, c.classRename, c.classRename))
			end
		end
	end
	if #plan.localEdit > 0 then
		-- Group by who wrote the class entry we are following, so the line is
		-- honest about WHERE the edit came from (and when). "another
		-- character" was wrong whenever the writer was this very character.
		local me = Client.PlayerDisplayName()
		local groups, order = {}, {}
		for _, e in ipairs(plan.localEdit) do
			local who = e.by or "another character"
			if not groups[who] then groups[who] = { names = {}, mtime = 0 }; order[#order + 1] = who end
			local g = groups[who]
			g.names[#g.names + 1] = e.name
			if (e.mtime or 0) > g.mtime then g.mtime = e.mtime end
		end
		for _, who in ipairs(order) do
			local g = groups[who]
			local when = g.mtime > 0 and (" on " .. date("%b %d, %I:%M%p", g.mtime)) or ""
			local src = (who == me) and ("edited here" .. when) or ("edited on " .. who .. when)
			Say(string.format("Updated %d macro%s %s: %s", #g.names, plural(#g.names), src, table.concat(g.names, ", ")))
		end
	end
	if #plan.classAdd > 0 then
		Say(string.format("Sharing %d new macro%s with your other %s characters: %s", #plan.classAdd, plural(#plan.classAdd), classLabel, Names(plan.classAdd)))
	end
	if #plan.classReplace > 0 then
		local t = {} for _, r in ipairs(plan.classReplace) do t[#t + 1] = r.entry.name end
		Say(string.format("Updated %d shared macro%s for your other %s characters: %s", #plan.classReplace, plural(#plan.classReplace), classLabel, table.concat(t, ", ")))
	end
	if #plan.tombstone > 0 then
		Say(string.format("%d macro%s you deleted here will stay off this character (other characters keep %s)", #plan.tombstone, plural(#plan.tombstone), #plan.tombstone == 1 and "it" or "them"))
	end
	if #plan.untombstone > 0 then
		local names = {}
		for _, h in ipairs(plan.untombstone) do local e = classSet[h]; names[#names + 1] = e and e.name or h end
		Say(string.format("%d macro%s you re-created here %s back in sync: %s", #plan.untombstone, plural(#plan.untombstone),
			#plan.untombstone == 1 and "is" or "are", table.concat(names, ", ")))
	end
	if #newOverflow > 0 then
		NS.Warn(string.format("%d macro%s did not fit (%d character slots): %s", #newOverflow, plural(#newOverflow), Client.MaxCharacterMacros(), table.concat(newOverflow, ", ")))
	end
	return #created + #plan.localEdit + #plan.classAdd + #plan.classReplace + #plan.tombstone + #plan.untombstone
end

frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("UPDATE_MACROS")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")

-- After the FIRST successful merge of a session: migrate class macros off the
-- General tab (if enabled) and re-point any stub buttons. Both are no-ops when
-- there is nothing to do, and both are deferred to post-combat by Sync.Run's
-- own gate (they are only reached when the merge itself ran).
local postLoginDone = false
local function PostLogin()
	if postLoginDone or not synced or not NS.Migrate then return end
	postLoginDone = true
	NS.Migrate.Auto()      -- each One() it runs calls Sync.Reconcile() itself
	NS.Migrate.Remap()
	if NS.OptionsRefresh then NS.OptionsRefresh() end
end

-- THE single entry point for "the character page changed, bring the store in
-- line". Anything in this addon that writes a macro to the page calls this
-- afterwards, synchronously, instead of relying on UPDATE_MACROS (which the
-- `applying` guard deliberately ignores for our own writes). The page is the
-- source of truth for what exists; db.classes is derived from it by Merge.
function Sync.Reconcile(reason)
	return Sync.Run(reason or "reconcile")
end

frame:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_ENTERING_WORLD" then
		inWorld = true
		C_Timer.After(1, function() if not synced then Sync.Run("login") end; PostLogin() end)
	elseif event == "UPDATE_MACROS" then
		if not inWorld or applying then return end
		Sync.Run(synced and "edit" or "login")
		PostLogin()
	elseif event == "PLAYER_REGEN_ENABLED" then
		if pendingCombat then
			pendingCombat = false
			Sync.Run("post-combat")
			PostLogin()
		end
	end
end)

function Sync.Status()
	local classSet, class = ClassSet()
	local rec = CharRecord()
	local localList = Macros.ReadCharacter()
	NS.Print(string.format("%s (%s) on %s client [%s]", rec.name, class, Client.flavour, Client.buildInfo or "?"))
	NS.Print(string.format("character page: %d/%d used, class set: %d macros, excluded here: %d, snapshot: %s, synced this session: %s",
		#localList, Client.MaxCharacterMacros(), NS.CountTable(classSet), NS.CountTable(rec.excluded),
		rec.snapshot and NS.CountTable(rec.snapshot) .. " entries" or "none (first sync pending)",
		synced and "yes" or "no"))
	local others = {}
	for guid, r in pairs(NS.db.chars) do
		if r.class == class and guid ~= Client.PlayerKey() then others[#others + 1] = r.name or guid end
	end
	if #others > 0 then NS.Print("other " .. class .. " characters: " .. table.concat(others, ", ")) end
	NS.Print(string.format("spell set: %d %s spells known (spellbook API: %s), auto-migrate: %s",
		NS.SpellSets and NS.SpellSets.Known(class) or 0, class, tostring(Client.spellbookSource or "not read yet"), NS.db.autoMigrate and "on" or "off"))
end

-- Tombstoned class macros for this character that are NOT archived: entries
-- in the class set the player deleted here and has not hidden. Returns a
-- list of { hash=, name=, icon=, body= } so the settings page can offer
-- Restore / Archive. Archived ones are deliberately left out: the only way
-- back from archived is to re-create the macro by hand, which the merge
-- detects by content hash and un-tombstones.
function Sync.ExcludedHere()
	local classSet = ClassSet()
	local rec = CharRecord()
	local out = {}
	for hash, state in pairs(rec.excluded) do
		local e = classSet[hash]
		if e and state ~= "archived" then out[#out + 1] = { hash = hash, name = e.name, icon = e.icon, body = e.body } end
	end
	table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
	return out
end

-- Hide a tombstone from the settings page. The exclusion stays (the macro is
-- still never recreated here); it just stops being listed. Nothing on the
-- page changes. Reversible only by re-creating the macro by hand.
function Sync.Archive(hash)
	local rec = CharRecord()
	if not rec.excluded[hash] then return false, "not excluded here" end
	rec.excluded[hash] = "archived"
	local e = ClassSet()[hash]
	NS.Print(string.format("Archived \"%s\". It stays off this character and is no longer listed; re-create it by hand to bring it back.", e and e.name or hash))
	return true
end

-- Undo a tombstone: forget the exclusion and let the next merge re-create the
-- macro on this page. Runs the merge immediately so the page updates now.
function Sync.Restore(hash)
	if InCombatLockdown() then NS.Warn("cannot change macros in combat") return false end
	local rec = CharRecord()
	if not rec.excluded[hash] then return false, "not excluded here" end
	local classSet = ClassSet()
	local e = classSet[hash]
	if not e then return false, "no longer in the class set" end
	if Macros.FreeSlots() <= 0 then return false, "character tab is full" end
	rec.excluded[hash] = nil
	Sync.Run("restore")
	NS.Print(string.format("Restored \"%s\" to this character's macros.", e.name))
	return true
end

-- Called after a full data wipe so the next sync behaves like a first login.
function Sync.ForgetSession()
	synced = false
	postLoginDone = false
	Sync.overflowReported = nil
end

-- Forget this character's snapshot AND tombstones: next sync pulls everything in the class set.
function Sync.ResetCharacter()
	local rec = CharRecord()
	rec.snapshot = nil
	rec.excluded = {}
	synced = false
	NS.Print("this character will pull every macro in the class set on the next sync (/velocitymacrosync sync)")
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
