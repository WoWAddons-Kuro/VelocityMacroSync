# Class Macro Sync (VelocityClassMacroSync) — SPEC

Folder / TOC / SavedVariables name: `VelocityClassMacroSync`. Display title: **Class Macro Sync**. Slash: `/cms`, `/classmacrosync`.

## Goal

The "Character Specific Macros" tab is identical on every character of the same class on the same
WoW account + client install. Log in on any of them and it converges: adds, edits and deletes made
on one character appear on the others at their next login. No UI, no library dependencies.

Clients: WoW Forever (16001) and Classic Era (11509). Retail is deliberately not shipped until testable.
SavedVariables are per account per install, so Era / Forever each keep their own class sets.

## Data model (`VelocityClassMacroSyncDB`)

```
classes[CLASS]  = { [key] = { name, icon, body } }     -- the shared set, e.g. classes.MAGE
chars[guid]     = { class, name, snapshot = { [key] = icon } }
debug           = bool
key             = name .. "\1" .. body
```

- `chars` is keyed by `UnitGUID("player")` (workspace rule: never Name-Realm). `name` is display only.
- `snapshot` = what THAT character's tab held after its last successful sync. `nil` = never synced.
- Icon is not part of the key: changing only the icon is an edit of the same macro.

## Three-way merge (`Core/Merge.lua`, pure, tested offline)

For each key, with S = in snapshot, L = on the character tab, C = in class set:

| L | C | S | meaning | action |
|---|---|---|---|---|
| 1 | 1 | * | in sync | none (icon: local≠snapshot → push to class; else class → local) |
| 1 | 0 | 1 | deleted on another char | `DeleteMacro` locally |
| 1 | 0 | 0 | new here | add to class set |
| 0 | 1 | 1 | deleted here | remove from class set |
| 0 | 1 | 0 | new elsewhere | `CreateMacro` locally |

- A local delete + local create with the **same name** are paired into one `EditMacro` in place so the
  macro keeps its action-bar slot. This is how an edit on character A lands on character B.
- **First sync** (no snapshot) is a plain union — "3 mages with 3 different macros → all have all 3".
- **First-sync name conflict** (same name, different body): keep both; the incoming one is renamed
  `Name~2`, `Name~3`… (trimmed to the 16-char macro name limit). Decided 2026-11-22.
- Deletes run highest index first so indices don't shift under the plan.

## Orchestration (`Core/Sync.lua`)

- Run on the first `UPDATE_MACROS` after `PLAYER_ENTERING_WORLD` (macros are server-synced and may not be
  present at `PLAYER_LOGIN`), with a 1 s fallback timer in case the event already fired.
- After that first sync, every `UPDATE_MACROS` re-runs the merge so in-session edits land in the class set
  immediately; nothing is left to do at logout. An `applying` flag ignores our own writes.
- `InCombatLockdown()` → defer to `PLAYER_REGEN_ENABLED` (macro writes are blocked in combat).
- **Slot overflow**: fill what fits in class-set order, then one red chat line listing the names that did not
  fit. The class set keeps them all. Decided 2026-11-22 (vs. refusing the whole sync).
- Snapshot is retaken after every apply.

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
| `/cms reset` | forget this character's snapshot → next sync is a plain union |
| `/cms resetclass` | wipe the class set and all sibling snapshots |
| `/cms debug` | per-action chat trace |

## Tests

`lua5.1 tests\run.lua` from the addon folder: fake macro API, six scenarios (union, edit, delete, conflict,
overflow, idempotence). `tests/` is `.pkgmeta`-ignored.

## Open / to verify in game

- Forever: confirm `GetNumMacros`/`CreateMacro(…, true)` shape and `MAX_CHARACTER_MACROS` value.
- Whether `UPDATE_MACROS` fires once or many times per `EditMacro` burst (harmless either way — merge is idempotent).
- Icon round-trip: `GetMacroInfo` returns a fileID on Forever and a texture path on Era; we pass back whatever
  we got, which is correct within one install.