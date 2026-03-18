import { useState, useMemo, useRef, useEffect } from "react";
import { useNavigate } from "react-router";
import { ChevronLeft, Search, SlidersHorizontal, Check } from "lucide-react";
import { useAppContext } from "../data";

type SortOption = "latest" | "title" | "progress";

export function SelectBookPage() {
  const navigate = useNavigate();
  const { books } = useAppContext();
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

  // 제목을 기준으로 중복된 책을 제거하고 가장 최근에 추가된(배열 앞쪽) 책만 남깁니다.
  const filteredBooks = useMemo(() => {
    const unique = books.filter((book, index, self) =>
      index === self.findIndex((b) => b.title === book.title)
    );
    if (!searchQuery) return unique;
    return unique.filter(
      (book) =>
        book.title.toLowerCase().includes(searchQuery.toLowerCase()) ||
        book.author.toLowerCase().includes(searchQuery.toLowerCase())
    );
  }, [books, searchQuery]);

  const sortedBooks = useMemo(() => {
    const sorted = [...filteredBooks];
    if (sortType === "title") {
      sorted.sort((a, b) => a.title.localeCompare(b.title));
    } else if (sortType === "progress") {
      sorted.sort((a, b) => {
        const progressA = a.totalPages ? (a.currentPage ?? 0) / a.totalPages : (a.progress ?? 0) / 100;
        const progressB = b.totalPages ? (b.currentPage ?? 0) / b.totalPages : (b.progress ?? 0) / 100;
        return progressB - progressA;
      });
    }
    return sorted;
  }, [filteredBooks, sortType]);

  return (
    <div className="min-h-full bg-[#FDFBF7] flex flex-col relative pb-20 font-sans">
      <header className="bg-white/80 backdrop-blur-md border-b border-stone-200 pt-12 pb-4 px-4 flex items-center justify-between sticky top-0 z-10 shadow-sm">
        <div className="flex items-center gap-3">
          <button onClick={() => navigate(-1)} className="p-2 -ml-2 rounded-full hover:bg-stone-100 text-stone-600 transition-colors">
            <ChevronLeft className="w-6 h-6" />
          </button>
          <h1 className="text-lg font-serif font-bold text-stone-800">
            읽던 책 선택
          </h1>
        </div>
      </header>

      <div className="p-6 space-y-4">
        {/* Search & Sort Bar */}
        <div className="flex items-center gap-2">
          <div className="flex-1 relative">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-stone-400" />
            <input 
              type="text" 
              placeholder="검색어를 입력하세요" 
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              className="w-full pl-9 pr-4 py-2.5 bg-white border border-stone-200 rounded-full text-sm outline-none focus:border-amber-400 focus:ring-1 focus:ring-amber-400/20 transition-all font-sans text-stone-700 placeholder:text-stone-400"
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

        <p className="text-stone-600 text-[15px] font-serif mb-2 break-keep">읽던 책을 선택해 기록을 보고 질문하기로 더 깊이 탐색해보세요.</p>
        
        <div className="space-y-3">
          {sortedBooks.map(book => {
            const pct = book.totalPages ? Math.round(((book.currentPage ?? 0) / book.totalPages) * 100) : (book.progress ?? 0);
            return (
              <button
                key={book.id}
                onClick={() => navigate(`/book/${book.id}`)}
                className="w-full flex items-center gap-4 p-4 bg-white rounded-2xl border border-stone-100 shadow-sm hover:border-amber-400 hover:ring-1 hover:ring-amber-400/20 transition-all text-left"
              >
                <img src={book.coverUrl} alt={book.title} className="w-14 h-20 object-cover rounded-md shadow-sm border border-stone-200" />
                <div className="flex-1">
                  <h3 className="font-serif font-bold text-stone-800 text-lg mb-1">{book.title}</h3>
                  <p className="text-stone-500 text-sm mb-3">{book.author}</p>
                  
                  {/* Progress Bar */}
                  <div className="flex items-center gap-3">
                    <div className="flex-1 h-1.5 bg-stone-100 rounded-full overflow-hidden">
                      <div 
                        className="h-full bg-amber-600 rounded-full"
                        style={{ width: `${pct}%` }}
                      />
                    </div>
                    <span className="text-xs font-medium text-stone-500 font-sans">
                      {book.totalPages ? `${book.currentPage}p / ${book.totalPages}p (${pct}%)` : `${pct}%`}
                    </span>
                  </div>
                </div>
              </button>
            );
          })}
          
          {books.length === 0 ? (
            <div className="py-12 text-center flex flex-col items-center text-stone-400">
              <p className="text-sm mb-4">아직 기록된 책이 없습니다.</p>
              <button
                onClick={() => navigate('/scan')}
                className="px-6 py-2.5 bg-amber-50 text-amber-800 text-sm font-medium rounded-xl hover:bg-amber-100 transition-colors"
              >
                새로운 책 기록하기
              </button>
            </div>
          ) : sortedBooks.length === 0 && (
            <div className="py-12 text-center text-stone-400 text-sm">
              검색 결과가 없습니다.
            </div>
          )}
        </div>
      </div>
    </div>
  );
}