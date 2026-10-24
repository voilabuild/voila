"""In-memory voila registry (doc/registry/openapi.yaml) for end-to-end tests.

Standalone: uv run uvicorn registry:app --port 7423
"""

from collections import Counter
from dataclasses import dataclass, field

from fastapi import FastAPI, Request, Response
from pydantic import BaseModel


@dataclass
class State:
    chunks: dict[str, bytes] = field(default_factory=dict[str, bytes])
    images: dict[str, bytes] = field(default_factory=dict[str, bytes])
    chunk_gets: Counter[str] = field(default_factory=Counter[str])
    chunk_puts: Counter[str] = field(default_factory=Counter[str])


class MissingRequest(BaseModel):
    ids: list[str] = []


class MissingResponse(BaseModel):
    missing: list[str]


state = State()
app = FastAPI()


@app.get("/registry/v1/registry/config")
def config() -> dict[str, str]:
    return {}


@app.get("/registry/v1/chunks/{chunk_id}")
def get_chunk(chunk_id: str) -> Response:
    # Stored as uploaded (possibly zstd); the client sniffs the magic and verifies the id.
    body = state.chunks.get(chunk_id)
    if body is None:
        return Response(status_code=404)
    state.chunk_gets[chunk_id] += 1
    return Response(body, media_type="application/octet-stream")


@app.put("/registry/v1/chunks/{chunk_id}")
async def put_chunk(chunk_id: str, request: Request) -> Response:
    existed = chunk_id in state.chunks
    state.chunks[chunk_id] = await request.body()
    state.chunk_puts[chunk_id] += 1
    return Response(status_code=200 if existed else 201)


@app.post("/registry/v1/chunks/missing")
def missing(req: MissingRequest) -> MissingResponse:
    return MissingResponse(missing=[i for i in req.ids if i not in state.chunks])


@app.get("/registry/v1/images/{ref:path}")
def get_image(ref: str) -> Response:
    body = state.images.get(ref)
    if body is None:
        return Response(status_code=404)
    return Response(body, media_type="application/json")


@app.put("/registry/v1/images/{ref:path}")
async def put_image(ref: str, request: Request) -> Response:
    state.images[ref] = await request.body()
    return Response(status_code=201)
