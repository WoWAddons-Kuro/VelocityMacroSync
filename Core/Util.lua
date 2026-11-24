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

-- Canonical icon. The user's "?" icon has TWO spellings depending on who you
-- ask: GetMacroInfo on Forever returns the fileID 134400, while writes MUST
-- use the string name (a numeric 134400 produces a static question mark that
-- never follows #showtooltip). Everything that compares or stores an icon
-- goes through here, so the two spellings are one value. Without this the
-- merge saw 134400 (page) ~= "INV_MISC_QUESTIONMARK" (class set), "fixed"
-- it with EditMacro, read back 134400, and nagged again at every login.
NS.QUESTION_MARK = "INV_MISC_QUESTIONMARK"
NS.QUESTION_MARK_FILEID = 134400
function NS.CanonIcon(icon)
	if icon == nil or icon == NS.QUESTION_MARK_FILEID then return NS.QUESTION_MARK end
	if type(icon) == "string" and icon:upper():find(NS.QUESTION_MARK, 1, true) then return NS.QUESTION_MARK end
	return icon
end

function NS.CountTable(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end
