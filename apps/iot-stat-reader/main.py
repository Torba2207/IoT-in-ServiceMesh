from contextlib import asynccontextmanager
from typing import Optional
import asyncio
import os

import asyncpg
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import StreamingResponse


DB_DSN = (
    f"postgresql://{os.getenv('DB_USER', 'chirpstack')}"
    f":{os.getenv('DB_PASSWORD', 'chirpstack')}"
    f"@{os.getenv('DB_HOST', 'postgres')}"
    f":{os.getenv('DB_PORT', '5432')}"
    f"/{os.getenv('DB_NAME', 'chirpstack')}"
)

pool: asyncpg.Pool = None
_sse_clients: set[asyncio.Queue] = set()


def _broadcast_uplink(conn, pid, channel, payload):
    for q in _sse_clients.copy():
        q.put_nowait(payload)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global pool
    pool = await asyncpg.create_pool(DB_DSN, min_size=1, max_size=5)

    listen_conn = await asyncpg.connect(DB_DSN)
    await listen_conn.add_listener("new_uplink", _broadcast_uplink)

    yield

    await listen_conn.remove_listener("new_uplink", _broadcast_uplink)
    await listen_conn.close()
    await pool.close()


app = FastAPI(title="IoT Stat Reader", version="1.0.0", lifespan=lifespan)


@app.get("/health")
async def health():
    async with pool.acquire() as conn:
        await conn.fetchval("SELECT 1")
    return {"status": "ok"}


@app.get("/tenants")
async def get_tenants():
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            "SELECT id, name, description, created_at, updated_at FROM tenant ORDER BY name"
        )
    return [dict(r) for r in rows]


@app.get("/applications")
async def get_applications(tenant_id: Optional[str] = None):
    query = """
        SELECT a.id, a.name, a.description, a.created_at, t.name AS tenant_name
        FROM application a
        JOIN tenant t ON t.id = a.tenant_id
    """
    params = []
    if tenant_id:
        query += " WHERE a.tenant_id = $1::uuid"
        params.append(tenant_id)
    query += " ORDER BY a.name"

    async with pool.acquire() as conn:
        rows = await conn.fetch(query, *params)
    return [dict(r) for r in rows]


@app.get("/devices")
async def get_devices(application_id: Optional[str] = None):
    query = """
        SELECT
            encode(d.dev_eui, 'hex') AS dev_eui,
            d.name,
            d.description,
            d.last_seen_at,
            d.is_disabled,
            d.latitude,
            d.longitude,
            d.battery_level,
            d.dr AS data_rate,
            a.name AS application_name
        FROM device d
        JOIN application a ON a.id = d.application_id
    """
    params = []
    if application_id:
        query += " WHERE d.application_id = $1::uuid"
        params.append(application_id)
    query += " ORDER BY d.name"

    async with pool.acquire() as conn:
        rows = await conn.fetch(query, *params)
    return [dict(r) for r in rows]


@app.get("/devices/{dev_eui}")
async def get_device(dev_eui: str):
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            """
            SELECT
                encode(d.dev_eui, 'hex') AS dev_eui,
                d.name,
                d.description,
                d.created_at,
                d.updated_at,
                d.last_seen_at,
                d.is_disabled,
                d.latitude,
                d.longitude,
                d.altitude,
                d.battery_level,
                d.dr AS data_rate,
                d.enabled_class,
                d.tags,
                a.name AS application_name,
                dp.name AS device_profile_name
            FROM device d
            JOIN application a ON a.id = d.application_id
            JOIN device_profile dp ON dp.id = d.device_profile_id
            WHERE d.dev_eui = decode($1, 'hex')
            """,
            dev_eui.lower(),
        )
    if not row:
        raise HTTPException(status_code=404, detail="Device not found")
    return dict(row)


@app.get("/gateways")
async def get_gateways():
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT
                encode(g.gateway_id, 'hex') AS gateway_id,
                g.name,
                g.description,
                g.last_seen_at,
                g.latitude,
                g.longitude,
                g.altitude,
                g.tags,
                t.name AS tenant_name
            FROM gateway g
            JOIN tenant t ON t.id = g.tenant_id
            ORDER BY g.name
            """
        )
    return [dict(r) for r in rows]


@app.get("/uplinks")
async def get_uplinks(
    dev_eui: Optional[str] = None,
    limit: int = Query(default=50, le=500),
):
    query = """
        SELECT id, device_eui, device_name, received_at, f_port, payload
        FROM device_uplinks
    """
    params = []
    if dev_eui:
        query += " WHERE device_eui = $1"
        params.append(dev_eui.lower())
    query += f" ORDER BY received_at DESC LIMIT ${len(params) + 1}"
    params.append(limit)

    async with pool.acquire() as conn:
        rows = await conn.fetch(query, *params)
    return [dict(r) for r in rows]


@app.get("/uplinks/stream")
async def stream_uplinks():
    queue: asyncio.Queue = asyncio.Queue()
    _sse_clients.add(queue)

    async def event_generator():
        try:
            while True:
                payload = await queue.get()
                yield f"data: {payload}\n\n"
        finally:
            _sse_clients.discard(queue)

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
