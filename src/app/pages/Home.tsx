import { useState, useMemo, useRef, useEffect } from "react";
import { useNavigate } from "react-router";
import { useAppContext } from "../data";
import { BookOpen, Plus, Clock, ChevronLeft, Sparkles, BookMarked, Search, SlidersHorizontal, Check } from "lucide-react";
import { motion, AnimatePresence } from "motion/react";

type SortOption = "latest" | "title" | "progress";

export function HomePage() {
  const { books } = useAppContext();
  const navigate = useNavigate();
  const [showBookSelection, setShowBookSelection] = useState(false);
  const [searchQuery, setSearchQuery] = useState("");
  const [sortType, setSortType] = useState<SortOption>("latest");
  const [isSortMenuOpen, setIsSortMenuOpen] = useState(false);
  const sortMenuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    function handleClickOutside(event: MouseEvent) {
      if (sortMenuRef.current && !sortMenuRef.current.contains(event.target as Node)) {
        setIsSortMenuOpen(false);
      }
    }
    document.addEventListener("mousedown", handleClickOutside);
    return () => document.removeEventListener("mousedown", handleClickOutside);
  }, []);

  const filteredBooks = useMemo(() => {
    const unique = Array.from(new Map(books.map(item => [item.title, item])).values());
    if (!searchQuery) return unique;
    return unique.filter(book => 
      book.title.toLowerCase().includes(searchQuery.toLowerCase()) || 
      book.author.toLowerCase().includes(searchQuery.toLowerCase())
    );
  }, [books, searchQuery]);

  const sortedBooks = useMemo(() => {
    let sorted = [...filteredBooks];
    if (sortType === "title") {
      sorted.sort((a, b) => a.title.localeCompare(b.title));
    } else if (sortType === "progress") {
      sorted.sort((a, b) => {
        const progressA = a.totalPages ? ((a.currentPage || 0) / a.totalPages) : ((a.progress || 0) / 100);
        const progressB = b.totalPages ? ((b.currentPage || 0) / b.totalPages) : ((b.progress || 0) / 100);
        return progressB - progressA;
      });
    }
    return sorted;
  }, [filteredBooks, sortType]);

  return (
    <div className="min-h-full bg-[#FDFBF7] flex flex-col font-sans">
      <header className="pt-12 pb-6 px-6 bg-transparent shrink-0">
        <div className="flex items-center gap-2 mb-2">
          <div className="relative flex items-center justify-center">
            <BookOpen className="w-7 h-7 text-amber-700" />
            <Sparkles className="w-3.5 h-3.5 text-amber-500 absolute -top-1 -right-1.5" />
          </div>
          <h1 className="text-2xl font-bold text-stone-800 font-serif ml-1 tracking-tight">ReadAssi</h1>
        </div>
        <p className="text-stone-500 text-sm">AI 독서 보조 애플리케이션</p>
      </header>

      <main className="flex-1 px-6 pb-12 flex flex-col justify-center relative overflow-hidden">
        <AnimatePresence mode="wait">
          {!showBookSelection ? (
            <motion.div 
              key="main-menu"
              initial={{ opacity: 0, x: -20 }}
              animate={{ opacity: 1, x: 0 }}
              exit={{ opacity: 0, x: -20 }}
              transition={{ duration: 0.3 }}
              className="space-y-6 w-full max-w-sm mx-auto"
            >
              <button
                onClick={() => navigate('/scan')}
                className="w-full group relative overflow-hidden bg-white border border-stone-200 p-8 rounded-3xl shadow-sm hover:shadow-md hover:border-amber-200 transition-all text-left flex flex-col gap-4"
              >
                <div className="absolute -right-4 -top-4 w-24 h-24 bg-amber-50 rounded-full opacity-50 group-hover:scale-150 transition-transform duration-500" />
                <div className="w-12 h-12 bg-amber-100/50 rounded-2xl flex items-center justify-center relative z-10 text-amber-700">
                  <Plus className="w-6 h-6" />
                </div>
                <div className="relative z-10">
                  <h2 className="text-xl font-bold text-stone-800 font-serif mb-1">새로운 책 읽기</h2>
                  <p className="text-sm text-stone-500 break-keep">새로운 책을 카메라로 스캔하여 기록을 시작합니다.</p>
                </div>
              </button>

              <button
                onClick={() => setShowBookSelection(true)}
                className="w-full group relative overflow-hidden bg-stone-50 border border-stone-200 p-8 rounded-3xl shadow-sm hover:shadow-md hover:border-stone-300 hover:bg-white transition-all text-left flex flex-col gap-4"
              >
                <div className="absolute -right-4 -top-4 w-24 h-24 bg-stone-100 rounded-full opacity-60 group-hover:scale-150 transition-transform duration-500" />
                <div className="w-12 h-12 bg-stone-200/50 rounded-2xl flex items-center justify-center relative z-10 text-stone-600">
                  <Clock className="w-6 h-6" />
                </div>
                <div className="relative z-10">
                  <h2 className="text-xl font-bold text-stone-800 font-serif mb-1">이어서 읽기</h2>
                  <p className="text-sm text-stone-500 break-keep">이전에 읽던 책을 선택해 이어서 스캔합니다.</p>
                </div>
              </button>
            </motion.div>
          ) : (
            <motion.div
              key="book-selection"
              initial={{ opacity: 0, x: 20 }}
              animate={{ opacity: 1, x: 0 }}
              exit={{ opacity: 0, x: 20 }}
              transition={{ duration: 0.3 }}
              className="absolute inset-0 bg-[#FDFBF7] z-10 flex flex-col"
            >
              <div className="pb-4 flex items-center justify-between shrink-0 border-b border-stone-200/50 mb-4">
                <div className="flex items-center gap-2">
                  <button 
                    onClick={() => setShowBookSelection(false)}
                    className="p-2 -ml-2 rounded-full hover:bg-stone-200/50 text-stone-600 transition-colors flex items-center justify-center"
                  >
                    <ChevronLeft className="w-6 h-6" />
                  </button>
                  <h2 className="text-lg font-bold text-stone-800 font-serif">이어서 읽을 책 선택</h2>
                </div>
              </div>

              {/* Search & Sort Bar */}
              <div className="mb-4 flex items-center gap-2 shrink-0">
                <div className="flex-1 relative">
                  <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-stone-400" />
                  <input 
                    type="text" 
                    placeholder="책 제목이나 저자 검색" 
                    value={searchQuery}
                    onChange={(e) => setSearchQuery(e.target.value)}
                    className="w-full pl-9 pr-4 py-2.5 bg-white border border-stone-200 rounded-full text-sm outline-none focus:border-amber-400 focus:ring-1 focus:ring-amber-400/20 transition-all font-sans text-stone-700 placeholder:text-stone-400 shadow-sm"
                  />
                </div>
                <div className="relative" ref={sortMenuRef}>
                  <button 
                    onClick={() => setIsSortMenuOpen(!isSortMenuOpen)}
                    className={`p-2.5 bg-white border rounded-full text-stone-600 hover:bg-stone-50 transition-colors shadow-sm ${isSortMenuOpen ? 'border-amber-400 ring-1 ring-amber-400/20' : 'border-stone-200'}`}
                  >
                    <SlidersHorizontal className="w-4 h-4" />
                  </button>
                  
                  {isSortMenuOpen && (
                    <div className="absolute right-0 top-full mt-2 w-36 bg-white rounded-xl shadow-lg border border-stone-100 py-1.5 z-20">
                      <button 
                        onClick={() => { setSortType("latest"); setIsSortMenuOpen(false); }}
                        className="w-full flex items-center justify-between px-4 py-2 text-sm text-stone-700 hover:bg-stone-50"
                      >
                        최신순 {sortType === "latest" && <Check className="w-4 h-4 text-amber-500" />}
                      </button>
                      <button 
                        onClick={() => { setSortType("title"); setIsSortMenuOpen(false); }}
                        className="w-full flex items-center justify-between px-4 py-2 text-sm text-stone-700 hover:bg-stone-50"
                      >
                        이름순 {sortType === "title" && <Check className="w-4 h-4 text-amber-500" />}
                      </button>
                      <button 
                        onClick={() => { setSortType("progress"); setIsSortMenuOpen(false); }}
                        className="w-full flex items-center justify-between px-4 py-2 text-sm text-stone-700 hover:bg-stone-50"
                      >
                        진행도순 {sortType === "progress" && <Check className="w-4 h-4 text-amber-500" />}
                      </button>
                    </div>
                  )}
                </div>
              </div>
              
              <div className="flex-1 overflow-y-auto pb-12 space-y-3 [&::-webkit-scrollbar]:w-1.5 [&::-webkit-scrollbar-track]:bg-transparent [&::-webkit-scrollbar-thumb]:bg-stone-200 [&::-webkit-scrollbar-thumb]:rounded-full hover:[&::-webkit-scrollbar-thumb]:bg-stone-300">
                {books.length === 0 ? (
                  <div className="text-center py-12 flex flex-col items-center">
                    <BookMarked className="w-12 h-12 text-stone-300 mb-4" />
                    <p className="text-stone-500 text-sm">아직 기록된 책이 없습니다.</p>
                    <button 
                      onClick={() => navigate('/scan')}
                      className="mt-4 px-6 py-2.5 bg-amber-50 text-amber-800 text-sm font-medium rounded-xl hover:bg-amber-100 transition-colors"
                    >
                      새로운 책 기록하기
                    </button>
                  </div>
                ) : sortedBooks.length === 0 ? (
                  <div className="text-center py-12 text-stone-400 text-sm">
                    검색 결과가 없습니다.
                  </div>
                ) : (
                  sortedBooks.map((book) => {
                    const pct = book.totalPages ? Math.round(((book.currentPage || 0) / book.totalPages) * 100) : (book.progress || 0);
                    return (
                      <button
                        key={book.id}
                        onClick={() => navigate(`/scan?bookId=${book.id}`)}
                        className="w-full flex items-center gap-4 p-4 bg-white rounded-2xl border border-stone-200 shadow-sm hover:border-amber-300 hover:shadow-md transition-all text-left group"
                      >
                        <img 
                          src={book.coverUrl} 
                          alt={book.title} 
                          className="w-14 h-20 rounded-lg object-cover shadow-sm bg-stone-100 border border-stone-100" 
                        />
                        <div className="flex-1 py-1">
                          <h3 className="font-bold text-stone-800 text-base font-serif line-clamp-1 group-hover:text-amber-800 transition-colors">{book.title}</h3>
                          <p className="text-sm text-stone-500 mt-1 mb-3 line-clamp-1">{book.author}</p>
                          
                          {/* Progress Bar */}
                          <div className="flex items-center gap-3">
                            <div className="flex-1 h-1.5 bg-stone-100 rounded-full overflow-hidden">
                              <div 
                                className="h-full bg-amber-600 rounded-full"
                                style={{ width: `${pct}%` }}
                              />
                            </div>
                            <span className="text-[11px] font-medium text-stone-500 font-sans">
                              {book.totalPages ? `${book.currentPage}p / ${book.totalPages}p (${pct}%)` : `${pct}%`}
                            </span>
                          </div>
                        </div>
                      </button>
                    );
                  })
                )}
              </div>
            </motion.div>
          )}
        </AnimatePresence>
      </main>
    </div>
  );
}