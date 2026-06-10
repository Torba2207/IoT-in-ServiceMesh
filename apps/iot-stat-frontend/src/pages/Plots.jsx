import { useEffect, useState } from "react";
import {
  LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip, Legend, ResponsiveContainer,
} from "recharts";
import { getUplinks, groupByDevice, numericKeys } from "../api.js";

const COLORS = ["#38bdf8", "#34d399", "#fbbf24", "#f87171", "#a78bfa", "#22d3ee", "#facc15"];
const fmtTime = (iso) =>
  new Date(iso).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });

function DeviceChart({ device }) {
  const keys = numericKeys(device.recs);
  const data = device.recs.map((r) => ({ t: fmtTime(r.received_at), ...r.payload }));

  return (
    <div className="rounded-lg border border-slate-700 bg-slate-800 p-4">
      <h3 className="text-sm font-semibold">{device.name || "Unnamed device"}</h3>
      <p className="mb-3 font-mono text-xs text-slate-400">{device.eui}</p>
      {keys.length === 0 ? (
        <p className="py-8 text-center text-sm text-slate-400">No numeric fields to plot</p>
      ) : (
        <ResponsiveContainer width="100%" height={240}>
          <LineChart data={data} margin={{ top: 5, right: 10, bottom: 5, left: -10 }}>
            <CartesianGrid stroke="#334155" strokeDasharray="3 3" />
            <XAxis dataKey="t" tick={{ fill: "#94a3b8", fontSize: 11 }} minTickGap={24} />
            <YAxis tick={{ fill: "#94a3b8", fontSize: 11 }} />
            <Tooltip contentStyle={{ background: "#1e293b", border: "1px solid #334155", color: "#e2e8f0" }} />
            <Legend wrapperStyle={{ fontSize: 12 }} />
            {keys.map((k, i) => (
              <Line key={k} type="monotone" dataKey={k} stroke={COLORS[i % COLORS.length]}
                dot={{ r: 2 }} isAnimationActive={false} connectNulls />
            ))}
          </LineChart>
        </ResponsiveContainer>
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
      {devices.map((d) => <DeviceChart key={d.eui} device={d} />)}
    </div>
  );
}
