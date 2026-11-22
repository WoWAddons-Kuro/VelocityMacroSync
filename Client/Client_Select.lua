-- Class Macro Sync: picks the client implementation for the running
-- game and binds it onto NS.Client. Loads after Client.lua and every Client_*.lua.
local ADDON, NS = ...
local Client = NS.Client

local function SelectFlavour()
	if WOW_PROJECT_ID ~= nil and WOW_PROJECT_CLASSIC ~= nil and WOW_PROJECT_ID == WOW_PROJECT_CLASSIC then
		return "classic_era"
	end
	return "forever"
end

Client.flavour = SelectFlavour()
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
