-- Velocity Macro Sync: the three-way merge. Pure logic, no game API calls, so it
-- can be reasoned about (and unit-tested) in isolation.
--
-- Inputs
--   snapshot : { [key] = icon }       what THIS character had after its last sync (nil = never synced)
--   localList: { {index,name,icon,body}, ... }  what the character tab holds right now
--   classSet : { [key] = {name,icon,body} }     the shared set for this class
--
-- key = NS.MacroKey(name, body). An edit therefore shows up as "old key gone,
-- new key appeared"; the plan pairs those by name so they become an in-place
-- EditMacro (keeps action-bar placement) instead of delete + create.
--
-- Decision table for a key K (S = in snapshot, L = local, C = class):
--    L  C  S   meaning                               action
--    1  1  *   in sync                                none (icon reconciled separately)
--    1  0  1   deleted on another character          delete locally
--    1  0  0   new here                              add to class
--    0  1  1   deleted here                          remove from class
--    0  1  0   new elsewhere                         create locally
--
-- First sync (no snapshot) degenerates to a plain union, which is the
-- "3 mages, 3 macros -> all have 3" behaviour. Same name + different body on
-- first sync: keep both; the incoming one is renamed ("Name~2").
local ADDON, NS = ...

local Merge = {}
NS.Merge = Merge

-- Returns a plan:
--   classAdd    = { entry, ... }                      put into class set
--   classRemove = { key, ... }                        drop from class set
--   localCreate = { entry, ... }                      CreateMacro on this character
--   localDelete = { {index=, name=, body=}, ... }     DeleteMacro on this character
--   localEdit   = { {index=, name=, icon=, body=, oldName=}, ... }  EditMacro in place
--   classIcon   = { {key=, icon=}, ... }              icon changed locally -> class
function Merge.Plan(snapshot, localList, classSet)
	local plan = { classAdd = {}, classRemove = {}, localCreate = {}, localDelete = {}, localEdit = {}, classIcon = {} }
	local firstSync = (snapshot == nil)
	snapshot = snapshot or {}

	local localSet = NS.Macros.ToSet(localList)
	local localNames = NS.Macros.NamesInUse(localList)

	-- Names in the class set, for first-sync conflict detection.
	local classNames = {}
	for key, e in pairs(classSet) do classNames[e.name] = key end

	local deletes, creates = {}, {}

	-- Pass 1: everything local.
	for key, m in pairs(localSet) do
		if classSet[key] then
			-- In sync. Reconcile icon: local changed since snapshot -> class; else class -> local.
			local cIcon = classSet[key].icon
			if m.icon ~= cIcon then
				if snapshot[key] ~= nil and m.icon ~= snapshot[key] then
					plan.classIcon[#plan.classIcon + 1] = { key = key, icon = m.icon }
				elseif cIcon ~= nil then
					plan.localEdit[#plan.localEdit + 1] = { index = m.index, name = m.name, icon = cIcon, body = m.body, oldName = m.name }
				end
			end
		elseif snapshot[key] ~= nil then
			deletes[#deletes + 1] = { index = m.index, name = m.name, body = m.body }
		else
			-- New here. On first sync a same-name different-body macro already in
			-- the class set means "keep both": rename ours before it joins the set.
			local entry = { name = m.name, icon = m.icon, body = m.body }
			if firstSync and classNames[m.name] and classNames[m.name] ~= key then
				local taken = {}
				for n in pairs(classNames) do taken[n] = true end
				for n in pairs(localNames) do taken[n] = true end
				entry.name = NS.UniqueName(m.name, taken)
				plan.localEdit[#plan.localEdit + 1] = { index = m.index, name = entry.name, icon = m.icon, body = m.body, oldName = m.name }
				localNames[entry.name] = true
			end
			plan.classAdd[#plan.classAdd + 1] = entry
			classNames[entry.name] = NS.MacroKey(entry.name, entry.body)
		end
	end

	-- Pass 2: everything in the class set that is not local.
	for key, e in pairs(classSet) do
		if not localSet[key] then
			if snapshot[key] ~= nil then
				plan.classRemove[#plan.classRemove + 1] = key
			else
				creates[#creates + 1] = { name = e.name, icon = e.icon, body = e.body }
			end
		end
	end

	-- Pair delete+create with the same name into an in-place edit.
	for _, c in ipairs(creates) do
		local paired = false
		for i, d in ipairs(deletes) do
			if d.name == c.name then
				plan.localEdit[#plan.localEdit + 1] = { index = d.index, name = c.name, icon = c.icon, body = c.body, oldName = d.name }
				table.remove(deletes, i)
				paired = true
				break
			end
		end
		if not paired then plan.localCreate[#plan.localCreate + 1] = c end
	end
	for _, d in ipairs(deletes) do plan.localDelete[#plan.localDelete + 1] = d end

	-- Deletes must run highest index first so earlier indices do not shift.
	table.sort(plan.localDelete, function(a, b) return a.index > b.index end)

	return plan
end

function Merge.IsEmpty(plan)
	return #plan.classAdd == 0 and #plan.classRemove == 0 and #plan.localCreate == 0
		and #plan.localDelete == 0 and #plan.localEdit == 0 and #plan.classIcon == 0
end
