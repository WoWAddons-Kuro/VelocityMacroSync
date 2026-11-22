-- Velocity Macro Sync: entry point. SavedVariables init and slash commands.
local ADDON, NS = ...

local DB_DEFAULTS = { classes = {}, chars = {}, debug = false }

local init = CreateFrame("Frame")
init:RegisterEvent("ADDON_LOADED")
init:SetScript("OnEvent", function(self, event, name)
	if name ~= ADDON then return end
	self:UnregisterEvent("ADDON_LOADED")
	VelocityMacroSyncDB = VelocityMacroSyncDB or {}
	NS.db = VelocityMacroSyncDB
	for k, v in pairs(DB_DEFAULTS) do
		if NS.db[k] == nil then NS.db[k] = type(v) == "table" and {} or v end
	end
end)

local function Help()
	NS.Print("Velocity Macro Sync commands:")
	NS.Print("  /cms status      - what this character and its class set hold")
	NS.Print("  /cms sync        - run the merge now")
	NS.Print("  /cms list        - list the class set")
	NS.Print("  /cms reset       - forget this character's snapshot (next sync = plain union)")
	NS.Print("  /cms resetclass  - wipe the class set; every character of this class re-unions")
	NS.Print("  /cms debug       - toggle debug output")
end

SLASH_CLASSMACROSYNC1 = "/cms"
SLASH_CLASSMACROSYNC2 = "/classmacrosync"
SlashCmdList.CLASSMACROSYNC = function(msg)
	local cmd = (msg or ""):lower():match("^%s*(%S*)")
	if cmd == "status" or cmd == "" then
		NS.Sync.Status()
	elseif cmd == "sync" then
		local n = NS.Sync.Run("manual")
		if n == 0 then NS.Print("already in sync") end
	elseif cmd == "list" then
		local class = NS.Client.PlayerClass()
		local set = NS.db.classes[class] or {}
		local names = {}
		for _, e in pairs(set) do names[#names + 1] = e.name end
		table.sort(names)
		NS.Print(class .. " class set (" .. #names .. "): " .. (#names > 0 and table.concat(names, ", ") or "empty"))
	elseif cmd == "reset" then
		NS.Sync.ResetCharacter()
	elseif cmd == "resetclass" then
		NS.Sync.ResetClass()
	elseif cmd == "debug" then
		NS.db.debug = not NS.db.debug
		NS.Print("debug " .. (NS.db.debug and "on" or "off"))
	else
		Help()
	end
end
