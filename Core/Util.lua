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

-- A macro's identity is a CONTENT HASH of its body. Name and icon are
-- attributes. Same body on two characters = the same macro, whatever either
-- calls it. Tombstones are on the hash too.
--
-- FNV-1a 32-bit, hex. Lua 5.1 has no bit ops; emulate the xor on bytes.
local function bxor(a, b)
	local r, bit = 0, 1
	while a > 0 or b > 0 do
		local x, y = a % 2, b % 2
		if x ~= y then r = r + bit end
		a, b, bit = (a - x) / 2, (b - y) / 2, bit * 2
	end
	return r
end
function NS.MacroKey(body)
	body = body or ""
	local h = 2166136261
	for i = 1, #body do
		h = bxor(h, body:byte(i))
		h = (h * 16777619) % 4294967296
	end
	return string.format("%08x", h)
end

-- Deliberately no UniqueName / Name~2 helper: the addon never renames a macro to dodge a collision.

function NS.CountTable(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end
