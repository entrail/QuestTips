# QuestTips

**Keep it, hand it in, sell it — or delete it? Every quest item tooltip
gives the answer.**

QuestTips is a lightweight tooltip addon for WoW Classic Era / Hardcore.
Every item that some quest needs — but that you can loot, gather, fish or
craft **without** having the quest — gets one line per quest, colored by
**your character's** state for that quest:

- <span style="color:#4ec94e">**Green**</span> — <span style="color:#4ec94e">*"Quest: Brotherhood of Thieves (Elwynn Forest, 15) — 7/12"*</span>.
  The quest is in your log right now, with your have/need count straight
  from your bags.
- <span style="color:#ffd100">**Yellow**</span> — <span style="color:#ffd100">*"Quest: Keeper of the Flame (Westfall, 16)"*</span>. You haven't
  done this quest yet — zone and level tell you right away whether it's
  for now, for later, or for never. Maybe hold on to the item instead of
  vendoring it at 4 a.m.
- <span style="color:#4da6ff">**Blue**</span> — <span style="color:#4da6ff">*(repeatable)*</span>. A repeatable turn-in (reputation and event
  quests): permanent demand, prime auction house material. Zone and
  level are shown here too — you know where to bring them.
- <span style="color:#ff5959">**Red**</span> — <span style="color:#ff5959">*(done)*</span>. You already completed the quest. You don't need
  the item anymore — but somebody on the auction house might.

Quests you can never do are never shown: the other faction's quests,
other classes' quests, quests your race can't take. Profession-gated
quests **are** shown — with a gray *"(missing profession)"* marker if you
lack the profession, so the line explains itself.

Works everywhere an item tooltip shows: bags, loot, vendors, the auction
house, chat links.

## Can this be deleted?

Bag space is the real endgame, and Blizzard never tells you when a quest
item has served its purpose. QuestTips does:

- **Quest-bound items** (only obtainable with the quest) get a clear red
  *"Quest completed — can be deleted"* line once every quest that needs
  them is done — or normal quest lines showing what still does.
- **Leftover quest-starter items** (maps, notes, insignias): Blizzard's
  own *"This Item Begins a Quest"* line keeps suggesting they're useful
  forever. Once the quest is completed, QuestTips says so.
- **Quest-provided baggage** (manuals, letters a questgiver handed you
  that no quest ever asks back): flagged deletable once the providing
  quest is done.

## Cleans up after you

Turn in (or abandon) a quest and a connected quest item is still sitting
in your bags with nothing left to need it? QuestTips announces it in
chat and offers a small window with the item and a **Delete all / Keep**
choice — one click and the leftovers are gone. Only items connected to
the quest you just finished are checked; tradeable items are never
announced (those are save-or-sell, your call).

## Configuration

Settings -> Options -> AddOns -> QuestTips, or simply `/questtips`
(also `/qtips`):

- Each of the four line colors (<span style="color:#4ec94e">green</span> / <span style="color:#ffd100">yellow</span> / <span style="color:#4da6ff">blue</span> / <span style="color:#ff5959">red</span>) can be
  toggled independently.
- **Show quest names** off gives one compact *"Needed for N quests"*
  line instead of the per-quest list.
- **Quests listed per item** (1-10) caps the lines; the rest becomes
  *"+N more quests"*.
- **Show only while holding** a modifier key (Shift/Ctrl/Alt) if you
  prefer clean tooltips by default.
- **Include gathered/fished/crafted items** — items that never drop from
  enemies can be excluded.
- The deletable check and the after-turn-in announcements can each be
  switched off.

## Data & compatibility

- Complete Classic Era catalogue: **2,800+ quests** and their **2,500+
  objective items**, plus 200+ quest-starter items and the quest-provided
  leftovers — generated from the original 1.12 world database, with
  source tags (drop, gathered, fished, crafted, limited-stock vendor,
  quest-bound) per item. Items sold by vendors in unlimited quantity are
  deliberately excluded: no keep-or-sell decision exists for them.
- Runs on **Classic Era 1.15**, including Hardcore and Anniversary
  realms.
- Fully locale-safe by design: all matching is by quest ID and item ID;
  quest titles and item names come from the game client at runtime and
  display localized on every client language.
- All settings are account-wide — the tooltips behave identically on
  every character, while quest states, faction and class are of course
  read live per character.
- Tiny footprint: no libraries, no minimap button, nothing until an item
  tooltip appears.

## Limitations & Roadmap

- The addon's own label texts (*"Quest"*, *"done"*, *"can be
  deleted"*, ...) are currently English on all clients — quest titles
  and item names always display in your language. Translations are
  planned; volunteers very welcome!
- The data comes from a 1.12 database; the modern Classic Era client has
  seen a few later adjustments, so an occasional item source or quest
  may have drifted. Spot-checks haven't surfaced one yet — if you find
  a quest line that's wrong, please report it with the item and quest;
  the data is generated and easy to fix.
- **TBC support** is prepared in the data layout but not built yet.

---

Enjoying QuestTips? You can support development on
[PayPal](https://paypal.me/adrianh91) — never expected, always
appreciated.
