-- Class Macro Sync: Classic Era client flavour (WOW_PROJECT_CLASSIC).
-- One-name characters; 18 character macro slots.
local ADDON, NS = ...

NS.ClientFlavours.classic_era = {
	PlayerKey = function()
		return UnitGUID("player")
	end,

	PlayerDisplayName = function()
		return UnitName("player") or "?"
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
}
