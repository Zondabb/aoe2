from __future__ import annotations

from dataclasses import dataclass, field

from protocol.models import Command, DebugEntry


@dataclass
class CommandContext:
    tick: int
    commands: list[Command] = field(default_factory=list)
    debug: list[DebugEntry] = field(default_factory=list)
    next_build_slot: int = 0
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

    def issue_move(self, unit_id: int, pos: list[float]) -> None:
        self._push(
            Command(
                command_id=self._next_id(),
                op="move",
                unit_id=unit_id,
                pos=pos,
            )
        )

    def issue_attack(self, unit_id: int, target_id: int) -> None:
        self._push(
            Command(
                command_id=self._next_id(),
                op="attack",
                unit_id=unit_id,
                target_id=target_id,
            )
        )

    def issue_build(self, villager_id: int, building_id: int) -> None:
        self._push(
            Command(
                command_id=self._next_id(),
                op="build",
                unit_id=villager_id,
                building_id=building_id,
            )
        )

    def issue_place_building(
        self,
        building_def_id: str,
        pos: list[float],
        builder_id: int | None = None,
    ) -> None:
        cmd = Command(
            command_id=self._next_id(),
            op="place_building",
            building_def_id=building_def_id,
            pos=pos,
        )
        if builder_id is not None:
            cmd.builder_id = builder_id
        self._push(cmd)
        self.next_build_slot += 1

    def _next_id(self) -> str:
        command_id = f"c_{self.tick}_{self._seq}"
        self._seq += 1
        return command_id

    def _push(self, command: Command) -> None:
        self.commands.append(command)
