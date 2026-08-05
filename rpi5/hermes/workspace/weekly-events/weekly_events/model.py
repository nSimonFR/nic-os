from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any

FIELDS = (
    "source_id", "external_id", "title", "games", "description", "start_at", "end_at",
    "timezone", "venue", "city", "organizer", "price", "capacity", "registered",
    "remaining_seats", "registration_url", "event_url", "calendar_url", "status", "content_hash",
)


@dataclass(frozen=True)
class Event:
    source_id: str
    external_id: str
    title: str
    games: list[str] = field(default_factory=list)
    description: str | None = None
    start_at: str | None = None
    end_at: str | None = None
    timezone: str | None = None
    venue: str | None = None
    city: str | None = None
    organizer: str | None = None
    price: str | None = None
    capacity: int | None = None
    registered: int | None = None
    remaining_seats: int | None = None
    registration_url: str | None = None
    event_url: str | None = None
    calendar_url: str | None = None
    status: str = "scheduled"
    content_hash: str = ""

    @property
    def key(self) -> str:
        return f"{self.source_id}:{self.external_id}"

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "Event":
        return cls(**{key: value.get(key) for key in FIELDS})
