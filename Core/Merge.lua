-- Velocity Macro Sync: the merge. Pure logic, no game API calls.
--
-- ============================  HARD RULES  ============================
--  1. THE ADDON NEVER DELETES A MACRO FROM THE CHARACTER PAGE. There is no
--     delete path anywhere in this addon; DeleteMacro is not even wrapped.
--  2. THE CLASS SET IS APPEND-ONLY. Nothing is ever removed from it.
--  3. When the PLAYER deletes a macro from their page, that character records
--     a TOMBSTONE for it: "not on this character's page by choice". The macro
--     stays in the class set and still goes to every other character.
-- =======================================================================
--
-- Inputs
--   snapshot : { [key] = icon }   what THIS character had after its last sync (nil = never synced)
--   excluded : { [key] = true }   tombstones for THIS character
--   localList: { {index,name,icon,body}, ... }   what the character page holds right now
--   classSet : { [key] = {name,icon,body} }      the shared set for this class
-- key = NS.MacroKey(name, body).
--
-- Plan:
--   classAdd    = { entry, ... }                              add to class set
--   localCreate = { entry, ... }                              CreateMacro on this page
--   localEdit   = { {index=,name=,icon=,body=,oldName=}, ...} EditMacro in place (icon or body refresh, rename on fork)
--   tombstone   = { key, ... }                                player deleted these here since last sync
local ADDON, NS = ...

local Merge = {}
NS.Merge = Merge

function Merge.Plan(snapshot, excluded, localList, classSet)
	local plan = { classAdd = {}, localCreate = {}, localEdit = {}, tombstone = {} }
	local firstSync = (snapshot == nil)
	snapshot = snapshot or {}
	excluded = excluded or {}

	local localSet = NS.Macros.ToSet(localList)
	local localByName = {}
	for key, m in pairs(localSet) do localByName[m.name] = key end
	-- Newest class entry per name (the set is append-only, so an edit leaves the
	-- old body behind; `seq` says which one is current).
	local classByName = {}
	for key, e in pairs(classSet) do
		local cur = classByName[e.name]
		if not cur or (e.seq or 0) > (classSet[cur].seq or 0) then classByName[e.name] = key end
	end

	local taken = {}
	for n in pairs(localByName) do taken[n] = true end
	for n in pairs(classByName) do taken[n] = true end

	-- Tombstones: was in the snapshot, is no longer on the page -> the player
	-- removed it here. Record, never recreate here, never touch the class set.
	for key in pairs(snapshot) do
		if not localSet[key] and not excluded[key] then
			plan.tombstone[#plan.tombstone + 1] = key
			excluded[key] = true   -- effective immediately for the passes below
		end
	end

	local handledClassKey = {}

	-- Pass 1: every macro on the page.
	for key, m in pairs(localSet) do
		if classSet[key] then
			handledClassKey[key] = true
			local newest = classByName[m.name]
			if newest ~= key and not excluded[newest] then
				-- A newer body for this name was shared elsewhere -> update in place; retire ours here.
				local c = classSet[newest]
				handledClassKey[newest] = true
				plan.localEdit[#plan.localEdit + 1] = { index = m.index, name = c.name, icon = c.icon, body = c.body, oldName = m.name }
				if not excluded[key] then plan.tombstone[#plan.tombstone + 1] = key; excluded[key] = true end
			else
				-- Same name+body; reconcile icon only.
				local cIcon = classSet[key].icon
				if m.icon ~= cIcon then
					if snapshot[key] ~= nil and m.icon ~= snapshot[key] then
						classSet[key].icon = m.icon
					elseif cIcon ~= nil then
						plan.localEdit[#plan.localEdit + 1] = { index = m.index, name = m.name, icon = cIcon, body = m.body, oldName = m.name }
					end
				end
			end
		else
			local cKey = classByName[m.name]
			if not cKey then
				-- New macro here -> share it.
				plan.classAdd[#plan.classAdd + 1] = { name = m.name, icon = m.icon, body = m.body }
			else
				-- Same name, different body.
				local c = classSet[cKey]
				handledClassKey[cKey] = true
				if snapshot[key] ~= nil then
					-- Our copy is the one we synced earlier; the class copy is a newer edit from elsewhere.
					plan.localEdit[#plan.localEdit + 1] = { index = m.index, name = c.name, icon = c.icon, body = c.body, oldName = m.name }
				elseif snapshot[cKey] ~= nil then
					-- The class copy is what we synced earlier; ours is a newer edit made here. Share the new
					-- body (append-only: old entry stays, tombstoned for us so it is not recreated here).
					plan.classAdd[#plan.classAdd + 1] = { name = m.name, icon = m.icon, body = m.body }
					if not excluded[cKey] then plan.tombstone[#plan.tombstone + 1] = cKey; excluded[cKey] = true end
				else
					-- First sync, genuine fork: keep both. Rename ours to Name~2, share it, take theirs.
					local newName = NS.UniqueName(m.name, taken)
					taken[newName] = true
					plan.localEdit[#plan.localEdit + 1] = { index = m.index, name = newName, icon = m.icon, body = m.body, oldName = m.name }
					plan.classAdd[#plan.classAdd + 1] = { name = newName, icon = m.icon, body = m.body }
					if not excluded[cKey] then
						plan.localCreate[#plan.localCreate + 1] = { name = c.name, icon = c.icon, body = c.body }
					end
				end
			end
		end
	end

	-- Pass 2: class entries not on the page and not tombstoned here -> create.
	for key, e in pairs(classSet) do
		if not handledClassKey[key] and not excluded[key] and not localByName[e.name] then
			plan.localCreate[#plan.localCreate + 1] = { name = e.name, icon = e.icon, body = e.body }
		end
	end

	table.sort(plan.localCreate, function(a, b) return a.name < b.name end)
	return plan
end

function Merge.IsEmpty(plan)
	return #plan.classAdd == 0 and #plan.localCreate == 0 and #plan.localEdit == 0 and #plan.tombstone == 0
end
