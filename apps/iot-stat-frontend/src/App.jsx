import { NavLink, Outlet } from "react-router-dom";

const linkClass = ({ isActive }) =>
  `px-3 py-2 rounded-md text-sm font-medium transition-colors ${
    isActive ? "bg-sky-600 text-white" : "text-slate-300 hover:bg-slate-700 hover:text-white"
  }`;

export default function App() {
  return (
    <div className="min-h-screen bg-slate-900 text-slate-100">
      <header className="border-b border-slate-700 bg-slate-800">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-6 py-3">
          <h1 className="text-lg font-semibold">IoT Stats</h1>
          <nav className="flex gap-2">
            <NavLink to="/plots" className={linkClass}>Plots</NavLink>
            <NavLink to="/uplinks" className={linkClass}>Uplinks</NavLink>
          </nav>
        </div>
      </header>
      <main className="mx-auto max-w-6xl px-6 py-6">
        <Outlet />
      </main>
    </div>
  );
}
