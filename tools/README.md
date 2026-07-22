# QuestTips data pipeline (Classic Era / Vanilla)

`generate_questdata.py` regenerates `Data/Vanilla/QuestData.lua` from a
vanilla (1.12) server-side world database SQL dump. It is a pure standard
library script (no pip packages) so it runs unmodified with the portable
Python "embeddable package" from python.org - no system Python install is
required.

## Data source

- Project: **cmangos/classic-db** - "A content database for mangos-classic,
  and World of Warcraft Client Patch 1.12"
  https://github.com/cmangos/classic-db
- Asset used: `classic-world-db.zip` from the repository's rolling `latest`
  GitHub release
  (https://github.com/cmangos/classic-db/releases/download/latest/classic-world-db.zip),
  downloaded 2026-07-16. That release build was tagged
  "Development Build(2026-07-16)" (i.e. built from `master` as of that date).
  It unpacks to a single `classicmangos.sql` mysqldump (~111 MB) of the
  `classicmangos` world database (patch 1.12 content: quests, items, loot,
  vendors, spells, etc; no realm/characters data).
- For a pinned/reproducible alternative, any tagged release such as
  `v1.12.1` ("Melting Pot v2", 2023-10-09) can be built from the repository
  source (`Full_DB/` + `Updates/` SQL scripts, see the repo's
  `InstallFullDB.sh`) if the rolling `latest` build ever changes in a way
  that breaks this pipeline.

### License

cmangos/classic-db is licensed under the **GNU General Public License v3.0**
(GPL-3.0), see `LICENSE.md` in that repository
(https://github.com/cmangos/classic-db/blob/master/LICENSE.md). Any
redistribution of the raw data (as opposed to the small, transformed,
factual subset baked into `QuestData.lua` - a list of quest/item ids and
letters) should take this into account before the addon is published;
consult the GPL-3.0 terms for what "derivative work" implies for a
generated data file derived from database content.

## Regeneration steps

1. Download the portable Python (used to develop/run this script):
   `https://www.python.org/ftp/python/3.12.7/python-3.12.7-embed-amd64.zip`,
   unzip anywhere (PowerShell `Expand-Archive`).
2. Download `classic-world-db.zip` from the URL above and unzip it; you get
   `classicmangos.sql`.
3. Run:
   ```
   python generate_questdata.py <path-to-classicmangos.sql>
   ```
   With no second argument, it writes into
   `Data/Vanilla/QuestData.lua` (relative to the script's own location),
   replacing only the region between the `-- DATA_START` and `-- DATA_END`
   marker lines. Pass a second argument to write elsewhere instead.
4. The script prints row counts, exclusion-reason tallies, and a source-tag
   histogram, and validates every generated line against a strict grammar
   regex before writing (aborts on any mismatch or brace/paren imbalance).

## What gets extracted

For every `quest_template` row with at least one non-zero `ReqItemId1-4`
(quest turn-in items) or `ReqSourceId1-4` (items needed to *produce* a
turn-in item, e.g. crafting reagents that are auto-consumed to create the
quest item) - the two lists are merged, de-duplicating any item id that
appears in both (the `ReqItem` count wins on collision).

**Obtainability filter** - the quest itself is only kept if it is reachable
without foreknowledge, i.e. it appears in `creature_questrelation` or
`gameobject_questrelation` (some NPC/object actually offers it), or some
`item_template.startquest` points at it (a quest-starting item exists).

**Item handling.** Only one rule fully *excludes* an item from a quest's
`add()` line (dropping it from the objective list, and dropping the whole
quest if every one of its items gets excluded that way, unless the quest
is also a `qstart()` target - see below):

- The item is sold by **any** vendor row (`npc_vendor` or
  `npc_vendor_template`, since this dump keeps all vendor stock rows in the
  `_template` table with `npc_vendor` itself empty) with `maxcount == 0`
  (unlimited stock) - if you can always just buy one, there is no
  keep-or-sell decision to surface. (Unknown item ids missing from
  `item_template` are also excluded defensively.)

Everything else stays in the quest's `items` table and is instead flagged
`Q` (quest-bound/conditional) in its `src()` line when:

- `item_template.bonding == 4` (`BIND_WHEN_PICKED_UP` semantics used for
  quest-bound items in this schema) - the item cannot be pre-collected or
  traded, **or**
- it has **no non-conditional source anywhere**: it does not appear with a
  positive `ChanceOrQuestChance` in any loot table
  (`creature_loot_template`, `gameobject_loot_template`,
  `item_loot_template`, `pickpocketing_loot_template`,
  `skinning_loot_template`, `disenchant_loot_template`,
  `fishing_loot_template` - resolving one level of
  `reference_loot_template` indirection, treating a resolved path as
  "positive" only if every chance value along the reference chain is
  non-negative), is not created by a spell (`spell_template` with
  `Effect{1,2,3} == 24` i.e. `SPELL_EFFECT_CREATE_ITEM`), and is not sold
  by any vendor with limited stock either. This single condition captures
  both "drops only while on the quest" (all loot entries negative-chance)
  and "genuinely unobtainable in this DB" (no loot/vendor/craft entry at
  all).

The `Q` tag lets the addon answer a second question besides "keep or
sell": "is this leftover quest item/lore item safe to delete once the
quest is done" (checked via quest completion state at runtime, using the
`qstart()` table below to know which quest a held item belongs to).

**Quest-starter items (`qstart`).** Every `item_template` row with
`startquest != 0` pointing at an obtainable quest produces a
`qstart(itemId, questId)` line, in a third block after `src()`. Any quest
that is a `qstart()` target always gets an `add()` line even if it has no
surviving objective items (emitted as `add(questId, {}, ...)` with an
empty items table, so faction/repeatable/classes/races/skill are still
available to the addon for that quest).

**Quest-provided items (`qprov`).** `quest_template.SrcItemId` is the item
the questgiver hands over on accept. When that item is never *required* by
any quest (not in any quest's merged Req list), does not start a quest
(`startquest == 0`), is not sold in unlimited stock, and is not equippable
gear (`InventoryType == 0` - gear is a keepsake decision, not junk), a
`qprov(itemId, questId)` line is emitted: pure informational baggage
(manuals, notes, letters) the addon can flag deletable once every providing
quest is completed. Provider quests always get an `add()` line (same
mechanism as qstart targets).

**Quest metadata** extracted alongside the item list:

- `RequiredRaces`: exactly 77 (Human|Dwarf|NightElf|Gnome) -> `"A"`; exactly
  178 (Orc|Undead|Tauren|Troll) -> `"H"`; 0 or 255 (both factions) -> no
  flag; any other non-zero mask -> stored raw as `races` in the extra
  table (a partial, non-faction-aligned race restriction).
- `RequiredClasses`: non-zero -> stored raw as `classes`.
- `SpecialFlags` bit 0 (value 1, `QUEST_SPECIAL_FLAGS_REPEATABLE`) -> `"R"`.
- `RequiredSkill`: non-zero -> stored as `skill` (a skill-line id, e.g.
  profession requirement).
- `QuestLevel`: positive -> stored as `lvl` (`-1` = scales with player ->
  omitted).
- `ZoneOrSort`: positive -> stored as `zone` (an AreaTable id the addon
  resolves to a localized zone name via `C_Map.GetAreaInfo`; negative
  values are quest-sort categories like class/profession -> omitted).
- `Title`: emitted only as a trailing `-- Comment`, ASCII-folded
  (`unicodedata` NFKD + ascii-encode-ignore) and stripped of newlines.

**Source tags** (`src(itemId, "tags")`, letters always in fixed order
`D G F C V Q`; an item with no other tags gets just `"Q"`):

- `D` - positive-chance entry in creature/item/pickpocketing/skinning/
  disenchant loot templates (direct or via a positive reference chain).
- `G` - positive-chance entry in `gameobject_loot_template` (herbs, ore
  veins, chests, etc).
- `F` - appears at all in `fishing_loot_template` (any chance sign; fishing
  chance signs are effectively always positive in this dump).
- `C` - created by a spell (`SPELL_EFFECT_CREATE_ITEM`).
- `V` - sold by a vendor with `maxcount > 0` (limited stock; a real
  keep-or-sell/limited-supply signal).
- `Q` - quest-bound/conditional: not obtainable or tradeable without the
  quest (see the bonding/no-source rule above). Can coexist with other
  tags if the data has both a positive source *and* `bonding == 4` (rare,
  but reported literally rather than papered over).

## Output format

```
add(<questId>, { [<itemId>]=<count>, ... }[, "<flags>"[, { classes=<n>, races=<n>, skill=<n>, lvl=<n>, zone=<n> }]]) -- <Quest Title>

src(<itemId>, "<tags>") -- <Item Name>

qstart(<itemId>, <questId>) -- <Item Name> -> <Quest Title>
```

`add()` lines sorted by quest id, items within `{}` sorted by item id (the
`{}` may be empty - see qstart above); `src()` lines sorted by item id;
`qstart()` lines sorted by item id. `flags` is a subset of `"AHR"` in that
order; the argument is omitted entirely when empty unless the following
`extra` table argument is present (in which case `nil` is passed). The
`extra` table only includes the keys that are actually set, and the whole
argument is omitted when none are set. Every `questId` referenced by a
`qstart()` line is guaranteed (validated) to have a matching `add()` line.

## Known caveats

- This is a **1.12** content database. Where Classic Era realms have since
  received later balance/content patches (1.13-1.15 client updates,
  "Anniversary"/SoM-style changes), a small number of item sources, vendor
  stock, or quest availability may have drifted from 1.12 and not be
  reflected here. Spot-checks against Wowhead Classic during development
  did not surface such a case, but this is a residual risk inherent to
  using a 1.12 DB for a modern Classic Era client.
- `npc_vendor` is empty in this dump; all vendor stock lives in
  `npc_vendor_template` (rows are looked up via `creature_template.
  VendorTemplateId`, not by creature entry directly). The script reads
  both tables and unions their `(item, maxcount)` observations, so this
  does not affect correctness, only where the rows physically live.
- Reference-loot indirection is resolved up to 5 levels deep; deeper
  nesting (not observed in this dump) would silently stop resolving
  further and could under-count sources for a small number of items.
- Quests that require an item in `ReqSourceId` alone (a crafting component
  consumed to produce the actual turn-in item, rather than the turn-in
  item itself) are listed using the *component's* item id/count, per the
  task spec - i.e. the addon will point at "you'll need N of the raw
  reagent", not the crafted intermediate item.
