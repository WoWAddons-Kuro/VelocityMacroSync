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

-- A macro's identity is its BODY. Name and icon are attributes the merge
-- reconciles in place; a rename or icon change is an edit of the same macro,
-- never a new one. Same body on two characters = the same macro, whatever
-- either happens to call it.
function NS.MacroKey(_, body)
	return body or ""
end

-- Deliberately no UniqueName / Name~2 helper: the addon never renames a macro to dodge a collision.

function NS.CountTable(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end
