"""Mandates: what the head of state wants, in the form departments read.

A mandate comes from one of three places. A player's order is interpreted by
the premier's model and grounded here against the catalog: ids are checked,
what this civilization cannot build is replaced by the nearest thing it can,
and amounts are capped. An AI opponent has no player, so its civilization
profile may carry a national policy script written as mandates. A team with
neither starts from the standing mandates derived from its profile.

Whatever the source, a mandate that cannot be carried out yet (a unit of a
later age, an upgrade nobody has researched, no building to train it in) is
expanded each tick into the mandates that make it possible, with the same
origin.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import json
from pathlib import Path
import re

from brain.land_progression import CATALOG
from brain.llm_commander import MILITARY_BUILDINGS
from brain.multi_agent.combat_model import unit_class

from .models import Mandate, RESOURCES, ROUTINE

NAMES = json.loads((Path(__file__).resolve().parents[2] / "data" / "name_catalog.json").read_text(encoding="utf-8"))
UNITS, TECHS = CATALOG["units"], NAMES["technologies"]

MIN_WORKER_TARGET = 16
WORKER_RANGE = (8, 60)
STOCKPILE_CAP = 60          # one order's worth of a unit; the population limit is the real ceiling
STOCKPILE_DEFAULT = 10      # "more of them", when no number was given
MAX_MANDATES = 3
GRASPS = ("exact", "approx", "guess", "none")
URGENCIES = ("normal", "rush")
# The kinds an order may be interpreted into, and the department each belongs to.
KIND_DEPT = {"boost_resource": "economy", "worker_target": "economy", "stockpile": "general", "attack": "general", "hold": "general",
             "fortify": "defense", "advance_age": "tech", "research": "tech", "scout": "intel"}
# Derived only, never asked of the model: a building some other mandate needs.
BUILD = "build"
AGE_NAMES = ("黑暗时代", "封建时代", "城堡时代", "帝王时代")
RESOURCE_NAMES = {"food": "食物", "wood": "木材", "gold": "黄金", "stone": "石头"}

# Upgrade lines, from the technologies that turn one unit into another. A few
# technologies name the start of their line as the unit they upgrade, not the
# form just before; their prerequisite technology says which form that is.
_STEPS = {(step[0], step[1]) for tech in TECHS.values() for step in tech["upgrades"]}
_STEPS |= {(before[1], step[1]) for tech in TECHS.values() for step in tech["upgrades"]
           for before in TECHS.get(tech["prerequisite_technology"], {}).get("upgrades", [])}


def _reach(start: str, forward: bool) -> set[str]:
    """Units later (or earlier) than `start` in its upgrade line."""
    found, frontier = set(), {start}
    while frontier:
        frontier = {(b if forward else a) for a, b in _STEPS if (a if forward else b) in frontier} - found - {start}
        found |= frontier
    return found


def later_forms(unit: str) -> set[str]:
    return _reach(unit, True)


def slot(mandate: Mandate) -> tuple:
    """Two mandates in one slot cannot both stand: the later one replaces the earlier."""
    if mandate.kind in ("attack", "hold"):
        return ("general", "stance")
    if mandate.kind in ("stockpile", "research", BUILD):
        return (mandate.dept, mandate.kind, mandate.subject)
    return (mandate.dept, mandate.kind)


def name_of(item: str) -> str:
    for table in (NAMES["units"], TECHS, NAMES["buildings"]):
        if item in table:
            return table[item]["zh"]
    return RESOURCE_NAMES.get(item, item)


def civ_name(civ: str) -> str:
    return NAMES["civilizations"].get(civ, "本文明")


def _allowed(record: dict, civ: str) -> bool:
    """Whether a civilization may use a catalog entry. An unknown civilization is not checked."""
    return civ not in NAMES["civilizations"] or not record.get("civilizations") or civ in record["civilizations"]


def name_table(civ: str) -> dict:
    """The catalog as the model sees it: id, Chinese name, English name, required age, usable by this civilization."""
    units = [[uid, NAMES["units"][uid]["zh"], NAMES["units"][uid]["en"], int(record.get("required_age", 0)), int(_allowed(record, civ))]
             for uid, record in UNITS.items() if uid in NAMES["units"]]
    techs = [[tid, record["zh"], record["en"], record["required_age"], int(_allowed(record, civ))] for tid, record in TECHS.items()]
    return {"units": units, "techs": techs}


def subject_ids() -> list[str]:
    """Every value a mandate's subject may take, for the answer's schema."""
    return ["", *RESOURCES, *[uid for uid in UNITS if uid in NAMES["units"]], *[tid for tid in TECHS if tid not in UNITS]]


# ---------------------------------------------------------------------------- grounding an interpretation
@dataclass
class Grounding:
    mandates: list[Mandate] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)       # what was changed, in words for the player
    problems: list[str] = field(default_factory=list)    # what could not be repaired, in words for the model


def _best(candidates: list[str]) -> str | None:
    """The strongest of some units: the latest age, then the harder hitter."""
    return max(candidates, key=lambda uid: (int(UNITS[uid].get("required_age", 0)), float(UNITS[uid].get("attack", 0)),
                                            sum(UNITS[uid].get("cost", {}).values()), uid), default=None)


def _replacement_unit(unit: str, civ: str) -> str | None:
    """The nearest unit this civilization can train: an earlier form in the same upgrade line, else one of the same class."""
    usable = [uid for uid, record in UNITS.items() if _allowed(record, civ) and uid != "villager"]
    earlier = _reach(unit, False)
    return _best([uid for uid in usable if uid in earlier]) or _best([uid for uid in usable if unit_class(uid) == unit_class(unit)])


def _replacement_tech(tech: str, civ: str) -> str | None:
    """The last step of the same line this civilization can research."""
    seen = set()
    while tech and tech not in seen:
        seen.add(tech)
        starts = {a for a, _ in TECHS[tech]["upgrades"]}
        previous = TECHS[tech]["prerequisite_technology"] or next(
            (tid for tid, record in TECHS.items() if tid not in seen and any(b in starts for _, b in record["upgrades"])), "")
        if previous in TECHS and _allowed(TECHS[previous], civ):
            return previous
        tech = previous if previous in TECHS else ""
    return None


def ground(raw: list, civ: str, age: int, origin: str = ROUTINE) -> Grounding:
    """Check an interpretation against the catalog and repair what can be repaired."""
    result = Grounding()
    chosen: dict[tuple, Mandate] = {}
    for item in raw if isinstance(raw, list) else []:
        if not isinstance(item, dict) or item.get("kind") not in KIND_DEPT:
            result.problems.append(f"kind {item.get('kind') if isinstance(item, dict) else item!r} 不在允许的九种里")
            continue
        kind, subject = item["kind"], str(item.get("subject") or "")
        amount = item.get("amount") if isinstance(item.get("amount"), int) and not isinstance(item.get("amount"), bool) else None
        amount = amount if amount and amount > 0 else None
        urgency = item.get("urgency") if item.get("urgency") in URGENCIES else "normal"
        if kind == "stockpile" and subject == "villager":
            kind = "worker_target"                           # villagers are the economy's, counted as a total
        if kind == "boost_resource":
            if subject not in RESOURCES:
                result.problems.append(f"boost_resource 的 subject 必须是 {'、'.join(RESOURCES)} 之一，不能是 {subject or '空'}")
                continue
            amount = None
        elif kind == "worker_target":
            if amount is None:
                result.problems.append("worker_target 需要 amount：村民总数")
                continue
            low, high = WORKER_RANGE
            if not low <= amount <= high:
                result.notes.append(f"村民目标 {amount} 超出范围，按 {max(low, min(high, amount))} 个执行")
                amount = max(low, min(high, amount))
            subject = ""
        elif kind == "stockpile":
            if subject not in UNITS:
                result.problems.append(f"stockpile 的 subject 必须是 names.units 里的 id，不能是 {subject or '空'}")
                continue
            if not _allowed(UNITS[subject], civ):
                replacement = _replacement_unit(subject, civ)
                if replacement is None:
                    result.problems.append(f"{civ_name(civ)}造不了 {subject}，也没有相近的兵种")
                    continue
                result.notes.append(f"{civ_name(civ)}造不了{name_of(subject)}，改为{name_of(replacement)}")
                subject = replacement
            if amount is None:
                result.notes.append(f"没有说数量，先按 {STOCKPILE_DEFAULT} 个")
                amount = STOCKPILE_DEFAULT
            elif amount > STOCKPILE_CAP:
                result.notes.append(f"{amount} 个超过一次指令的上限，按 {STOCKPILE_CAP} 个执行")
                amount = STOCKPILE_CAP
        elif kind == "research":
            if subject not in TECHS:
                result.problems.append(f"research 的 subject 必须是 names.techs 里的 id，不能是 {subject or '空'}")
                continue
            if not _allowed(TECHS[subject], civ):
                replacement = _replacement_tech(subject, civ)
                if replacement is None:
                    result.problems.append(f"{civ_name(civ)}不能研究 {subject}，这条升级线上也没有能研究的")
                    continue
                result.notes.append(f"{civ_name(civ)}不能研究{name_of(subject)}，改为{name_of(replacement)}")
                subject = replacement
            amount = None
        elif kind == "advance_age":
            target = max(1, min(3, amount if amount is not None else age + 1))
            if amount is not None and amount != target:
                result.notes.append(f"时代只到{AGE_NAMES[3]}，按{AGE_NAMES[target]}执行")
            amount, subject = target, ""
        else:                                                # attack, hold, fortify, scout
            amount, subject = None, ""
        mandate = Mandate(KIND_DEPT[kind], kind, subject or None, amount, urgency, origin)
        chosen.pop(slot(mandate), None)                      # said twice in one order: the later wording stands
        chosen[slot(mandate)] = mandate
    result.mandates = list(chosen.values())[:MAX_MANDATES]
    return result


NO_MANDATE = "grasp 不是 none 时，mandates 里至少要有一条任务书"


def ground_reading(grasp: str, raw: list, civ: str, age: int, origin: str = ROUTINE) -> Grounding:
    """Ground a model's reading of an order. Saying it understood and naming nothing to do is a problem too."""
    grounding = ground(raw, civ, age, origin)
    if grasp != "none" and not raw:
        grounding.problems.append(NO_MANDATE)
    return grounding


# ---------------------------------------------------------------------------- what a mandate needs first
def _researched(f, tech: str) -> bool:
    progression = f.obs.progression
    return bool(progression and progression.researched_technologies.get(tech))


def _owned(f, building: str) -> bool:
    return any(b.get("def_id") == building for b in f.buildings)


def _unlocking_tech(unit: str) -> str | None:
    """The technology that turns an earlier unit into this one, if it is the end of an upgrade step."""
    return next((tid for tid, record in TECHS.items() if any(b == unit for _, b in record["upgrades"])), None)


def prerequisites(mandate: Mandate, f) -> list[Mandate]:
    """What has to be there before a mandate can be carried out: the age, the research, the building.

    Each carries the mandate's origin and urgency, so the request it leads to
    is ranked with the order it serves."""
    needed: list[Mandate] = []
    child = lambda dept, kind, subject=None, amount=None: needed.append(Mandate(dept, kind, subject, amount, mandate.urgency, mandate.origin))
    builder = lambda building: "general" if building in MILITARY_BUILDINGS else "tech"
    if mandate.kind == "stockpile" and mandate.subject in UNITS:
        record = UNITS[mandate.subject]
        if int(record.get("required_age", 0)) > f.age:
            child("tech", "advance_age", amount=int(record["required_age"]))
        unlock = _unlocking_tech(mandate.subject)
        if unlock and not _researched(f, unlock):
            child("tech", "research", unlock)
        producer = record.get("train_at")
        if producer and not _owned(f, producer):
            child(builder(producer), BUILD, producer)
    elif mandate.kind == "research" and mandate.subject in TECHS:
        record = TECHS[mandate.subject]
        if record["required_age"] > f.age:
            child("tech", "advance_age", amount=record["required_age"])
        before = record["prerequisite_technology"]
        if before in TECHS and not _researched(f, before):
            child("tech", "research", before)
        if record["research_at"] and not _owned(f, record["research_at"]):
            child(builder(record["research_at"]), BUILD, record["research_at"])
    return needed


def needs_of(mandate: Mandate, f) -> tuple[str, ...]:
    """The same, as the short words a blocked request shows."""
    return tuple(f"age_{m.amount}" if m.kind == "advance_age" else f"{m.kind}:{m.subject}" for m in prerequisites(mandate, f))


def derive(mandates: list[Mandate], f) -> list[Mandate]:
    """The mandates, each followed by what it still needs, and that by what it needs in turn.

    Standing mandates are not expanded: the departments already plan their own
    ages and buildings."""
    result: list[Mandate] = []
    seen: set[tuple] = set()

    def add(mandate: Mandate) -> None:
        if slot(mandate) in seen:
            return
        seen.add(slot(mandate))
        result.append(mandate)
        if mandate.origin != ROUTINE and f.progression_enabled:
            for needed in prerequisites(mandate, f):
                add(needed)

    for mandate in mandates:
        add(mandate)
    return result


# ---------------------------------------------------------------------------- standing mandates and the policy script
def default_mandates(profile) -> list[Mandate]:
    """The civilization profile as standing mandates."""
    mandates = [Mandate("economy", "worker_target", amount=max(MIN_WORKER_TARGET, int(profile.villager_target))),
                Mandate("general", "stockpile", amount=max(2, min(24, int(profile.military_attack_count))))]
    for unit, count in profile.army_composition.items():
        if isinstance(count, int) and count > 0:
            mandates.append(Mandate("general", "stockpile", subject=str(unit), amount=count))
    return mandates


WHEN = re.compile(r"^(start|age>=([0-3])|done:([1-9][0-9]?))$")


def policy_origin(number: int) -> str:
    return f"policy#{number}"


def load_policy(entries, civ: str) -> list[dict]:
    """A national policy script, checked once when the match starts.

    Each entry is a mandate with a `when`: "start", "age>=N" or "done:K" (the
    K-th entry, counting from 1, has been carried out). An entry the catalog
    does not allow is refused here, loudly, and not at some later minute of a
    match."""
    script = []
    for number, entry in enumerate(entries if isinstance(entries, list) else [], 1):
        if not isinstance(entry, dict) or not WHEN.match(str(entry.get("when", ""))):
            raise ValueError(f"national_policy entry {number}: when must be start, age>=N or done:K")
        when = WHEN.match(entry["when"])
        if when.group(3) and int(when.group(3)) >= number:
            raise ValueError(f"national_policy entry {number}: done:{when.group(3)} must name an earlier entry")
        if entry.get("dept") not in (None, KIND_DEPT.get(entry.get("kind"))):
            raise ValueError(f"national_policy entry {number}: {entry.get('kind')} is not a task of {entry.get('dept')}")
        grounded = ground([entry], civ, 0, policy_origin(number))
        if grounded.problems or grounded.notes or len(grounded.mandates) != 1:
            raise ValueError(f"national_policy entry {number}: {'; '.join(grounded.problems + grounded.notes) or 'not a mandate'}")
        script.append({"when": entry["when"], "mandate": grounded.mandates[0], "number": number})
    return script


def policy_entries(script: list[dict], age: int, done: set[int]) -> list[dict]:
    """The entries of a policy script whose time has come and that are not carried out yet."""
    active = []
    for entry in script:
        when = WHEN.match(entry["when"])
        if entry["number"] in done or when.group(2) and age < int(when.group(2)) or when.group(3) and int(when.group(3)) not in done:
            continue
        active.append(entry)
    return active


# ---------------------------------------------------------------------------- how far a mandate has got
def progress(mandate: Mandate, f, engine, since: float = 0.0) -> tuple[bool, str]:
    """Whether a mandate has been carried out, and a short figure for the ledger."""
    if mandate.kind == "stockpile" and mandate.amount:
        family = {mandate.subject} | later_forms(mandate.subject) if mandate.subject else None
        have = sum(u.get("def_id") != "villager" and (family is None or u.get("def_id") in family) for u in f.units)
        return have >= mandate.amount, f"{have}/{mandate.amount}"
    if mandate.kind == "worker_target" and mandate.amount:
        have = sum(u.get("def_id") == "villager" for u in f.units)
        return have >= mandate.amount, f"{have}/{mandate.amount}"
    if mandate.kind == "advance_age" and mandate.amount is not None:
        return f.age >= mandate.amount, AGE_NAMES[min(3, f.age)]
    if mandate.kind == "research":
        return _researched(f, mandate.subject), ""
    if mandate.kind == BUILD:
        return any(b.get("def_id") == mandate.subject and b.get("is_complete") for b in f.buildings), ""
    if mandate.kind == "attack":
        departed = engine.goals.get("sortie_departed")
        return departed is not None and departed >= since, ""
    return False, ""                                         # standing: boost, hold, fortify, scout
