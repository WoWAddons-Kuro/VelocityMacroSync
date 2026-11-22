-- Velocity Macro Sync: picks the client implementation for the running
-- game and binds it onto NS.Client. Loads after Client.lua and every Client_*.lua.
local ADDON, NS = ...
local Client = NS.Client

local function SelectFlavour()
	-- 1. Interface version is the most reliable signal: it is baked into the
	--    build, bounded on both ends, and does not depend on constants that
	--    appeared mid-beta (Forever reported WOW_PROJECT_ID == 1 before build
	--    70170, identical to Retail).
	--      Classic Era  11xxx     (1.15.x)
	--      Forever      16xxx     (1.60.x)   [16000, 17000)
	--      Retail       >= 100000 (10.x+)
	local iface = select(4, GetBuildInfo())
	if type(iface) == "number" then
		if iface >= 16000 and iface < 17000 then return "forever" end
		if iface >= 100000 then return "retail" end
		if iface >= 11000 and iface < 12000 then return "classic_era" end
	end
	-- 2. Project constants, for a client whose interface number we did not
	--    anticipate (TBC/Wrath/Cata Classic, a future Forever major bump).
	if WOW_PROJECT_CAMELOT ~= nil and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT then
		return "forever"
	end
	if WOW_PROJECT_CLASSIC ~= nil and WOW_PROJECT_ID == WOW_PROJECT_CLASSIC then
		return "classic_era"
	end
	if WOW_PROJECT_MAINLINE ~= nil and WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
		return "retail"
	end
	-- 3. Last resort: probe the API shape. Modern spellbook namespace means a
	--    Mainline-family client; absence means a Classic-family client.
	if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines then
		return "forever"   -- Mainline-family default; Forever is what we ship to
	end
	return "classic_era"
end

Client.flavour = SelectFlavour()
do
	local v, build, _, iface = GetBuildInfo()
	Client.buildInfo = string.format("%s (%s) iface %s project %s", tostring(v), tostring(build), tostring(iface), tostring(WOW_PROJECT_ID))
end
local impl = NS.ClientFlavours[Client.flavour]
if not impl then
	NS.Warn("no client implementation for flavour " .. tostring(Client.flavour))
	impl = {}
end

for _, name in ipairs(Client.INTERFACE) do
	if type(impl[name]) == "function" then
		Client[name] = impl[name]
	else
		NS.Warn(Client.flavour .. " client is missing " .. name)
		Client[name] = function() return nil end
	end
end

-- Flag a flavour file that implements something the interface does not list.
for flavour, table_ in pairs(NS.ClientFlavours) do
	for name in pairs(table_) do
		local listed = false
		for _, n in ipairs(Client.INTERFACE) do if n == name then listed = true break end end
		if not listed then NS.Warn(flavour .. " client defines " .. name .. " which is not in Client.INTERFACE") end
	end
end
