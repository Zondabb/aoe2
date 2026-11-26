"""Team-local source releases, worker handoff and durable commit boundaries.

Version one supports additive department state and a linear chain of bills.
Clearing the player instruction window conservatively revokes that whole chain;
appending new instructions does not interrupt unrelated bills.
"""
from __future__ import annotations

import copy
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import math
from pathlib import Path
import threading

from .process import WorkerClient, WorkerError
from .releases import ReleaseStore
from .store import SessionStore
from .agent import CodingSession


def fingerprint(req):
    return hashlib.sha256(json.dumps(req.model_dump(), sort_keys=True, allow_nan=False,
                                    separators=(",", ":")).encode()).hexdigest()


class LegislativeRuntime:
    planning_roles = ("premier", "premier_orders", "legislative_council")

    def __init__(self, profile_id="default", *, root, mode="docker", image="", timeout=5.0):
        self.profile = profile_id
        self.store = ReleaseStore(Path(root) / "source")
        self.sessions = SessionStore(root)
        self.base = self.store.bootstrap()
        self.release = self.base
        self.options = dict(mode=mode, image=image, timeout=timeout)
        self.worker = self._start(self.release)
        self.state = self.worker.checkpoint
        self.identity = None
        self.instructions = ()
        self.last_seq, self.last_time, self.event = -1, -1.0, 0
        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="legislation-build")
        self._lock = threading.RLock()
        self._candidate = None
        self._job = None
        self._request = None
        self._coding = None
        self._progress_key = None
        self._generation = 0
        self._pending_tick = None
        self._journal = []
        self._failed = []
        self._closed = False

    def _start(self, release):
        return WorkerClient(self.store.path(release), self.profile, **self.options)

    def _restore(self, worker, state, release):
        fields = []
        current = release
        while current:
            manifest = self.store.manifest(current)
            proposal = manifest.get("proposal") or {}
            fields = proposal.get("state_fields", []) + fields
            current = manifest.get("parent")
        worker.call("restore", state, self.profile, fields)

    def bind_session(self, req):
        identity = json.dumps([req.metadata.match_id, req.metadata.team,
                               req.metadata.session_epoch, self.profile], separators=(",", ":"))
        if self.identity and self.identity != identity:
            raise WorkerError("worker_session_changed")
        if self.identity:
            return
        self.identity = identity
        record = self.sessions.load(identity)
        if record:
            worker = self._start(record["release"])
            try:
                self._restore(worker, record["state"], record["release"])
            except BaseException:
                worker.close()
                raise
            self.worker.close()
            self.worker = worker
            self.base, self.release, self.state = record["base"], record["release"], record["state"]
            self.last_seq, self.last_time, self.event = record["seq"], record["time"], record["event"]
            self.instructions = tuple(record["instructions"])
            saved = record.get("coding")
            if saved and saved["base_release"] == self.release:
                self._coding = CodingSession(self.store, saved["requirement"], self.release, saved["data"])
                if self._coding.status in {"validating", "ready"}:
                    self._coding.data.update(status="coding", feedback={
                        "message": "Service resumed; drafts preserved. Submit finish again to revalidate."})

    def _record(self):
        return dict(base=self.base, release=self.release, state=self.state, seq=self.last_seq,
                    time=self.last_time, event=self.event, instructions=list(self.instructions),
                    coding=self._coding.snapshot() if self._coding else None)

    def _save_coding(self):
        if self.identity and self._pending_tick is None and not self._closed:
            self.sessions.save(self.identity, self._record())

    def _coding_progress(self):
        """Only the foreground calls the active worker; builders update host state."""
        coding = self._coding
        if not coding:
            return
        proposal_id = coding.requirement["proposal_id"]
        reason = str(coding.data["feedback"].get("error", coding.data["feedback"].get("reason", "")))[:500]
        key = (proposal_id, coding.status, coding.data["steps"], coding.data["failures"], reason)
        if key == self._progress_key:
            return
        if coding.status in {"failed", "blocked"}:
            if not coding.data.get("reported"):
                self._call("legislation_result", proposal_id, "failed", reason or "coding_step_limit")
                coding.data["reported"] = True
        elif coding.status in {"coding", "validating", "ready"}:
            phase = "retrying" if coding.data["failures"] else coding.status
            self._call("legislation_progress", proposal_id, phase, reason, coding.data["steps"])
        self._progress_key = key

    def cached_response(self, req):
        return self.sessions.response(self.identity, req.metadata.tick, fingerprint(req))

    def commit_response(self, req, response):
        with self._lock:
            previous = self.last_seq, self.last_time, self.event
            self.last_seq, self.last_time = req.metadata.tick, req.metadata.time_sec
            self.state = self.worker.checkpoint
            self.event += 1
            try:
                self.sessions.save(self.identity, self._record(), (self.last_seq, fingerprint(req), response))
            except BaseException:
                self.last_seq, self.last_time, self.event = previous
                raise
            self._pending_tick = None

    def _call(self, method, *args):
        try:
            result = self.worker.call(method, *args)
        except WorkerError:
            self.worker.close()
            worker = self._start(self.release)
            try:
                self._restore(worker, self.state, self.release)
                result = worker.call(method, *args)
            except BaseException:
                worker.close()
                raise
            self.worker = worker
        self.state = self.worker.checkpoint
        self.event += 1
        if self.identity and self._pending_tick is None:
            self.sessions.save(self.identity, self._record())
        return result

    @property
    def goals(self):
        return self._call("properties")["goals"]

    @property
    def match_summary(self):
        return self._call("properties")["match_summary"]

    def load_strategic_memory(self, snapshot):
        self._call("load_strategic_memory", snapshot)

    def planning_interval(self, role):
        if role == "legislative_council":
            return 30 if self._coding and self._coding.data["failures"] else 0
        interval = self._call("planning_interval", role)
        return math.inf if interval is None else interval

    def planning_context(self, role):
        if role == "legislative_council":
            coding = self._coding
            return {"goals": self.goals, "plan_version": self.release, "goal_version": self.event,
                    "legislation_phase": coding.status if coding else "waiting",
                    "legislation_step": coding.data["steps"] if coding else 0,
                    "active_proposal_id": coding.requirement["proposal_id"]
                                          if coding and coding.status == "coding" else None}
        return self._call("planning_context", role)

    def planning_brief(self, role):
        if role != "legislative_council":
            return self._call("planning_brief", role)
        with self._lock:
            self._coding_progress()
            if self._job and not self._job.done() or self._candidate:
                return None
            requests = self._call("legislative_requests")
            if not requests:
                if self._coding and self._coding.status not in {"installed", "failed", "blocked"}:
                    self._coding = None
                    self._request = None
                    self._progress_key = None
                    self._save_coding()
                return None
            self._request = copy.deepcopy(requests[0])
            if (not self._coding or self._coding.base != self.release
                    or self._coding.requirement["proposal_id"] != self._request["proposal_id"]):
                self._coding = CodingSession(self.store, self._request, self.release)
            if self._coding.status != "coding":
                return None
            try:
                brief = self._coding.brief()
            except ValueError as exc:
                self._coding.data.update(status="failed", feedback={"error": str(exc)})
                self._coding_progress()
                self._save_coding()
                return None
            self._save_coding()
            return brief

    def plan_rejected(self, role, reason, response=None):
        if role != "legislative_council":
            return self._call("plan_rejected", role, reason, response)
        with self._lock:
            if not self._coding or self._coding.status != "coding":
                return False
            self._coding.reject(reason)
            self._coding_progress()
            self._save_coding()
            return True

    def planning_feedback(self, role, feedback):
        if role == "legislative_council":
            with self._lock:
                if self._coding and self._coding.status == "coding":
                    self._coding.data["feedback"]["tool_selection"] = copy.deepcopy(feedback)
                    self._save_coding()

    def apply_plan(self, role, plan):
        if role != "legislative_council":
            return self._call("apply_plan", role, plan)
        with self._lock:
            if (not self._request or plan.get("proposal_id") != self._request["proposal_id"]
                    or plan.get("base_release") != self.release or self._candidate
                    or self._job and not self._job.done()):
                return False
            coding = None
            if "action" in plan:
                coding = self._coding
                if not coding or coding.status != "coding":
                    return False
                try:
                    proposal = coding.apply(plan)
                except Exception as exc:
                    coding.reject(str(exc))
                    proposal = None
                self._coding_progress()
                self._save_coding()
                if proposal is None:
                    return coding.status != "failed" and not coding.data["failures"]
            else:
                # Retained for trusted callers and release regression tests. The
                # model-facing contract only exposes legislative_step.
                proposal = plan
            self._job = self._pool.submit(self._prepare, copy.deepcopy(proposal), self.release,
                                          copy.deepcopy(self.state), self._generation, coding)
            return True

    def _prepare(self, proposal, base, state, generation, coding=None):
        worker = None
        try:
            release = self.store.build(base, proposal)
            worker = self._start(release)
            self._restore(worker, state, release)
            # Exercise backward projection before permitting a mid-match install.
            from brain.cabinet.runtime import CabinetRuntime
            from .checkpoint import restore_checkpoint
            restore_checkpoint(worker.checkpoint, CabinetRuntime(self.profile))
            with self._lock:
                if self._closed or base != self.release or generation != self._generation:
                    worker.close()
                    return
                self._candidate = (release, worker, proposal["proposal_id"], base, generation)
                if coding is self._coding and coding is not None:
                    coding.data["status"] = "ready"
                    self._save_coding()
                worker = None
        except Exception as exc:
            with self._lock:
                if self._closed or base != self.release or generation != self._generation:
                    return
                if coding is self._coding and coding is not None:
                    coding.reject("candidate_validation_failed: " + str(exc)[:300])
                    self._save_coding()
                else:
                    self._failed.append((proposal.get("proposal_id"), str(exc)[:300]))
                self._journal.append(("legislation_failed", {"proposal_id": proposal.get("proposal_id"),
                                                            "reason": str(exc)[:300]}))
        finally:
            if worker:
                worker.close()

    def _validate(self, req, result, checkpoint, previous):
        # The validation runs with host code, never the candidate's validators.
        from brain.cabinet.orders import TOWER_LINE, default_mandates, load_policy
        from brain.cabinet.runtime import CabinetRuntime
        from .checkpoint import restore_checkpoint
        from protocol.models import Command
        current = restore_checkpoint(checkpoint, CabinetRuntime(self.profile))
        if current.field.last_tick != req.metadata.tick or current.field.last_req.model_dump() != req.model_dump():
            raise WorkerError("checkpoint_input_mismatch")
        before = restore_checkpoint(previous, CabinetRuntime(self.profile))
        f = before.field.kernel.begin(req)
        if any(isinstance(raw, dict) and raw.get("op") == "place_building"
               and raw.get("building_def_id") in TOWER_LINE for raw in result.get("commands", [])):
            trusted = restore_checkpoint(previous, CabinetRuntime(self.profile))
            tf = trusted.field._open_frame(req)
            if trusted.policy is None:
                profile = trusted.field.validator.profile
                trusted.policy = load_policy(list(profile.national_policy), profile.civ_id)
                if trusted.mandates is None:
                    trusted.mandates = [] if trusted.policy else default_mandates(profile)
            trusted.ledger.intake(tf.obs.player_instructions, trusted.field.now)
            trusted.defense.update(tf, trusted._mandates(tf), trusted.brief)
            if trusted.defense.tower_order is not None:
                trusted.defense._draft_towers(tf)
                tower_defs = {k: v for k, v in tf.building_defs.items() if k in TOWER_LINE}
                if tower_defs:
                    f.building_defs = {**f.building_defs, **tower_defs}
                tower_sites = [o for o in tf.context.get("construction_options", [])
                               if isinstance(o, dict) and o.get("building_def_id") in TOWER_LINE]
                if tower_sites:
                    offered = f.context.get("construction_options", [])
                    if not any(isinstance(o, dict) and o.get("building_def_id") in TOWER_LINE for o in offered):
                        f.context = {**f.context, "construction_options": [*offered, *tower_sites]}
        if current.field.kernel._last_event_seq != before.field.kernel._last_event_seq:
            raise WorkerError("fabricated_event_cursor")
        if current.field.validator.profile != before.field.validator.profile:
            raise WorkerError("profile_changed")
        for dept, old in zip(current.departments, before.departments):
            if dept._serial < old._serial:
                raise WorkerError("request_serial_regressed")
        request_ids = [r.id for r in current.requests]
        if len(set(request_ids)) != len(request_ids):
            raise WorkerError("duplicate_request_id")
        for demand in current.requests:
            if demand.dept not in {"economy", "general", "defense", "tech", "intel"}:
                raise WorkerError("invalid_request_department")
            for amounts in (demand.tranche, demand.remaining):
                if any(key not in {"wood", "food", "gold", "stone"} or type(value) not in (int, float)
                       or not math.isfinite(value) or value < 0 for key, value in amounts.items()):
                    raise WorkerError("invalid_request_cost")
        before.treasury.observe(req.metadata.time_sec, {r: float(getattr(req.observation.economy, r))
                                                       for r in ("food", "wood", "gold", "stone")})
        tiers = before.premier.rank(current.requests, current.brief, req.metadata.time_sec)
        before.treasury.allocate(f.budget, current.requests, tiers, req.metadata.time_sec)
        if before.treasury.granted != current.treasury.granted:
            raise WorkerError("invalid_treasury_grants")
        seen = set()
        spent = {r: 0.0 for r in ("food", "wood", "gold", "stone")}
        for index, raw in enumerate(result["commands"]):
            command = Command.model_validate(raw)
            if command.command_id != f"ma_{req.metadata.session_epoch}_{req.metadata.tick}_{index}":
                raise WorkerError("invalid_command_id")
            if not command.command_id or command.command_id in seen or command.command_id in before.field.kernel.tasks:
                raise WorkerError("duplicate_command_id")
            seen.add(command.command_id)
            actor = raw.get("unit_id", raw.get("builder_id", raw.get("building_id")))
            lease = before.field.kernel.leases.get(actor, {})
            if lease.get("role") == "human" and lease.get("until", 0) > req.metadata.time_sec:
                raise WorkerError("human_lease_violation")
            task = current.field.kernel.tasks.get(command.command_id)
            if not task or task["command"] != raw or current.field.pending.get(command.command_id) is not task:
                raise WorkerError("missing_command_task")
            if task["role"] not in before.field.roles:
                raise WorkerError("invalid_command_role")
            budget = dict(f.budget)
            if not f.add(command.op, raw, "legislation_validator"):
                raise WorkerError("invalid_worker_command")
            cost = {r: budget[r] - f.budget[r] for r in budget if budget[r] > f.budget[r]}
            if task["cost"] != cost:
                raise WorkerError("fabricated_command_cost")
            for r, value in cost.items():
                spent[r] += value
        for task_id, task in current.field.kernel.tasks.items():
            if task_id in seen:
                continue
            old = before.field.kernel.tasks.get(task_id)
            if not old or any(task.get(k) != old.get(k) for k in ("id", "command", "cost", "population", "issued_at")):
                raise WorkerError("fabricated_task_history")
        for resource, amount in spent.items():
            actual = sum(current.treasury.spent(rid).get(resource, 0) for rid in request_ids)
            if abs(actual - amount) > 1e-6:
                raise WorkerError("unaccounted_treasury_spend")

    def tick(self, req):
        with self._lock:
            self.bind_session(req)
            if self._pending_tick:
                old, result = self._pending_tick
                if old == fingerprint(req):
                    return copy.deepcopy(result)
                raise WorkerError("uncommitted_tick")
            instructions = tuple(req.observation.player_instructions)
            for proposal_id, reason in self._failed:
                self._call("legislation_result", proposal_id, "failed", reason)
            self._failed.clear()
            if instructions != self.instructions:
                if not instructions:
                    self._generation += 1
                    if self._candidate:
                        self._candidate[1].close()
                        self._candidate = None
                    self._request = None
                    self._coding = None
                    self._progress_key = None
                    if self.release != self.base:
                        replacement = self._start(self.base)
                        try:
                            self._restore(replacement, self.state, self.base)
                            replacement.call("retire_bills", "revoked", "instruction_window_changed")
                        except BaseException:
                            replacement.close()
                            raise
                        self.worker.close()
                        self.worker, self.release = replacement, self.base
                        self.state = replacement.checkpoint
                        self._journal.append(("legislation_revoked", {"reason": "instruction_window_changed"}))
                self.instructions = instructions
            self._coding_progress()
            previous = self.state
            active, release = self.worker, self.release
            candidate = self._candidate
            if candidate:
                self._candidate = None
                release, active, proposal_id, base, generation = candidate
                if base != self.release or generation != self._generation:
                    active.close()
                    active, release, candidate = self.worker, self.release, None
            try:
                if candidate:
                    self._restore(active, previous, release)
                    if not active.call("legislation_result", proposal_id, "installed", "source_release_ready"):
                        active.close()
                        active, release, candidate = self.worker, self.release, None
                result = active.call("tick", req.model_dump())
                self._validate(req, result, active.checkpoint, previous)
            except Exception as exc:
                if active is not self.worker:
                    active.close()
                    active, release = self.worker, self.release
                else:
                    active.close()
                    active, release = self._start(self.base), self.base
                self._restore(active, previous, release)
                if release == self.base:
                    active.call("retire_bills", "failed", "source_rolled_back")
                if candidate:
                    if self._coding and self._coding.requirement["proposal_id"] == proposal_id:
                        self._coding.reject("candidate_tick_failed: " + str(exc)[:300])
                        if self._coding.status == "coding":
                            active.call("legislation_progress", proposal_id, "retrying",
                                        self._coding.data["feedback"]["error"], self._coding.data["steps"])
                        else:
                            active.call("legislation_result", proposal_id, "failed", "candidate_tick_failed")
                    else:
                        active.call("legislation_result", proposal_id, "failed", "candidate_tick_failed")
                elif self._coding:
                    self._coding.data.update(status="failed", feedback={"error": "source_rolled_back"})
                result = active.call("tick", req.model_dump())
                self._validate(req, result, active.checkpoint, previous)
                self._journal.append(("legislation_rollback", {"reason": str(exc)[:300], "release": release}))
            else:
                if candidate:
                    if self._coding:
                        self._coding.data["status"] = "installed"
                    self._journal.append(("legislation_installed", {"proposal_id": proposal_id,
                                                                   "release": release, "effective_seq": req.metadata.tick}))
            if active is not self.worker:
                self.worker.close()
            self.worker, self.release = active, release
            self.state = active.checkpoint
            result.setdefault("planning", {})["legislation"] = {"release": release, "effective_seq": req.metadata.tick}
            if self._coding:
                result["planning"]["legislation"].update(
                    proposal_id=self._coding.requirement["proposal_id"], phase=self._coding.status,
                    step=self._coding.data["steps"], reason=str(self._coding.data["feedback"].get(
                        "error", self._coding.data["feedback"].get("reason", "")))[:500])
            self._pending_tick = fingerprint(req), copy.deepcopy(result)
            return result

    def take_journal(self):
        result, self._journal = self._journal, []
        return result + self._call("take_journal")

    def close(self):
        with self._lock:
            self._closed = True
            self.worker.close()
            if self._candidate:
                self._candidate[1].close()
                self._candidate = None
        self._pool.shutdown(wait=False, cancel_futures=True)
