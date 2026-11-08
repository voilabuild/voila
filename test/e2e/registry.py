"""In-memory voila registry (doc/registry/openapi.yaml) for end-to-end tests.

Standalone: uv run uvicorn registry:app --port 7423
"""

import asyncio
import time
from collections.abc import AsyncIterator
from collections import Counter
from dataclasses import dataclass, field

from fastapi import FastAPI, Request, Response
from fastapi.responses import StreamingResponse
from pydantic import BaseModel


@dataclass
class State:
    chunks: dict[str, bytes] = field(default_factory=dict[str, bytes])
    images: dict[str, bytes] = field(default_factory=dict[str, bytes])
    chunk_gets: Counter[str] = field(default_factory=Counter[str])
    chunk_puts: Counter[str] = field(default_factory=Counter[str])
    put_delay_ms: float = 0
    config_delay_ms: float = 0
    # Every chunk GET waits this long before answering.
    chunk_delay_ms: float = 0
    # Chunks bigger than this are sent slowly (4 KiB every 0.5 s), slower than the
    # client's request timeout allows for a 1 MiB chunk.
    trickle_over_bytes: int | None = None
    # Like registry.voila.build: decode zstd uploads and store (and serve) raw bytes.
    decode_uploads: bool = False
    inflight: int = 0
    max_inflight: int = 0


class MissingRequest(BaseModel):
    ids: list[str] = []


class MissingResponse(BaseModel):
    missing: list[str]


state = State()
app = FastAPI()


@app.get("/registry/v1/registry/config")
async def config() -> dict[str, str]:
    if state.config_delay_ms > 0:
        await asyncio.sleep(state.config_delay_ms / 1000)
    return {}


@app.get("/registry/v1/chunks/{chunk_id}")
def get_chunk(chunk_id: str) -> Response:
    # Stored as uploaded (possibly zstd); the client sniffs the magic and verifies the id.
    body = state.chunks.get(chunk_id)
    if body is None:
        return Response(status_code=404)
    state.chunk_gets[chunk_id] += 1
    if state.chunk_delay_ms > 0:
        time.sleep(state.chunk_delay_ms / 1000)  # sync handler: runs on a worker thread
    limit = state.trickle_over_bytes
    if limit is not None and len(body) > limit:
        return StreamingResponse(trickle(body), media_type="application/octet-stream", headers={"Content-Length": str(len(body))})
    return Response(body, media_type="application/octet-stream")


async def trickle(body: bytes) -> AsyncIterator[bytes]:
    for i in range(0, len(body), 4096):
        yield body[i : i + 4096]
        await asyncio.sleep(0.5)


@app.put("/registry/v1/chunks/{chunk_id}")
async def put_chunk(chunk_id: str, request: Request) -> Response:
    state.inflight += 1
    state.max_inflight = max(state.max_inflight, state.inflight)
    try:
        if state.put_delay_ms > 0:
            await asyncio.sleep(state.put_delay_ms / 1000)
        existed = chunk_id in state.chunks
        body = await request.body()
        if state.decode_uploads and request.headers.get("content-encoding") == "zstd":
            from compression import zstd  # Python 3.14+; tests that set this skip otherwise

            body = zstd.decompress(body)
        state.chunks[chunk_id] = body
        state.chunk_puts[chunk_id] += 1
        return Response(status_code=200 if existed else 201)
    finally:
        state.inflight -= 1


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
