import { useState, useRef, useEffect } from "react";
import { useParams, useNavigate } from "react-router";
import { ChevronLeft, Info, Users, Network, MessageCircle, BookOpen, Send, Sparkles } from "lucide-react";
import { useAppContext, Character } from "../data";
import { motion } from "motion/react";

interface Message {
  id: string;
  role: 'user' | 'assistant';
  content: string;
}

export function BookDetailPage() {
  const { id } = useParams();
  const navigate = useNavigate();
  const { books } = useAppContext();
  const book = books.find(b => b.id === id);
  const [activeTab, setActiveTab] = useState<'summary' | 'characters' | 'map' | 'chat'>('summary');

  const [messages, setMessages] = useState<Message[]>([
    {
      id: "m1",
      role: 'assistant',
      content: `안녕하세요. 책 서재지기입니다. 이 책의 이야기, 등장인물, 또는 숨겨진 의미에 대해 자유롭게 질문해 주세요.`
    }
  ]);
  const [input, setInput] = useState("");
  const messagesEndRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (activeTab === 'chat') {
      messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
    }
  }, [messages, activeTab]);

  const handleSend = () => {
    if (!input.trim() || !book) return;

    const newMsg: Message = { id: Date.now().toString(), role: 'user', content: input };
    setMessages(prev => [...prev, newMsg]);
    setInput("");

    // Mock AI response
    setTimeout(() => {
      const aiResponse: Message = { 
        id: (Date.now() + 1).toString(), 
        role: 'assistant', 
        content: `"${book.title}"에서 읽어들인 문장들을 살펴보면, 깊은 내면적인 갈등이 있는 것을 알 수 있습니다. 특정 장면에 대해 더 이야기해 볼까요?`
      };
      setMessages(prev => [...prev, aiResponse]);
    }, 1000);
  };

  if (!book) return <div className="p-6 pt-20 text-center text-stone-500">책을 찾을 수 없습니다.</div>;

  return (
    <div className="min-h-full bg-[#FDFBF7] flex flex-col relative pb-20 font-sans">
      {/* Header Image */}
      <div className="relative h-72 w-full shadow-sm">
        <div className="absolute inset-0 bg-gradient-to-t from-stone-900/80 via-stone-900/30 to-black/40 z-10" />
        <img src={book.coverUrl} alt={book.title} className="w-full h-full object-cover" />
        
        {/* Nav */}
        <div className="absolute top-0 left-0 w-full p-6 pt-12 z-20 flex justify-between items-center">
          <button 
            onClick={() => navigate(-1)}
            className="w-10 h-10 rounded-full bg-white/20 backdrop-blur-md flex items-center justify-center text-white hover:bg-white/30 transition-colors"
          >
            <ChevronLeft className="w-6 h-6" />
          </button>
        </div>

        {/* Title Info */}
        <div className="absolute bottom-6 left-6 right-6 z-20 text-white">
          <h1 className="text-3xl font-bold leading-tight mb-2 font-serif text-amber-50 drop-shadow-md">{book.title}</h1>
          <p className="text-sm text-stone-300 font-medium flex items-center gap-1">
            {book.author}
          </p>
        </div>
      </div>

      {/* Tabs */}
      <div className="flex border-b border-stone-200 sticky top-0 bg-[#FDFBF7]/95 backdrop-blur-sm z-30 px-2">
        {[
          { id: 'summary', icon: Info, label: '이야기' },
          { id: 'characters', icon: Users, label: '인물' },
          { id: 'map', icon: Network, label: '관계' },
          { id: 'chat', icon: MessageCircle, label: '질문하기' },
        ].map((tab) => (
          <button
            key={tab.id}
            onClick={() => setActiveTab(tab.id as any)}
            className={`flex-1 flex flex-col items-center py-4 px-2 gap-1.5 relative transition-colors ${
              activeTab === tab.id ? 'text-amber-800' : 'text-stone-500 hover:text-stone-700'
            }`}
          >
            <tab.icon className="w-5 h-5" />
            <span className="text-[11px] font-bold tracking-wider">{tab.label}</span>
            {activeTab === tab.id && (
              <motion.div 
                layoutId="activeTab" 
                className="absolute bottom-0 left-2 right-2 h-0.5 bg-amber-700 rounded-t-full" 
              />
            )}
          </button>
        ))}
      </div>

      {/* Content Area */}
      <div className="p-6 flex-1">
        {activeTab === 'summary' && (
          <motion.div 
            initial={{ opacity: 0, y: 10 }} 
            animate={{ opacity: 1, y: 0 }}
            className="space-y-8"
          >
            <div className="bg-white p-5 rounded-2xl shadow-sm border border-stone-100">
              <h3 className="text-lg font-bold text-stone-800 mb-4 font-serif flex items-center gap-2">
                <BookOpen className="w-5 h-5 text-amber-700" />
                줄거리
              </h3>
              <p className="text-stone-700 leading-loose text-[15px] font-serif break-keep mb-6">
                {book.summary}
              </p>
              
              {book.keywords && book.keywords.length > 0 && (
                <div className="pt-4 border-t border-stone-100">
                  <h4 className="text-sm font-bold text-stone-800 mb-3 font-serif flex items-center gap-2">
                    <Sparkles className="w-4 h-4 text-amber-600" />
                    핵심 키워드
                  </h4>
                  <div className="flex flex-wrap gap-2">
                    {book.keywords.map((kw, idx) => (
                      <span key={idx} className="px-3 py-1.5 bg-[#FDFBF7] text-amber-800 border border-amber-200/60 rounded-lg text-[13px] font-medium font-sans">
                        #{kw}
                      </span>
                    ))}
                  </div>
                </div>
              )}
            </div>
          </motion.div>
        )}

        {activeTab === 'characters' && (
          <motion.div 
            initial={{ opacity: 0, y: 10 }} 
            animate={{ opacity: 1, y: 0 }}
            className="space-y-4"
          >
            {book.characters.length > 0 ? (
              book.characters.map((char: Character) => (
                <div key={char.id} className="flex gap-4 items-start p-4 bg-white rounded-2xl border border-stone-100 shadow-sm">
                  <img src={char.imageUrl} alt={char.name} className="w-16 h-16 rounded-xl object-cover border border-stone-200 shadow-sm" />
                  <div>
                    <h4 className="font-bold text-stone-800 font-serif text-lg">{char.name}</h4>
                    <span className="inline-block mt-1 px-2.5 py-0.5 bg-stone-100 text-stone-600 rounded-md text-[11px] font-medium">
                      {char.role}
                    </span>
                    <p className="text-[13px] text-stone-500 mt-2 leading-relaxed">{char.description}</p>
                  </div>
                </div>
              ))
            ) : (
              <div className="flex flex-col items-center justify-center py-16 text-stone-400">
                <Users className="w-12 h-12 mb-4 opacity-50" />
                <p className="text-sm text-center">아직 기록된 인물 정보가 없습니다.<br/>책을 더 스캔하여 분석해보세요.</p>
              </div>
            )}
          </motion.div>
        )}

        {activeTab === 'map' && (
          <motion.div 
            initial={{ opacity: 0, y: 10 }} 
            animate={{ opacity: 1, y: 0 }}
            className="h-80 bg-white rounded-2xl border border-stone-100 shadow-sm flex items-center justify-center p-4 relative overflow-hidden"
          >
            {book.characters.length > 2 ? (
              <div className="relative w-full h-full max-w-[300px] max-h-[300px]">
                {/* SVG Lines for Relationships */}
                <svg className="absolute inset-0 w-full h-full pointer-events-none" style={{ zIndex: 0 }}>
                  <line x1="150" y1="60" x2="60" y2="200" stroke="#d6d3d1" strokeWidth="1.5" strokeDasharray="4 4" />
                  <line x1="150" y1="60" x2="240" y2="200" stroke="#d6d3d1" strokeWidth="1.5" strokeDasharray="4 4" />
                  <line x1="60" y1="200" x2="240" y2="200" stroke="#d6d3d1" strokeWidth="1.5" strokeDasharray="4 4" />
                </svg>

                {/* Nodes */}
                <div className="absolute top-4 left-1/2 -translate-x-1/2 flex flex-col items-center">
                  <img src={book.characters[0].imageUrl} className="w-14 h-14 rounded-full border-2 border-amber-600 z-10 shadow-sm" />
                  <span className="text-[11px] font-bold mt-1.5 bg-white px-2 py-0.5 rounded-full border border-stone-200 shadow-sm text-stone-700">{book.characters[0].name}</span>
                </div>
                
                <div className="absolute bottom-6 left-2 flex flex-col items-center">
                  <img src={book.characters[1].imageUrl} className="w-14 h-14 rounded-full border-2 border-stone-400 z-10 shadow-sm" />
                  <span className="text-[11px] font-bold mt-1.5 bg-white px-2 py-0.5 rounded-full border border-stone-200 shadow-sm text-stone-700">{book.characters[1].name}</span>
                </div>
                
                <div className="absolute bottom-6 right-2 flex flex-col items-center">
                  <img src={book.characters[2].imageUrl} className="w-14 h-14 rounded-full border-2 border-stone-600 z-10 shadow-sm" />
                  <span className="text-[11px] font-bold mt-1.5 bg-white px-2 py-0.5 rounded-full border border-stone-200 shadow-sm text-stone-700">{book.characters[2].name}</span>
                </div>

                {/* Labels */}
                <div className="absolute top-[45%] left-[10%] text-[10px] bg-[#FDFBF7] px-2 py-0.5 rounded-full text-amber-700 font-medium border border-amber-100/50 shadow-sm">{book.relationships[0]?.label || ''}</div>
                <div className="absolute top-[45%] right-[10%] text-[10px] bg-[#FDFBF7] px-2 py-0.5 rounded-full text-amber-700 font-medium border border-amber-100/50 shadow-sm">{book.relationships[1]?.label || ''}</div>
                <div className="absolute bottom-[25px] left-1/2 -translate-x-1/2 text-[10px] bg-[#FDFBF7] px-2 py-0.5 rounded-full text-amber-700 font-medium border border-amber-100/50 shadow-sm">{book.relationships[2]?.label || ''}</div>
              </div>
            ) : (
              <div className="flex flex-col items-center text-stone-400">
                <Network className="w-10 h-10 mb-3 opacity-50" />
                <p className="text-sm text-center">관계를 표시할 충분한 인물 정보가 없습니다.</p>
              </div>
            )}
          </motion.div>
        )}

        {activeTab === 'chat' && (
          <motion.div 
            initial={{ opacity: 0, y: 10 }} 
            animate={{ opacity: 1, y: 0 }}
            className="flex flex-col h-[600px] bg-white rounded-2xl border border-stone-100 shadow-sm overflow-hidden"
          >
            <div className="flex-1 overflow-y-auto p-4 space-y-4 bg-[#FDFBF7] [&::-webkit-scrollbar]:w-1.5 [&::-webkit-scrollbar-track]:bg-transparent [&::-webkit-scrollbar-thumb]:bg-stone-200 [&::-webkit-scrollbar-thumb]:rounded-full hover:[&::-webkit-scrollbar-thumb]:bg-stone-300">
              {messages.map((msg) => (
                <div key={msg.id} className={`flex ${msg.role === 'user' ? 'justify-end' : 'justify-start'}`}>
                  <div 
                    className={`max-w-[85%] rounded-2xl px-4 py-3 text-[14px] leading-relaxed shadow-sm ${
                      msg.role === 'user' 
                        ? 'bg-amber-700 text-amber-50 rounded-br-sm' 
                        : 'bg-white text-stone-700 border border-stone-100 rounded-bl-sm font-serif break-keep'
                    }`}
                  >
                    {msg.content}
                  </div>
                </div>
              ))}
              <div ref={messagesEndRef} />
            </div>

            <div className="bg-white border-t border-stone-200 p-3">
              <div className="flex items-end gap-2 bg-[#FDFBF7] p-2 rounded-xl border border-stone-200 focus-within:border-amber-400 focus-within:ring-1 focus-within:ring-amber-400/20 transition-all">
                <textarea 
                  value={input}
                  onChange={(e) => setInput(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter' && !e.shiftKey) {
                      e.preventDefault();
                      handleSend();
                    }
                  }}
                  placeholder="질문을 입력하세요..."
                  className="flex-1 max-h-32 min-h-[40px] bg-transparent resize-none outline-none text-[14px] p-2 text-stone-800 placeholder:text-stone-400"
                  rows={1}
                />
                <button 
                  onClick={handleSend}
                  disabled={!input.trim()}
                  className="p-2.5 bg-stone-800 text-stone-50 rounded-lg mb-0.5 disabled:opacity-40 disabled:bg-stone-400 shrink-0 transition-colors hover:bg-stone-700"
                >
                  <Send className="w-4 h-4" />
                </button>
              </div>
            </div>
          </motion.div>
        )}
      </div>

    </div>
  );
}