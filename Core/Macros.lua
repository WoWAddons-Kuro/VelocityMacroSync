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
-- character-specific macro currently on this character.
function Macros.ReadCharacter()
	local _, numChar = Client.GetNumMacros()
	local base = Client.MaxAccountMacros()
	local list = {}
	for i = 1, (numChar or 0) do
		local index = base + i
		local name, icon, body = Client.GetMacroInfo(index)
		if name then
			list[#list + 1] = { index = index, name = name, icon = icon, body = body or "" }
		end
	end
	return list
end

-- Builds { [key] = {name=, icon=, body=} } from a list; keeps `index` if present.
function Macros.ToSet(list)
	local set = {}
	for _, m in ipairs(list) do
		set[NS.MacroKey(m.name, m.body)] = { name = m.name, icon = m.icon, body = m.body, index = m.index }
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

-- Icon argument differs by client generation: Classic Era wants a texture
-- path/name, Forever (Mainline code) accepts a fileID or path. GetMacroInfo
-- hands back whatever the client uses, so round-tripping it is safe.
function Macros.Create(name, icon, body)
	local ok, idx = pcall(Client.CreateMacro, name, icon or 134400, body, true) -- 134400 = INV_Misc_QuestionMark
	if not ok then NS.Warn("CreateMacro failed for " .. name .. ": " .. tostring(idx)) return nil end
	return idx
end

function Macros.Edit(index, name, icon, body)
	local ok, err = pcall(Client.EditMacro, index, name, icon, body)
	if not ok then NS.Warn("EditMacro failed for " .. name .. ": " .. tostring(err)) return false end
	return true
end

-- There is deliberately NO Macros.Delete. The addon never deletes a macro; only the player does.
