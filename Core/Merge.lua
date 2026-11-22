-- Velocity Macro Sync: the merge. Pure logic, no game API calls.
--
-- ============================  HARD RULES  ============================
--  1. THE ADDON NEVER DELETES A MACRO FROM THE CHARACTER PAGE. There is no
--     delete path anywhere in this addon; DeleteMacro is not even wrapped.
--  2. THE CLASS SET IS APPEND-ONLY. Nothing is ever removed from it.
--  3. When the PLAYER deletes a macro from their page, that character records
--     a TOMBSTONE for it. The macro stays in the class set and still goes to
--     every other character.
--  4. THE ADDON NEVER RENAMES A MACRO TO AVOID A COLLISION. A macro's
--     identity is its BODY. Name and icon are attributes that get reconciled
--     in place. There is no Name~2 path.
-- =======================================================================
--
-- Inputs
--   snapshot : { [key] = icon }   what THIS character had after its last sync (nil = never synced)
--   excluded : { [key] = true }   tombstones for THIS character
--   localList: { {index,name,icon,body}, ... }   what the character page holds right now
--   classSet : { [key] = {name,icon,body,seq} } the shared set for this class
-- key = body.
--
-- Plan:
--   classAdd    = { entry, ... }                              add to class set
--   classAttr   = { {key=, name=, icon=}, ... }               name/icon changed here -> update class entry
--   localCreate = { entry, ... }                              CreateMacro on this page
--   localEdit   = { {index=,name=,icon=,body=,oldName=}, ...} EditMacro in place
--   tombstone   = { key, ... }                                player deleted these here since last sync
local ADDON, NS = ...

local Merge = {}
NS.Merge = Merge

function Merge.Plan(snapshot, excluded, localList, classSet)
	local plan = { classAdd = {}, classAttr = {}, localCreate = {}, localEdit = {}, tombstone = {} }
	local hadSnapshot = (snapshot ~= nil)
	snapshot = snapshot or {}
	excluded = excluded or {}

	local localSet = NS.Macros.ToSet(localList)
	local localByName = {}
	for key, m in pairs(localSet) do localByName[m.name] = m end

	-- Newest class entry per name (append-only set: an edited body leaves the old
	-- one behind; highest seq for a name is current).
	local classNewestByName = {}
	for key, e in pairs(classSet) do
		local cur = classNewestByName[e.name]
		if not cur or (e.seq or 0) > (classSet[cur].seq or 0) then classNewestByName[e.name] = key end
	end

	-- Tombstones: in snapshot, no longer on page, and the player did not simply
	-- edit it (a body edit shows up as old key gone + a same-NAME macro present).
	for key in pairs(snapshot) do
		if not localSet[key] and not excluded[key] then
			local c = classSet[key]
			local renamedOrEdited = c and localByName[c.name] ~= nil
			if not renamedOrEdited then
				plan.tombstone[#plan.tombstone + 1] = key
			end
			excluded[key] = true   -- either way, never recreate this exact body here
		end
	end

	local handled = {}

	-- Pass 1: every macro on the page.
	for key, m in pairs(localSet) do
		local c = classSet[key]
		if c then
			handled[key] = true
			local newestKey = classNewestByName[c.name]
			if newestKey ~= key and not excluded[newestKey] and not localSet[newestKey] then
				-- Body edited elsewhere: move this page to the newer body in place.
				local n = classSet[newestKey]
				handled[newestKey] = true
				plan.localEdit[#plan.localEdit + 1] = { index = m.index, name = n.name, icon = n.icon, body = n.body, oldName = m.name }
				excluded[key] = true
			else
				-- Same body. Reconcile name/icon: if OURS changed since snapshot, push to class;
				-- otherwise take the class's.
				if m.name ~= c.name or m.icon ~= c.icon then
					local s = snapshot[key]
					local oursChanged = s and (s.name ~= m.name or s.icon ~= m.icon)
					if oursChanged or not hadSnapshot then
						plan.classAttr[#plan.classAttr + 1] = { key = key, name = m.name, icon = m.icon }
					else
						plan.localEdit[#plan.localEdit + 1] = { index = m.index, name = c.name, icon = c.icon, body = m.body, oldName = m.name }
					end
				end
			end
		else
			-- Body not in the class set: new here (or edited here). Share it.
			plan.classAdd[#plan.classAdd + 1] = { name = m.name, icon = m.icon, body = m.body }
			-- If a class entry with this NAME exists and is not on this page, that is the
			-- body we edited away from; do not recreate it here.
			local oldKey = classNewestByName[m.name]
			if oldKey and not localSet[oldKey] then excluded[oldKey] = true; handled[oldKey] = true end
		end
	end

	-- Pass 2: class entries not on the page and not tombstoned here -> create.
	-- Only the newest body per name is a candidate, and only if the name is free.
	for name, key in pairs(classNewestByName) do
		if not handled[key] and not excluded[key] and not localByName[name] then
			local e = classSet[key]
			plan.localCreate[#plan.localCreate + 1] = { name = e.name, icon = e.icon, body = e.body }
		end
	end

	table.sort(plan.localCreate, function(a, b) return a.name < b.name end)
	return plan
end

function Merge.IsEmpty(plan)
	return #plan.classAdd == 0 and #plan.classAttr == 0 and #plan.localCreate == 0 and #plan.localEdit == 0 and #plan.tombstone == 0
end
