import { Outlet, NavLink, useLocation } from "react-router";
import { Home } from "lucide-react";
import { AppProvider } from "../data";

export function Layout() {
  const location = useLocation();
  const hideBottomNav = location.pathname.includes("/scan");

  return (
    <AppProvider>
      <div className="flex justify-center w-full min-h-screen bg-stone-900">
        <div className="w-full max-w-[430px] bg-[#FDFBF7] relative flex flex-col min-h-screen shadow-2xl overflow-hidden font-serif selection:bg-amber-100">
          {/* Main content area */}
          <div className={`flex-1 overflow-y-auto [&::-webkit-scrollbar]:w-1.5 [&::-webkit-scrollbar-track]:bg-transparent [&::-webkit-scrollbar-thumb]:bg-stone-200 [&::-webkit-scrollbar-thumb]:rounded-full hover:[&::-webkit-scrollbar-thumb]:bg-stone-300 ${!hideBottomNav ? 'pb-20' : ''}`}>
            <Outlet />
          </div>

          {/* Bottom Navigation */}
          {!hideBottomNav && (
            <nav className="absolute bottom-0 w-full bg-[#FDFBF7] border-t border-stone-200 pb-safe pt-2 flex justify-evenly items-center z-50">
              <NavLink
                to="/"
                className={({ isActive }) =>
                  `flex flex-col items-center py-2 px-8 transition-colors ${
                    isActive ? "text-amber-700" : "text-stone-400 hover:text-stone-600"
                  }`
                }
              >
                <Home className="w-6 h-6 mb-1" />
                <span className="text-xs font-medium font-sans">홈</span>
              </NavLink>

              <NavLink
                to="/select-book"
                className={({ isActive }) =>
                  `flex flex-col items-center py-2 px-8 transition-colors ${
                    isActive ? "text-amber-700" : "text-stone-400 hover:text-stone-600"
                  }`
                }
              >
                <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="w-6 h-6 mb-1">
                  <path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z"/>
                </svg>
                <span className="text-xs font-medium font-sans">분석 기록</span>
              </NavLink>
            </nav>
          )}
        </div>
      </div>
    </AppProvider>
  );
}