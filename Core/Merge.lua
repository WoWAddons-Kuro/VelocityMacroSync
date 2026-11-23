-- Velocity Macro Sync: the merge. Pure logic, no game API calls.
--
-- ============================  HARD RULES  ============================
--  1. THE ADDON NEVER DELETES A MACRO FROM THE CHARACTER PAGE. Only the
--     player does. DeleteMacro is not wrapped anywhere.
--  2. THE CLASS SET IS APPEND-ONLY and KEYED BY CONTENT HASH of the body.
--     Same body = same macro. The ONE exception to append-only: when the
--     player EDITS a shared macro's body in place (same name, new text), the
--     old entry is replaced by the new one - they are the same macro. The
--     old hash is remembered in db.superseded so stale copies elsewhere are
--     edited in place rather than re-shared as a new macro.
--  3. A PLAYER DELETION becomes a per-character TOMBSTONE on the hash.
--  4. THE ADDON NEVER RENAMES A MACRO THE PLAYER MADE. If the player names
--     their macro "charge", it stays "charge" on their page. The only rename
--     that ever happens is to an INCOMING class macro being created on a page
--     where its name is already taken by a macro with a DIFFERENT body.
-- =======================================================================
--
-- Inputs
--   snapshot : { [hash] = { name=, icon= } }   what THIS page had after its last sync (nil = never synced)
--   excluded : { [hash] = true }                tombstones for THIS character
--   localList: { {index,name,icon,body}, ... }  what the page holds right now
--   classSet : { [hash] = {name,icon,body,seq} } the shared set
--
-- Plan:
--   classAdd    = { entry, ... }                       add to class set (hash of body)
--   classReplace= { {oldHash=, entry=}, ... }          player EDITED a shared macro's body here: old entry is
--                                                      superseded, new body takes its place (same name)
--   classAttr   = { {hash=, name=, icon=}, ... }       player changed name/icon of a shared macro here
--   localCreate = { entry, ... }                       CreateMacro on this page (entry.name may be suffixed)
--   localEdit   = { {index=,name=,icon=,body=}, ... }  EditMacro in place (name/icon only, never body of a player macro)
--   tombstone   = { hash, ... }                        player deleted these here since last sync
--   untombstone = { hash, ... }                        player re-created a tombstoned body by hand; exclusion cleared
--
-- excluded[hash] is true (shown with Restore on the settings page) or "archived" (hidden there).
local ADDON, NS = ...

local Merge = {}
NS.Merge = Merge

-- "Charge" taken -> "Charge 2", "Charge 3" ... within the 16-char limit.
-- Used ONLY for an incoming class macro whose name is held on this page by a different body.
local function FreeName(name, taken)
	if not taken[name] then return name end
	local n = 2
	while true do
		local suffix = " " .. n
		local base = name
		if #base + #suffix > 16 then base = base:sub(1, 16 - #suffix) end
		local c = base .. suffix
		if not taken[c] then return c end
		n = n + 1
	end
end

function Merge.Plan(snapshot, excluded, localList, classSet, superseded)
	local plan = { classAdd = {}, classReplace = {}, classAttr = {}, localCreate = {}, localEdit = {}, tombstone = {}, untombstone = {} }
	local hadSnapshot = (snapshot ~= nil)
	snapshot = snapshot or {}
	excluded = excluded or {}
	superseded = superseded or {}

	-- Page, keyed by hash; and the set of names in use on the page.
	-- Empty bodies are the client's blank "New" macro the player has not
	-- filled in yet; they are never shared and never tombstoned.
	local localByHash, localNames = {}, {}
	for _, m in ipairs(localList) do
		if (m.body or ""):match("%S") then
			localByHash[NS.MacroKey(m.body)] = m
			localNames[m.name] = m
		end
	end

	-- Hashes that were on the page at last sync and are not now. Two cases:
	--   body EDITED : a macro with the same NAME is still on the page but with a
	--                 different body -> the new body REPLACES the old one in the
	--                 class set (recorded in editedFrom so pass 1 can pair them)
	--   DELETED     : no macro of that name remains -> tombstone
	local editedFrom = {}   -- newHash -> oldHash
	for hash, s in pairs(snapshot) do
		if not localByHash[hash] and not excluded[hash] then
			local stillNamed = localNames[s.name]
			if stillNamed then
				editedFrom[NS.MacroKey(stillNamed.body)] = hash
			else
				plan.tombstone[#plan.tombstone + 1] = hash
			end
			excluded[hash] = true   -- either way: never recreate this exact body here
		end
	end

	-- Hashes that will be on the page once pass 1's in-place edits land.
	-- Pass 2 must not also CREATE these; that is how an edit became a sibling.
	local resolvedByEdit = {}

	-- Pass 1: every macro on the page.
	for hash, m in pairs(localByHash) do
		-- The player re-created a body they had deleted (or archived) here.
		-- That is an explicit "I want this back": clear the tombstone so it
		-- syncs normally again. Works for both true and "archived".
		if excluded[hash] then
			plan.untombstone[#plan.untombstone + 1] = hash
			excluded[hash] = nil
		end
		local c = classSet[hash]
		if not c then
			-- Is this body a STALE version of a shared macro that was edited on
			-- another character? Then it is the same macro: EditMacro our copy to
			-- the current body instead of sharing the old text as something new.
			local current = superseded[hash]
			if current and classSet[current] then
				local n = classSet[current]
				plan.localEdit[#plan.localEdit + 1] = { index = m.index, name = n.name, icon = n.icon, body = n.body }
				resolvedByEdit[current] = true
				excluded[hash] = nil
			else
			local oldHash = editedFrom[hash]
			if oldHash and classSet[oldHash] then
				-- Player edited a shared macro's body: the new body supersedes the old entry.
				plan.classReplace[#plan.classReplace + 1] = { oldHash = oldHash, entry = { name = m.name, icon = m.icon, body = m.body } }
			else
				-- Genuinely new body: share it under the player's name.
				plan.classAdd[#plan.classAdd + 1] = { name = m.name, icon = m.icon, body = m.body }
			end
			end
		elseif m.name ~= c.name or m.icon ~= c.icon then
			-- Same body, different name/icon. Who changed it?
			local s = snapshot[hash]
			local oursChanged = (s ~= nil) and (s.name ~= m.name or s.icon ~= m.icon)
			if oursChanged or not hadSnapshot then
				-- Player renamed/re-iconed it here (or this is the first sync): the page is truth.
				plan.classAttr[#plan.classAttr + 1] = { hash = hash, name = m.name, icon = m.icon }
			elseif not localNames[c.name] or localNames[c.name] == m then
				-- Renamed elsewhere, and the new name is free here: follow it.
				plan.localEdit[#plan.localEdit + 1] = { index = m.index, name = c.name, icon = c.icon, body = m.body }
			else
				-- New name is taken here by a different body: keep our name, take the icon only.
				if m.icon ~= c.icon then
					plan.localEdit[#plan.localEdit + 1] = { index = m.index, name = m.name, icon = c.icon, body = m.body }
				end
			end
		end
	end

	-- Pass 2: class macros not on this page and not tombstoned here -> create.
	-- If the class name is held here by a DIFFERENT body, the incoming one gets a
	-- suffixed name. The player's macro is never touched.
	local taken = {}
	for n in pairs(localNames) do taken[n] = true end
	local incoming = {}
	for hash, e in pairs(classSet) do
		if not localByHash[hash] and not excluded[hash] and not resolvedByEdit[hash] then incoming[#incoming + 1] = e end
	end
	table.sort(incoming, function(a, b) return (a.seq or 0) < (b.seq or 0) end)
	for _, e in ipairs(incoming) do
		local name = FreeName(e.name, taken)
		taken[name] = true
		plan.localCreate[#plan.localCreate + 1] = { name = name, icon = e.icon, body = e.body, classRename = (name ~= e.name) and e.name or nil }
	end

	return plan
end

function Merge.IsEmpty(plan)
	return #plan.classAdd == 0 and #plan.classReplace == 0 and #plan.classAttr == 0 and #plan.localCreate == 0 and #plan.localEdit == 0 and #plan.tombstone == 0 and #plan.untombstone == 0
end
