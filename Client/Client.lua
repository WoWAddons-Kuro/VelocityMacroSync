-- Velocity Macro Sync: client abstraction.
-- Declares exactly what the addon needs from the game client; one file per
-- flavour implements it (Client_ClassicEra.lua, Client_Forever.lua) and
-- Client_Select.lua binds the right one onto NS.Client.
--
-- Rule (AddonManagement\PROJECT_STRUCTURE.md): per-character keys are the
-- player GUID, names are display-only and only ever come from here.
local ADDON, NS = ...

NS.Client = NS.Client or {}
NS.ClientFlavours = NS.ClientFlavours or {}
local Client = NS.Client

Client.INTERFACE = {
	"PlayerKey",          -- () -> UnitGUID("player")
	"PlayerDisplayName",  -- () -> "Kuro" (Era) / "Kuro Oakheart" (Forever)
	"PlayerClass",        -- () -> classFile token, e.g. "MAGE" (locale independent)
	"MaxAccountMacros",   -- () -> number of account-wide (General) slots
	"MaxCharacterMacros", -- () -> number of character-specific slots
}

-- Shared across flavours: the macro API itself has the same shape on every
-- client we ship to, so the thin wrappers live here rather than per flavour.
function Client.GetNumMacros()
	return GetNumMacros()
end

-- Returns name, iconTexture, body for a macro index (nil if empty).
function Client.GetMacroInfo(index)
	return GetMacroInfo(index)
end

function Client.CreateMacro(name, icon, body, perCharacter)
	return CreateMacro(name, icon, body, perCharacter)
end

function Client.EditMacro(index, name, icon, body)
	return EditMacro(index, name, icon, body)
end

-- Deliberately no DeleteMacro wrapper: this addon never deletes a macro.
