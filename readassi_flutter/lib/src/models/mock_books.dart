import 'book.dart';

const mockBooks = <Book>[
  Book(
    id: 'b1',
    title: '시간의 파수꾼',
    author: '헤일리 로즈',
    coverUrl:
        'https://images.unsplash.com/photo-1772225027406-00bda64076b6?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&ixid=M3w3Nzg4Nzd8MHwxfHNlYXJjaHwxfHxib29rJTIwY292ZXIlMjBzY2llbmNlJTIwZmljdGlvbnxlbnwxfHx8fDE3NzM3ODM4MDJ8MA&ixlib=rb-4.1.0&q=80&w=1080&utm_source=figma&utm_medium=referral',
    summary:
        '천재 물리학자가 시간의 균열을 발견하면서 벌어지는 이야기를 다룹니다. 진실에 가까워질수록 주인공을 막으려는 세력도 더 선명하게 드러납니다.',
    keywords: ['SF', '시간 이동', '천재 물리학자', '미스터리'],
    characters: [
      Character(
        id: 'c1',
        name: '미라 데이즈',
        role: '주인공',
        description: '시간의 균열을 연구하는 천재 물리학자입니다.',
        imageUrl:
            'https://images.unsplash.com/photo-1580489944761-15a19d654956?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&ixid=M3w3Nzg4Nzd8MHwxfHNlYXJjaHwxfHx3b21hbiUyMHBvcnRyYWl0fGVufDF8fHx8MTc3Mzc0MDU3NXww&ixlib=rb-4.1.0&q=80&w=1080&utm_source=figma&utm_medium=referral',
      ),
      Character(
        id: 'c2',
        name: '줄리안',
        role: '협력자',
        description: '사라진 차원의 비밀을 뒤쫓는 조사 요원입니다.',
        imageUrl:
            'https://images.unsplash.com/photo-1506794778202-cad84cf45f1d?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&ixid=M3w3Nzg4Nzd8MHwxfHNlYXJjaHwxfHxtYW4lMjBwb3J0cmFpdHxlbnwxfHx8fDE3NzM3OTQ1MTB8MA&ixlib=rb-4.1.0&q=80&w=1080&utm_source=figma&utm_medium=referral',
      ),
      Character(
        id: 'c3',
        name: '에이든 교수',
        role: '조력자',
        description: '미라의 지도 교수이자 차원 이론을 수호하려는 인물입니다.',
        imageUrl:
            'https://images.unsplash.com/photo-1503443062224-9f77d743cf25?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&ixid=M3w3Nzg4Nzd8MHwxfHNlYXJjaHwxfHxvbGQlMjBtYW4lMjBwb3J0cmFpdHxlbnwxfHx8fDE3NzM3OTQ1MTB8MA&ixlib=rb-4.1.0&q=80&w=1080&utm_source=figma&utm_medium=referral',
      ),
    ],
    relationships: [
      Relationship(source: 'c1', target: 'c2', label: '공동 추적'),
      Relationship(source: 'c1', target: 'c3', label: '스승과 제자'),
      Relationship(source: 'c2', target: 'c3', label: '숨겨진 이해관계'),
    ],
    currentPage: 240,
    totalPages: 320,
    progress: 75,
  ),
  Book(
    id: 'b2',
    title: '별빛의 그림자',
    author: '마리 엘렌',
    coverUrl:
        'https://images.unsplash.com/photo-1711185892188-13f35959d3ca?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&ixid=M3w3Nzg4Nzd8MHwxfHNlYXJjaHwxfHxib29rJTIwY292ZXIlMjBmYW50YXN5fGVufDF8fHx8MTc3Mzc0OTQyOHww&ixlib=rb-4.1.0&q=80&w=1080&utm_source=figma&utm_medium=referral',
    summary: '마법과 기술의 경계에서 살아가는 주인공이 자신의 숨겨진 정체와 마주하며 성장하는 판타지 소설입니다.',
    keywords: ['판타지', '마법', '정체성', '모험'],
    characters: [],
    relationships: [],
    currentPage: 135,
    totalPages: 450,
    progress: 30,
  ),
  Book(
    id: 'b3',
    title: '침묵의 관찰자',
    author: '에릭 머로',
    coverUrl:
        'https://images.unsplash.com/photo-1604435062356-a880b007922c?crop=entropy&cs=tinysrgb&fit=max&fm=jpg&ixid=M3w3Nzg4Nzd8MHwxfHNlYXJjaHwxfHxib29rJTIwY292ZXIlMjBteXN0ZXJ5fGVufDF8fHx8MTc3Mzc5NDUwM3ww&ixlib=rb-4.1.0&q=80&w=1080&utm_source=figma&utm_medium=referral',
    summary: '형사가 미제 사건의 단서를 하나씩 모으며 조용하지만 집요하게 진실을 추적하는 미스터리 작품입니다.',
    keywords: ['스릴러', '연쇄 사건', '추리', '미스터리'],
    characters: [],
    relationships: [],
    currentPage: 28,
    totalPages: 280,
    progress: 10,
  ),
];
