-- Velocity Macro Sync: the general-macro classifier. Pure logic, no game API.
--
-- Given a macro body and the class spell sets, decide which class (if any)
-- the macro belongs to. Conservative: the only wrong answer is a wrong class,
-- and the rules make that impossible; the cost is that some class macros are
-- left unclassified until the spell sets fill in.
--
-- Verdict shape:
--   { class = "MAGE" }                                   -- exactly one class, migratable
--   { class = nil, reason = "nosync" }                   -- #nosync line present
--   { class = nil, reason = "noclassspell" }             -- no /cast etc. names at all
--   { class = nil, reason = "unknown", names = {...} }   -- a name no class set knows
--   { class = nil, reason = "mixed", classes = {...} }   -- names from 2+ classes
local ADDON, NS = ...

local Classify = {}
NS.Classify = Classify

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Lines whose arguments are spell names. /use is deliberately absent: it is the
-- item command (/use Trinket, /use 13) and items are not in any spellbook.
local SPELL_COMMANDS = {
	["cast"] = true, ["castsequence"] = true, ["castrandom"] = true,
	["showtooltip"] = true, ["show"] = true,
}

function Classify.HasNoSync(body)
	for line in (body or ""):gmatch("[^\r\n]+") do
		if trim(line):lower() == "#nosync" then return true end
	end
	return false
end

-- One argument string -> list of candidate spell names.
--   strip [conditionals], reset=... clauses, leading !, (Rank N) suffixes
--   split on ; and (castsequence) on ,
--   ignore bare numbers (inventory slots) and empty tokens
local function NamesFromArgs(args, isSequence)
	local out = {}
	args = args:gsub("%b[]", "")               -- [conditionals]
	args = args:gsub("reset=%S+", "")          -- castsequence reset clause
	if isSequence then args = args:gsub(",", ";") end
	for piece in (args .. ";"):gmatch("([^;]*);") do
		piece = trim(piece)
		piece = piece:gsub("^!", "")
		piece = trim((piece:gsub("%s*%b()%s*$", "")))   -- (Rank 3)
		if piece ~= "" and not piece:match("^%d+$") then
			out[#out + 1] = piece
		end
	end
	return out
end

-- All spell names referenced by a body (de-duplicated, order of first appearance).
function Classify.SpellNames(body)
	local names, seen = {}, {}
	for line in (body or ""):gmatch("[^\r\n]+") do
		line = trim(line)
		local cmd, rest = line:match("^[/#](%a+)%s*(.*)$")
		if cmd and SPELL_COMMANDS[cmd:lower()] then
			for _, n in ipairs(NamesFromArgs(rest, cmd:lower() == "castsequence")) do
				if not seen[n] then seen[n] = true; names[#names + 1] = n end
			end
		end
	end
	return names
end

-- The verdict. `classesFor(name) -> { CLASS, ... }` is injected so this file
-- stays free of NS.db (SpellSets.ClassesFor in production, a stub in tests).
function Classify.Verdict(body, classesFor)
	if Classify.HasNoSync(body) then return { class = nil, reason = "nosync" } end
	local names = Classify.SpellNames(body)
	if #names == 0 then return { class = nil, reason = "noclassspell" } end

	local unknown, classSeen, classList = {}, {}, {}
	for _, n in ipairs(names) do
		local owners = classesFor(n)
		if #owners == 0 then
			unknown[#unknown + 1] = n
		else
			for _, c in ipairs(owners) do
				if not classSeen[c] then classSeen[c] = true; classList[#classList + 1] = c end
			end
		end
	end
	if #classList == 0 then return { class = nil, reason = "noclassspell" } end
	if #classList > 1 then table.sort(classList); return { class = nil, reason = "mixed", classes = classList } end
	if #unknown > 0 then return { class = nil, reason = "unknown", names = unknown } end
	return { class = classList[1] }
end

-- Human text for a verdict (settings table / tooltip).
function Classify.Describe(v)
	if v.class then return v.class end
	if v.reason == "nosync" then return "#nosync" end
	if v.reason == "noclassspell" then return "no class spell" end
	if v.reason == "unknown" then return "unknown: " .. table.concat(v.names, ", ") end
	if v.reason == "mixed" then return "mixed: " .. table.concat(v.classes, ", ") end
	return "?"
end
