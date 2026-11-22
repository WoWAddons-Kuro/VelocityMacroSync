# SPEC-ClassMacroMigration: Automatic General → Class Macro Migration

- **Status:** Draft
- **Addon:** VelocityMacroSync
- **Clients:** Classic Era, WoW Forever (shipped); Retail (client flavour written blind, no TOC until testable)
- **Product spec:** `00_VelocityMacroSync.md` — its HARD RULES apply here unchanged
- **References:** API links in [External References](#external-references)

This spec was drafted before the sync core existed and has been adapted to it. Where the two differ, the
code direction in `00_VelocityMacroSync.md` wins: content-hash identity, append-only class set, no delete
path, per-client files under `Client\`.

- [ ] M1 Client interface additions: `ActionSlots`, `ReadSpellbook` in `Client.lua`; impl in `Client_ClassicEra`, `Client_Forever`, new `Client_Retail`
- [ ] M2 `Core/SpellSets.lua`: build `db.classSpells[CLASS]` from the spellbook
- [ ] M3 `Core/Classify.lua`: extract spell names, apply the rules (pure, tested offline)
- [ ] M4 `Core/Migrate.lua`: bar scan → classify → create class macro → re-place slots → stub
- [ ] M5 Remap sweep on login, after `Sync.Run`
- [ ] M6 Per-client verification in game (see [Verification Checklist](#verification-checklist))

## Overview

VelocityMacroSync keeps the character-specific macro tab identical across all characters of the same class. This spec covers one feature of it: automatically moving macros that contain class-specific spells out of the **General** tab and into the character tab, where the class sync then carries them to every character of that class.

The hard constraint is action bars. A general macro is shared by every character on the account, and a bar button holds a reference to the macro, not its text. Deleting a general macro makes the buttons that reference it on other characters silently disappear, with nothing left to identify what was there. So migration never deletes, and nothing else in the addon does either (product rule 1). It converts the general macro into a **stub** in place by renaming it and rewriting its body with `EditMacro`, which keeps every button reference alive. Each other character of the class swaps its stub buttons for the class macro the next time it logs in.

Stubs are renamed so they sort to the end of the General tab, forming a block of migrated records. They are permanent; the addon has no delete path.

## Design

### Terms

| Term | Meaning |
|---|---|
| General macro | Macro in the account-wide tab. Indices `1..MAX_ACCOUNT_MACROS`. |
| Character macro | Macro in the per-character tab. Indices above `MAX_ACCOUNT_MACROS`. |
| Class macro | A character macro held in the class set (`db.classes[CLASS]`) and synced to all characters of a class. Identified by the **content hash of its body** (`NS.MacroKey(body)`, FNV-1a 32-bit hex). |
| Stub | A general macro that has been migrated: renamed, re-iconed, body replaced by a marker line. |
| Action slot | A bar button position (`1..120` on Classic clients, more on Retail). Never shifts. |
| Macro index | A macro's position in the macro list. Shifts on create, rename and delete, because the list is sorted by name. |

**Rule: a macro index is never stored.** Indices are resolved from name (and body where needed) at the moment of use, and re-resolved after every create, edit or delete.

### Flow

```
Character A (mage) logs in
  1. class sync merge runs           (character tab == class store)
  2. spell set for MAGE updated      (from A's spellbook)
  3. bar scan: which general macros are on A's action bars
  4. for each of those classified MAGE:
       create class macro  ->  re-place A's bar buttons  ->  convert general macro to stub
  5. remap sweep: any bar button on a MAGE stub -> class macro

Character B (mage) logs in later
  1. class sync merge runs           (B now has the class macro)
  5. remap sweep: B's buttons on MAGE stubs -> class macro

Character C (warrior) logs in
  - MAGE stubs on C's bars are left alone (button does nothing)
```

All macro and action-bar writes are blocked in combat. Every step that writes goes through one out-of-combat queue, drained on `PLAYER_REGEN_ENABLED` if the character is in combat at the time.

### Triggers

The feature is event-driven; nothing polls.

| Event | Use |
|---|---|
| `UPDATE_MACROS` (first after `PLAYER_ENTERING_WORLD`) | Macros are loaded. Run sync merge, then classifier, migration and remap sweep. |
| `SPELLS_CHANGED` | Refresh this class's spell set. |
| `PLAYER_REGEN_ENABLED` | Drain the write queue if work was deferred by combat. |

The addon's own macro writes fire `UPDATE_MACROS`; a re-entrancy guard suppresses handling while a write batch is in progress.

### Opt-out: `#nosync`

A general macro whose body contains a line that is exactly `#nosync` (case-insensitive, surrounding
whitespace ignored) is never migrated, whatever else it contains. The line is a macro comment so the
client ignores it. Checked before classification; such a macro is skipped silently.

### Class Spell Sets

The classifier needs to know which spell names belong to which class. Each character contributes its own spellbook to an account-wide table, so no spell data ships with the addon and the same code works on all three clients.

- Walk the spellbook tabs for the logged-in character and record each spell name under the character's class token (second return of `UnitClass("player")`, locale-independent).
- **Skip the General tab** (tab 1), so racials, professions and shared abilities are never treated as class spells.
- Strip rank text; names are stored without ranks.
- Spell names are locale-specific. The table is keyed by the client locale's names, which is correct because macro bodies use the same names.

```lua
-- pseudocode
VelocityMacroSyncDB.classSpells[classToken][spellName] = true
```

The set only contains spells some character of that class has learned. The consequence is conservative: an unknown spell prevents classification, it never causes a wrong one.

### Classifier

**Gate: only general macros this character actually has on an action bar are candidates.** A general macro
that is not placed on any of this character's bars is never migrated by this character, whatever it contains.
A macro on the bars is the one the player uses; an unused one in the General tab is a leftover they may not
want moved. This also makes the bar scan the source of truth for the re-place step below.

For each general macro referenced by at least one of this character's action slots and not already a stub:

1. Extract spell names from `/cast`, `/castsequence`, `#showtooltip` and `#show` lines. **`/use` lines are
   ignored** (they are the item command: `/use Trinket`, `/use 13`, `/use Healing Potion`; items are not in
   any spellbook). A macro with only `/use` lines therefore has no spell names and stays in General — the
   player can move it to a character macro by hand if they want it on one class.
2. Strip `[conditionals]`, `reset=` clauses, rank suffixes and leading `!`; split on `;` and (for `/castsequence`) `,`.
3. Look each name up in the class spell sets.

A macro is migrated only when **all** of the following hold:

- **At least one name is a spell of the logged-in character's class. A macro with no class spell in it is
  never migrated, by anyone, ever.** `/say`, `/target`, `/equip`, trinket-only, mount, bandage and
  consumable macros stay in General. This is the rule that makes the "different class" case impossible:
  a migrated macro always contains a spell only its class can have.
- No name is recognized as a spell of a different class.
- No name is unrecognized (a spell no character of yours has learned yet blocks until one does).

Macros that fail any rule are left untouched in the General tab.

### Migration on the Current Character

For a general macro `G` (name `N`, icon `I`, body `B`) classified as the current class:

1. **Find or create the class macro.**
   - `hash = NS.MacroKey(B)`. If `db.classes[CLASS][hash]` exists the class already has this macro; if it
     is on this character's page, reuse it, otherwise the next `Sync.Run` will create it.
   - Otherwise `CreateMacro(N, I, B, true)` and let `Sync.Run` add it to the class set (it is a new body
     on the page, which is exactly the `classAdd` path). Creating a character macro does not renumber general macros.
   - If the character tab is full (`MAX_CHARACTER_MACROS`), skip this macro, leave `G` untouched and print a message. Nothing is ever dropped silently.
   - If `N` is already held on the page by a different body, product rule 5 applies: the migrated copy is created as `N 2`.
2. **Re-place this character's bar buttons.** For every action slot holding `G`: pick up the class macro, place it in the slot, clear the cursor.
3. **Convert `G` to a stub** with `EditMacro` (see below). `EditMacro` changes the macro in place, so references to it from other characters' bars survive. The rename re-sorts the list; use the index `EditMacro` returns.

```lua
-- pseudocode
local classIndex = FindOrCreateClassMacro(N, I, B)   -- resolves by NS.MacroKey(B)
for slot = 1, MAX_ACTION_SLOT do
    if SlotHoldsGeneralMacro(slot, G) then
        PickupMacro(classIndex); PlaceAction(slot); ClearCursor()
    end
end
EditMacro(ResolveIndex(G), NextStubName(), STUB_ICON, StubBody(classToken, NS.MacroKey(B), N))
```

### Stub Format

**Name:** `zz` followed by a zero-padded three-digit number, for example `zz007`.

- Punctuation sorts before letters in the macro list, so a letter prefix is used. `zz` places stubs at the end of the General tab.
- The number only makes the name unique and keeps stubs in migration order. It is not the record ID.
- The next number is taken by scanning existing general macro names for the highest `^zz(%d+)$` and adding one. It is not kept as a counter in SavedVariables, so a wiped SavedVariables file cannot cause a collision with stubs that still exist.
- A stub is recognized by the **whole-name** pattern `^zz%d+$` together with the body marker, so a real macro that happens to start with `zz` is never mistaken for one.

**Icon:** one fixed "migrated" icon for all stubs (constant `STUB_ICON`; the question-mark icon, file ID 134400, is the default).

**Body:** a single comment line.

```
#VelocityMacroSync-migrated v1 <CLASS> <bodyHash> <original macro name>
```

| Field | Meaning |
|---|---|
| `v1` | Payload format version. |
| `<CLASS>` | Class token, e.g. `MAGE`. |
| `<bodyHash>` | `NS.MacroKey(originalBody)`: 8 hex chars. Looks the class macro up in `db.classes[CLASS]`. |
| rest of line | The original macro name. Placed last because names may contain spaces and punctuation. |

```lua
-- pseudocode; note the escaped hyphen
local class, hash, name =
    body:match("^#VelocityMacroSync%-migrated v1 (%u+) (%x+) (.+)")
```

Limits: macro names are at most 16 characters and bodies at most 255. The marker prefix is 27 characters, so the full line fits with a wide margin.

**The stub is the migration record.** It carries everything needed to remap, so no separate migration table is required in SavedVariables. If the class set is ever wiped (`/velocitymacrosync reset`) and the hash no longer resolves, the original name in the payload is the fallback for finding the class macro on the page.

### Login Remap Sweep

Runs on every login after the class sync merge, so the character already has the class macros.

1. For each action slot whose action type is `macro`, read the button's macro name with `GetActionText(slot)`.
2. If the name matches `^zz%d+$`, resolve the general macro by that name (stub names are unique) and parse its body.
3. If the payload's class equals the logged-in character's class:
   - Resolve the class macro on this page: by body hash (`NS.MacroKey` of each page macro's body), falling back to the original name.
   - Pick up the class macro, place it in the slot, clear the cursor.
4. Stubs for other classes are ignored.

Matching on the button's name avoids depending on what `GetActionInfo` returns as the macro identifier, which differs between clients.

The sweep is idempotent: once a slot is remapped it no longer holds a stub, so repeated runs do nothing.

If the class macro cannot be resolved (deleted from the class store, or not yet synced), the slot is left on the stub and a message is printed.

### Stubs Are Permanent

The addon never deletes a macro, so stubs stay in the General tab. They sort to the end as a `zz###` block and are inert (a comment-only body does nothing when pressed). They are the only thing keeping other characters' bar buttons alive until those characters log in and remap, and there is no way to know from one character whether every other character has done so.

If the user wants the general slots back they delete the stubs by hand, knowing that any character of that class that has not logged in since the migration will lose those buttons.

### Behavior on Other Characters

| Situation | Result |
|---|---|
| Same class, addon running | Buttons remapped at login. |
| Same class, addon disabled | Button shows the stub and does nothing until the addon runs. |
| Different class | Cannot happen for a correctly classified macro: every spell in it belongs to one class, so no other class could have been using it. A stub of another class on a bar is therefore only ever the result of the user placing the general macro there by mistake; it stays inert and is not remapped. |
| Character tab full at migration time | Macro not migrated; message printed. |
| Class macro with same name, different body already exists | Product rule 5: the player's existing macro keeps its name; the migrated copy is created as `Name 2`. Tracked by body hash. |
| General macro body has a `#nosync` line | Never migrated. |

### Saved Data

Account-wide SavedVariables (`VelocityMacroSyncDB`), per client install. Era, Forever and Retail each keep their own data, which matches their separate macro storage.

```lua
-- additions to the layout in 00_VelocityMacroSync.md
VelocityMacroSyncDB.classSpells = { MAGE = { ["Frostbolt"] = true, ... }, ... }
-- classes[CLASS][hash] = { name, icon, body, seq }   already exists; owned by Core/Sync.lua
```

SavedVariables are written only at logout or `/reload`.

### Client abstraction (follows `Client\` pattern from the product spec)

Everything flavour-specific lives in the per-client files; `Core\*` never branches on client. Additions to
`Client.INTERFACE`:

| Method | Returns | Notes |
|---|---|---|
| `MaxActionSlot()` | number | 120 on Classic clients; higher on Retail |
| `ActionSlotMacroName(slot)` | name or nil | `GetActionInfo(slot)` type `"macro"` → `GetActionText(slot)` |
| `ReadSpellbook()` | `{ name, ... }` | Player's class spells, General tab skipped, ranks stripped |

| File | Spellbook source |
|---|---|
| `Client_ClassicEra.lua` | `GetNumSpellTabs`, `GetSpellTabInfo`, `GetSpellBookItemName(i, BOOKTYPE_SPELL)` |
| `Client_Forever.lua` | same Classic shape (Forever is Mainline UI code on a Classic-era data set; verify in M6) |
| `Client_Retail.lua` | `C_SpellBook.GetNumSpellBookSkillLines`, `GetSpellBookSkillLineInfo`, `GetSpellBookItemName(i, Enum.SpellBookSpellBank.Player)`. **Written blind**; no Retail TOC ships until it is tested. |

`Client_Select.lua` gains a `retail` branch (`WOW_PROJECT_ID == WOW_PROJECT_MAINLINE`). Shared wrappers
(`PickupMacro`, `PlaceAction`, `ClearCursor`, `GetMacroIndexByName`) go in `Client.lua` like the macro
wrappers already there. Pure logic (`Classify`, stub format, remap decision) is flavour-free and testable
under `tests\run.lua` with the fake API extended for action slots and a spellbook.

### Settings page

The page (`UI\Options.lua`) grows from two cards to four, top to bottom:

1. **Top card** — icon, title, description (exists).
2. **Class Macros: `<class>`** (exists; list becomes a table) — `Open Macro Window` button, summary line, then a
   **two-column table**: macro name | body. Body is multi-line, so rows are variable height: each row is a
   frame with two FontStrings, the row height is `max(name height, body height) + padding`, rows stack with
   `SetPoint("TOPLEFT", prevRow, "BOTTOMLEFT")`. Rebuilt on every `Refresh`. Body text is shown verbatim
   (monospace not required; GameFontHighlightSmall, left-justified, word-wrap on).
3. **General Macro Migration** (new) —
   - `[ ] Enable automatic migration of class-specific macros` → `db.autoMigrate` (default **off**).
     **Turning it on requires a confirmation dialog.** Clicking the unchecked box does *not* set the value;
     it reverts the checkbox to unchecked and opens a `StaticPopup` that repeats the warning below in full
     with buttons `Enable migration` / `Cancel`. Only `Enable migration` sets `db.autoMigrate = true` and
     re-ticks the box. Turning it **off** is immediate, no dialog. The popup has `showAlert = true`
     (the red exclamation art) so it reads as a warning, not an info box.
   - Warning text, always visible, red:
     > WARNING: This will *move* your class-specific macros from General into per-character macros for each
     > class. Make sure you are happy with this addon before you turn this on, because characters referencing
     > general macros will only be updated if this addon is still running when you first login to them.
   - A **dense table** of every General-tab macro (stubs excluded): name | detected class | `Migrate` button.
     Detected class is the classifier's verdict with the current spell sets: a class token coloured with
     `RAID_CLASS_COLORS`, or grey `—` with a reason in a tooltip (`no class spell`, `unknown: Frostfire Bolt`,
     `#nosync`, `mixed: MAGE, WARRIOR`). The `Migrate` button is enabled only when the verdict is the
     **logged-in character's class** (migration creates a character macro, which can only happen on a
     character of that class) and the macro is not `#nosync`. Clicking migrates that one macro through the
     same `Core/Migrate.lua` path as auto-migration, then refreshes the table.
   - The per-macro button is **not** gated by `autoMigrate` and **not** gated by bar placement: it is the
     player's explicit choice. Auto-migration keeps both gates.
4. **Reset** (exists).

`db.autoMigrate` is read by `Core/Migrate.lua` at the login hook; when false the bar scan does not run.

### Saved Data (additions)

```lua
VelocityMacroSyncDB.autoMigrate = false
```

## API Surface

| Function | Notes |
|---|---|
| `GetNumMacros()` | Returns `numGeneral, numCharacter`. |
| `GetMacroInfo(indexOrName)` | Returns `name, icon, body`. |
| `GetMacroBody(indexOrName)` | Body only. |
| `GetMacroIndexByName(name)` | `0` if not found. |
| `CreateMacro(name, icon, body, perCharacter)` | Returns the new index. Blocked in combat. |
| `EditMacro(indexOrName, name, icon, body)` | Edits in place; returns the new index after re-sort. Blocked in combat. |
| `GetActionInfo(slot)` | Returns `actionType, id, subType`. `actionType == "macro"` for macro buttons. |
| `GetActionText(slot)` | Macro name for macro buttons. |
| `PickupMacro(indexOrName)`, `PlaceAction(slot)`, `ClearCursor()` | Place a macro into a slot. `PlaceAction` is blocked in combat. |
| `InCombatLockdown()` | Gate for the write queue. |
| `UnitClass("player")` | Second return is the class token. |
| Spellbook (Classic) | `GetNumSpellTabs()`, `GetSpellTabInfo(tab)`, `GetSpellBookItemName(index, BOOKTYPE_SPELL)` |
| Spellbook (Retail) | `C_SpellBook.GetNumSpellBookSkillLines()`, `C_SpellBook.GetSpellBookSkillLineInfo(i)`, `C_SpellBook.GetSpellBookItemName(index, Enum.SpellBookSpellBank.Player)` |

Constants: `MAX_ACCOUNT_MACROS`, `MAX_CHARACTER_MACROS` (read at runtime; do not hardcode, the character cap differs between clients).

## Verification Checklist

Confirmed by test on Classic Era:

- Deleting a general macro makes buttons referencing it on other characters disappear silently.

To confirm on each client before relying on it:

- [ ] `EditMacro` on a general macro (rename + new body) keeps bar references on **other** characters intact.
- [ ] A body consisting only of a `#…` line is ignored when the button is pressed (not sent to chat).
- [ ] `GetActionText(slot)` returns the macro name for macro buttons.
- [ ] What `GetActionInfo(slot)` returns as `id` for a macro button (macro index on Classic; may differ on Retail).
- [ ] Highest action slot number (`120` on Classic clients; higher on Retail).
- [ ] `zz###` names sort after all other general macros.
- [ ] Macro API parity on WoW Forever (`CreateMacro`, `EditMacro`, `GetActionText`).
- [ ] `UPDATE_MACROS` fires after macros are available at login.

## External References

- [CreateMacro](https://warcraft.wiki.gg/wiki/API_CreateMacro) — creating the class macro
- [EditMacro](https://warcraft.wiki.gg/wiki/API_EditMacro) — converting a general macro to a stub
- [GetMacroInfo](https://warcraft.wiki.gg/wiki/API_GetMacroInfo) — reading name, icon, body
- [GetActionInfo](https://warcraft.wiki.gg/wiki/API_GetActionInfo) — identifying macro buttons
- [GetActionText](https://warcraft.wiki.gg/wiki/API_GetActionText) — macro name of a button
- [PlaceAction](https://warcraft.wiki.gg/wiki/API_PlaceAction) — placing the class macro in a slot
- [InCombatLockdown](https://warcraft.wiki.gg/wiki/API_InCombatLockdown) — write gating
- [UPDATE_MACROS](https://warcraft.wiki.gg/wiki/UPDATE_MACROS) — macro change event
- [Macro conditionals](https://warcraft.wiki.gg/wiki/Macro_conditionals) — syntax the classifier strips
- [Making a macro](https://warcraft.wiki.gg/wiki/Making_a_macro) — macro line syntax and limits

## Open Questions

- ~~Items in class macros~~ Decided 2026-11-22: `/use` lines are ignored by the classifier (see Classifier).
- **Migration during play.** Migration runs at login. Should it also run when a general macro is created or edited mid-session, or would moving a macro the player just saved be surprising?
- **Stub feedback.** The stub body is a comment only, so pressing an un-remapped button does nothing. Add a second line that prints where the macro went?

## Alternatives Considered

- **Delete the general macro after migrating.** Simplest, and frees the general slot immediately. Not chosen because buttons on other characters disappear with no trace, so they cannot be remapped.
- **A purge command to delete stubs later.** Considered and rejected: a stub is a user macro that has been renamed and rewritten, and the addon never deletes a user macro (product rule 1). Deleting a stub would also empty the buttons of any character of that class that has not yet logged in and remapped, which is the exact failure the stub exists to prevent. Stubs stay in the General tab; the user can delete them by hand if they want the slot back.
- **Keep the general macro's name and replace only the body.** Keeps the button label unchanged. Not chosen because the stub and the class macro would share a name, making name-based lookup ambiguous, and stubs would stay scattered through the General tab instead of collecting at the end.
- **Per-character slot map.** Record which slots hold which macros for every character, then restore placements after a delete. It would allow immediate deletion, but needs continuous bar tracking and still fails for characters the addon has never seen. The stub carries the same information with no extra state.