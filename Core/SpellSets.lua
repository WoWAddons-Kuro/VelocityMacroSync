-- Velocity Macro Sync: class spell sets.
--
-- The classifier needs to know which spell names belong to which class. No
-- spell data ships with the addon: every character contributes its own
-- spellbook (class tabs only, ranks stripped) under its class token, so the
-- table grows as you log in on each class and works on every client.
--
-- db.classSpells[CLASS][spellName] = true
--
-- Conservative by construction: a spell nobody has learned yet is simply
-- unknown, which blocks classification rather than causing a wrong one.
local ADDON, NS = ...
local Client = NS.Client

local SpellSets = {}
NS.SpellSets = SpellSets

-- Re-read this character's spellbook into its class entry. Returns how many
-- names were new to the set.
function SpellSets.Refresh()
	if not NS.db then return 0 end
	NS.db.classSpells = NS.db.classSpells or {}
	local class = Client.PlayerClass()
	if not class then return 0 end
	local set = NS.db.classSpells[class] or {}
	NS.db.classSpells[class] = set
	local added = 0
	for _, name in ipairs(Client.ReadSpellbook() or {}) do
		if not set[name] then set[name] = true; added = added + 1 end
	end
	if added > 0 then NS.Debug(string.format("spell set %s += %d (now %d)", class, added, NS.CountTable(set))) end
	return added
end

-- Which class(es) know this spell name? Returns a list of class tokens (usually
-- 0 or 1 entries; 2+ means a shared name and the classifier treats it as mixed).
function SpellSets.ClassesFor(spellName)
	local out = {}
	if not (NS.db and NS.db.classSpells) then return out end
	for class, set in pairs(NS.db.classSpells) do
		if set[spellName] then out[#out + 1] = class end
	end
	table.sort(out)
	return out
end

function SpellSets.Known(class)
	return NS.db and NS.db.classSpells and NS.db.classSpells[class] and NS.CountTable(NS.db.classSpells[class]) or 0
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("SPELLS_CHANGED")
f:RegisterEvent("LEARNED_SPELL_IN_TAB")
f:SetScript("OnEvent", function()
	SpellSets.Refresh()
end)
