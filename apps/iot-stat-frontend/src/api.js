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

// Constant metadata fields that aren't interesting to plot.
const META_KEYS = new Set([
  "sn", "firmware_version", "hardware_version", "ipso_version",
  "lorawan_class", "device_status",
]);

// Numeric payload keys present for a device (these become line-plotted series).
export function numericKeys(recs) {
  const keys = new Set();
  for (const r of recs) {
    const p = r.payload || {};
    for (const k of Object.keys(p)) {
      if (!META_KEYS.has(k) && typeof p[k] === "number") keys.add(k);
    }
  }
  return [...keys];
}

// Pull a categorical label out of a payload value:
//  - plain strings (e.g. daylight "dim", pir "trigger")
//  - objects carrying a `status` string (e.g. button_event {status:"short press"})
function categoryLabel(v) {
  if (typeof v === "string") return v;
  if (v && typeof v === "object" && typeof v.status === "string") return v.status;
  return null;
}

// Categorical (string/enum) series per device, keyed by field name.
// Returns { fieldName: [{ t, label }, ...] } with records in the order given.
export function categoricalSeries(recs) {
  const series = {};
  for (const r of recs) {
    const p = r.payload || {};
    for (const [k, v] of Object.entries(p)) {
      if (META_KEYS.has(k)) continue;
      const label = categoryLabel(v);
      if (label == null) continue;
      (series[k] ||= []).push({ t: r.received_at, label });
    }
  }
  return series;
}

// Preferred ordering for known categories so the Y axis reads naturally
// (low -> high). Unknown values are appended in first-seen order.
export const CATEGORY_ORDER = {
  daylight: ["dark", "dim", "bright"],
  pir: ["normal", "trigger"],
  button_event: ["short press", "double press", "long press"],
};
