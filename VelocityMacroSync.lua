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
	-- Migration to schema 3 (content-hash keys). Earlier keys were
	-- name.."\1"..body (schema 1) or the raw body (schema 2). Class entries
	-- carry their body, so they re-key exactly; per-character snapshots and
	-- tombstones are re-keyed through the class set where the body is known.
	if (NS.db.schema or 1) < 3 then
		local bodyOfOldKey = {}
		for class, set in pairs(NS.db.classes) do
			local out = {}
			for oldKey, e in pairs(set) do
				if type(e) == "table" and e.body then
					bodyOfOldKey[oldKey] = e.body
					local body = oldKey:match("^.-\1(.*)$") or oldKey
					bodyOfOldKey[body] = e.body
					out[NS.MacroKey(e.body)] = e
				end
			end
			NS.db.classes[class] = out
		end
		local function rekey(t, toValue)
			if type(t) ~= "table" then return nil end
			local out = {}
			for oldKey, v in pairs(t) do
				local body = bodyOfOldKey[oldKey] or oldKey:match("^.-\1(.*)$") or oldKey
				local name = oldKey:match("^(.-)\1")
				out[NS.MacroKey(body)] = toValue(v, name)
			end
			return out
		end
		for _, rec in pairs(NS.db.chars) do
			rec.snapshot = rekey(rec.snapshot, function(v, name)
				if type(v) == "table" then return v end
				return { name = name or "", icon = v }
			end)
			rec.excluded = rekey(rec.excluded, function() return true end) or {}
		end
		NS.db.schema = 3
	end
	-- Schema 4: canonical icons. Earlier builds stored whatever GetMacroInfo
	-- returned (fileID 134400 on Forever) while writing the string name; the
	-- two spellings of the same "?" made the merge non-idempotent (nagged
	-- "Updated N macros" at every login). Scrub every stored icon once.
	if (NS.db.schema or 1) < 4 then
		for _, set in pairs(NS.db.classes) do
			for _, e in pairs(set) do if type(e) == "table" then e.icon = NS.CanonIcon(e.icon) end end
		end
		for _, rec in pairs(NS.db.chars) do
			for _, s in pairs(rec.snapshot or {}) do if type(s) == "table" then s.icon = NS.CanonIcon(s.icon) end end
		end
		NS.db.schema = 4
	end
end)

-- Wipes every byte of saved data, then immediately re-syncs so this
-- character's page becomes the new class set. Pages are untouched (the addon
-- never deletes macros); other characters re-share at their next login.
function NS.WipeAllData()
	for k in pairs(NS.db) do NS.db[k] = nil end
	for k, v in pairs(DB_DEFAULTS) do NS.db[k] = type(v) == "table" and {} or v end
	NS.db.schema = 4
	if NS.Sync.ForgetSession then NS.Sync.ForgetSession() end
	NS.Print("all saved data wiped. No macros were touched on any character; other characters re-share at their next login.")
	NS.Sync.Run("login")
	if NS.OptionsRefresh then NS.OptionsRefresh() end
end

StaticPopupDialogs["VELOCITYMACROSYNC_WIPE"] = {
	text = "Velocity Macro Sync\n\nDelete ALL saved sync data for every class and character on this account?\n\nNo macros are removed from any character's macro page. Each character will re-share what is on its page the next time it logs in.",
	button1 = "Delete everything",
	button2 = CANCEL,
	OnAccept = function() NS.WipeAllData() end,
	timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true, preferredIndex = 3,
}
function NS.ConfirmWipe() StaticPopup_Show("VELOCITYMACROSYNC_WIPE") end

local function Help()
	NS.Print("Velocity Macro Sync commands:")
	NS.Print("  /velocitymacrosync status      - what this character and its class set hold")
	NS.Print("  /velocitymacrosync sync        - run the merge now")
	NS.Print("  /velocitymacrosync list        - list the class set")
	NS.Print("  /velocitymacrosync resetchar   - forget this character's sync state; next sync pulls the whole class set")
	NS.Print("  /velocitymacrosync resetclass  - clear this class's shared set; every character re-shares at next login")
	NS.Print("  /velocitymacrosync reset       - DELETE ALL saved data for every class and character (asks first)")
	NS.Print("  /velocitymacrosync debug       - toggle debug output")
	NS.Print("No command ever removes a macro from a character's macro page.")
end

SLASH_VELOCITYMACROSYNC1 = "/velocitymacrosync"
SlashCmdList.VELOCITYMACROSYNC = function(msg)
	local cmd = (msg or ""):lower():match("^%s*(%S*)")
	if cmd == "status" or cmd == "" then
		NS.Sync.Status()
	elseif cmd == "sync" then
		local n = NS.Sync.Run("manual")
		if n == 0 then NS.Print("already in sync") end
	elseif cmd == "list" then
		local class = NS.Client.PlayerClass()
		local set = NS.db.classes[class] or {}
		local entries = {}
		for _, e in pairs(set) do entries[#entries + 1] = e end
		table.sort(entries, function(a, b) return (a.seq or 0) < (b.seq or 0) end)
		NS.Print(class .. " class set (" .. #entries .. "):")
		for _, e in ipairs(entries) do
			local who = e.by and (" by " .. e.by) or ""
			local when = e.mtime and (" " .. date("%Y-%m-%d %H:%M", e.mtime)) or ""
			NS.Print(string.format("  #%d %s%s%s", e.seq or 0, e.name, who, when))
		end
		if #entries == 0 then NS.Print("  empty") end
	elseif cmd == "resetchar" then
		NS.Sync.ResetCharacter()
	elseif cmd == "resetclass" then
		NS.Sync.ResetClass()
	elseif cmd == "reset" then
		NS.ConfirmWipe()
	elseif cmd == "debug" then
		NS.db.debug = not NS.db.debug
		NS.Print("debug " .. (NS.db.debug and "on" or "off"))
	else
		Help()
	end
end
