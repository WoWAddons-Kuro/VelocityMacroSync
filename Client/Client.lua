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
	"MaxActionSlot",      -- () -> highest action-bar slot number (120 on Classic clients)
	"ActionSlotMacroName",-- (slot) -> macro name if the slot holds a macro, else nil
	"ReadSpellbook",      -- () -> { spellName, ... } for the player's CLASS tabs only (General tab skipped, ranks stripped)
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

function Client.GetMacroIndexByName(name)
	return GetMacroIndexByName(name)
end

-- Put macro `index` into action slot `slot`. Blocked in combat (caller gates).
function Client.PlaceMacroInSlot(index, slot)
	PickupMacro(index)
	PlaceAction(slot)
	ClearCursor()
end

-- Strip "(Rank 3)" / "(Passive)" style suffixes and surrounding whitespace.
function Client.StripRank(name)
	if not name then return nil end
	name = name:gsub("%s*%b()%s*$", "")
	return (name:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Spellbook walk. Two API shapes exist and a client may have either, so try
-- both and report which one answered (Client.spellbookSource) so /status can
-- say what happened instead of silently learning nothing.
--   classic : GetNumSpellTabs / GetSpellTabInfo / GetSpellBookItemName
--   modern  : C_SpellBook.GetNumSpellBookSkillLines / GetSpellBookSkillLineInfo / GetSpellBookItemName
-- Tab/skill-line 1 is General (racials, professions) and is skipped.
local function AddName(names, seen, raw)
	local name = Client.StripRank(raw)
	if name and name ~= "" and not seen[name] then seen[name] = true; names[#names + 1] = name end
end

function Client.ReadSpellbookClassic()
	local names, seen = {}, {}
	if GetNumSpellTabs and GetSpellTabInfo and GetSpellBookItemName then
		local numTabs = GetNumSpellTabs() or 0
		for tab = 2, numTabs do
			local _, _, offset, numSpells = GetSpellTabInfo(tab)
			for i = (offset or 0) + 1, (offset or 0) + (numSpells or 0) do
				AddName(names, seen, (GetSpellBookItemName(i, BOOKTYPE_SPELL or "spell")))
			end
		end
		if #names > 0 then Client.spellbookSource = "classic"; return names end
	end
	if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and C_SpellBook.GetSpellBookSkillLineInfo and C_SpellBook.GetSpellBookItemName then
		local bank = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
		for line = 2, C_SpellBook.GetNumSpellBookSkillLines() or 0 do
			local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
			if info and info.itemIndexOffset and info.numSpellBookItems then
				for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
					AddName(names, seen, (C_SpellBook.GetSpellBookItemName(i, bank)))
				end
			end
		end
		if #names > 0 then Client.spellbookSource = "modern"; return names end
	end
	Client.spellbookSource = "none"
	return names
end

-- Shared action-slot read: macro name if the slot holds a macro, else nil.
-- GetActionText is the macro NAME on every client; GetActionInfo's id differs
-- between clients and is deliberately not used.
function Client.ActionSlotMacroNameShared(slot)
	if HasAction and not HasAction(slot) then return nil end
	local actionType = GetActionInfo(slot)
	if actionType ~= "macro" then return nil end
	local text = GetActionText(slot)
	if text and text ~= "" then return text end
	return nil
end

-- Deliberately no DeleteMacro wrapper: this addon never deletes a macro.
