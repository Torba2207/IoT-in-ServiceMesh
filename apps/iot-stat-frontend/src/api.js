// All calls go through nginx (prod) or the Vite dev proxy, which forward /api -> iot-stat-reader.
const BASE = "/api";

// The reader returns the jsonb `payload` as a raw JSON string (asyncpg default),
// so normalize it to an object for the rest of the app to consume.
function parsePayload(p) {
  if (p && typeof p === "object") return p;
  if (typeof p === "string") {
    try { return JSON.parse(p); } catch { return {}; }
  }
  return {};
}

export async function getUplinks(limit = 50, devEui) {
  const params = new URLSearchParams({ limit: String(limit) });
  if (devEui) params.set("dev_eui", devEui);
  const res = await fetch(`${BASE}/uplinks?${params}`);
  if (!res.ok) throw new Error(`uplinks: ${res.status}`);
  const data = await res.json();
  return data.map((u) => ({ ...u, payload: parsePayload(u.payload) }));
}

// Group a flat list of uplinks by device, keeping records oldest -> newest for plotting.
export function groupByDevice(uplinks) {
  const map = new Map();
  for (const u of uplinks) {
    if (!map.has(u.device_eui)) {
      map.set(u.device_eui, { eui: u.device_eui, name: u.device_name, recs: [] });
    }
    map.get(u.device_eui).recs.push(u);
  }
  for (const d of map.values()) d.recs.reverse();
  return [...map.values()];
}

// Numeric payload keys present for a device (these become plotted series).
export function numericKeys(recs) {
  const keys = new Set();
  for (const r of recs) {
    const p = r.payload || {};
    for (const k of Object.keys(p)) if (typeof p[k] === "number") keys.add(k);
  }
  return [...keys];
}
