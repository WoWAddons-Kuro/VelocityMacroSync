# Velocity Macro Sync

Keeps the **Character Specific Macros** tab identical across every character of the same class.

Log in on any mage and your mage macros are there. Add a macro on one, edit it on another, delete it on a
third — each change reaches the rest the next time they log in. Nothing to configure, no UI, no libraries.

- **WoW Forever** and **Classic Era**.
- Edits are applied in place, so macros stay on your action bars.
- Same-name clashes on first sync are kept (second copy becomes `Name~2`), never silently dropped.
- If a character runs out of macro slots you get one chat line saying which macros didn't fit.
- Changes you make during a session are captured as you make them; nothing is lost on a crash.

## Commands

```
/velocitymacrosync             status: this character, its class set, sibling characters
/velocitymacrosync sync        run the merge now
/velocitymacrosync list        names in the class set
/velocitymacrosync reset       forget this character's sync state (next login merges as a plain union)
/velocitymacrosync resetclass  wipe this class's shared set
/velocitymacrosync debug       toggle per-action trace
```

## Notes

- Class sets are stored in the account SavedVariables of the install you're on, so Era and Forever each
  have their own (the spells differ anyway).
- Macros are never written while in combat; the sync waits for combat to end.

Design details: [SPECS/00_VelocityMacroSync.md](SPECS/00_VelocityMacroSync.md). Licence: MIT.