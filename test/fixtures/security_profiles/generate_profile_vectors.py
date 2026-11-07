#!/usr/bin/env python3
"""Phase 11 / M1: generator of the language-neutral Security Profile parity
vectors in profile_vectors.json.

The SAME JSON file is executed by
  * Dart:   test/profiles/security_profile_parity_vectors_test.dart
            (SecurityProfileDocument / SecurityProfile -> SecurityProfilePolicy;
            checks that Dart compiles each profile to exactly the fixture's
            overlay transport and sends exactly the fixture's combined
            transport), and
  * Kotlin: android/app/src/test/kotlin/com/smartapplock/app/
            SecurityProfileParityVectorsTest.kt
            (the combined transport through SmartRuleTransport.parse ->
            SmartRulePolicy, and the real ProtectionStateStore configure ->
            effectiveLevel path, incl. restart and HELD/APPLIED switches).

Semantics (approved Phase 11 decisions D1, D6; Phase 10 rule semantics
unchanged):
  * a profile is a RAISE-ONLY overlay (Sensitive / Critical only);
  * effective = strictest(saved baseline, strictest matching Smart Rule,
    active-profile overlay); never below the baseline;
  * "all protected apps" applies to the protected set only (an empty set
    never means all apps); per-app entries have no effect on unprotected apps;
  * a profile compiles to all-day, every-day raising entries of the existing
    Smart Rule transport (one engine);
  * a switch/edit relaxes when the combined (rules + overlay) strictness of
    some package drops at some weekday/minute (brute force here).

Expected values come from this script's own reference model. Every
compiled-overlay result is cross-checked against a DIRECT model
(strictest(baseline, rule level, overlay level)), and every hand-written
expectation against the reference, so a mistake stops generation.

Usage:  python3 generate_profile_vectors.py           (rewrites the JSON)
        python3 generate_profile_vectors.py --check   (exit 1 if stale)
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "profile_vectors.json")

NOTES = "com.example.notes"
CHAT = "com.example.chat"
BANK = "com.example.bank"
GAME = "com.example.game"     # never protected
OTHER = "com.example.other"   # never protected, never targeted

RANK = {"critical": 3, "sensitive": 2, "standard": 1, "unlocked": 0}
LEVEL_RANK = {"standard": 1, "sensitive": 2, "critical": 3}
WEEK = {1: "2026-11-02", 2: "2026-11-03", 3: "2026-11-04", 4: "2026-11-05",
        5: "2026-11-06", 6: "2026-11-07", 7: "2026-11-08"}  # Mon..Sun
EVERY = [1, 2, 3, 4, 5, 6, 7]
WEEKDAYS = [1, 2, 3, 4, 5]
ALL_DAY = {"type": "allDay"}
LABEL = {"normal": "Normal", "home": "Home", "work": "Work", "guest": "Guest",
         "kids": "Kids"}
KINDS = ["normal", "home", "work", "guest", "kids"]


def hm(h, m=0):
    return h * 60 + m


def window(start, end):
    return {"type": "window", "start": start, "end": end}


def rule(rid, name, action, days, time, targets, enabled=True):
    return {"id": rid, "name": name, "enabled": enabled,
            "targets": sorted(set(targets)), "days": sorted(set(days)),
            "time": time, "action": action}


def profile(pid, all_level=None, apps=None):
    return {"id": pid, "all": all_level, "apps": dict(sorted((apps or {}).items()))}


# -- reference model (Phase 10 semantics) ---------------------------------------


def prev_day(d):
    return 7 if d == 1 else d - 1


def matches(r, pkg, day, minute):
    if not r["enabled"] or pkg not in r["targets"]:
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


def rule_level(rules, pkg, day, minute):
    m = [r for r in rules if matches(r, pkg, day, minute)]
    if not m:
        return None
    top = max(RANK[r["action"]] for r in m)
    action = next(a for a, v in RANK.items() if v == top)
    return action if action in ("critical", "sensitive") else None


def stricter(a, b):
    if a is None:
        return b
    if b is None:
        return a
    return a if LEVEL_RANK[a] >= LEVEL_RANK[b] else b


def overlay_rules(p, protected):
    """The compile step (mirrors SecurityProfilePolicy.overlayRules)."""
    out = []
    if p["all"] is not None and protected:
        out.append(rule(f"profile-{p['id']}-all", f"{LABEL[p['id']]} profile",
                        p["all"], EVERY, ALL_DAY, sorted(protected)))
    for level in ("sensitive", "critical"):
        targets = sorted(k for k, v in p["apps"].items() if v == level)
        if targets:
            out.append(rule(f"profile-{p['id']}-{level}", f"{LABEL[p['id']]} profile",
                            level, EVERY, ALL_DAY, targets))
    return out


def direct_overlay(p, pkg, protected):
    """Independent of the compile step: the overlay level for a package."""
    lv = p["all"] if pkg in protected else None
    return stricter(lv, p["apps"].get(pkg))


def transport(rules):
    out = []
    for r in rules:
        if not r["enabled"] or r["action"] not in ("critical", "sensitive"):
            continue
        all_day = r["time"]["type"] == "allDay"
        out.append({"level": r["action"], "days": list(r["days"]), "allDay": all_day,
                    "start": 0 if all_day else r["time"]["start"],
                    "end": 0 if all_day else r["time"]["end"],
                    "targets": list(r["targets"])})
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


def ch(level):
    return {"critical": "C", "sensitive": "S", "standard": "T", None: "-"}[level]


def evaluate(baselines, rules, p, pkg, day, minute):
    protected = set(baselines)
    combined = rules + overlay_rules(p, protected)
    extra = rule_level(combined, pkg, day, minute)
    rl = rule_level(rules, pkg, day, minute)
    ov = direct_overlay(p, pkg, protected)
    base = baselines.get(pkg)
    # Cross-check: compiled engine == direct strictest(rule, overlay) for
    # protected packages.
    if base is not None and extra != stricter(rl, ov):
        raise SystemExit(f"compile mismatch for {p['id']} {pkg} {day} {minute}")
    eff = None if base is None else stricter(base, extra)
    if eff is not None and LEVEL_RANK[eff] < LEVEL_RANK[base]:
        raise SystemExit("below baseline")
    return {"ruleLevel": rl, "overlayLevel": ov if base is not None else None,
            "extraLevel": extra if base is not None else None, "effective": eff}


# -- scenarios -----------------------------------------------------------------

R_WORK = rule("b-work", "Work", "sensitive", WEEKDAYS, window(hm(8), hm(18)), [NOTES, CHAT, BANK])
R_LUNCH = rule("a-lunch", "Lunch", "critical", EVERY, window(hm(12), hm(14)), [NOTES])
R_NIGHT = rule("n-night", "Night", "sensitive", [7], window(hm(22), hm(6)), [NOTES, CHAT])
R_DAYCRIT = rule("d-crit", "Day Critical", "critical", WEEKDAYS, window(hm(9), hm(17)), [NOTES])
R_ALWAYS = rule("x-always", "Always Critical", "critical", EVERY, ALL_DAY, [NOTES, CHAT, BANK])
R_STD = rule("s-std", "Standard", "standard", EVERY, ALL_DAY, [NOTES])
R_OFF = rule("o-off", "Off Critical", "critical", EVERY, ALL_DAY, [CHAT], enabled=False)

BASE = {NOTES: "standard", CHAT: "sensitive", BANK: "critical"}

SCENARIOS = []


def scenario(sid, description, baselines, rules, p, cases):
    SCENARIOS.append({"id": sid, "description": description, "baselines": baselines,
                      "rules": rules, "profile": p, "cases": cases})


def case(name, app, day, minute, **expect):
    return {"name": name, "app": app, "day": day, "minute": minute, "expect": expect}


scenario("normal-no-rules", "Normal adds nothing: saved levels only.", BASE, [],
         profile("normal"), [
             case("notes stays Standard", NOTES, 1, hm(12), effective="standard", extraLevel=None),
             case("bank stays Critical", BANK, 6, hm(3), effective="critical"),
         ])
scenario("normal-with-rules", "Normal with rules: transport equals the rules-only transport.",
         BASE, [R_WORK, R_LUNCH, R_STD, R_OFF], profile("normal"), [
             case("lunch Critical", NOTES, 1, hm(12, 30), effective="critical", overlayLevel=None),
             case("work Sensitive", NOTES, 1, hm(9), effective="sensitive"),
             case("Saturday evening Standard", NOTES, 6, hm(20), effective="standard"),
             case("disabled rule ignored", CHAT, 6, hm(20), effective="sensitive"),
         ])
scenario("guest-all-critical", "Guest: every protected app Critical all week; unprotected untouched.",
         BASE, [R_WORK], profile("guest", "critical"), [
             case("notes Critical at night", NOTES, 6, hm(3), effective="critical", overlayLevel="critical"),
             case("chat Critical during work", CHAT, 2, hm(10), effective="critical", ruleLevel="sensitive"),
             case("bank Critical (already)", BANK, 7, hm(23, 59), effective="critical"),
             case("game not protected", GAME, 1, hm(12), effective=None),
         ])
scenario("kids-selected", "Kids: only user-selected apps; never below baseline; unprotected entry inert.",
         BASE, [R_LUNCH],
         profile("kids", None, {NOTES: "critical", CHAT: "sensitive", BANK: "sensitive", GAME: "critical"}), [
             case("notes Critical (overlay)", NOTES, 3, hm(8), effective="critical", overlayLevel="critical"),
             case("chat stays Sensitive", CHAT, 3, hm(8), effective="sensitive"),
             case("bank overlay Sensitive never lowers Critical", BANK, 3, hm(8), effective="critical",
                  overlayLevel="sensitive"),
             case("game entry has no effect", GAME, 3, hm(8), effective=None),
         ])
scenario("home-sensitive-plus-rule", "Home all Sensitive; a Critical rule window still wins inside it.",
         BASE, [R_DAYCRIT, R_WORK], profile("home", "sensitive"), [
             case("notes Sensitive at night (overlay)", NOTES, 1, hm(2), effective="sensitive",
                  ruleLevel=None, overlayLevel="sensitive"),
             case("notes Critical 09:00 (rule start inclusive)", NOTES, 1, hm(9), effective="critical"),
             case("notes Sensitive 17:00 (rule end exclusive)", NOTES, 1, hm(17), effective="sensitive"),
             case("chat Sensitive", CHAT, 6, hm(12), effective="sensitive"),
         ])
scenario("work-overnight", "Work overlay with an overnight Sunday rule (owner-day semantics kept).",
         BASE, [R_NIGHT], profile("work", None, {CHAT: "critical"}), [
             case("notes Sensitive Monday 05:59 (Sunday's night)", NOTES, 1, hm(5, 59), effective="sensitive"),
             case("notes Standard Monday 06:00", NOTES, 1, hm(6), effective="standard"),
             case("notes Standard Sunday 21:59", NOTES, 7, hm(21, 59), effective="standard"),
             case("chat Critical all week (overlay over rule)", CHAT, 1, hm(3), effective="critical",
                  ruleLevel="sensitive", overlayLevel="critical"),
         ])
scenario("guest-no-protected-apps", "Guest with nothing protected: no entry (empty never means all).",
         {}, [], profile("guest", "critical"), [
             case("game not protected", GAME, 1, hm(12), effective=None),
         ])

# -- switches / edits (D6) ------------------------------------------------------

P_NORMAL = profile("normal")
P_GUEST = profile("guest", "critical")
P_KIDS_N = profile("kids", None, {NOTES: "critical"})
P_KIDS_NC = profile("kids", None, {NOTES: "critical", CHAT: "critical"})
P_KIDS_NS = profile("kids", None, {NOTES: "sensitive"})
P_HOME_S = profile("home", "sensitive")
P_HOME_SB = profile("home", "sensitive", {BANK: "critical"})
P_HOME_C = profile("home", "critical")
P_WORK_C = profile("work", None, {CHAT: "critical"})

SWITCHES = [
    ("Normal -> Guest (raise)", [], P_NORMAL, P_GUEST),
    ("Guest -> Normal (leave Guest)", [], P_GUEST, P_NORMAL),
    ("Guest -> Kids (others lose Critical)", [], P_GUEST, P_KIDS_N),
    ("Kids: remove an app (edit the active profile)", [], P_KIDS_NC, P_KIDS_N),
    ("Kids: lower an app Critical -> Sensitive", [], P_KIDS_N, P_KIDS_NS),
    ("Kids: raise an app Sensitive -> Critical", [], P_KIDS_NS, P_KIDS_N),
    ("Home: add a per-app Critical", [], P_HOME_S, P_HOME_SB),
    ("Guest -> Home all Critical (equal)", [], P_GUEST, P_HOME_C),
    ("Guest -> Normal fully covered by an all-week Critical rule", [R_ALWAYS], P_GUEST, P_NORMAL),
    ("Work -> Normal with a weekday rule (gap outside the window)", [R_DAYCRIT, rule(
        "c-chat", "Chat day", "critical", WEEKDAYS, window(hm(9), hm(17)), [CHAT])], P_WORK_C, P_NORMAL),
    ("Normal -> Normal", [R_WORK], P_NORMAL, P_NORMAL),
]


def relaxed(baselines, rules, before, after):
    protected = set(baselines)
    b = rules + overlay_rules(before, protected)
    a = rules + overlay_rules(after, protected)
    out = []
    for pkg in sorted({p for r in b for p in r["targets"]}):
        hit = False
        for day in EVERY:
            for minute in range(1440):
                was = rule_level(b, pkg, day, minute)
                if was is None:
                    continue
                now = rule_level(a, pkg, day, minute)
                if now is None or LEVEL_RANK[was] > LEVEL_RANK[now]:
                    hit = True
                    break
            if hit:
                break
        if hit:
            out.append(pkg)
    return out


# -- invalid profile documents (Dart decode must reject; never reach native) ----

GOOD = {"version": 1, "activeProfileId": "normal",
        "profiles": [profile(k, "critical" if k == "guest" else None) for k in KINDS]}


def mutate(fn):
    d = json.loads(json.dumps(GOOD))
    fn(d)
    return d


def set_profile(d, pid, **kw):
    for p in d["profiles"]:
        if p["id"] == pid:
            p.update(kw)


INVALID_DOCUMENTS = [
    ("Standard overlay level", mutate(lambda d: set_profile(d, "kids", apps={NOTES: "standard"})), "corrupt"),
    ("Unlocked overlay level", mutate(lambda d: set_profile(d, "home", all="unlocked")), "corrupt"),
    ("Normal with an overlay", mutate(lambda d: set_profile(d, "normal", apps={NOTES: "critical"})), "corrupt"),
    ("Guest not Critical", mutate(lambda d: set_profile(d, "guest", all="sensitive")), "corrupt"),
    ("Guest with per-app entries", mutate(lambda d: set_profile(d, "guest", apps={NOTES: "critical"})), "corrupt"),
    ("active id names no profile", mutate(lambda d: d.update(activeProfileId="party")), "corrupt"),
    ("duplicate preset", mutate(lambda d: d["profiles"].append(profile("kids"))), "corrupt"),
    ("missing preset", mutate(lambda d: d["profiles"].pop()), "corrupt"),
    ("unknown profile id", mutate(lambda d: d["profiles"].append(profile("party"))), "corrupt"),
    ("invalid package", mutate(lambda d: set_profile(d, "work", apps={"not a package": "critical"})), "corrupt"),
    ("own package", mutate(lambda d: set_profile(d, "kids", apps={"com.smartapplock.app": "critical"})), "corrupt"),
    ("extra key", mutate(lambda d: d.update(extra=True)), "corrupt"),
    ("extra profile key", mutate(lambda d: set_profile(d, "home", isActive=True)), "corrupt"),
    ("level as number", mutate(lambda d: set_profile(d, "home", all=2)), "corrupt"),
    ("version 0", mutate(lambda d: d.update(version=0)), "corrupt"),
    ("version as string", mutate(lambda d: d.update(version="1")), "corrupt"),
    ("newer version", mutate(lambda d: d.update(version=2)), "unsupportedVersion"),
]


# -- build ---------------------------------------------------------------------


def build():
    scenarios = []
    for s in SCENARIOS:
        base, rules, p = s["baselines"], s["rules"], s["profile"]
        protected = set(base)
        cases = []
        for c in s["cases"]:
            exp = evaluate(base, rules, p, c["app"], c["day"], c["minute"])
            for k, v in c["expect"].items():
                if exp[k] != v:
                    raise SystemExit(f"[{s['id']}] '{c['name']}': hand-written {k}={v!r}, "
                                     f"reference {exp[k]!r}")
            cases.append({"name": c["name"], "app": c["app"], "day": c["day"],
                          "minute": c["minute"],
                          "local": f"{WEEK[c['day']]}T{c['minute'] // 60:02d}:{c['minute'] % 60:02d}:00",
                          **exp})
        combined = rules + overlay_rules(p, protected)
        minutes = grid_minutes(combined)
        packages = sorted(protected | {t for r in combined for t in r["targets"]} | {OTHER})
        grid = {pkg: ["".join(ch(evaluate(base, rules, p, pkg, d, m)["effective"]) for m in minutes)
                      for d in EVERY] for pkg in packages}
        extra_grid = {pkg: ["".join(ch(rule_level(combined, pkg, d, m)) for m in minutes)
                            for d in EVERY] for pkg in packages}
        scenarios.append({
            "id": s["id"], "description": s["description"], "baselines": base,
            "rules": rules, "profile": p,
            "overlayTransport": transport(overlay_rules(p, protected)),
            "transport": transport(combined),
            "rulesTransport": transport(rules),
            "cases": cases, "gridMinutes": minutes,
            "grid": grid, "transportGrid": extra_grid,
        })
    switches = []
    for name, rules, before, after in SWITCHES:
        pk = relaxed(BASE, rules, before, after)
        protected = set(BASE)
        switches.append({
            "name": name, "baselines": BASE, "rules": rules,
            "before": before, "after": after,
            "beforeTransport": transport(rules + overlay_rules(before, protected)),
            "afterTransport": transport(rules + overlay_rules(after, protected)),
            "relaxes": bool(pk), "relaxedPackages": pk,
        })
    return {
        "_comment": "GENERATED by generate_profile_vectors.py - do not edit by hand. "
                    "Executed by the Dart and Kotlin parity tests (Phase 11 / M1).",
        "version": 1,
        "referenceWeek": WEEK,
        "presets": [profile(k, "critical" if k == "guest" else None) for k in KINDS],
        "scenarios": scenarios,
        "switches": switches,
        "invalidDocuments": [{"name": n, "document": d, "problem": pr}
                             for n, d, pr in INVALID_DOCUMENTS],
    }


def main():
    text = json.dumps(build(), indent=1, sort_keys=False) + "\n"
    if "--check" in sys.argv:
        with open(OUT) as f:
            if f.read() != text:
                print("profile_vectors.json is stale; rerun the generator")
                sys.exit(1)
        print("profile_vectors.json is current")
        return
    with open(OUT, "w") as f:
        f.write(text)
    b = build()
    n_cases = sum(len(s["cases"]) for s in b["scenarios"])
    n_grid = sum(len(s["gridMinutes"]) * 7 * len(s["grid"]) for s in b["scenarios"])
    n_relax = sum(1 for s in b["switches"] if s["relaxes"])
    print(f"wrote {OUT}: {len(b['scenarios'])} scenarios, {n_cases} cases, {n_grid} grid points, "
          f"{len(b['switches'])} switches ({n_relax} relaxing), "
          f"{len(b['invalidDocuments'])} invalid documents")


if __name__ == "__main__":
    main()
