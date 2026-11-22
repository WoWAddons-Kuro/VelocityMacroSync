-- Velocity Macro Sync: Retail (Mainline) client flavour.
--
-- WRITTEN BLIND. No Retail install exists in this workspace and no Retail TOC
-- ships. Every API name below comes from the warcraft.wiki.gg documentation
-- for the C_SpellBook namespace (introduced in 11.0). Verify before shipping.
local ADDON, NS = ...

NS.ClientFlavours.retail = {
	PlayerKey = function()
		return UnitGUID("player")
	end,

	PlayerDisplayName = function()
		local name, realm = UnitFullName("player")
		name = name or UnitName("player") or "?"
		if realm and realm ~= "" then return name .. "-" .. realm end
		return name
	end,

	PlayerClass = function()
		local _, classFile = UnitClass("player")
		return classFile
	end,

	MaxAccountMacros = function()
		return MAX_ACCOUNT_MACROS or 120
	end,

	MaxCharacterMacros = function()
		return MAX_CHARACTER_MACROS or 30
	end,

	-- 12 bars x 12 = 144 in Dragonflight+; 180 covers extra bars. Reading past
	-- the real end just returns nil from GetActionInfo, so over-shooting is safe.
	MaxActionSlot = function()
		return 180
	end,

	ActionSlotMacroName = function(slot)
		return NS.Client.ActionSlotMacroNameShared(slot)
	end,

	-- C_SpellBook (11.0+). Skill line 1 is General; class lines follow.
	ReadSpellbook = function()
		local names, seen = {}, {}
		if not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines) then return names end
		local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
		for line = 2, C_SpellBook.GetNumSpellBookSkillLines() do
			local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
			if info and info.itemIndexOffset and info.numSpellBookItems then
				for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
					local name = C_SpellBook.GetSpellBookItemName(i, bank)
					name = NS.Client.StripRank(name)
					if name and name ~= "" and not seen[name] then
						seen[name] = true
						names[#names + 1] = name
					end
				end
			end
		end
		return names
	end,
}
