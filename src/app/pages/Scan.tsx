import { useState, useEffect, useRef } from "react";
import { useNavigate, useSearchParams } from "react-router";
import { X, BookOpen, MessageSquare, BookMarked, Users, Sparkles, Send } from "lucide-react";
import { useAppContext } from "../data";
import { motion, AnimatePresence } from "motion/react";

type TabType = 'text' | 'summary' | 'characters' | 'chat';

export function ScanPage() {
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const { books, addBook } = useAppContext();
  const [isScanning, setIsScanning] = useState(false);
  const [showTooltip, setShowTooltip] = useState(true);
  
  // AI Interaction states
  const [activeTab, setActiveTab] = useState<TabType>('text');
  const [hasData, setHasData] = useState(false);
  
  const [extractedText, setExtractedText] = useState("");
  const [aiSummary, setAiSummary] = useState("");
  const [keywords, setKeywords] = useState<string[]>([]);
  const [characters, setCharacters] = useState<{name: string, desc: string}[]>([]);
  const [chatMessages, setChatMessages] = useState<{role: 'user'|'ai', content: string}[]>([]);
  const [chatInput, setChatInput] = useState("");

  const chatEndRef = useRef<HTMLDivElement>(null);

  // "이어서 읽기" 흐름: URL 파라미터로 기존 책 정보 불러오기
  const existingBookId = searchParams.get("bookId");
  const existingBook = existingBookId ? books.find(b => b.id === existingBookId) ?? null : null;

  // Mock real-time OCR stream & AI pipeline
  useEffect(() => {
    if (!isScanning) return;
    
    setHasData(true);
    let step = 0;
    
    const sequence = [
      { delay: 1000, action: () => setExtractedText(prev => prev + "손자병법 제1편 시계(始計)... ") },
      { delay: 2000, action: () => setExtractedText(prev => prev + "병자 국지대사(兵者 國之大事), 사생지지(死生之地), 존망지도(存亡之道), 불가불찰야(不可不찰야). ") },
      { delay: 3500, action: () => {
          setExtractedText(prev => prev + "전쟁은 국가의 중대사이다. 백성의 생사와 국가의 존망이 달린 문제이므로 깊이 살피지 않을 수 없다.");
      }},
      { delay: 4500, action: () => {
          setAiSummary("이 구절은 손자병법의 핵심 사상인 '신중한 전쟁관'을 담고 있습니다. 전쟁이 국가와 백성의 운명을 좌우하는 중대사이므로, 철저한 계산과 준비(시계) 없이는 절대 전쟁을 일으켜서는 안 된다는 경고를 전합니다.");
          setKeywords(["신중함", "전략", "국가의 중대사", "철저한 준비"]);
      }},
      { delay: 6000, action: () => {
          setCharacters([
            { name: "손무 (孫武)", desc: "춘추시대 오나라의 장군. '싸우지 않고 이기는 것'을 최선으로 여긴 천재 전략가." },
            { name: "합려 (闔閭)", desc: "오나라의 왕. 손무를 기용하여 천하의 패자가 되고자 한 인물." }
          ]);
      }},
      { delay: 7500, action: () => {
          if (chatMessages.length === 0) {
            setChatMessages([
              { role: 'ai', content: "손자병법의 '시계' 편을 읽고 계시군요! 전쟁의 신중함을 강조하는 이 부분에 대해 더 궁금한 점이 있으신가요?" }
            ]);
          }
      }}
    ];

    const timeouts = sequence.map((item, index) => {
      // Aggregate delays for sequential execution
      const cumulativeDelay = sequence.slice(0, index + 1).reduce((acc, curr) => acc + curr.delay, 0);
      return setTimeout(item.action, cumulativeDelay);
    });

    return () => timeouts.forEach(clearTimeout);
  }, [isScanning]);

  useEffect(() => {
    if (activeTab === 'chat' && chatEndRef.current) {
      chatEndRef.current.scrollIntoView({ behavior: 'smooth' });
    }
  }, [chatMessages, activeTab]);

  useEffect(() => {
    if (isScanning) {
      setActiveTab('text');
    } else if (hasData && extractedText) {
      // 스캔이 종료되었을 때 AI 데이터가 없으면 즉시 채워줍니다.
      if (!aiSummary) {
        setAiSummary("이 ��절은 손자병법의 핵심 사상인 '신중한 전쟁관'을 담고 있습니다. 전쟁이 국가와 백성의 운명을 좌우하는 중대사이므로, 철저한 계산과 준비(시계) 없이는 절대 전쟁을 일으켜서는 안 된다는 경고를 전합니다.");
        setKeywords(["신중함", "전략", "국가의 중대사", "철저한 준비"]);
      }
      if (characters.length === 0) {
        setCharacters([
          { name: "손무 (孫武)", desc: "춘추시대 오나라의 장군. '싸우지 않고 이기는 것'을 최선으로 여긴 천재 전략가." },
          { name: "합려 (闔閭)", desc: "오나라의 왕. 손무를 기용하여 천하의 패자가 되고자 한 인물." }
        ]);
      }
      if (chatMessages.length === 0) {
        setChatMessages([
          { role: 'ai', content: "손자병법의 '시계' 편을 읽고 계시군요! 전쟁의 신중함을 강조하는 이 부분에 대해 더 궁금한 점이 있으신가요?" }
        ]);
      }
    }
  }, [isScanning, hasData, extractedText, aiSummary, characters.length, chatMessages.length]);

  // Hide tooltip after a few seconds
  useEffect(() => {
    const timer = setTimeout(() => setShowTooltip(false), 5000);
    return () => clearTimeout(timer);
  }, []);

  const handleSendMessage = () => {
    if (!chatInput.trim()) return;
    
    setChatMessages(prev => [...prev, { role: 'user', content: chatInput }]);
    setChatInput("");
    
    // Mock AI reply
    setTimeout(() => {
      setChatMessages(prev => [...prev, { 
        role: 'ai', 
        content: "네, 맞습니다. '시계(始計)'는 말 그대로 '처음에 계산한다'는 뜻으로, 개전 이전에 이미 피아의 전력을 5사 7계라는 기준으로 철저히 비교 분석해야 승리할 수 있다는 의미를 내포하고 있습니다." 
      }]);
    }, 1500);
  };

  const handleSaveToLibrary = () => {
    const totalPages = existingBook?.totalPages ?? 300;
    const currentPage = existingBook
      ? Math.min((existingBook.currentPage ?? 0) + Math.floor(Math.random() * 30) + 10, totalPages)
      : Math.floor(Math.random() * 90) + 1;
    const newBook = {
      id: `b${Date.now()}`,
      title: existingBook?.title ?? "손자병법",
      author: existingBook?.author ?? "손무",
      coverUrl: existingBook?.coverUrl ?? "https://images.unsplash.com/photo-1604435062356-a880b007922c?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&ixid=M3w3Nzg4Nzd8MHwxfHNlYXJjaHwxfHxib29rJTIwY292ZXIlMjBteXN0ZXJ5fGVufDF8fHx8MTc3Mzc5NDUwM3ww&ixlib=rb-4.1.0&q=80&w=1080",
      summary: aiSummary || "분석된 요약이 없습니다.",
      keywords: keywords,
      characters: characters.map(c => ({ id: c.name, name: c.name, role: c.desc, description: c.desc })),
      relationships: existingBook?.relationships ?? [],
      currentPage,
      totalPages,
      progress: Math.round((currentPage / totalPages) * 100)
    };
    addBook(newBook);
    navigate(`/book/${newBook.id}`);
  };

  return (
    <div className="fixed inset-0 bg-stone-950 flex flex-col z-50 max-w-[430px] mx-auto w-full h-full overflow-hidden font-sans">
      {/* Top Header */}
      <div className="absolute top-0 left-0 w-full p-6 z-30 flex justify-between items-center bg-gradient-to-b from-stone-950/80 to-transparent pb-12">
        <button onClick={() => navigate(-1)} className="p-2.5 bg-stone-800/40 rounded-full backdrop-blur-md text-stone-100 hover:bg-stone-700/50 transition-colors">
          <X className="w-5 h-5" />
        </button>
        {hasData && !isScanning && (
           <button 
             onClick={handleSaveToLibrary}
             className="px-4 py-2 bg-amber-700/90 text-amber-50 rounded-full text-sm font-medium hover:bg-amber-600 backdrop-blur-md transition-colors shadow-lg flex items-center gap-1.5"
           >
             <BookMarked className="w-4 h-4" /> 기록 저장
           </button>
        )}
      </div>

      {/* Live Camera View Area */}
      <div className="absolute inset-0 z-0">
        <div className="w-full h-full bg-stone-900 flex flex-col items-center justify-center relative">
          <div className="absolute inset-0 opacity-[0.03] pointer-events-none mix-blend-overlay" style={{ backgroundImage: `url("data:image/svg+xml,%3Csvg viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noiseFilter'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.65' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noiseFilter)'/%3E%3C/svg%3E")` }} />
          
          <div className={`w-4/5 aspect-[3/4] relative transition-opacity duration-500 ${isScanning ? 'opacity-80' : 'opacity-20'}`}>
            <div className={`absolute top-0 left-0 w-12 h-12 border-t-2 border-l-2 transition-colors ${isScanning ? 'border-amber-500' : 'border-stone-600'}`} />
            <div className={`absolute top-0 right-0 w-12 h-12 border-t-2 border-r-2 transition-colors ${isScanning ? 'border-amber-500' : 'border-stone-600'}`} />
            <div className={`absolute bottom-0 left-0 w-12 h-12 border-b-2 border-l-2 transition-colors ${isScanning ? 'border-amber-500' : 'border-stone-600'}`} />
            <div className={`absolute bottom-0 right-0 w-12 h-12 border-b-2 border-r-2 transition-colors ${isScanning ? 'border-amber-500' : 'border-stone-600'}`} />
            
            {isScanning && (
              <div className="absolute inset-0 bg-amber-500/10 animate-pulse pointer-events-none" />
            )}
          </div>
        </div>
      </div>

      {/* AI Interactive Panel (visible during & after scan if data exists) */}
      <div className="flex-1 relative z-20 flex flex-col justify-end pb-[160px] pointer-events-none">
        <AnimatePresence>
          {!hasData && showTooltip && !isScanning && (
            <motion.div 
              key="tooltip"
              initial={{ opacity: 0, y: 20 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -10 }}
              className="bg-stone-800/80 backdrop-blur-md text-stone-200 text-sm py-3 px-5 rounded-2xl mb-auto mt-24 mx-auto text-center border border-stone-700 shadow-xl"
            >
              카메라를 책 페이지에 비추고<br/>하단의 스캔 버튼을 눌러주세요.
            </motion.div>
          )}

          {hasData && (
            <motion.div 
              key="ai-panel"
              initial={{ opacity: 0, y: 40 }}
              animate={{ opacity: 1, y: 0 }}
              className="w-full bg-[#FDFBF7]/95 backdrop-blur-xl rounded-t-3xl shadow-[0_-10px_40px_rgba(0,0,0,0.3)] pointer-events-auto border-t border-amber-200/50 flex flex-col max-h-[50vh]"
            >
              {/* Tabs */}
              <div className="flex items-center px-4 pt-4 pb-2 border-b border-stone-200/50 overflow-x-auto hide-scrollbar shrink-0">
                <button 
                  onClick={() => setActiveTab('text')}
                  className={`flex items-center gap-1.5 px-4 py-2 rounded-full text-sm font-medium whitespace-nowrap transition-colors ${activeTab === 'text' ? 'bg-amber-100 text-amber-900' : 'text-stone-500 hover:bg-stone-100'}`}
                >
                  <BookOpen className="w-4 h-4" /> 실시간 원문
                </button>
                <button 
                  onClick={() => !isScanning && setActiveTab('summary')}
                  disabled={isScanning}
                  className={`flex items-center gap-1.5 px-4 py-2 rounded-full text-sm font-medium whitespace-nowrap transition-colors ${
                    isScanning 
                      ? 'text-stone-300 cursor-not-allowed opacity-50' 
                      : activeTab === 'summary' 
                        ? 'bg-amber-100 text-amber-900' 
                        : 'text-stone-500 hover:bg-stone-100'
                  }`}
                >
                  <Sparkles className="w-4 h-4" /> AI 요약
                </button>
                <button 
                  onClick={() => !isScanning && setActiveTab('characters')}
                  disabled={isScanning}
                  className={`flex items-center gap-1.5 px-4 py-2 rounded-full text-sm font-medium whitespace-nowrap transition-colors ${
                    isScanning 
                      ? 'text-stone-300 cursor-not-allowed opacity-50' 
                      : activeTab === 'characters' 
                        ? 'bg-amber-100 text-amber-900' 
                        : 'text-stone-500 hover:bg-stone-100'
                  }`}
                >
                  <Users className="w-4 h-4" /> 인물 정보
                </button>
                <button 
                  onClick={() => !isScanning && setActiveTab('chat')}
                  disabled={isScanning}
                  className={`flex items-center gap-1.5 px-4 py-2 rounded-full text-sm font-medium whitespace-nowrap transition-colors ${
                    isScanning 
                      ? 'text-stone-300 cursor-not-allowed opacity-50' 
                      : activeTab === 'chat' 
                        ? 'bg-amber-100 text-amber-900' 
                        : 'text-stone-500 hover:bg-stone-100'
                  }`}
                >
                  <MessageSquare className="w-4 h-4" /> 질문하기
                </button>
              </div>

              {/* Status indicator when scanning */}
              {isScanning && (
                <div className="px-6 py-2 bg-amber-50/50 flex items-center gap-2 border-b border-amber-100/50 shrink-0">
                  <div className="w-2 h-2 rounded-full bg-amber-500 animate-pulse" />
                  <span className="text-xs font-medium text-amber-700">카메라를 통해 텍스트를 인식하고 있습니다...</span>
                </div>
              )}

              {/* Tab Content Area */}
              <div className="p-6 overflow-y-auto flex-1 font-serif text-stone-800 [&::-webkit-scrollbar]:w-1.5 [&::-webkit-scrollbar-track]:bg-transparent [&::-webkit-scrollbar-thumb]:bg-stone-200 [&::-webkit-scrollbar-thumb]:rounded-full hover:[&::-webkit-scrollbar-thumb]:bg-stone-300">
                {activeTab === 'text' && (
                  <div className="space-y-4">
                    {extractedText ? (
                      <p className="leading-loose text-sm break-keep">{extractedText}</p>
                    ) : (
                      <p className="text-stone-400 text-sm italic">텍스트를 인식하고 있습니다...</p>
                    )}
                  </div>
                )}
                
                {activeTab === 'summary' && (
                  <div className="space-y-4">
                    {aiSummary ? (
                      <div className="bg-white p-5 rounded-2xl shadow-sm border border-stone-100">
                        <h4 className="font-bold text-amber-900 mb-3 text-sm flex items-center gap-2">
                          <Sparkles className="w-4 h-4 text-amber-600" /> 문맥 요약
                        </h4>
                        <p className="leading-relaxed text-sm break-keep mb-4">{aiSummary}</p>
                        
                        {keywords.length > 0 && (
                          <div className="flex flex-wrap gap-2 pt-3 border-t border-stone-100">
                            {keywords.map((kw, idx) => (
                              <span key={idx} className="px-2.5 py-1 bg-[#FDFBF7] text-amber-800 border border-amber-200/60 rounded-md text-[11px] font-medium font-sans">
                                #{kw}
                              </span>
                            ))}
                          </div>
                        )}
                      </div>
                    ) : (
                      <p className="text-stone-400 text-sm italic">원문을 충분히 인식한 후 요약을 제공합니다...</p>
                    )}
                  </div>
                )}

                {activeTab === 'characters' && (
                  <div className="space-y-3">
                    {characters.length > 0 ? (
                      characters.map((char, idx) => (
                        <div key={idx} className="bg-white p-4 rounded-xl shadow-sm border border-stone-100 flex gap-4">
                          <div className="w-10 h-10 bg-amber-50 rounded-full flex items-center justify-center shrink-0">
                            <Users className="w-5 h-5 text-amber-700" />
                          </div>
                          <div>
                            <h4 className="font-bold text-stone-900 text-sm mb-1">{char.name}</h4>
                            <p className="text-xs text-stone-600 leading-relaxed">{char.desc}</p>
                          </div>
                        </div>
                      ))
                    ) : (
                      <p className="text-stone-400 text-sm italic">발견된 인물 정보가 없습니다.</p>
                    )}
                  </div>
                )}

                {activeTab === 'chat' && (
                  <div className="flex flex-col h-full h-[200px]">
                    <div className="flex-1 overflow-y-auto space-y-4 pb-4 pr-2 font-sans [&::-webkit-scrollbar]:w-1.5 [&::-webkit-scrollbar-track]:bg-transparent [&::-webkit-scrollbar-thumb]:bg-stone-200 [&::-webkit-scrollbar-thumb]:rounded-full hover:[&::-webkit-scrollbar-thumb]:bg-stone-300">
                      {chatMessages.length > 0 ? (
                        chatMessages.map((msg, idx) => (
                          <div key={idx} className={`flex ${msg.role === 'user' ? 'justify-end' : 'justify-start'}`}>
                            <div className={`max-w-[85%] p-3.5 rounded-2xl text-sm leading-relaxed ${
                              msg.role === 'user' 
                                ? 'bg-amber-700 text-white rounded-tr-sm' 
                                : 'bg-white border border-stone-200 text-stone-800 rounded-tl-sm shadow-sm'
                            }`}>
                              {msg.content}
                            </div>
                          </div>
                        ))
                      ) : (
                        <div className="text-center text-stone-400 text-sm mt-10">
                          AI가 맥락을 파악한 후 대화를 제안합니다.
                        </div>
                      )}
                      <div ref={chatEndRef} />
                    </div>
                    
                    <div className="flex gap-2 shrink-0 bg-white p-2 rounded-full border border-stone-200 shadow-inner">
                      <input 
                        type="text" 
                        value={chatInput}
                        onChange={(e) => setChatInput(e.target.value)}
                        onKeyDown={(e) => e.key === 'Enter' && handleSendMessage()}
                        placeholder="궁금한 점을 물어보세요..."
                        className="flex-1 bg-transparent px-4 text-sm outline-none font-sans"
                      />
                      <button 
                        onClick={handleSendMessage}
                        className="w-10 h-10 bg-amber-700 text-white rounded-full flex items-center justify-center hover:bg-amber-800 transition-colors"
                      >
                        <Send className="w-4 h-4 -ml-0.5" />
                      </button>
                    </div>
                  </div>
                )}
              </div>
            </motion.div>
          )}
        </AnimatePresence>
      </div>

      {/* Bottom Controls */}
      <div className={`absolute bottom-0 left-0 w-full p-6 pb-safe pt-8 z-30 transition-colors duration-500 ${hasData ? 'bg-[#FDFBF7]' : 'bg-gradient-to-t from-stone-950 via-stone-950/90 to-transparent'}`}>
        <div className="flex items-center justify-center w-full">
          <button 
            onClick={() => setIsScanning(!isScanning)}
            className={`relative group flex items-center justify-center transition-all duration-300 ${
              isScanning ? 'scale-90' : 'scale-100'
            }`}
          >
            {/* Outer glowing ring */}
            <div className={`absolute inset-0 rounded-full transition-all duration-500 ${
              isScanning 
                ? 'bg-amber-500/20 blur-xl scale-150 animate-pulse' 
                : hasData ? 'bg-amber-500/10 blur-md scale-110' : 'bg-white/10 blur-md scale-110 group-hover:scale-125'
            }`} />
            
            {/* Middle decorative border */}
            <div className={`absolute inset-[-8px] rounded-full border-2 transition-colors duration-300 ${
              isScanning 
                ? 'border-amber-500/50 border-dashed animate-[spin_4s_linear_infinite]' 
                : hasData ? 'border-amber-300/30' : 'border-white/20'
            }`} />
            
            {/* Core button */}
            <div className={`relative w-20 h-20 rounded-full flex items-center justify-center shadow-2xl transition-all duration-300 overflow-hidden ${
              isScanning 
                ? 'bg-amber-600' 
                : 'bg-gradient-to-br from-stone-100 to-stone-300'
            }`}>
              
              {/* Inner animated element */}
              {isScanning ? (
                <div className="w-8 h-8 bg-amber-50 rounded-md transition-all duration-300 shadow-inner" /> 
              ) : (
                <>
                  <div className="absolute inset-0 bg-white/40 backdrop-blur-sm" />
                  <div className="w-16 h-16 rounded-full border-[3px] border-stone-800/80 transition-all duration-300" />
                </>
              )}
            </div>
          </button>
        </div>
        <p className={`text-center text-xs font-medium mt-6 tracking-wide ${hasData ? 'text-stone-500' : 'text-stone-400'}`}>
          {isScanning ? '인식 중지' : hasData ? '다시 스캔하기' : '실시간 스캔 시작'}
        </p>
      </div>
    </div>
  );
}