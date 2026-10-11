"""Read-only observation tools served through the official MCP SDK over stdio."""
from mcp.server import MCPServer

from .database import SessionLocal
from .services import retrieval

server = MCPServer('PetMind records')


@server.tool()
def search_observations(pet_id: str, before: str, query: str, days: int = 7, limit: int = 5,
                        start: str | None = None, semantic: bool = False) -> dict:
    """Search earlier observations for exactly one pet; synthetic inputs are labeled."""
    with SessionLocal() as db:
        return retrieval.search_result(db, pet_id, before, query, days, limit, start, semantic)


@server.tool()
def get_observation_stats(pet_id: str, before: str, days: int = 7, start: str | None = None) -> dict:
    """Aggregate earlier observation windows for one pet; return sample counts."""
    with SessionLocal() as db:
        return retrieval.get_observation_stats(db, pet_id, before, days, start)


@server.tool()
def get_care_history(pet_id: str, before: str, limit: int = 5, start: str | None = None) -> dict:
    """Read earlier suggestions and device outcomes for one pet."""
    with SessionLocal() as db:
        return {'history': retrieval.get_care_history(db, pet_id, before, limit, start)}


if __name__ == '__main__':
    server.run(transport='stdio')
