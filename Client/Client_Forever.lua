-- Velocity Macro Sync: WoW Forever client flavour (Mainline UI code).
-- Two-name characters: UnitName() is the FIRST name only, so display names
-- come from UnitNameUnmodified (name, surname). Keys are always the GUID.
local ADDON, NS = ...

NS.ClientFlavours.forever = {
	PlayerKey = function()
		return UnitGUID("player")
	end,

	PlayerDisplayName = function()
		local name, surname = UnitNameUnmodified("player")
		name = name or UnitName("player") or "?"
		if surname and surname ~= "" then
			return name .. " " .. surname
		end
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
		return MAX_CHARACTER_MACROS or 18
	end,

	MaxActionSlot = function()
		return 120
	end,

	ActionSlotMacroName = function(slot)
		return NS.Client.ActionSlotMacroNameShared(slot)
	end,

	-- Forever runs Mainline UI code on a Classic-era data set; the spellbook
	-- API is the Classic shape. Verify in M6 (see SPEC-ClassMacroMigration).
	ReadSpellbook = function()
		return NS.Client.ReadSpellbookClassic()
	end,
}
