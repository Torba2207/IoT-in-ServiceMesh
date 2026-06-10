import { useEffect, useState } from "react";
import {
  LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer,
} from "recharts";
import {
  getUplinks, groupByDevice, numericKeys, categoricalSeries, CATEGORY_ORDER,
} from "../api.js";

const COLORS = ["#38bdf8", "#34d399", "#fbbf24", "#f87171", "#a78bfa", "#22d3ee", "#facc15"];
const fmtTime = (iso) =>
  new Date(iso).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });

const axisTick = { fill: "#94a3b8", fontSize: 11 };
const tooltipStyle = { background: "#1e293b", border: "1px solid #334155", color: "#e2e8f0" };

function NumericChart({ recs, keys }) {
  const data = recs.map((r) => ({ t: fmtTime(r.received_at), ...r.payload }));
  return (
    <ResponsiveContainer width="100%" height={220}>
      <LineChart data={data} margin={{ top: 5, right: 10, bottom: 5, left: -10 }}>
        <CartesianGrid stroke="#334155" strokeDasharray="3 3" />
        <XAxis dataKey="t" tick={axisTick} minTickGap={24} />
        <YAxis tick={axisTick} />
        <Tooltip contentStyle={tooltipStyle} />
        <Legend wrapperStyle={{ fontSize: 12 }} />
        {keys.map((k, i) => (
          <Line key={k} type="monotone" dataKey={k} stroke={COLORS[i % COLORS.length]}
            dot={{ r: 2 }} isAnimationActive={false} connectNulls />
        ))}
      </LineChart>
    </ResponsiveContainer>
  );
}

// One categorical field over time: the Y axis is the set of possible values,
// drawn as a step line so state changes (and discrete events) are easy to read.
function CategoricalChart({ field, points }) {
  const present = [...new Set(points.map((p) => p.label))];
  const known = CATEGORY_ORDER[field] || [];
  const categories = [
    ...known.filter((c) => present.includes(c)),
    ...present.filter((c) => !known.includes(c)),
  ];
  const idx = Object.fromEntries(categories.map((c, i) => [c, i]));
  const data = points.map((p) => ({ t: fmtTime(p.t), v: idx[p.label] }));

  return (
    <div className="mt-3">
      <p className="mb-1 text-xs font-medium text-slate-300">{field}</p>
      <ResponsiveContainer width="100%" height={130}>
        <LineChart data={data} margin={{ top: 5, right: 10, bottom: 5, left: 0 }}>
          <CartesianGrid stroke="#334155" strokeDasharray="3 3" />
          <XAxis dataKey="t" tick={axisTick} minTickGap={24} />
          <YAxis
            type="number" domain={[-0.5, categories.length - 0.5]}
            ticks={categories.map((_, i) => i)} tickFormatter={(i) => categories[i]}
            tick={axisTick} width={90} interval={0}
          />
          <Tooltip contentStyle={tooltipStyle} formatter={(val) => categories[val]} />
          <Line type="stepAfter" dataKey="v" stroke="#f472b6" dot={{ r: 3 }} isAnimationActive={false} />
        </LineChart>
      </ResponsiveContainer>
    </div>
  );
}

// How many of the most recent records to plot per device (keeps charts readable).
const PLOT_POINTS = 15;

function DeviceCard({ device }) {
  const recs = device.recs.slice(-PLOT_POINTS); // most recent N, oldest -> newest
  const numKeys = numericKeys(recs);
  const catSeries = categoricalSeries(recs);
  const catFields = Object.keys(catSeries);

  return (
    <div className="rounded-lg border border-slate-700 bg-slate-800 p-4">
      <h3 className="text-sm font-semibold">{device.name || "Unnamed device"}</h3>
      <p className="mb-3 font-mono text-xs text-slate-400">{device.eui}</p>

      {numKeys.length > 0 && <NumericChart recs={recs} keys={numKeys} />}
      {catFields.map((f) => (
        <CategoricalChart key={f} field={f} points={catSeries[f]} />
      ))}

      {numKeys.length === 0 && catFields.length === 0 && (
        <p className="py-8 text-center text-sm text-slate-400">Nothing to plot</p>
      )}
    </div>
  );
}

export default function Plots() {
  const [devices, setDevices] = useState([]);
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let active = true;
    const load = async () => {
      try {
        const uplinks = await getUplinks(500);
        if (active) { setDevices(groupByDevice(uplinks)); setError(null); }
      } catch (e) {
        if (active) setError(e.message);
      } finally {
        if (active) setLoading(false);
      }
    };
    load();
    const id = setInterval(load, 10000);
    return () => { active = false; clearInterval(id); };
  }, []);

  if (loading) return <p className="text-slate-400">Loading…</p>;
  if (error) return <p className="text-red-400">Error: {error}</p>;
  if (devices.length === 0) return <p className="text-slate-400">No device data yet.</p>;

  return (
    <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
      {devices.map((d) => <DeviceCard key={d.eui} device={d} />)}
    </div>
  );
}
