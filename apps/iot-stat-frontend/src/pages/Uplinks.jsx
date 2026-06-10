import { useEffect, useState } from "react";
import { getUplinks } from "../api.js";

export default function Uplinks() {
  const [rows, setRows] = useState([]);
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let active = true;
    const load = async () => {
      try {
        const data = await getUplinks(50);
        if (active) { setRows(data); setError(null); }
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

  return (
    <div className="overflow-hidden rounded-lg border border-slate-700">
      <table className="w-full text-left text-sm">
        <thead className="bg-slate-800 text-slate-400">
          <tr>
            <th className="px-4 py-2 font-medium">Received</th>
            <th className="px-4 py-2 font-medium">Device</th>
            <th className="px-4 py-2 font-medium">EUI</th>
            <th className="px-4 py-2 font-medium">fPort</th>
            <th className="px-4 py-2 font-medium">Payload</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-800 bg-slate-900">
          {rows.length === 0 ? (
            <tr><td colSpan={5} className="px-4 py-6 text-center text-slate-400">No uplinks yet</td></tr>
          ) : (
            rows.map((u) => (
              <tr key={u.id} className="hover:bg-slate-800/50">
                <td className="whitespace-nowrap px-4 py-2">{new Date(u.received_at).toLocaleString()}</td>
                <td className="px-4 py-2">{u.device_name}</td>
                <td className="px-4 py-2 font-mono text-xs text-slate-400">{u.device_eui}</td>
                <td className="px-4 py-2">{u.f_port}</td>
                <td className="px-4 py-2 font-mono text-xs text-sky-300">{JSON.stringify(u.payload)}</td>
              </tr>
            ))
          )}
        </tbody>
      </table>
    </div>
  );
}
