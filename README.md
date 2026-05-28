# 헬스케어 플랫폼

개인 맞춤 건강 관리 플랫폼 — 진료 기록, 건강 정보, AI 챗봇, OCR을 통합한 헬스케어 앱

## 현재 구현 상태 (프로토타입)

| 기능 | 상태 |
|------|------|
| 회원가입 / 로그인 | ✅ 완료 |
| 내 건강 정보 (기본정보·약물·알러지·지병·접종) | ✅ 완료 |
| 복용 약물 조회 | ✅ 완료 |
| 접종 이력 조회 | ✅ 완료 |
| 진료 기록 CRUD | ✅ 완료 |
| DB 스키마 설계 | ✅ 완료 |

## 기술 스택

### 프로토타입 (현재)
- **Frontend**: HTML + Bootstrap 5 + Vanilla JS
- **저장소**: localStorage (DB 없음)
- **인증**: SHA-256 해시 (클라이언트 사이드)

### 목표 스택
| 영역 | 기술 |
|------|------|
| Frontend | React + MUI |
| Backend | FastAPI + PostgreSQL |
| AI/ML | GPT-4o, LangChain, Whisper, EasyOCR |
| 인증 | JWT + OAuth 2.0 (Google/Naver/Kakao) |
| 저장소 | AWS S3, AWS RDS |
| 배포 | AWS EC2, Docker, NGINX |
| 모바일 | React Native (WebView) |

## 프로젝트 구조

```
healthcare-platform/
├── frontend/
│   └── index.html          # 프로토타입 단일 파일 앱
├── database/
│   └── schema.sql          # PostgreSQL 스키마 (16개 테이블)
└── README.md
```

## 로컬 실행

```bash
# frontend/index.html 을 브라우저에서 바로 열면 됩니다.
# 서버 불필요 — localStorage 기반 동작
```

## DB 스키마 주요 테이블

| 테이블 | 설명 |
|--------|------|
| `users` | 사용자 계정 |
| `health_basic` | 기본 건강 정보 |
| `medications` + `medication_times` | 복용 약물 |
| `allergies` | 알러지 |
| `user_diseases` | 지병 |
| `vaccinations` | 접종 이력 |
| `medical_records` + `record_prescriptions` | 진료 기록 |
| `files` | S3 파일 메타데이터 |
| `chat_sessions` + `chat_messages` | AI 챗봇 이력 |
| `llm_audit_logs` | LLM 감사 로그 |

## 개발 계획 (스프린트)

> 전체 계획: 10 스프린트 × 2주 = 20주

- **Sprint 1–2**: 인프라 (AWS EC2, Docker, NGINX, RDS)
- **Sprint 3–4**: FastAPI 백엔드 + React 프론트엔드 전환
- **Sprint 5–6**: AI 파이프라인 (OCR, STT, LLM)
- **Sprint 7**: AI 챗봇 (LangGraph)
- **Sprint 8**: 알림 서비스 + React Native
- **Sprint 9–10**: 보안 강화, 성능 최적화, 운영 배포

## 라이선스

MIT
