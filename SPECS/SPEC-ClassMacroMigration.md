# SPEC-ClassMacroMigration: Automatic General → Class Macro Migration

- **Status:** Draft
- **Addon:** VelocityClassMacroSync
- **Clients:** Classic Era, WoW Forever, Retail
- **References:** API links in [External References](#external-references)

- [ ] Per-client API verification (see [Verification Checklist](#verification-checklist))
- [ ] Class spell sets built from spellbooks
- [ ] Classifier: identify general macros that belong to one class
- [ ] Migration on the current character (create, re-place bars, stub)
- [ ] Login remap sweep on other characters of the class
- [ ] Stub purge command

## Overview

VelocityClassMacroSync keeps the character-specific macro tab identical across all characters of the same class. This spec covers one feature of it: automatically moving macros that contain class-specific spells out of the **General** tab and into the character tab, where the class sync then carries them to every character of that class.

The hard constraint is action bars. A general macro is shared by every character on the account, and a bar button holds a reference to the macro, not its text. Deleting a general macro makes the buttons that reference it on other characters silently disappear, with nothing left to identify what was there. So migration never deletes. It converts the general macro into a **stub** in place, which keeps every button reference alive. Each other character of the class swaps its stub buttons for the class macro the next time it logs in.

Stubs are renamed so they sort to the end of the General tab, forming a block of migrated records that can be purged later.

## Design

### Terms

| Term | Meaning |
|---|---|
| General macro | Macro in the account-wide tab. Indices `1..MAX_ACCOUNT_MACROS`. |
| Character macro | Macro in the per-character tab. Indices above `MAX_ACCOUNT_MACROS`. |
| Class macro | A character macro held in the class store and synced to all characters of a class. Has a stable ID. |
| Stub | A general macro that has been migrated: renamed, re-iconed, body replaced by a marker line. |
| Action slot | A bar button position (`1..120` on Classic clients, more on Retail). Never shifts. |
| Macro index | A macro's position in the macro list. Shifts on create, rename and delete, because the list is sorted by name. |

**Rule: a macro index is never stored.** Indices are resolved from name (and body where needed) at the moment of use, and re-resolved after every create, edit or delete.

### Flow

```
Character A (mage) logs in
  1. class sync merge runs           (character tab == class store)
  2. spell set for MAGE updated      (from A's spellbook)
  3. classifier scans General tab
  4. for each general macro classified MAGE:
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

### Class Spell Sets

The classifier needs to know which spell names belong to which class. Each character contributes its own spellbook to an account-wide table, so no spell data ships with the addon and the same code works on all three clients.

- Walk the spellbook tabs for the logged-in character and record each spell name under the character's class token (second return of `UnitClass("player")`, locale-independent).
- **Skip the General tab** (tab 1), so racials, professions and shared abilities are never treated as class spells.
- Strip rank text; names are stored without ranks.
- Spell names are locale-specific. The table is keyed by the client locale's names, which is correct because macro bodies use the same names.

```lua
-- pseudocode
VCMS_DB.classSpells[classToken][spellName] = true
```

The set only contains spells some character of that class has learned. The consequence is conservative: an unknown spell prevents classification, it never causes a wrong one.

### Classifier

For each general macro that is not already a stub:

1. Extract spell names from `/cast`, `/use`, `/castsequence`, `#showtooltip` and `#show` lines.
2. Strip `[conditionals]`, `reset=` clauses, rank suffixes and leading `!`; split on `;` and (for `/castsequence`) `,`.
3. Look each name up in the class spell sets.

A macro is migrated only when **all** of the following hold:

- At least one name is recognized as a spell of the logged-in character's class.
- No name is recognized as a spell of a different class.
- No name is unrecognized. (Item names in `/use` lines are unrecognized by this definition, so macros that mix class spells with trinkets or consumables are left alone. See Open Questions.)

Macros that fail any rule are left untouched in the General tab.

### Migration on the Current Character

For a general macro `G` (name `N`, icon `I`, body `B`) classified as the current class:

1. **Find or create the class macro.**
   - If a character macro with the same name and body already exists, reuse it.
   - Otherwise `CreateMacro(N, I, B, true)`. Creating a character macro does not renumber general macros.
   - If the character tab is full (`MAX_CHARACTER_MACROS`), skip this macro, leave `G` untouched and print a message. Nothing is ever dropped silently.
   - Register it in the class store and obtain its stable class macro ID.
2. **Re-place this character's bar buttons.** For every action slot holding `G`: pick up the class macro, place it in the slot, clear the cursor.
3. **Convert `G` to a stub** with `EditMacro` (see below). `EditMacro` changes the macro in place, so references to it from other characters' bars survive. The rename re-sorts the list; use the index `EditMacro` returns.

```lua
-- pseudocode
local classIndex = FindOrCreateClassMacro(N, I, B)
for slot = 1, MAX_ACTION_SLOT do
    if SlotHoldsGeneralMacro(slot, G) then
        PickupMacro(classIndex); PlaceAction(slot); ClearCursor()
    end
end
EditMacro(ResolveIndex(G), NextStubName(), STUB_ICON, StubBody(classToken, classMacroId, N))
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
#VelocityClassMacroSync-migrated v1 <CLASS> <classMacroId> <original macro name>
```

| Field | Meaning |
|---|---|
| `v1` | Payload format version. |
| `<CLASS>` | Class token, e.g. `MAGE`. |
| `<classMacroId>` | Stable ID of the class macro in the class store. No spaces. |
| rest of line | The original macro name. Placed last because names may contain spaces and punctuation. |

```lua
-- pseudocode; note the escaped hyphen
local class, id, name =
    body:match("^#VelocityClassMacroSync%-migrated v1 (%u+) (%S+) (.+)")
```

Limits: macro names are at most 16 characters and bodies at most 255. The marker prefix is 32 characters, so the full line fits with a wide margin.

**The stub is the migration record.** It carries everything needed to remap, so no separate migration table is required in SavedVariables. If the class store is ever lost and the ID no longer resolves, the original name in the payload is the fallback for finding the class macro.

### Login Remap Sweep

Runs on every login after the class sync merge, so the character already has the class macros.

1. For each action slot whose action type is `macro`, read the button's macro name with `GetActionText(slot)`.
2. If the name matches `^zz%d+$`, resolve the general macro by that name (stub names are unique) and parse its body.
3. If the payload's class equals the logged-in character's class:
   - Resolve the class macro: by ID through the class store, falling back to the original name.
   - Pick up the class macro, place it in the slot, clear the cursor.
4. Stubs for other classes are ignored.

Matching on the button's name avoids depending on what `GetActionInfo` returns as the macro identifier, which differs between clients.

The sweep is idempotent: once a slot is remapped it no longer holds a stub, so repeated runs do nothing.

If the class macro cannot be resolved (deleted from the class store, or not yet synced), the slot is left on the stub and a message is printed.

### Stub Purge

Stubs stay until removed. A slash command deletes every general macro that matches the stub name pattern and carries the marker line.

Purging a stub while some character of that class has not yet logged in and remapped clears that character's buttons for it. The command prints how many stubs it will delete and requires confirmation.

### Behavior on Other Characters

| Situation | Result |
|---|---|
| Same class, addon running | Buttons remapped at login. |
| Same class, addon disabled | Button shows the stub and does nothing until the addon runs. |
| Different class with the stub on a bar | Button shows the stub and does nothing. Not remapped. |
| Character tab full at migration time | Macro not migrated; message printed. |
| Class macro with same name, different body already exists | Both exist in the character tab (duplicate names are allowed); the migrated one is tracked by ID. |

### Saved Data

Account-wide SavedVariables, per client install. Era, Forever and Retail each keep their own data, which matches their separate macro storage.

```lua
-- pseudocode
VCMS_DB = {
    classSpells = { MAGE = { ["Frostbolt"] = true, ... }, ... },
    classMacros = { MAGE = { [id] = { name=, icon=, body= }, ... }, ... },  -- owned by the sync core
}
```

SavedVariables are written only at logout or `/reload`.

## API Surface

| Function | Notes |
|---|---|
| `GetNumMacros()` | Returns `numGeneral, numCharacter`. |
| `GetMacroInfo(indexOrName)` | Returns `name, icon, body`. |
| `GetMacroBody(indexOrName)` | Body only. |
| `GetMacroIndexByName(name)` | `0` if not found. |
| `CreateMacro(name, icon, body, perCharacter)` | Returns the new index. Blocked in combat. |
| `EditMacro(indexOrName, name, icon, body)` | Edits in place; returns the new index after re-sort. Blocked in combat. |
| `DeleteMacro(indexOrName)` | Used only by the purge command. Blocked in combat. |
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

- **Automatic stub purge.** The addon could keep a roster of characters it has seen and delete a stub once every seen character of that class has remapped. A character that predates the addon and has not logged in since would lose its buttons for that macro. Manual purge only, or add the roster gate?
- **Items in class macros.** A macro that casts a class spell and also uses a trinket or consumable is currently left in General because the item name is unrecognized. Should `/use` item names be ignored by the classifier instead of blocking?
- **Migration during play.** Migration runs at login. Should it also run when a general macro is created or edited mid-session, or would moving a macro the player just saved be surprising?
- **Stub feedback.** The stub body is a comment only, so pressing an un-remapped button does nothing. Add a second line that prints where the macro went?
- **Opt-out.** A way to mark a general macro as "never migrate" (for example a marker line in its body).

## Alternatives Considered

- **Delete the general macro after migrating.** Simplest, and frees the general slot immediately. Not chosen because buttons on other characters disappear with no trace, so they cannot be remapped.
- **Keep the general macro's name and replace only the body.** Keeps the button label unchanged. Not chosen because the stub and the class macro would share a name, making name-based lookup ambiguous, and stubs would stay scattered through the General tab instead of collecting at the end.
- **Per-character slot map.** Record which slots hold which macros for every character, then restore placements after a delete. It would allow immediate deletion, but needs continuous bar tracking and still fails for characters the addon has never seen. The stub carries the same information with no extra state.