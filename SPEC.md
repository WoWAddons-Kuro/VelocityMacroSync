# Velocity Macro Sync (VelocityMacroSync) — SPEC

Folder / TOC / SavedVariables name: `VelocityMacroSync`. Display title: **Velocity Macro Sync**. Slash: `/cms`, `/classmacrosync`.

## Goal

The "Character Specific Macros" tab is identical on every character of the same class on the same
WoW account + client install. Log in on any of them and it converges: adds and edits made on one
character appear on the others at their next login. No library dependencies.

## HARD RULES (non-negotiable, set 2026-11-22 after the addon wrongly emptied a page)

1. **The addon NEVER deletes a macro from a character's page.** Only the player does. There is no
   `DeleteMacro` wrapper anywhere in the code; the test harness makes `DeleteMacro` a hard error.
2. **The class set is append-only.** Nothing is ever removed from it except by `/cms resetclass`.
3. **A player deletion becomes a per-character TOMBSTONE** ("not on this character's page by choice").
   The macro stays in the class set and still syncs to every other character. It is never recreated
   on the character that tombstoned it, unless that character runs `/cms reset`.

Clients: WoW Forever (16001) and Classic Era (11509). Retail is deliberately not shipped until testable.
SavedVariables are per account per install, so Era / Forever each keep their own class sets.

## Data model (`VelocityMacroSyncDB`)

```
classes[CLASS]  = { [key] = { name, icon, body, seq } } -- the shared set, append-only; seq = insertion order
chars[guid]     = { class, name, snapshot = { [key] = icon }, excluded = { [key] = true } }
seq             = global counter stamped onto every class-set addition
debug           = bool
key             = name .. "\1" .. body
```

- `chars` is keyed by `UnitGUID("player")` (workspace rule: never Name-Realm). `name` is display only.
- `snapshot` = what THAT character's tab held after its last successful sync. `nil` = never synced.
- `excluded` = tombstones for that character.
- Icon is not part of the key: changing only the icon is an edit of the same macro.
- Because the set is append-only, an edit leaves the old body behind as a second entry with the same
  name; the entry with the highest `seq` for a name is the current one.

## Merge (`Core/Merge.lua`, pure, tested offline)

Plan has four lists only: `classAdd`, `localCreate`, `localEdit`, `tombstone`. No delete list exists.

| situation | action |
|---|---|
| in snapshot, not on page | player deleted it here → **tombstone** (nothing else) |
| on page, key in class set, newer `seq` exists for that name (not tombstoned here) | `EditMacro` in place to the newer body; tombstone the old key here |
| on page, key in class set, it is the newest | in sync; icon: local≠snapshot → class, else class → local |
| on page, name unknown to class set | `classAdd` |
| on page, same name different body, page key in snapshot | class copy is newer → `EditMacro` in place |
| on page, same name different body, class key in snapshot | page copy is newer → `classAdd` new body, tombstone old key here |
| on page, same name different body, neither in snapshot (first-sync fork) | keep both: rename ours `Name~2`, `classAdd` it, `localCreate` theirs |
| in class set, not on page, not tombstoned here, name free | `localCreate` |

- **First sync** (no snapshot) is a plain union — "3 mages with 3 different macros → all have all 3";
  a fresh character with an empty page simply receives the whole class set.
- Edits are applied with `EditMacro` in place so the macro keeps its action-bar slot.
- `Name~2` renames are trimmed to the 16-char macro name limit.

## Orchestration (`Core/Sync.lua`)

- Run on the first `UPDATE_MACROS` after `PLAYER_ENTERING_WORLD` (macros are server-synced and may not be
  present at `PLAYER_LOGIN`), with a 1 s fallback timer in case the event already fired.
- After that first sync, every `UPDATE_MACROS` re-runs the merge so in-session edits land in the class set
  immediately; nothing is left to do at logout. An `applying` flag, held for 1 s after our last write,
  swallows the `UPDATE_MACROS` burst our own writes cause.
- `InCombatLockdown()` → defer to `PLAYER_REGEN_ENABLED` (macro writes are blocked in combat).
- **Slot overflow**: fill what fits in class-set order, then one red chat line listing the names that did not
  fit (once per name per session). The class set keeps them all. Decided 2026-11-22.
- Snapshot is retaken after every apply.
- Chat: login/manual syncs print plain-English lines with names ("Added 2 Warrior macros from your other
  characters: Charge, Shout"). In-session edits print nothing unless `/cms debug` is on.

## Client abstraction (`Client/`)

`Client.lua` declares `INTERFACE = { PlayerKey, PlayerDisplayName, PlayerClass, MaxAccountMacros, MaxCharacterMacros }`
and hosts the flavour-agnostic macro API wrappers. `Client_ClassicEra.lua` / `Client_Forever.lua` implement
the interface (Forever display name = `UnitNameUnmodified` name + surname). `Client_Select.lua` binds by
`WOW_PROJECT_ID` and warns on interface drift. `Core/Util.lua` loads first because Select needs `NS.Warn`.

## Commands

| cmd | effect |
|---|---|
| `/cms` / `/cms status` | character, class, slots used, class-set size, snapshot state, sibling characters |
| `/cms sync` | run the merge now |
| `/cms list` | names in the class set |
| `/cms reset` | forget this character's snapshot and tombstones → next sync pulls the whole class set |
| `/cms resetclass` | clear the class-set record and sibling snapshots/tombstones. Pages are untouched; every character re-shares at next login |
| `/cms debug` | per-action chat trace |

## Tests

`lua5.1 tests\run.lua` from the addon folder: fake macro API where `DeleteMacro` raises. Scenarios: fresh
character receives the set, union, in-place edit, player-delete → tombstone, fork, overflow, idempotence.

## Open / to verify in game

- Forever: confirm `GetNumMacros`/`CreateMacro(…, true)` shape and `MAX_CHARACTER_MACROS` value.
- Whether `UPDATE_MACROS` fires once or many times per `EditMacro` burst (harmless either way — merge is idempotent).
- Icon round-trip: `GetMacroInfo` returns a fileID on Forever and a texture path on Era; we pass back whatever
  we got, which is correct within one install.