-- Velocity Macro Sync: reads/writes the "Character Specific Macros" tab.
--
-- Character macros occupy indices MaxAccountMacros+1 .. MaxAccountMacros+MaxCharacterMacros.
-- GetNumMacros() returns (numAccount, numCharacter); the character ones are
-- packed contiguously from MaxAccountMacros+1.
local ADDON, NS = ...
local Client = NS.Client

local Macros = {}
NS.Macros = Macros

-- Returns an ordered list of { index=, name=, icon=, body= } for every
-- character-specific macro currently on this character. Icons are
-- canonicalised (NS.CanonIcon) so a "?" compares equal however the client spells it.
function Macros.ReadCharacter()
	local _, numChar = Client.GetNumMacros()
	local base = Client.MaxAccountMacros()
	local list = {}
	for i = 1, (numChar or 0) do
		local index = base + i
		local name, icon, body = Client.GetMacroInfo(index)
		if name then
			list[#list + 1] = { index = index, name = name, icon = NS.CanonIcon(icon), body = body or "" }
		end
	end
	return list
end

-- Builds { [key] = {name=, icon=, body=} } from a list; keeps `index` if present.
function Macros.ToSet(list)
	local set = {}
	for _, m in ipairs(list) do
		set[NS.MacroKey(m.body)] = { name = m.name, icon = m.icon, body = m.body, index = m.index }
	end
	return set
end

-- Set of names currently in use on the character tab (for collision avoidance).
function Macros.NamesInUse(list)
	local names = {}
	for _, m in ipairs(list) do names[m.name] = true end
	return names
end

function Macros.FreeSlots()
	local _, numChar = Client.GetNumMacros()
	return Client.MaxCharacterMacros() - (numChar or 0)
end

-- The user's "?" icon. MUST be the string name: CreateMacro with the numeric
-- fileID 134400 produces a macro whose icon stays a static question mark and
-- never follows #showtooltip (confirmed on WoWInterface, 2016 and 2020).
Macros.QUESTION_MARK = NS.QUESTION_MARK
Macros.QUESTION_MARK_FILEID = NS.QUESTION_MARK_FILEID

-- Read the icon a macro was SAVED with, not the one it is currently drawing.
--
-- GetMacroInfo(i) returns the DISPLAYED icon. For a macro the user set to
-- "?" with #showtooltip, that is whatever spell it resolves to right now -
-- so copying it verbatim freezes the user's dynamic icon onto one picture.
-- The Macro UI avoids this by reading the icon while the body is blank. We
-- do the same: blank the body, read, restore. EditMacro's icon argument is
-- optional and nil means "keep the stored icon", so the blanking write MUST
-- pass nil - passing the displayed icon back in would store it and destroy
-- the "?" permanently. Body goes back byte-for-byte. Caller gates combat.
function Macros.StoredIcon(index)
	local name, shownIcon, body = Client.GetMacroInfo(index)
	if not name then return nil end
	if body == nil or body == "" then return shownIcon end
	Client.EditMacro(index, name, nil, "")
	local _, storedIcon = Client.GetMacroInfo(index)
	Client.EditMacro(index, name, nil, body)
	return storedIcon
end

-- Normalise an icon for CreateMacro/EditMacro so a "?" keeps its dynamic
-- behaviour: the numeric fileID becomes the string name. Anything else is
-- the user's own choice and passes through untouched. Same rule as NS.CanonIcon.
function Macros.IconForWrite(icon)
	return NS.CanonIcon(icon)
end

-- Icon argument differs by client generation: Classic Era wants a texture
-- path/name, Forever (Mainline code) accepts a fileID or path. GetMacroInfo
-- hands back whatever the client uses, so round-tripping it is safe.
function Macros.Create(name, icon, body)
	local ok, idx = pcall(Client.CreateMacro, name, Macros.IconForWrite(icon), body, true)
	if not ok then NS.Warn("CreateMacro failed for " .. name .. ": " .. tostring(idx)) return nil end
	return idx
end

function Macros.Edit(index, name, icon, body)
	local ok, err = pcall(Client.EditMacro, index, name, Macros.IconForWrite(icon), body)
	if not ok then NS.Warn("EditMacro failed for " .. name .. ": " .. tostring(err)) return false end
	return true
end

-- There is deliberately NO Macros.Delete. The addon never deletes a macro; only the player does.
