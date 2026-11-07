#!/usr/bin/env python3
"""Phase 10 / M3 (PRD 10J, 10L): generator of the language-neutral Smart Rule
conflict/parity vectors in conflict_vectors.json.

The SAME JSON file is executed by
  * Dart:   test/rules/smart_rule_parity_vectors_m3_test.dart
            (SmartRule.fromJson -> SmartRulePolicy / SmartRuleConflictPolicy /
            SmartRuleDiagnostics; also checks that Dart's nativeTransport()
            equals the "transport" given to Kotlin), and
  * Kotlin: android/app/src/test/kotlin/com/smartapplock/app/
            SmartRuleParityVectorsTest.kt
            (SmartRuleTransport.parse -> SmartRulePolicy, and the real
            ProtectionStateStore configure -> effectiveLevel path).

Expected values come from this script's own reference model of the M1/M2
semantics (written independently of both implementations), and every
hand-written case expectation below is cross-checked against it, so a
mistake in either the hand-written cases or the reference stops generation.

Semantics (M1/M2, locked for M3):
  * local wall clock, minute 0..1439, start inclusive, end exclusive;
  * ISO weekdays Monday = 1 .. Sunday = 7;
  * a window with start > end crosses midnight; the after-midnight part
    belongs to the PREVIOUS day (Monday's previous day is Sunday);
  * explicit all-day; disabled rules never match; exact package match;
  * priority Critical > Sensitive > Standard > Unlocked; only Critical and
    Sensitive raise; effective = stricter(saved, rule level);
  * equal strongest actions tie; the sorted first id is the deciding rule.

Usage:  python3 generate_conflict_vectors.py   (rewrites conflict_vectors.json)
        python3 generate_conflict_vectors.py --check   (exit 1 if stale)
"""
import json
import os
import sys
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "conflict_vectors.json")

BANK = "com.example.bank"
CHAT = "com.example.chat"
NOTES = "com.example.notes"
OTHER = "com.example.other"  # never protected, never targeted

RANK = {"critical": 3, "sensitive": 2, "standard": 1, "unlocked": 0}
LEVEL_RANK = {"standard": 1, "sensitive": 2, "critical": 3}
WEEK = {1: "2026-11-02", 2: "2026-11-03", 3: "2026-11-04", 4: "2026-11-05",
        5: "2026-11-06", 6: "2026-11-07", 7: "2026-11-08"}  # Mon..Sun


def hm(h, m=0):
    return h * 60 + m


def rule(rid, name, action, days, time, targets, enabled=True):
    return {
        "id": rid,
        "name": name,
        "enabled": enabled,
        "targets": sorted(set(targets)),
        "days": sorted(set(days)),
        "time": time,
        "action": action,
    }


def window(start, end):
    return {"type": "window", "start": start, "end": end}


ALL_DAY = {"type": "allDay"}
EVERY = [1, 2, 3, 4, 5, 6, 7]
WEEKDAYS = [1, 2, 3, 4, 5]

# -- reference model -----------------------------------------------------------


def prev_day(d):
    return 7 if d == 1 else d - 1


def matches(r, pkg, day, minute):
    if not r["enabled"] or pkg not in r["targets"]:
        return False
    if not (1 <= day <= 7) or not (0 <= minute < 1440):
        return False
    t = r["time"]
    if t["type"] == "allDay":
        return day in r["days"]
    s, e = t["start"], t["end"]
    if s < e:
        return s <= minute < e and day in r["days"]
    if minute >= s:
        return day in r["days"]
    if minute < e:
        return prev_day(day) in r["days"]
    return False


def resolve(rules, pkg, day, minute):
    m = [r for r in rules if matches(r, pkg, day, minute)]
    if not m:
        return None, [], []
    top = max(RANK[r["action"]] for r in m)
    strongest = sorted(r["id"] for r in m if RANK[r["action"]] == top)
    action = next(a for a, v in RANK.items() if v == top)
    level = action if action in ("critical", "sensitive") else None
    return level, strongest, sorted(r["id"] for r in m)


def effective(baseline, level):
    if baseline is None:
        return None
    if level is not None and LEVEL_RANK[level] > LEVEL_RANK[baseline]:
        return level
    return baseline


def expected(rules, baselines, pkg, day, minute):
    level, strongest, matching = resolve(rules, pkg, day, minute)
    base = baselines.get(pkg)
    eff = effective(base, level)
    decided_by_rule = (base is not None and level is not None
                       and LEVEL_RANK[level] > LEVEL_RANK[base])
    return {
        "ruleLevel": level,
        "effective": eff,
        "deciding": strongest[0] if decided_by_rule else None,
        "tied": strongest[1:] if decided_by_rule else [],
        "strongest": strongest,
        "matching": matching,
    }


def transport(rules):
    out = []
    for r in rules:
        if not r["enabled"] or r["action"] not in ("critical", "sensitive"):
            continue
        all_day = r["time"]["type"] == "allDay"
        out.append({
            "level": r["action"],
            "days": list(r["days"]),
            "allDay": all_day,
            "start": 0 if all_day else r["time"]["start"],
            "end": 0 if all_day else r["time"]["end"],
            "targets": list(r["targets"]),
        })
    return out


def grid_minutes(rules):
    ms = {0, 1439}
    for r in rules:
        t = r["time"]
        if t["type"] == "window":
            for x in (t["start"], t["end"]):
                for dx in (-1, 0, 1):
                    ms.add((x + dx) % 1440)
    return sorted(ms)


def level_char(level):
    return {"critical": "C", "sensitive": "S", None: "-"}[level]


# -- rule sets -----------------------------------------------------------------

SETS = []


def add_set(sid, description, baselines, rules, cases):
    SETS.append({"id": sid, "description": description, "baselines": baselines,
                 "rules": rules, "cases": cases})


def case(name, app, day, minute, second=0, **exp):
    return {"name": name, "app": app, "day": day, "minute": minute,
            "second": second, "expect": exp}


# 1. Two rules on the same app, different levels (conflicts 1, overlap D).
add_set(
    "two_rules_same_app",
    "Work Hours (Sensitive) and Lunch Banking (Critical) overlap on one app.",
    {BANK: "standard", CHAT: "standard"},
    [
        rule("work-hours", "Work Hours", "sensitive", WEEKDAYS, window(hm(9), hm(17)), [BANK, CHAT]),
        rule("lunch-bank", "Lunch Banking", "critical", WEEKDAYS, window(hm(12), hm(14)), [BANK]),
    ],
    [
        case("before both", BANK, 1, hm(8, 59), ruleLevel=None, effective="standard", deciding=None),
        case("work starts (inclusive)", BANK, 1, hm(9), ruleLevel="sensitive", effective="sensitive", deciding="work-hours"),
        case("critical starts inside work", BANK, 1, hm(12), ruleLevel="critical", effective="critical", deciding="lunch-bank"),
        case("critical last second", BANK, 1, hm(13, 59), second=59, ruleLevel="critical", effective="critical", deciding="lunch-bank"),
        case("critical ends (exclusive) -> next strongest", BANK, 1, hm(14), ruleLevel="sensitive", effective="sensitive", deciding="work-hours"),
        case("work ends (exclusive)", BANK, 1, hm(17), ruleLevel=None, effective="standard", deciding=None),
        case("other app only gets its own rule", CHAT, 1, hm(12, 30), ruleLevel="sensitive", effective="sensitive", deciding="work-hours"),
        case("weekend no rule", BANK, 6, hm(12, 30), ruleLevel=None, effective="standard", deciding=None),
        case("untargeted app", OTHER, 1, hm(12, 30), ruleLevel=None, effective=None, deciding=None),
    ],
)

# 2. Three or more rules incl. Standard and the reserved Unlocked (conflicts 2).
add_set(
    "three_rule_priority",
    "Standard all day, Sensitive daytime, Critical mid-morning Mon/Wed/Fri, "
    "and a reserved Unlocked rule: Critical > Sensitive > Standard > Unlocked.",
    {NOTES: "standard", CHAT: "sensitive"},
    [
        rule("a-standard", "Always Standard", "standard", EVERY, ALL_DAY, [NOTES, CHAT]),
        rule("b-sensitive", "Daytime", "sensitive", EVERY, window(hm(8), hm(20)), [NOTES, CHAT]),
        rule("c-critical", "Focus", "critical", [1, 3, 5], window(hm(10), hm(12)), [NOTES, CHAT]),
        rule("d-unlocked", "Reserved", "unlocked", EVERY, ALL_DAY, [NOTES, CHAT]),
    ],
    [
        case("only standard + unlocked match", NOTES, 1, hm(7), ruleLevel=None, effective="standard", deciding=None),
        case("sensitive beats standard/unlocked", NOTES, 1, hm(9), ruleLevel="sensitive", effective="sensitive", deciding="b-sensitive"),
        case("critical beats all three", NOTES, 1, hm(10), ruleLevel="critical", effective="critical", deciding="c-critical"),
        case("critical not on Tuesday", NOTES, 2, hm(10), ruleLevel="sensitive", effective="sensitive", deciding="b-sensitive"),
        case("saved Sensitive covers the Sensitive rule", CHAT, 2, hm(9), ruleLevel="sensitive", effective="sensitive", deciding=None),
        case("Critical rule raises a Sensitive app", CHAT, 5, hm(11, 59), ruleLevel="critical", effective="critical", deciding="c-critical"),
        case("unlocked never lowers saved Sensitive", CHAT, 7, hm(23), ruleLevel=None, effective="sensitive", deciding=None),
    ],
)

# 3. Same-level ties: deciding = first sorted id (conflicts 3, J).
add_set(
    "same_level_ties",
    "Three Critical rules with different overlapping windows; ids sort "
    "a-crit < m-crit < z-crit.",
    {BANK: "standard"},
    [
        rule("z-crit", "Zulu", "critical", EVERY, window(hm(8), hm(13)), [BANK]),
        rule("m-crit", "Mike", "critical", EVERY, window(hm(10), hm(12)), [BANK]),
        rule("a-crit", "Alpha", "critical", EVERY, window(hm(9), hm(11)), [BANK]),
    ],
    [
        case("only zulu", BANK, 3, hm(8, 30), ruleLevel="critical", effective="critical", deciding="z-crit", tied=[]),
        case("alpha + zulu tie", BANK, 3, hm(9, 30), ruleLevel="critical", effective="critical", deciding="a-crit", tied=["z-crit"]),
        case("three-way tie", BANK, 3, hm(10, 30), ruleLevel="critical", effective="critical", deciding="a-crit", tied=["m-crit", "z-crit"]),
        case("alpha ended, mike + zulu", BANK, 3, hm(11), ruleLevel="critical", effective="critical", deciding="m-crit", tied=["z-crit"]),
        case("all ended", BANK, 3, hm(13), ruleLevel=None, effective="standard", deciding=None, tied=[]),
    ],
)

# 4. Cross-midnight overlap and Sunday->Monday rollover (E, F; conflicts 7, 8).
add_set(
    "overnight_rollover",
    "Sunday night Sensitive 22:00-06:00, Sunday all-day Sensitive, Monday "
    "late Critical 23:00-02:00, Monday early Critical 05:00-07:00.",
    {CHAT: "standard"},
    [
        rule("sun-night", "Sunday Night", "sensitive", [7], window(hm(22), hm(6)), [CHAT]),
        rule("sun-all", "Sunday", "sensitive", [7], ALL_DAY, [CHAT]),
        rule("mon-late", "Monday Late", "critical", [1], window(hm(23), hm(2)), [CHAT]),
        rule("mon-early", "Monday Early", "critical", [1], window(hm(5), hm(7)), [CHAT]),
    ],
    [
        case("Sunday 21:59 all-day only", CHAT, 7, hm(21, 59), ruleLevel="sensitive", effective="sensitive", deciding="sun-all", tied=[]),
        case("Sunday 22:00 night + all-day tie", CHAT, 7, hm(22), ruleLevel="sensitive", effective="sensitive", deciding="sun-all", tied=["sun-night"]),
        case("Monday 00:00 owner day Sunday", CHAT, 1, hm(0), ruleLevel="sensitive", effective="sensitive", deciding="sun-night", tied=[]),
        case("Monday 05:00 critical overlaps Sunday night", CHAT, 1, hm(5), ruleLevel="critical", effective="critical", deciding="mon-early"),
        case("Monday 06:00 Sunday night ended (exclusive)", CHAT, 1, hm(6), ruleLevel="critical", effective="critical", deciding="mon-early"),
        case("Monday 07:00 all ended", CHAT, 1, hm(7), ruleLevel=None, effective="standard", deciding=None),
        case("Monday 23:30 late critical", CHAT, 1, hm(23, 30), ruleLevel="critical", effective="critical", deciding="mon-late"),
        case("Tuesday 01:59 owner day Monday", CHAT, 2, hm(1, 59), ruleLevel="critical", effective="critical", deciding="mon-late"),
        case("Tuesday 02:00 ended", CHAT, 2, hm(2), ruleLevel=None, effective="standard", deciding=None),
        case("Saturday 23:00 Sunday night not yet", CHAT, 6, hm(23), ruleLevel=None, effective="standard", deciding=None),
        case("next Monday 00:30 not owned by Monday-late", CHAT, 1, hm(0, 30), ruleLevel="sensitive", effective="sensitive", deciding="sun-night"),
    ],
)

# 5. All-day vs timed overlap, disabled stronger rule, baseline floor (G, I).
add_set(
    "all_day_vs_timed_disabled",
    "Weekend all-day Sensitive, Saturday 13:00-15:00 Critical, a DISABLED "
    "every-day Critical; Bank is saved Critical.",
    {NOTES: "standard", BANK: "critical"},
    [
        rule("weekend", "Weekend", "sensitive", [6, 7], ALL_DAY, [NOTES, BANK]),
        rule("sat-crit", "Saturday Afternoon", "critical", [6], window(hm(13), hm(15)), [NOTES]),
        rule("off-crit", "Always Critical (off)", "critical", EVERY, ALL_DAY, [NOTES, BANK], enabled=False),
    ],
    [
        case("weekday: disabled Critical ignored", NOTES, 3, hm(14), ruleLevel=None, effective="standard", deciding=None),
        case("Saturday morning all-day only", NOTES, 6, hm(12, 59), ruleLevel="sensitive", effective="sensitive", deciding="weekend"),
        case("Saturday timed Critical beats all-day", NOTES, 6, hm(13), ruleLevel="critical", effective="critical", deciding="sat-crit"),
        case("Saturday 15:00 back to all-day", NOTES, 6, hm(15), ruleLevel="sensitive", effective="sensitive", deciding="weekend"),
        case("Saturday 23:59 all-day still", NOTES, 6, hm(23, 59), second=59, ruleLevel="sensitive", effective="sensitive", deciding="weekend"),
        case("saved Critical never lowered", BANK, 7, hm(10), ruleLevel="sensitive", effective="critical", deciding=None),
        case("saved Critical with no rule", BANK, 2, hm(10), ruleLevel=None, effective="critical", deciding=None),
    ],
)

# 6. Expired / nonmatching higher-priority rule (conflicts 6).
add_set(
    "nonmatching_higher_priority",
    "A Critical rule on Tuesday only and a Critical rule for another app "
    "never count; the Sensitive rule decides.",
    {BANK: "standard", CHAT: "standard"},
    [
        rule("tue-crit", "Tuesday", "critical", [2], ALL_DAY, [BANK]),
        rule("chat-crit", "Chat Critical", "critical", EVERY, ALL_DAY, [CHAT]),
        rule("daily-sens", "Daily", "sensitive", EVERY, window(hm(6), hm(22)), [BANK]),
    ],
    [
        case("Monday: Tuesday rule not counted", BANK, 1, hm(12), ruleLevel="sensitive", effective="sensitive", deciding="daily-sens"),
        case("Tuesday: Critical counts", BANK, 2, hm(12), ruleLevel="critical", effective="critical", deciding="tue-crit"),
        case("Tuesday 23:00 all-day Critical, daily expired", BANK, 2, hm(23), ruleLevel="critical", effective="critical", deciding="tue-crit"),
        case("Wednesday 22:00 daily expired", BANK, 3, hm(22), ruleLevel=None, effective="standard", deciding=None),
        case("different app rule isolated", CHAT, 1, hm(12), ruleLevel="critical", effective="critical", deciding="chat-crit"),
    ],
)

# 7/8. Removing the winner falls back to the next strongest (conflicts 10, M).
WINNER_BEFORE = [
    rule("w-crit", "Winner", "critical", WEEKDAYS, window(hm(9), hm(17)), [BANK]),
    rule("w-sens", "Fallback", "sensitive", WEEKDAYS, window(hm(8), hm(18)), [BANK]),
]
add_set(
    "winner_before_removal",
    "Critical winner overlapping a wider Sensitive rule.",
    {BANK: "standard"},
    WINNER_BEFORE,
    [
        case("winner decides", BANK, 2, hm(10), ruleLevel="critical", effective="critical", deciding="w-crit"),
        case("fallback alone before winner", BANK, 2, hm(8, 30), ruleLevel="sensitive", effective="sensitive", deciding="w-sens"),
    ],
)
add_set(
    "winner_after_removal",
    "The Critical winner deleted: the Sensitive rule remains (never Standard).",
    {BANK: "standard"},
    [WINNER_BEFORE[1]],
    [
        case("falls back to next strongest", BANK, 2, hm(10), ruleLevel="sensitive", effective="sensitive", deciding="w-sens"),
        case("outside fallback window", BANK, 2, hm(18), ruleLevel=None, effective="standard", deciding=None),
    ],
)
add_set(
    "winner_disabled",
    "The Critical winner disabled instead of deleted: same fallback.",
    {BANK: "standard"},
    [dict(WINNER_BEFORE[0], enabled=False), WINNER_BEFORE[1]],
    [
        case("disabled winner falls back", BANK, 2, hm(10), ruleLevel="sensitive", effective="sensitive", deciding="w-sens"),
    ],
)

# 9. No rules: saved baseline.
add_set(
    "no_rules",
    "No rules: every app keeps its saved level.",
    {BANK: "critical", CHAT: "sensitive", NOTES: "standard"},
    [],
    [
        case("saved Critical", BANK, 1, hm(12), ruleLevel=None, effective="critical", deciding=None),
        case("saved Sensitive", CHAT, 4, hm(0), ruleLevel=None, effective="sensitive", deciding=None),
        case("saved Standard", NOTES, 7, hm(23, 59), ruleLevel=None, effective="standard", deciding=None),
    ],
)

# 10. Multiple weekdays and same-day overlapping windows (C, D, H).
add_set(
    "multi_day_same_day_overlap",
    "Mon/Wed/Fri 07:00-10:00 Sensitive overlapping Mon/Fri 09:00-09:30 "
    "Critical and a Wed 08:00-12:00 Sensitive.",
    {NOTES: "standard"},
    [
        rule("mwf-morning", "Mornings", "sensitive", [1, 3, 5], window(hm(7), hm(10)), [NOTES]),
        rule("mf-standup", "Standup", "critical", [1, 5], window(hm(9), hm(9, 30)), [NOTES]),
        rule("wed-block", "Wednesday Block", "sensitive", [3], window(hm(8), hm(12)), [NOTES]),
    ],
    [
        case("Friday standup", NOTES, 5, hm(9, 15), ruleLevel="critical", effective="critical", deciding="mf-standup"),
        case("Friday 09:30 standup ended", NOTES, 5, hm(9, 30), ruleLevel="sensitive", effective="sensitive", deciding="mwf-morning"),
        case("Wednesday two Sensitive tie", NOTES, 3, hm(9, 15), ruleLevel="sensitive", effective="sensitive", deciding="mwf-morning", tied=["wed-block"]),
        case("Wednesday 10:00 one left", NOTES, 3, hm(10), ruleLevel="sensitive", effective="sensitive", deciding="wed-block", tied=[]),
        case("Thursday nothing", NOTES, 4, hm(9, 15), ruleLevel=None, effective="standard", deciding=None),
    ],
)

# -- DST / time-zone instants (Kotlin converts epoch -> local; both levels) --

DST_RULES = [
    rule("dst-skip", "Skipped Hour", "critical", [7], window(hm(2), hm(3)), [BANK]),
    rule("dst-repeat", "Repeated Hour", "sensitive", [7], window(hm(1), hm(2)), [BANK]),
    rule("tz-evening", "Evening", "critical", [1], window(hm(20), hm(21)), [BANK]),
]
DST_BASE = {BANK: "standard"}


def instant(name, zone, utc):
    local = utc.astimezone(ZoneInfo(zone))
    day = local.isoweekday()
    minute = local.hour * 60 + local.minute
    level, _, _ = resolve(DST_RULES, BANK, day, minute)
    return {"name": name, "zone": zone,
            "epochMillis": int(utc.timestamp() * 1000),
            "localDay": day, "localMinute": minute,
            "ruleLevel": level, "effective": effective("standard", level)}


INSTANTS = [
    instant("spring forward 01:59 EST", "America/New_York", datetime(2026, 3, 8, 6, 59, tzinfo=timezone.utc)),
    instant("spring forward 03:00 EDT (02:xx skipped)", "America/New_York", datetime(2026, 3, 8, 7, 0, tzinfo=timezone.utc)),
    instant("fall back first 01:30 EDT", "America/New_York", datetime(2026, 11, 1, 5, 30, tzinfo=timezone.utc)),
    instant("fall back repeated 01:30 EST", "America/New_York", datetime(2026, 11, 1, 6, 30, tzinfo=timezone.utc)),
    instant("fall back 02:00 EST", "America/New_York", datetime(2026, 11, 1, 7, 0, tzinfo=timezone.utc)),
    instant("same instant UTC Monday 20:00", "UTC", datetime(2026, 11, 2, 20, 0, tzinfo=timezone.utc)),
    instant("same instant Karachi Tuesday 01:00", "Asia/Karachi", datetime(2026, 11, 2, 20, 0, tzinfo=timezone.utc)),
    instant("Karachi Monday 20:30", "Asia/Karachi", datetime(2026, 11, 2, 15, 30, tzinfo=timezone.utc)),
    instant("New York Monday 20:59", "America/New_York", datetime(2026, 11, 3, 1, 59, tzinfo=timezone.utc)),
    instant("New York Monday 21:00 (exclusive)", "America/New_York", datetime(2026, 11, 3, 2, 0, tzinfo=timezone.utc)),
]

# -- invalid inputs ------------------------------------------------------------

GOOD_T = {"level": "critical", "days": [1], "allDay": False, "start": 540, "end": 600, "targets": [BANK]}
INVALID_TRANSPORT = [
    {"name": "standard level is never sent", "entry": dict(GOOD_T, level="standard")},
    {"name": "unlocked level is never sent", "entry": dict(GOOD_T, level="unlocked")},
    {"name": "unknown level", "entry": dict(GOOD_T, level="Critical")},
    {"name": "empty days", "entry": dict(GOOD_T, days=[])},
    {"name": "day 8", "entry": dict(GOOD_T, days=[8])},
    {"name": "day 0", "entry": dict(GOOD_T, days=[0])},
    {"name": "zero-length window", "entry": dict(GOOD_T, start=540, end=540)},
    {"name": "start 1440", "entry": dict(GOOD_T, start=1440)},
    {"name": "negative end", "entry": dict(GOOD_T, end=-1)},
    {"name": "fractional minute", "entry": dict(GOOD_T, start=540.5)},
    {"name": "empty targets", "entry": dict(GOOD_T, targets=[])},
    {"name": "invalid package", "entry": dict(GOOD_T, targets=["bank"])},
    {"name": "missing allDay", "entry": {k: v for k, v in GOOD_T.items() if k != "allDay"}},
]
GOOD_R = rule("bad", "Bad", "critical", [1], window(540, 600), [BANK])
INVALID_RULES = [
    {"name": "unknown action", "rule": dict(GOOD_R, action="Critical")},
    {"name": "empty days", "rule": dict(GOOD_R, days=[])},
    {"name": "day 8", "rule": dict(GOOD_R, days=[8])},
    {"name": "zero-length window", "rule": dict(GOOD_R, time=window(540, 540))},
    {"name": "start 1440", "rule": dict(GOOD_R, time=window(1440, 600))},
    {"name": "fractional minute", "rule": dict(GOOD_R, time={"type": "window", "start": 540.5, "end": 600})},
    {"name": "empty targets", "rule": dict(GOOD_R, targets=[])},
    {"name": "invalid package", "rule": dict(GOOD_R, targets=["bank"])},
    {"name": "missing enabled", "rule": {k: v for k, v in GOOD_R.items() if k != "enabled"}},
    {"name": "unsorted days", "rule": dict(GOOD_R, days=[3, 1])},
]
INVALID_QUERIES = [
    {"name": "day 0", "app": BANK, "day": 0, "minute": 560},
    {"name": "day 8", "app": BANK, "day": 8, "minute": 560},
    {"name": "minute -1", "app": BANK, "day": 1, "minute": -1},
    {"name": "minute 1440", "app": BANK, "day": 1, "minute": 1440},
    {"name": "malformed package", "app": "not a package", "day": 1, "minute": 560},
]
INVALID_QUERY_RULES = [rule("q-crit", "Query", "critical", EVERY, ALL_DAY, [BANK])]

# -- relaxation (CR-2 / held boundary) ----------------------------------------
# Dart SmartRulePolicy.relaxedPackages and native SmartRulePolicy.relaxes
# decide whether a change is a reduction (needs CR-2, else native HOLDS the
# stricter union). The oracle here is brute force over every minute of the
# week, independent of the boundary shortcut both implementations use.


def relaxed_packages(before, after):
    out = set()
    pkgs = sorted({p for r in before for p in r["targets"]})
    for pkg in pkgs:
        found = False
        for day in range(1, 8):
            for minute in range(1440):
                was = resolve(before, pkg, day, minute)[0]
                if was is None:
                    continue
                now = resolve(after, pkg, day, minute)[0]
                if now is None or LEVEL_RANK[was] > LEVEL_RANK[now]:
                    found = True
                    break
            if found:
                break
        if found:
            out.add(pkg)
    return sorted(out)


R_CRIT_DAY = rule("x-crit", "Day Critical", "critical", WEEKDAYS, window(hm(8), hm(18)), [BANK])
R_SENS_IN = rule("x-sens-in", "Inner Sensitive", "sensitive", WEEKDAYS, window(hm(9), hm(17)), [BANK])
R_CRIT_IN = rule("x-crit-in", "Inner Critical", "critical", WEEKDAYS, window(hm(9), hm(17)), [BANK])
R_SENS_OUT = rule("x-sens-out", "Outer Sensitive", "sensitive", WEEKDAYS, window(hm(8), hm(18)), [BANK])
R_NIGHT = rule("x-night", "Night", "sensitive", [7], window(hm(22), hm(6)), [BANK])
R_ALL = rule("x-all", "Always Critical", "critical", EVERY, ALL_DAY, [BANK, CHAT])
R_STD = rule("x-std", "Standard", "standard", EVERY, ALL_DAY, [BANK])
R_TWO = rule("x-two", "Two apps", "critical", WEEKDAYS, window(hm(9), hm(12)), [BANK, CHAT])
R_AM = rule("x-am", "Morning", "sensitive", WEEKDAYS, window(hm(8), hm(12)), [BANK])
R_PM = rule("x-pm", "Afternoon", "sensitive", WEEKDAYS, window(hm(12), hm(18)), [BANK])

RELAXATION_PAIRS = [
    ("delete the winner while a wider rule remains", WINNER_BEFORE, [WINNER_BEFORE[1]]),
    ("disable the winner while a wider rule remains", WINNER_BEFORE, [dict(WINNER_BEFORE[0], enabled=False), WINNER_BEFORE[1]]),
    ("delete a rule fully covered by a stricter one", [R_CRIT_DAY, R_SENS_IN], [R_CRIT_DAY]),
    ("delete a Critical rule covered by an identical-window Critical", [R_CRIT_IN, dict(R_CRIT_IN, id="x-crit-in-2")], [R_CRIT_IN]),
    ("delete a wider weaker rule only partly covered", [R_CRIT_IN, R_SENS_OUT], [R_CRIT_IN]),
    ("lower Critical to Sensitive", [R_CRIT_DAY], [dict(R_CRIT_DAY, action="sensitive")]),
    ("raise Sensitive to Critical", [R_SENS_OUT], [dict(R_SENS_OUT, action="critical")]),
    ("narrow a window by one minute", [R_CRIT_DAY], [dict(R_CRIT_DAY, time=window(hm(8), hm(17, 59)))]),
    ("widen a window", [R_CRIT_IN], [dict(R_CRIT_IN, time=window(hm(8), hm(18)))]),
    ("add a rule", [R_SENS_OUT], [R_SENS_OUT, R_CRIT_IN]),
    ("remove a weekday", [R_CRIT_DAY], [dict(R_CRIT_DAY, days=[1, 2, 3, 4])]),
    ("overnight end moved earlier (Monday 05:00-06:00 lost)", [R_NIGHT], [dict(R_NIGHT, time=window(hm(22), hm(5)))]),
    ("overnight start moved later", [R_NIGHT], [dict(R_NIGHT, time=window(hm(23), hm(6)))]),
    ("all-day replaced by 00:00-23:59 (last minute lost)", [dict(R_ALL, targets=[BANK])], [dict(R_ALL, targets=[BANK], time=window(0, 1439))]),
    ("two halves merged into one equal rule", [R_AM, R_PM], [dict(R_AM, id="x-day", time=window(hm(8), hm(18)))]),
    ("reordered list only", [R_SENS_OUT, R_CRIT_IN], [R_CRIT_IN, R_SENS_OUT]),
    ("one app removed from a two-app rule", [R_TWO], [dict(R_TWO, targets=[BANK])]),
    ("an app removed from a rule but covered all week by another", [R_ALL, R_TWO], [R_ALL, dict(R_TWO, targets=[BANK])]),
    ("deleting a Standard rule never relaxes", [R_STD, R_SENS_OUT], [R_SENS_OUT]),
    ("deleting everything", [R_CRIT_IN, R_SENS_OUT], []),
    ("from no rules", [], [R_CRIT_IN]),
]


def relaxation_vectors():
    out = []
    for name, before, after in RELAXATION_PAIRS:
        pk = relaxed_packages(before, after)
        out.append({
            "name": name,
            "before": before, "after": after,
            "beforeTransport": transport(before), "afterTransport": transport(after),
            "relaxes": bool(pk), "relaxedPackages": pk,
        })
    return out


# -- build ---------------------------------------------------------------------


def build():
    sets = []
    for s in SETS:
        rules, base = s["rules"], s["baselines"]
        cases = []
        for c in s["cases"]:
            exp = expected(rules, base, c["app"], c["day"], c["minute"])
            for k, v in c["expect"].items():
                if exp[k] != v:
                    raise SystemExit(
                        f"[{s['id']}] case '{c['name']}': hand-written {k}={v!r} "
                        f"but reference gives {exp[k]!r}")
            cases.append({
                "name": c["name"], "app": c["app"], "day": c["day"],
                "minute": c["minute"], "second": c["second"],
                "local": f"{WEEK[c['day']]}T{c['minute'] // 60:02d}:"
                         f"{c['minute'] % 60:02d}:{c['second']:02d}",
                **exp,
            })
        minutes = grid_minutes(rules)
        packages = sorted({p for r in rules for p in r["targets"]} | set(base) | {OTHER})
        grid = {p: ["".join(level_char(resolve(rules, p, d, m)[0]) for m in minutes)
                    for d in range(1, 8)] for p in packages}
        sets.append({
            "id": s["id"], "description": s["description"],
            "baselines": base, "rules": rules, "transport": transport(rules),
            "cases": cases, "gridMinutes": minutes, "grid": grid,
        })
    return {
        "_comment": "GENERATED by generate_conflict_vectors.py - do not edit by hand. "
                    "Executed by the Dart and Kotlin parity tests (Phase 10 / M3).",
        "version": 1,
        "referenceWeek": WEEK,
        "ruleSets": sets,
        "dst": {"rules": DST_RULES, "transport": transport(DST_RULES),
                "baselines": DST_BASE, "instants": INSTANTS},
        "invalidTransport": INVALID_TRANSPORT,
        "invalidRules": INVALID_RULES,
        "relaxation": relaxation_vectors(),
        "invalidQueries": {"rules": INVALID_QUERY_RULES,
                           "transport": transport(INVALID_QUERY_RULES),
                           "queries": INVALID_QUERIES},
    }


def main():
    text = json.dumps(build(), indent=1, sort_keys=False) + "\n"
    if "--check" in sys.argv:
        with open(OUT) as f:
            if f.read() != text:
                print("conflict_vectors.json is stale; rerun the generator")
                sys.exit(1)
        print("conflict_vectors.json is current")
        return
    with open(OUT, "w") as f:
        f.write(text)
    n_cases = sum(len(s["cases"]) for s in build()["ruleSets"])
    n_grid = sum(len(s["gridMinutes"]) * 7 * len(s["grid"]) for s in build()["ruleSets"])
    print(f"wrote {OUT}: {len(SETS)} rule sets, {n_cases} cases, {n_grid} grid points, "
          f"{len(INSTANTS)} instants, {len(INVALID_TRANSPORT)} invalid transports, "
          f"{len(INVALID_RULES)} invalid rules, {len(INVALID_QUERIES)} invalid queries, "
          f"{len(RELAXATION_PAIRS)} relaxation pairs")


if __name__ == "__main__":
    main()
