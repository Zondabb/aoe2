from __future__ import annotations

from dataclasses import dataclass, field

from protocol.models import Command, DebugEntry


@dataclass
class CommandContext:
    tick: int
    commands: list[Command] = field(default_factory=list)
    debug: list[DebugEntry] = field(default_factory=list)
    _seq: int = 0

    def log_decision(self, category: str, message: str) -> None:
        self.debug.append(DebugEntry(category=category, message=message))

    def issue_gather(self, villager_id: int, resource_id: int) -> None:
        self._push(
            Command(
                command_id=self._next_id(),
                op="gather",
                unit_id=villager_id,
                target_id=resource_id,
            )
        )

    def issue_train(self, building_id: int, unit_def_id: str) -> None:
        self._push(
            Command(
                command_id=self._next_id(),
                op="train",
                building_id=building_id,
                unit_def_id=unit_def_id,
            )
        )

    def _next_id(self) -> str:
        command_id = f"c_{self.tick}_{self._seq}"
        self._seq += 1
        return command_id

    def _push(self, command: Command) -> None:
        self.commands.append(command)
