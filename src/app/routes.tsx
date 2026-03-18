import { createBrowserRouter } from "react-router";
import { Layout } from "./components/Layout";
import { HomePage } from "./pages/Home";
import { ScanPage } from "./pages/Scan";
import { BookDetailPage } from "./pages/BookDetail";
import { SelectBookPage } from "./pages/SelectBook";

export const router = createBrowserRouter([
  {
    path: "/",
    Component: Layout,
    children: [
      { index: true, Component: HomePage },
      { path: "scan", Component: ScanPage },
      { path: "book/:id", Component: BookDetailPage },
      { path: "select-book", Component: SelectBookPage },
    ],
  },
]);
