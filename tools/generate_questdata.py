#!/usr/bin/env python3
"""Generate Data/Vanilla/QuestData.lua from a cmangos/classic-db world SQL dump.

Usage:
    python generate_questdata.py <path-to-classicmangos.sql> [output_lua_path]

Standard-library only (no pip packages). Tested with the embeddable
CPython 3.12 Windows build (no system Python install required).

See tools/README.md for the data source, license, and a full description
of the filtering rules implemented here.
"""

import sys
import os
import re
import unicodedata
from collections import defaultdict

# ---------------------------------------------------------------------------
# Low level SQL dump parsing: locate CREATE TABLE column lists and stream the
# row tuples out of (possibly huge, single-line) INSERT INTO ... VALUES ...;
# statements without needing a real SQL engine.
# ---------------------------------------------------------------------------

ESCAPES = {
    '0': '\0', 'n': '\n', 'r': '\r', 't': '\t', 'b': '\b',
    'Z': '\x1a', "'": "'", '"': '"', '\\': '\\', '%': '%', '_': '_',
}


def get_columns(text, table):
    """Return the ordered column-name list for `table`'s CREATE TABLE block."""
    m = re.search(r"CREATE TABLE `%s` \((.*?)\n\) ENGINE" % re.escape(table),
                  text, re.DOTALL)
    if not m:
        raise RuntimeError("CREATE TABLE for %r not found" % table)
    body = m.group(1)
    cols = []
    for line in body.split("\n"):
        line = line.strip().rstrip(",")
        if not line.startswith("`"):
            continue  # PRIMARY KEY / KEY / CONSTRAINT / UNIQUE KEY lines
        name = line[1:line.index("`", 1)]
        cols.append(name)
    return cols


def parse_row(text, pos):
    """Parse one `(...)` tuple starting at text[pos] == '('. Returns (fields, newpos)."""
    n = len(text)
    assert text[pos] == '('
    pos += 1
    fields = []
    while True:
        while text[pos] in ' \t\r\n':
            pos += 1
        c = text[pos]
        if c == "'":
            pos += 1
            buf = []
            while True:
                c2 = text[pos]
                if c2 == '\\':
                    nxt = text[pos + 1]
                    buf.append(ESCAPES.get(nxt, nxt))
                    pos += 2
                    continue
                if c2 == "'":
                    if pos + 1 < n and text[pos + 1] == "'":
                        buf.append("'")
                        pos += 2
                        continue
                    pos += 1
                    break
                buf.append(c2)
                pos += 1
            fields.append(''.join(buf))
        else:
            start = pos
            while text[pos] not in ',)':
                pos += 1
            tok = text[start:pos].strip()
            if tok == 'NULL':
                fields.append(None)
            elif tok in ('', ):
                fields.append(None)
            elif re.match(r'^-?\d+$', tok):
                fields.append(int(tok))
            else:
                try:
                    fields.append(float(tok))
                except ValueError:
                    fields.append(tok)
        while text[pos] in ' \t\r\n':
            pos += 1
        if text[pos] == ',':
            pos += 1
            continue
        elif text[pos] == ')':
            pos += 1
            break
    return fields, pos


def get_rows(text, table):
    """Yield every row tuple (list of python values) for `table`, across all
    INSERT INTO `table` VALUES ...; statements found in the dump."""
    rows = []
    needle = "INSERT INTO `%s` VALUES" % table
    n = len(text)
    start = 0
    while True:
        i = text.find(needle, start)
        if i == -1:
            break
        pos = i + len(needle)
        while text[pos] in ' \t\r\n':
            pos += 1
        while True:
            if text[pos] == ';':
                pos += 1
                break
            if text[pos] == ',':
                pos += 1
                continue
            if text[pos] == '(':
                fields, pos = parse_row(text, pos)
                rows.append(fields)
                continue
            break
        start = pos
    return rows


def load_table(text, table):
    cols = get_columns(text, table)
    idx = {name: i for i, name in enumerate(cols)}
    rows = get_rows(text, table)
    return idx, rows


def ascii_name(s):
    if s is None:
        return ""
    s = s.replace("\r", " ").replace("\n", " ")
    norm = unicodedata.normalize('NFKD', s)
    out = norm.encode('ascii', 'ignore').decode('ascii')
    out = re.sub(r'\s+', ' ', out).strip()
    return out


# ---------------------------------------------------------------------------
# Loot template reference resolution
# ---------------------------------------------------------------------------

def build_ref_map(idx, rows):
    i_item = idx['item']
    i_chance = idx['ChanceOrQuestChance']
    i_mcor = idx['mincountOrRef']
    i_entry = idx['entry']
    ref_map = defaultdict(list)
    for r in rows:
        ref_map[r[i_entry]].append((r[i_item], r[i_chance], r[i_mcor]))
    return ref_map


def expand_row(item, chance, mincount_or_ref, path_positive, ref_map, depth=0):
    """Resolve one loot-template row (possibly a reference row) down to leaf
    (item_id, positive) pairs. `positive` is False as soon as any link in the
    chain has a negative ChanceOrQuestChance (quest-only drop)."""
    positive_here = path_positive and (chance is not None and chance >= 0)
    if mincount_or_ref is not None and mincount_or_ref < 0 and depth < 5:
        ref_id = -mincount_or_ref
        out = []
        for (ritem, rchance, rmcor) in ref_map.get(ref_id, ()):
            out.extend(expand_row(ritem, rchance, rmcor, positive_here, ref_map, depth + 1))
        return out
    else:
        return [(item, positive_here)]


def scan_loot_table(idx, rows, ref_map, positive_set, seen_set):
    i_item = idx['item']
    i_chance = idx['ChanceOrQuestChance']
    i_mcor = idx['mincountOrRef']
    for r in rows:
        for leaf_item, positive in expand_row(r[i_item], r[i_chance], r[i_mcor], True, ref_map):
            seen_set.add(leaf_item)
            if positive:
                positive_set.add(leaf_item)


# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------

ALLIANCE_RACES = 1 + 4 + 8 + 64        # Human, Dwarf, NightElf, Gnome
HORDE_RACES = 2 + 16 + 32 + 128        # Orc, Undead, Tauren, Troll
BOTH_RACES = ALLIANCE_RACES | HORDE_RACES


def main():
    if len(sys.argv) < 2:
        print("usage: generate_questdata.py <dump.sql> [output.lua]", file=sys.stderr)
        sys.exit(1)
    dump_path = sys.argv[1]
    out_path = sys.argv[2] if len(sys.argv) > 2 else None
    if out_path is None:
        here = os.path.dirname(os.path.abspath(__file__))
        out_path = os.path.normpath(os.path.join(here, "..", "Data", "Vanilla", "QuestData.lua"))

    print("Reading dump: %s" % dump_path)
    with open(dump_path, "r", encoding="utf-8", errors="replace") as f:
        text = f.read()
    print("Dump size: %d bytes" % len(text))

    stats = {}

    # ---- item_template -----------------------------------------------
    print("Parsing item_template ...")
    it_idx, it_rows = load_table(text, "item_template")
    items = {}
    for r in it_rows:
        entry = r[it_idx['entry']]
        items[entry] = {
            'name': r[it_idx['name']],
            'bonding': r[it_idx['bonding']],
            'startquest': r[it_idx['startquest']],
            'invtype': r[it_idx['InventoryType']],
        }
    print("  item_template rows: %d" % len(items))

    # ---- quest_template -------------------------------------------------
    print("Parsing quest_template ...")
    q_idx, q_rows = load_table(text, "quest_template")
    quests = {}
    for r in q_rows:
        entry = r[q_idx['entry']]
        quests[entry] = r
    print("  quest_template rows: %d" % len(quests))

    # ---- obtainability: creature/gameobject questrelation + item startquest
    print("Parsing creature_questrelation / gameobject_questrelation ...")
    cq_idx, cq_rows = load_table(text, "creature_questrelation")
    gq_idx, gq_rows = load_table(text, "gameobject_questrelation")
    obtainable_quests = set()
    for r in cq_rows:
        obtainable_quests.add(r[cq_idx['quest']])
    for r in gq_rows:
        obtainable_quests.add(r[gq_idx['quest']])
    item_start_count = 0
    for entry, it in items.items():
        sq = it['startquest']
        if sq:
            obtainable_quests.add(sq)
            item_start_count += 1
    print("  obtainable via creature: %d, gameobject: %d, item startquest: %d, union: %d" % (
        len(set(r[cq_idx['quest']] for r in cq_rows)),
        len(set(r[gq_idx['quest']] for r in gq_rows)),
        item_start_count, len(obtainable_quests)))

    # ---- vendors ---------------------------------------------------------
    print("Parsing npc_vendor / npc_vendor_template ...")
    unlimited_vendor_items = set()
    limited_vendor_items = set()
    for table in ("npc_vendor", "npc_vendor_template"):
        v_idx, v_rows = load_table(text, table)
        for r in v_rows:
            item = r[v_idx['item']]
            maxcount = r[v_idx['maxcount']]
            if maxcount == 0:
                unlimited_vendor_items.add(item)
            else:
                limited_vendor_items.add(item)
    print("  unlimited-stock items: %d, limited-stock items: %d" % (
        len(unlimited_vendor_items), len(limited_vendor_items)))

    # ---- spell_template: SPELL_EFFECT_CREATE_ITEM (24) -------------------
    print("Parsing spell_template (create-item effects) ...")
    sp_idx, sp_rows = load_table(text, "spell_template")
    craft_items = set()
    eff_cols = [sp_idx['Effect1'], sp_idx['Effect2'], sp_idx['Effect3']]
    itype_cols = [sp_idx['EffectItemType1'], sp_idx['EffectItemType2'], sp_idx['EffectItemType3']]
    for r in sp_rows:
        for ec, ic in zip(eff_cols, itype_cols):
            if r[ec] == 24 and r[ic]:
                craft_items.add(r[ic])
    print("  craftable (create-item) items: %d" % len(craft_items))

    # ---- loot templates + reference resolution ----------------------------
    print("Parsing reference_loot_template ...")
    rl_idx, rl_rows = load_table(text, "reference_loot_template")
    ref_map = build_ref_map(rl_idx, rl_rows)

    d_tables = ["creature_loot_template", "item_loot_template",
                "pickpocketing_loot_template", "skinning_loot_template",
                "disenchant_loot_template"]
    g_tables = ["gameobject_loot_template"]
    f_tables = ["fishing_loot_template"]

    d_positive, d_seen = set(), set()
    g_positive, g_seen = set(), set()
    f_positive, f_seen = set(), set()

    for t in d_tables:
        print("Parsing %s ..." % t)
        idx, rows = load_table(text, t)
        scan_loot_table(idx, rows, ref_map, d_positive, d_seen)
    for t in g_tables:
        print("Parsing %s ..." % t)
        idx, rows = load_table(text, t)
        scan_loot_table(idx, rows, ref_map, g_positive, g_seen)
    for t in f_tables:
        print("Parsing %s ..." % t)
        idx, rows = load_table(text, t)
        scan_loot_table(idx, rows, ref_map, f_positive, f_seen)

    has_positive_loot_any = d_positive | g_positive | f_positive

    # ---- per-item exclusion / tag decision --------------------------------
    # Only the unlimited-vendor rule fully excludes an item from add() lines
    # now (no keep-or-sell decision exists at all). Quest-bound items
    # (bonding==4) and items with no non-conditional source are kept in
    # add() but flagged "Q" (quest-bound/conditional) in src().
    def item_tags(item_id):
        """Return (excluded: bool, tags: str) for item_id.
        excluded=True means: do not list this item as a quest objective at
        all (still fully tradeable-unlimited, no tip needed)."""
        info = items.get(item_id)
        if info is None:
            return True, ""  # unknown item id -> cannot verify, exclude
        if item_id in unlimited_vendor_items:
            return True, ""
        tags = []
        if item_id in d_positive:
            tags.append('D')
        if item_id in g_positive:
            tags.append('G')
        if item_id in f_seen:
            tags.append('F')
        if item_id in craft_items:
            tags.append('C')
        if item_id in limited_vendor_items:
            tags.append('V')
        has_source = (item_id in has_positive_loot_any or
                      item_id in craft_items or
                      item_id in limited_vendor_items)
        if info['bonding'] == 4 or not has_source:
            tags.append('Q')
        return False, ''.join(tags)

    # ---- build quest candidates --------------------------------------------
    # Every obtainable quest gets a candidate entry (kept items may be empty).
    # Whether it actually gets an add() line is decided afterwards, once we
    # know which quests are targets of a qstart() item (those always need an
    # add() line, even with an empty items table, so faction/repeatable/etc
    # is available to the "can I delete this quest item" check).
    print("Building quest entries ...")
    candidates = {}  # questId -> (kept_items_dict, flags, extra, title)
    src_items = {}   # questId -> SrcItemId (item the questgiver provides)
    used_item_ids = set()

    excl_unlimited_vendor = 0
    excl_unknown_item = 0
    q_bonding = 0
    q_no_source = 0

    for qid in sorted(obtainable_quests):
        r = quests.get(qid)
        if r is None:
            continue

        req = {}  # itemId -> count, ReqItem wins over ReqSource on collision
        req_source_only = {}
        for i in range(1, 5):
            iid = r[q_idx['ReqItemId%d' % i]]
            cnt = r[q_idx['ReqItemCount%d' % i]]
            if iid:
                req[iid] = cnt if cnt else 1
        for i in range(1, 5):
            iid = r[q_idx['ReqSourceId%d' % i]]
            cnt = r[q_idx['ReqSourceCount%d' % i]]
            if iid and iid not in req:
                req_source_only[iid] = cnt if cnt else 1
        req.update(req_source_only)

        kept = {}
        for iid, cnt in req.items():
            if iid not in items:
                excl_unknown_item += 1
                continue
            excluded, tags = item_tags(iid)
            if excluded:
                excl_unlimited_vendor += 1
                continue
            if 'Q' in tags:
                info = items.get(iid)
                if info is not None and info['bonding'] == 4:
                    q_bonding += 1
                else:
                    q_no_source += 1
            kept[iid] = cnt

        races = r[q_idx['RequiredRaces']]
        classes = r[q_idx['RequiredClasses']]
        skill = r[q_idx['RequiredSkill']]
        special = r[q_idx['SpecialFlags']]
        title = ascii_name(r[q_idx['Title']])
        qlevel = r[q_idx['QuestLevel']]
        zone = r[q_idx['ZoneOrSort']]  # >0: AreaTable id; <0: quest sort

        faction = ""
        raw_races = None
        if races == 0 or races == BOTH_RACES:
            pass
        elif races == ALLIANCE_RACES:
            faction = "A"
        elif races == HORDE_RACES:
            faction = "H"
        else:
            raw_races = races

        repeatable = bool(special is not None and (special & 1))

        flags = faction + ("R" if repeatable else "")

        extra = {}
        if classes:
            extra['classes'] = classes
        if raw_races is not None:
            extra['races'] = raw_races
        if skill:
            extra['skill'] = skill
        # QuestLevel -1 means "scales with player" (a handful of quests);
        # no level shown for those. ZoneOrSort <= 0 is a sort category
        # (class/profession quests), not a zone - omitted likewise.
        if qlevel is not None and qlevel > 0:
            extra['lvl'] = qlevel
        if zone is not None and zone > 0:
            extra['zone'] = zone

        candidates[qid] = (kept, flags, extra, title)
        src_items[qid] = r[q_idx['SrcItemId']]

    # ---- quest-starter items (qstart) --------------------------------------
    # item_template.startquest -> questId, for every item whose quest exists
    # and is a real candidate (it always is: startquest already contributed
    # this qid to obtainable_quests above).
    print("Collecting quest-starter items ...")
    qstart_pairs = []  # (itemId, questId)
    for iid, info in items.items():
        sq = info['startquest']
        if sq and sq in candidates:
            qstart_pairs.append((iid, sq))
    needed_qids = set(qid for _, qid in qstart_pairs)
    print("  quest-starter item/quest pairs: %d" % len(qstart_pairs))

    # ---- quest-provided items (qprov) --------------------------------------
    # quest_template.SrcItemId: the item the questgiver hands over on accept.
    # When that item is never REQUIRED by any quest, starts no quest, and is
    # not equippable gear, it is informational baggage (manuals, notes,
    # letters) the player keeps forever - emit qprov() so the addon can flag
    # it deletable once its providing quest(s) are completed.
    print("Collecting quest-provided items ...")
    required_anywhere = set()
    for _qid, (kept, _f, _e, _t) in candidates.items():
        required_anywhere.update(kept.keys())
    qprov_pairs = []
    for qid in sorted(candidates.keys()):
        si = src_items.get(qid)
        if not si:
            continue
        info = items.get(si)
        if info is None:
            continue
        if si in required_anywhere:
            continue  # a real objective item somewhere - normal lines apply
        if info['startquest']:
            continue  # quest-starting items are qstart() territory
        if si in unlimited_vendor_items:
            continue
        if info['invtype']:
            continue  # equippable gear is a keepsake decision, not junk
        qprov_pairs.append((si, qid))
    needed_qids.update(qid for _, qid in qprov_pairs)
    print("  quest-provided item/quest pairs: %d" % len(qprov_pairs))

    # ---- finalize add() entries --------------------------------------------
    # A quest gets an add() line if it has >=1 surviving item, OR it is the
    # target of a qstart() item (in which case it is emitted with an empty
    # items table so faction/repeatable/etc is still available).
    add_entries = {}
    dropped_quest_empty = 0
    for qid, (kept, flags, extra, title) in candidates.items():
        if kept or qid in needed_qids:
            add_entries[qid] = (kept, flags, extra, title)
            used_item_ids.update(kept.keys())
        else:
            dropped_quest_empty += 1

    print("  quests kept: %d (of which with no items, kept only for qstart: %d)" % (
        len(add_entries), sum(1 for qid in add_entries if not add_entries[qid][0])))
    print("  quests dropped (no surviving items and not a qstart target): %d" % dropped_quest_empty)
    print("  item exclusions -> unlimited vendor (fully excluded): %d, unknown item id: %d" % (
        excl_unlimited_vendor, excl_unknown_item))
    print("  item Q-tag reasons -> bonding=4: %d, no non-conditional source: %d" % (
        q_bonding, q_no_source))

    # ---- emit Lua ----------------------------------------------------------
    print("Emitting Lua ...")
    lines = []
    for qid in sorted(add_entries.keys()):
        kept, flags, extra, title = add_entries[qid]
        item_parts = ", ".join("[%d]=%d" % (iid, kept[iid]) for iid in sorted(kept.keys()))
        call = "add(%d, {%s}" % (qid, item_parts)
        if flags or extra:
            if flags:
                call += ', "%s"' % flags
            else:
                call += ", nil"
            if extra:
                extra_parts = []
                for key in ("classes", "races", "skill", "lvl", "zone"):
                    if key in extra:
                        extra_parts.append("%s=%d" % (key, extra[key]))
                call += ", {%s}" % ", ".join(extra_parts)
        call += ")"
        comment = " -- %s" % title if title else ""
        lines.append(call + comment)

    lines.append("")

    src_lines = []
    for iid in sorted(used_item_ids):
        excluded, tags = item_tags(iid)
        name = ascii_name(items[iid]['name'])
        src_lines.append('src(%d, "%s")%s' % (iid, tags, (" -- %s" % name) if name else ""))
    lines.extend(src_lines)

    lines.append("")

    qstart_lines = []
    for iid, qid in sorted(qstart_pairs):
        item_name = ascii_name(items[iid]['name'])
        quest_title = candidates[qid][3]
        comment = " -- %s -> %s" % (item_name, quest_title) if (item_name or quest_title) else ""
        qstart_lines.append('qstart(%d, %d)%s' % (iid, qid, comment))
    lines.extend(qstart_lines)

    lines.append("")

    qprov_lines = []
    for iid, qid in sorted(qprov_pairs):
        item_name = ascii_name(items[iid]['name'])
        quest_title = candidates[qid][3]
        comment = " -- %s <- %s" % (item_name, quest_title) if (item_name or quest_title) else ""
        qprov_lines.append('qprov(%d, %d)%s' % (iid, qid, comment))
    lines.extend(qprov_lines)

    # ---- validation ---------------------------------------------------------
    print("Validating generated lines ...")
    add_re = re.compile(
        r'^add\(\d+, \{(?:\[\d+\]=\d+(?:, \[\d+\]=\d+)*)?\}'
        r'(?:, (?:nil|"[AH]?R?")(?:, \{(?:(?:classes|races|skill|lvl|zone)=\d+'
        r'(?:, (?:classes|races|skill|lvl|zone)=\d+)*)?\})?)?'
        r'\)( -- .*)?$'
    )
    src_re = re.compile(r'^src\(\d+, "[DGFCVQ]*"\)( -- .*)?$')
    qstart_re = re.compile(r'^qstart\(\d+, \d+\)( -- .*)?$')
    qprov_re = re.compile(r'^qprov\(\d+, \d+\)( -- .*)?$')
    bad = 0
    for ln in lines:
        if ln == "":
            continue
        if ln.startswith("add("):
            if not add_re.match(ln):
                print("INVALID add line: %s" % ln[:200])
                bad += 1
        elif ln.startswith("src("):
            if not src_re.match(ln):
                print("INVALID src line: %s" % ln[:200])
                bad += 1
        elif ln.startswith("qstart("):
            if not qstart_re.match(ln):
                print("INVALID qstart line: %s" % ln[:200])
                bad += 1
        elif ln.startswith("qprov("):
            if not qprov_re.match(ln):
                print("INVALID qprov line: %s" % ln[:200])
                bad += 1
        else:
            print("UNEXPECTED line: %s" % ln[:200])
            bad += 1
    # Every qstart()/qprov()-referenced questId must have an add() line.
    for iid, qid in qstart_pairs:
        if qid not in add_entries:
            print("INVALID qstart reference: item %d -> quest %d has no add() line" % (iid, qid))
            bad += 1
    for iid, qid in qprov_pairs:
        if qid not in add_entries:
            print("INVALID qprov reference: item %d -> quest %d has no add() line" % (iid, qid))
            bad += 1

    joined = "\n".join(lines)
    if joined.count("{") != joined.count("}"):
        print("WARNING: brace mismatch in generated block")
        bad += 1
    if joined.count("(") != joined.count(")"):
        print("WARNING: paren mismatch in generated block")
        bad += 1
    if bad:
        print("VALIDATION FAILED: %d problem(s). Aborting write." % bad)
        sys.exit(2)
    print("Validation OK: %d add() lines, %d src() lines, %d qstart() lines, %d qprov() lines" % (
        len(add_entries), len(src_lines), len(qstart_lines), len(qprov_lines)))

    # ---- source tag distribution -------------------------------------------
    tag_dist = defaultdict(int)
    for iid in used_item_ids:
        _, tags = item_tags(iid)
        tag_dist[tags] += 1
    print("Source tag distribution (over %d distinct items used):" % len(used_item_ids))
    for tags, count in sorted(tag_dist.items(), key=lambda kv: -kv[1]):
        print("  %-6r %d" % (tags, count))

    # ---- write into QuestData.lua between markers -------------------------
    print("Writing into: %s" % out_path)
    with open(out_path, "r", encoding="utf-8") as f:
        orig = f.read()
    start_marker = "-- DATA_START (generated by tools/; do not hand-edit between markers)"
    end_marker = "-- DATA_END"
    si = orig.index(start_marker)
    ei = orig.index(end_marker, si)
    new_block = orig[:si + len(start_marker)] + "\n" + joined + "\n" + orig[ei:]
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(new_block)

    print("Done. Quests: %d, distinct items: %d" % (len(add_entries), len(used_item_ids)))


if __name__ == "__main__":
    main()
