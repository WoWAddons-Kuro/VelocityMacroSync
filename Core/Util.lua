-- Velocity Macro Sync: small shared helpers (chat output, key building).
local ADDON, NS = ...

NS.PREFIX = "|cff33ccffVelocityMacroSync|r "

function NS.Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage(NS.PREFIX .. tostring(msg))
end

function NS.Warn(msg)
	DEFAULT_CHAT_FRAME:AddMessage(NS.PREFIX .. "|cffff4040" .. tostring(msg) .. "|r")
end

function NS.Debug(msg)
	if NS.db and NS.db.debug then
		DEFAULT_CHAT_FRAME:AddMessage(NS.PREFIX .. "|cff888888" .. tostring(msg) .. "|r")
	end
end

-- A macro's identity is its (name, body) pair. Icon changes alone are treated
-- as edits of the same macro (handled by the merge via name lookup), so they
-- are deliberately NOT part of the key.
function NS.MacroKey(name, body)
	return (name or "") .. "\1" .. (body or "")
end

-- Renames "Frostbolt" -> "Frostbolt~2", "Frostbolt~3", ... avoiding names
-- already present in `taken` (a set of names). Macro names are capped at 16
-- characters by the client, so the base is trimmed to make room.
function NS.UniqueName(name, taken)
	if not taken[name] then return name end
	local n = 2
	while true do
		local suffix = "~" .. n
		local base = name
		if #base + #suffix > 16 then base = base:sub(1, 16 - #suffix) end
		local candidate = base .. suffix
		if not taken[candidate] then return candidate end
		n = n + 1
	end
end

function NS.CountTable(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end
