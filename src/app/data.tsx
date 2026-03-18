import { createContext, useContext, useState, ReactNode } from 'react';

export interface Character {
  id: string;
  name: string;
  role: string;
  description: string;
  imageUrl: string;
}

export interface Relationship {
  source: string;
  target: string;
  label: string;
}

export interface Book {
  id: string;
  title: string;
  author: string;
  coverUrl: string;
  summary: string;
  keywords?: string[];
  characters: Character[];
  relationships: Relationship[];
  currentPage?: number;
  totalPages?: number;
  progress?: number;
}

export const mockBooks: Book[] = [
  {
    id: "b1",
    title: "양자 수수께끼",
    author: "엘레나 로스토바",
    coverUrl: "https://images.unsplash.com/photo-1772225027406-00bda64076b6?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&ixid=M3w3Nzg4Nzd8MHwxfHNlYXJjaHwxfHxib29rJTIwY292ZXIlMjBzY2llbmNlJTIwZmljdGlvbnxlbnwxfHx8fDE3NzM3ODM4MDJ8MA&ixlib=rb-4.1.0&q=80&w=1080&utm_source=figma&utm_medium=referral",
    summary: "천재 물리학자가 우리가 사는 세상과 똑같은 숨겨진 차원을 발견합니다. 그녀가 진실을 파헤치는 동안, 정체불명의 인물이 그녀를 막으려 합니다.",
    keywords: ["SF", "차원 이동", "천재 물리학자", "미스터리"],
    characters: [
      {
        id: "c1",
        name: "닥터 엘라라 밴스",
        role: "주인공",
        description: "다른 차원을 연구하는 천재 물리학자.",
        imageUrl: "https://images.unsplash.com/photo-1580489944761-15a19d654956?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&ixid=M3w3Nzg4Nzd8MHwxfHNlYXJjaHwxfHx3b21hbiUyMHBvcnRyYWl0fGVufDF8fHx8MTc3Mzc0MDU3NXww&ixlib=rb-4.1.0&q=80&w=1080&utm_source=figma&utm_medium=referral"
      },
      {
        id: "c2",
        name: "줄리안",
        role: "악역",
        description: "숨겨진 차원의 비밀을 아는 비밀 요원.",
        imageUrl: "https://images.unsplash.com/photo-1506794778202-cad84cf45f1d?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&ixid=M3w3Nzg4Nzd8MHwxfHNlYXJjaHwxfHxtYW4lMjBwb3J0cmFpdHxlbnwxfHx8fDE3NzM3OTQ1MTB8MA&ixlib=rb-4.1.0&q=80&w=1080&utm_source=figma&utm_medium=referral"
      },
      {
        id: "c3",
        name: "아서 교수",
        role: "조력자",
        description: "엘라라의 지도 교수이자 차원의 비밀 수호자.",
        imageUrl: "https://images.unsplash.com/photo-1503443062224-9f77d743cf25?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&ixid=M3w3Nzg4Nzd8MHwxfHNlYXJjaHwxfHxvbGQlMjBtYW4lMjBwb3J0cmFpdHxlbnwxfHx8fDE3NzM3OTQ1MTB8MA&ixlib=rb-4.1.0&q=80&w=1080&utm_source=figma&utm_medium=referral"
      }
    ],
    relationships: [
      { source: "c1", target: "c2", label: "적대 관계" },
      { source: "c1", target: "c3", label: "스승과 제자" },
      { source: "c2", target: "c3", label: "오랜 라이벌" }
    ],
    currentPage: 240,
    totalPages: 320,
    progress: 75
  },
  {
    id: "b2",
    title: "왕국의 그림자",
    author: "마커스 쏜",
    coverUrl: "https://images.unsplash.com/photo-1711185892188-13f35959d3ca?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&ixid=M3w3Nzg4Nzd8MHwxfHNlYXJjaHwxfHxib29rJTIwY292ZXIlMjBmYW50YXN5fGVufDF8fHx8MTc3Mzc0OTQyOHww&ixlib=rb-4.1.0&q=80&w=1080&utm_source=figma&utm_medium=referral",
    summary: "마법이 금지된 세계에서, 한 젊은 도둑이 자신이 왕좌의 정당한 후계자라는 사실을 알게 됩니다.",
    keywords: ["판타지", "마법", "왕좌", "모험"],
    characters: [],
    relationships: [],
    currentPage: 135,
    totalPages: 450,
    progress: 30
  },
  {
    id: "b3",
    title: "침묵의 관찰자",
    author: "앨리스 먼로",
    coverUrl: "https://images.unsplash.com/photo-1604435062356-a880b007922c?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&ixid=M3w3Nzg4Nzd8MHwxfHNlYXJjaHwxfHxib29rJTIwY292ZXIlMjBteXN0ZXJ5fGVufDF8fHx8MTc3Mzc5NDUwM3ww&ixlib=rb-4.1.0&q=80&w=1080&utm_source=figma&utm_medium=referral",
    summary: "형사가 미출간 원고의 줄거리를 그대로 따르는 연쇄 살인 사건을 해결해야 합니다.",
    keywords: ["스릴러", "연쇄살인", "추리", "미스터리"],
    characters: [],
    relationships: [],
    currentPage: 28,
    totalPages: 280,
    progress: 10
  }
];

interface AppContextType {
  books: Book[];
  addBook: (book: Book) => void;
}

const AppContext = createContext<AppContextType | undefined>(undefined);

export function AppProvider({ children }: { children: ReactNode }) {
  const [books, setBooks] = useState<Book[]>(mockBooks);

  const addBook = (book: Book) => {
    setBooks(prev => [book, ...prev]);
  };

  return (
    <AppContext.Provider value={{ books, addBook }}>
      {children}
    </AppContext.Provider>
  );
}

export function useAppContext() {
  const context = useContext(AppContext);
  if (context === undefined) {
    throw new Error('useAppContext must be used within an AppProvider');
  }
  return context;
}
