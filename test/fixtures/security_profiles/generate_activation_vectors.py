#!/usr/bin/env python3
"""Phase 11 / M3: generator of the language-neutral "Apply profile"
activation parity vectors in activation_vectors.json.

The SAME JSON file is executed by
  * Dart:   test/profiles/profile_activation_parity_vectors_m3_test.dart
            (SmartRule v3 JSON + SecurityProfileSet -> SecurityProfilePolicy
            .combinedTransport must equal the fixture transport exactly; the
            Dart effective level and layer diagnosis must equal the grid; the
            combined relaxed set must equal each transition's), and
  * Kotlin: android/app/src/test/kotlin/com/smartapplock/app/
            ProfileActivationParityVectorsTest.kt
            (the transport through the UNCHANGED native path:
            SmartRuleTransport.parse -> SmartRulePolicy, and
            ProtectionStateStore.configure -> effectiveLevel incl. restart,
            HELD vs APPLIED transitions and a failed durable write).

Semantics (Phase 11 / M3 gate; Phase 10 / M1-M2 semantics unchanged):
  * an "Apply profile" rule adds the referenced profile's raise-only overlay
    IN ADDITION to the manual profile, during the rule's own days/window
    (overnight windows belong to their start day; end exclusive);
  * effective = strictest(saved, direct level rules, manual overlay,
    every matching activation); never below the saved level;
  * "all protected apps" = the protected set only; unprotected apps never
    change; a missing profile reference is Critical for every protected app
    during its window (fail closed);
  * activation compiles to raising entries of the EXISTING v1 transport
    (one engine, no protocol change); expiry is evaluation, never a change;
  * a transition relaxes when the combined strictness of some protected
    package drops at some weekday/minute (brute force here).

Expected values come from this script's own reference model. Every grid
point is cross-checked between the COMPILED transport model and a DIRECT
per-layer model, and every hand-written case against the reference, so a
mistake stops generation.

Usage:  python3 generate_activation_vectors.py           (rewrites the JSON)
        python3 generate_activation_vectors.py --check   (exit 1 if stale)
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "activation_vectors.json")

NOTES = "com.example.notes"
CHAT = "com.example.chat"
BANK = "com.example.bank"
GAME = "com.example.game"  # never protected
TRIP = "custom-00000000000a"
GONE = "custom-0000000000ff"  # never exists (dangling reference)

LEVEL_RANK = {"critical": 3, "sensitive": 2, "standard": 1}
RANK = {"critical": 3, "sensitive": 2, "standard": 1, "unlocked": 0}
EVERY = [1, 2, 3, 4, 5, 6, 7]
WEEKDAYS = [1, 2, 3, 4, 5]
WEEKEND = [6, 7]
ALL_DAY = {"type": "allDay"}
WEEK = {str(d): f"2026-11-{1 + d:02d}" for d in EVERY}
BASE = {NOTES: "standard", CHAT: "sensitive", BANK: "critical"}
KINDS = ["normal", "home", "work", "guest", "kids"]


def hm(h, m=0):
    return h * 60 + m


def window(start, end):
    return {"type": "window", "start": start, "end": end}


def level_rule(rid, action, days, time, targets, enabled=True):
    return {"id": rid, "name": f"Rule {rid}", "enabled": enabled,
            "targets": sorted(set(targets)), "days": sorted(set(days)),
            "time": time, "action": action}


def apply_rule(rid, profile_id, days, time, enabled=True):
    """v3 profile-rule JSON layout (exactly SmartRule.toJson)."""
    return {"id": rid, "name": f"Apply {rid}", "enabled": enabled,
            "days": sorted(set(days)), "time": time, "action": "profile",
            "profile": profile_id}


def profile(pid, all_level=None, apps=None, name=None):
    p = {"id": pid, "all": all_level, "apps": dict(sorted((apps or {}).items()))}
    if name is not None:
        p["name"] = name
    return p


def profile_set(active="normal", trip=None, kids=None):
    ps = [profile(k, "critical" if k == "guest" else None,
                  kids if k == "kids" and kids else None) for k in KINDS]
    if trip is not None:
        ps.append(profile(TRIP, trip, name="Trip"))
    return {"active": active, "profiles": ps}


def by_id(pset, pid):
    for p in pset["profiles"]:
        if p["id"] == pid:
            return p
    return None


# -- reference model -------------------------------------------------------------


def prev_day(d):
    return 7 if d == 1 else d - 1


def time_matches(days, t, day, minute):
    if t["type"] == "allDay":
        return day in days
    s, e = t["start"], t["end"]
    if s < e:
        return s <= minute < e and day in days
    if minute >= s:
        return day in days
    if minute < e:
        return prev_day(day) in days
    return False


def stricter(a, b):
    if a is None:
        return b
    if b is None:
        return a
    return a if LEVEL_RANK[a] >= LEVEL_RANK[b] else b


def overlay_specs(p, protected, days=EVERY, time=ALL_DAY):
    """Compile step: the profile's raising specs with the given schedule."""
    out = []
    if p["all"] is not None and protected:
        out.append({"level": p["all"], "days": list(days), "time": time,
                    "targets": sorted(protected)})
    for level in ("sensitive", "critical"):
        targets = sorted(k for k, v in p["apps"].items() if v == level)
        if targets:
            out.append({"level": level, "days": list(days), "time": time,
                        "targets": targets})
    return out


def compiled_specs(rules, pset, protected):
    out = []
    for r in rules:
        if r["enabled"] and r["action"] in ("critical", "sensitive"):
            out.append({"level": r["action"], "days": r["days"], "time": r["time"],
                        "targets": r["targets"]})
    out += overlay_specs(by_id(pset, pset["active"]), protected)
    for r in rules:
        if not r["enabled"] or r["action"] != "profile":
            continue
        p = by_id(pset, r["profile"])
        if p is None:
            if protected:
                out.append({"level": "critical", "days": r["days"], "time": r["time"],
                            "targets": sorted(protected)})
        else:
            out += overlay_specs(p, protected, r["days"], r["time"])
    return out


def spec_level(specs, pkg, day, minute):
    best = None
    for s in specs:
        if pkg in s["targets"] and time_matches(s["days"], s["time"], day, minute):
            best = stricter(best, s["level"])
    return best


def dart_str(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, list):
        return "[" + ", ".join(dart_str(x) for x in v) + "]"
    return str(v)


def transport(specs):
    out = []
    for s in specs:
        all_day = s["time"]["type"] == "allDay"
        out.append({"level": s["level"], "days": list(s["days"]), "allDay": all_day,
                    "start": 0 if all_day else s["time"]["start"],
                    "end": 0 if all_day else s["time"]["end"],
                    "targets": list(s["targets"])})
    # Dart: sorted by Map.toString().
    out.sort(key=lambda m: "{" + ", ".join(f"{k}: {dart_str(v)}" for k, v in m.items()) + "}")
    return out


def direct_layers(rules, pset, pkg, day, minute, protected):
    """Independent of the compile step: one level per layer."""
    base = BASE.get(pkg) if pkg in protected else None
    if base is None:
        return None
    direct = None
    for r in rules:
        if (r["enabled"] and r["action"] != "profile" and pkg in r["targets"]
                and time_matches(r["days"], r["time"], day, minute)):
            top = r["action"] if RANK[r["action"]] >= 2 else None
            direct = stricter(direct, top)
    manual_p = by_id(pset, pset["active"])
    manual = manual_p["apps"].get(pkg)
    manual = stricter(manual, manual_p["all"])
    scheduled = None
    for r in rules:
        if (r["enabled"] and r["action"] == "profile"
                and time_matches(r["days"], r["time"], day, minute)):
            p = by_id(pset, r["profile"])
            lvl = "critical" if p is None else stricter(p["apps"].get(pkg), p["all"])
            scheduled = stricter(scheduled, lvl)
    eff = base
    for lvl in (manual, direct, scheduled):
        eff = stricter(eff, lvl)
    return eff


def ch(level):
    return {"critical": "C", "sensitive": "S", "standard": "T", None: "-"}[level]


def grid_minutes(rules):
    ms = {0, 1439}
    for r in rules:
        t = r["time"]
        if t["type"] == "window":
            for x in (t["start"], t["end"]):
                for dx in (-1, 0, 1):
                    ms.add((x + dx) % 1440)
    return sorted(ms)


def relaxed(rules_b, pset_b, rules_a, pset_a, protected):
    b = compiled_specs(rules_b, pset_b, protected)
    a = compiled_specs(rules_a, pset_a, protected)
    out = []
    for pkg in sorted({p for s in b for p in s["targets"]}):
        hit = False
        for day in EVERY:
            for minute in range(1440):
                was = spec_level(b, pkg, day, minute)
                if was is None:
                    continue
                now = spec_level(a, pkg, day, minute)
                if now is None or LEVEL_RANK[was] > LEVEL_RANK[now]:
                    hit = True
                    break
            if hit:
                break
        if hit:
            out.append(pkg)
    return out


# -- scenarios -----------------------------------------------------------------

A_WEEKEND_GUEST = apply_rule("w-guest", "guest", WEEKEND, window(hm(22), hm(6)))
A_DAY_TRIP = apply_rule("t-trip", TRIP, EVERY, window(hm(9), hm(17)))
A_DAY_GUEST = apply_rule("g-guest", "guest", EVERY, window(hm(9), hm(17)))
A_KIDS = apply_rule("k-kids", "kids", WEEKDAYS, window(hm(15), hm(19)))
A_GONE = apply_rule("m-gone", GONE, [1], window(hm(8), hm(12)))
A_HOME = apply_rule("h-home", "home", EVERY, ALL_DAY)
A_OFF = apply_rule("o-off", "guest", EVERY, ALL_DAY, enabled=False)
A_ALWAYS_GUEST = apply_rule("x-guest", "guest", EVERY, ALL_DAY)
R_NOTES_SENS = level_rule("d-notes", "sensitive", WEEKDAYS, window(hm(8), hm(18)), [NOTES])
R_CHAT_CRIT = level_rule("c-chat", "critical", EVERY, window(hm(12), hm(14)), [CHAT])

SCENARIOS = []


def scenario(sid, description, rules, pset, cases):
    SCENARIOS.append({"id": sid, "description": description, "rules": rules,
                      "profiles": pset, "cases": cases})


def case(name, app, day, minute, effective):
    return {"name": name, "app": app, "day": day, "minute": minute, "effective": effective}


scenario("weekend-guest-overnight",
         "Normal manual + scheduled Guest Sat/Sun 22:00-06:00 (overnight belongs to its start day).",
         [A_WEEKEND_GUEST], profile_set(),
         [case("Fri 23:00 not selected", NOTES, 5, hm(23), "standard"),
          case("Sat 05:59 is Fri's window", NOTES, 6, hm(5, 59), "standard"),
          case("Sat 22:00 start inclusive", NOTES, 6, hm(22), "critical"),
          case("Sun 03:00 Sat window continues", CHAT, 7, hm(3), "critical"),
          case("Sun 06:00 end exclusive", NOTES, 7, hm(6), "standard"),
          case("Mon 05:59 Sun window continues", NOTES, 1, hm(5, 59), "critical"),
          case("unprotected app never enrolled", GAME, 6, hm(23), None)])
scenario("manual-work-scheduled-trip",
         "Work manual (no overlay) + scheduled custom Trip (all Sensitive) daytime.",
         [A_DAY_TRIP], profile_set(active="work", trip="sensitive"),
         [case("in window notes Sensitive", NOTES, 3, hm(10), "sensitive"),
          case("bank never lowered", BANK, 3, hm(10), "critical"),
          case("after expiry back to saved", NOTES, 3, hm(17), "standard")])
scenario("manual-guest-scheduled-home",
         "Manual Guest stays Critical whatever is scheduled (Home adds nothing).",
         [A_HOME], profile_set(active="guest"),
         [case("always Critical", NOTES, 2, hm(12), "critical"),
          case("chat Critical", CHAT, 7, hm(3), "critical")])
scenario("kids-per-app-plus-direct",
         "Manual Kids(chat Critical) + scheduled Trip Sensitive + a direct notes rule + a direct chat rule.",
         [A_DAY_TRIP, R_NOTES_SENS, R_CHAT_CRIT, A_KIDS],
         profile_set(active="kids", trip="sensitive", kids={CHAT: "critical"}),
         [case("chat manual Kids Critical", CHAT, 6, hm(20), "critical"),
          case("notes direct Sensitive", NOTES, 1, hm(8), "sensitive"),
          case("notes Trip Sensitive Sat", NOTES, 6, hm(10), "sensitive"),
          case("notes nothing Sat night", NOTES, 6, hm(20), "standard")])
scenario("overlapping-activations",
         "Two overlapping activations (Guest Critical, Trip Sensitive): strictest wins.",
         [A_DAY_TRIP, A_DAY_GUEST], profile_set(trip="sensitive"),
         [case("overlap Critical", NOTES, 4, hm(12), "critical"),
          case("outside both", NOTES, 4, hm(8), "standard")])
scenario("missing-profile",
         "A dangling reference is Critical for every protected app during its window.",
         [A_GONE], profile_set(),
         [case("Mon 08:00 Critical", NOTES, 1, hm(8), "critical"),
          case("Mon 12:00 end exclusive", NOTES, 1, hm(12), "standard"),
          case("Tue not selected", CHAT, 2, hm(9), "sensitive"),
          case("unprotected never", GAME, 1, hm(9), None)])
scenario("disabled-and-noop",
         "A disabled Guest activation and an enabled Home activation add nothing.",
         [A_OFF, A_HOME], profile_set(),
         [case("nothing", NOTES, 1, hm(12), "standard")])

TRANSITIONS = [
    ("delete an activation", [A_DAY_GUEST], profile_set(), [], profile_set()),
    ("disable an activation", [A_DAY_GUEST], profile_set(),
     [apply_rule("g-guest", "guest", EVERY, window(hm(9), hm(17)), enabled=False)], profile_set()),
    ("narrow an activation", [A_DAY_GUEST], profile_set(),
     [apply_rule("g-guest", "guest", EVERY, window(hm(10), hm(17)))], profile_set()),
    ("retarget Guest -> Trip Sensitive", [A_DAY_GUEST], profile_set(trip="sensitive"),
     [apply_rule("g-guest", TRIP, EVERY, window(hm(9), hm(17)))], profile_set(trip="sensitive")),
    ("weaken the referenced Trip", [A_DAY_TRIP], profile_set(trip="critical"),
     [A_DAY_TRIP], profile_set(trip="sensitive")),
    ("add an activation", [], profile_set(), [A_DAY_GUEST], profile_set()),
    ("widen an activation", [A_DAY_GUEST], profile_set(),
     [apply_rule("g-guest", "guest", EVERY, window(hm(8), hm(18)))], profile_set()),
    ("expiry (same snapshot)", [A_DAY_GUEST], profile_set(), [A_DAY_GUEST], profile_set()),
    ("manual Guest -> Normal covered by an all-week Guest activation",
     [A_ALWAYS_GUEST], profile_set(active="guest"), [A_ALWAYS_GUEST], profile_set()),
    ("edit an unreferenced inactive Trip", [A_DAY_GUEST], profile_set(trip="critical"),
     [A_DAY_GUEST], profile_set(trip="sensitive")),
]


def build():
    protected = set(BASE)
    scenarios = []
    for s in SCENARIOS:
        rules, pset = s["rules"], s["profiles"]
        specs = compiled_specs(rules, pset, protected)
        minutes = grid_minutes(rules)
        grid = {}
        for pkg in [NOTES, CHAT, BANK, GAME]:
            rows = []
            for day in EVERY:
                row = ""
                for m in minutes:
                    extra = spec_level(specs, pkg, day, m)
                    base = BASE.get(pkg)
                    compiled = None if base is None else stricter(base, extra)
                    direct = direct_layers(rules, pset, pkg, day, m, protected)
                    if compiled != direct:
                        raise SystemExit(f"{s['id']}: compile mismatch {pkg} {day} {m}: "
                                         f"{compiled} != {direct}")
                    if base is None and extra is not None:
                        raise SystemExit(f"{s['id']}: unprotected {pkg} enrolled")
                    row += ch(compiled)
                rows.append(row)
            grid[pkg] = rows
        for c in s["cases"]:
            got = direct_layers(rules, pset, c["app"], c["day"], c["minute"], protected)
            if got != c["effective"]:
                raise SystemExit(f"{s['id']}: case '{c['name']}' expected {c['effective']}, model {got}")
            c["local"] = f"{WEEK[str(c['day'])]}T{c['minute'] // 60:02d}:{c['minute'] % 60:02d}:00"
        scenarios.append({**s, "baselines": BASE, "transport": transport(specs),
                          "gridMinutes": minutes, "grid": grid})
    transitions = []
    for name, rb, pb, ra, pa in TRANSITIONS:
        rel = relaxed(rb, pb, ra, pa, protected)
        transitions.append({
            "name": name, "baselines": BASE,
            "rulesBefore": rb, "profilesBefore": pb,
            "rulesAfter": ra, "profilesAfter": pa,
            "beforeTransport": transport(compiled_specs(rb, pb, protected)),
            "afterTransport": transport(compiled_specs(ra, pa, protected)),
            "relaxes": bool(rel), "relaxedPackages": rel,
        })
    return {
        "_comment": "GENERATED by generate_activation_vectors.py - do not edit by hand. "
                    "Executed by the Dart and Kotlin parity tests (Phase 11 / M3).",
        "version": 1,
        "referenceWeek": WEEK,
        "scenarios": scenarios,
        "transitions": transitions,
    }


def main():
    text = json.dumps(build(), indent=1, sort_keys=False) + "\n"
    if "--check" in sys.argv:
        with open(OUT) as f:
            if f.read() != text:
                print("activation_vectors.json is stale; rerun the generator")
                sys.exit(1)
        print("activation_vectors.json is current")
        return
    with open(OUT, "w") as f:
        f.write(text)
    b = build()
    n_cases = sum(len(s["cases"]) for s in b["scenarios"])
    n_grid = sum(len(s["gridMinutes"]) * 7 * len(s["grid"]) for s in b["scenarios"])
    n_relax = sum(1 for t in b["transitions"] if t["relaxes"])
    print(f"wrote {OUT}: {len(b['scenarios'])} scenarios, {n_cases} cases, {n_grid} grid points, "
          f"{len(b['transitions'])} transitions ({n_relax} relaxing)")


if __name__ == "__main__":
    main()
