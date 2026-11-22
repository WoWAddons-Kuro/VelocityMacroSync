-- Offline tests for Core/Classify.lua.  lua5.1 tests\classify.lua
package.path = "./?.lua;" .. package.path
local NS = {}
assert(loadfile("Core/Classify.lua"))("VelocityMacroSync", NS)
local C = NS.Classify

local function expect(label, got, want)
	if got ~= want then error(label .. "\n  got:  " .. tostring(got) .. "\n  want: " .. tostring(want), 2) end
	print("ok   " .. label)
end
local function names(body) return table.concat(C.SpellNames(body), "|") end

-- spell sets for the verdict tests
local SETS = {
	WARRIOR = { Charge = true, Intercept = true, ["Berserker Stance"] = true, ["Battle Stance"] = true, ["Heroic Strike"] = true },
	MAGE = { Frostbolt = true, Fireball = true, Blink = true, ["Frost Nova"] = true },
	PRIEST = { ["Power Word: Shield"] = true, Renew = true },
}
local function classesFor(n) local o = {} for c, s in pairs(SETS) do if s[n] then o[#o + 1] = c end end table.sort(o) return o end
local function verdict(body) return C.Describe(C.Verdict(body, classesFor)) end

-------------------------------------------------------------------- name extraction
expect("simple cast", names("/cast Frostbolt"), "Frostbolt")
expect("rank stripped", names("/cast Frostbolt(Rank 3)"), "Frostbolt")
expect("rank with space stripped", names("/cast Frostbolt (Rank 3)"), "Frostbolt")
expect("conditionals stripped", names("/cast [stance:1,nocombat] Charge; [stance:3,combat] Intercept"), "Charge|Intercept")
expect("the user's real charge macro", names("#showtooltip\n/targetenemy [noexists,nocombat][dead,nocombat]\n/cast [stance:1,nocombat] Charge; [stance:3,combat] Intercept; [combat] Berserker Stance; Battle Stance"), "Charge|Intercept|Berserker Stance|Battle Stance")
expect("bang stripped", names("/cast !Frostbolt"), "Frostbolt")
expect("castsequence splits on comma and drops reset", names("/castsequence reset=combat Frostbolt, Fireball, Blink"), "Frostbolt|Fireball|Blink")
expect("showtooltip counts", names("#showtooltip Frostbolt\n/cast Frostbolt"), "Frostbolt")
expect("empty showtooltip ignored", names("#showtooltip\n/cast Blink"), "Blink")
expect("/use ignored", names("/use Talisman of Ephemeral Power\n/cast Frostbolt"), "Frostbolt")
expect("/use slot ignored", names("/use 13\n/cast Frostbolt"), "Frostbolt")
expect("non-spell commands ignored", names("/say hi\n/target focus\n/equip Sword"), "")
expect("colon in name survives", names("/cast Power Word: Shield"), "Power Word: Shield")
expect("dedup", names("/cast Frostbolt\n/cast Frostbolt"), "Frostbolt")
expect("case of command irrelevant", names("/CAST Blink"), "Blink")
expect("windows newlines", names("/cast Blink\r\n/cast Frostbolt"), "Blink|Frostbolt")

-------------------------------------------------------------------- #nosync
expect("nosync detected", C.HasNoSync("/cast Frostbolt\n#nosync"), true)
expect("nosync case/space insensitive", C.HasNoSync("  #NoSync  \n/cast Frostbolt"), true)
expect("nosync must be whole line", C.HasNoSync("/cast Frostbolt #nosync"), false)

-------------------------------------------------------------------- verdicts
expect("warrior macro", verdict("#showtooltip\n/cast [stance:1] Charge; Intercept"), "WARRIOR")
expect("mage macro", verdict("/cast Frostbolt(Rank 2)"), "MAGE")
expect("mage + trinket is still mage (/use ignored)", verdict("/use 13\n/cast Frostbolt"), "MAGE")
expect("trinket only = no class spell", verdict("/use 13\n/use 14"), "no class spell")
expect("say only = no class spell", verdict("/say pull in 3"), "no class spell")
expect("empty body", verdict(""), "no class spell")
expect("nosync wins", verdict("#nosync\n/cast Frostbolt"), "#nosync")
expect("unknown blocks", verdict("/cast Frostbolt\n/cast Arcane Explosion"), "unknown: Arcane Explosion")
expect("all unknown reports the names, not no-class-spell", verdict("/cast Totally Made Up"), "unknown: Totally Made Up")
expect("mixed classes", verdict("/cast Frostbolt\n/cast Charge"), "mixed: MAGE, WARRIOR")
expect("mixed beats unknown in report", verdict("/cast Frostbolt\n/cast Charge\n/cast Whatever"), "mixed: MAGE, WARRIOR")
expect("priest colon name", verdict("/cast Power Word: Shield"), "PRIEST")

print("\nCLASSIFY TESTS PASSED")
