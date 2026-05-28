-- =============================================================
--  헬스케어 플랫폼 PostgreSQL 스키마
--  기준: healthcare.html localStorage 구조 및 요구사항 정의서
--  DB  : PostgreSQL 14+
--  작성: 2026-05-28
-- =============================================================

-- 확장 활성화
CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "pg_trgm";    -- 한글 LIKE 인덱스

-- =============================================================
--  ENUM 타입 정의
-- =============================================================

CREATE TYPE gender_type      AS ENUM ('male', 'female', 'other');
CREATE TYPE blood_type       AS ENUM ('A+','A-','B+','B-','O+','O-','AB+','AB-','unknown');
CREATE TYPE med_time_slot    AS ENUM ('아침','점심','저녁','취침 전');
CREATE TYPE allergy_type     AS ENUM ('drug','food');
CREATE TYPE guardian_status  AS ENUM ('pending','accepted','rejected');
CREATE TYPE notification_type AS ENUM ('medication','checkup','hospital','warning','general');
CREATE TYPE dept_type        AS ENUM (
    '내과','외과','정형외과','피부과','안과','이비인후과',
    '치과','산부인과','소아청소년과','신경과','정신건강의학과',
    '응급의학과','가정의학과','기타'
);
CREATE TYPE file_category    AS ENUM ('prescription','diagnosis','checkup','other');

-- =============================================================
--  updated_at 자동 갱신 트리거 함수 (공통)
-- =============================================================

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =============================================================
--  1. USERS  —  사용자 계정
--     REG01 FBF-01, ACC01 FBF-04/05/08/09
-- =============================================================

CREATE TABLE users (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    email        VARCHAR(255) NOT NULL,
    name         VARCHAR(50)  NOT NULL,
    password_hash VARCHAR(255) NOT NULL,      -- bcrypt (운영) / SHA-256 (현재 FE)
    provider     VARCHAR(20)  NOT NULL DEFAULT 'email',  -- email / google / naver / kakao
    provider_uid VARCHAR(255),               -- 소셜 로그인 고유 ID
    is_active    BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    deleted_at   TIMESTAMPTZ,                -- 소프트 딜리트 (FBF-03/12 회원 탈퇴)

    -- 활성 계정에 대해서만 email 중복 방지 (탈퇴 후 재가입 허용)
    -- UNIQUE 제약 대신 아래 partial unique index 사용

    CONSTRAINT chk_provider   CHECK (provider IN ('email','google','naver','kakao'))
);

COMMENT ON TABLE  users              IS '사용자 계정 (REG01, ACC01)';
COMMENT ON COLUMN users.provider     IS 'email | google | naver | kakao';
COMMENT ON COLUMN users.deleted_at   IS 'NOT NULL 이면 탈퇴 처리된 계정';

-- 활성 계정만 email 유일성 보장 (탈퇴 계정은 동일 email 재가입 가능)
CREATE UNIQUE INDEX uq_users_email_active ON users (email) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_provider           ON users (provider, provider_uid);

CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================
--  2. SESSIONS  —  JWT Refresh Token
--     ACC01 FFC-05
-- =============================================================

CREATE TABLE sessions (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    refresh_token VARCHAR(512) NOT NULL UNIQUE,
    device_info   TEXT,                          -- user-agent 등
    ip_address    INET,
    expires_at    TIMESTAMPTZ NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    revoked_at    TIMESTAMPTZ                    -- 명시적 로그아웃
);

COMMENT ON TABLE sessions IS 'JWT Refresh Token 관리 (ACC01 FFC-05)';

CREATE INDEX idx_sessions_user_id ON sessions (user_id);
CREATE INDEX idx_sessions_token   ON sessions (refresh_token) WHERE revoked_at IS NULL;

-- =============================================================
--  3. USER_GUARDIANS  —  보호자 연결
--     ACC01 FBF-11
-- =============================================================

CREATE TABLE user_guardians (
    id           UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID           NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    guardian_id  UUID           NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status       guardian_status NOT NULL DEFAULT 'pending',
    created_at   TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    responded_at TIMESTAMPTZ,

    CONSTRAINT uq_user_guardian UNIQUE (user_id, guardian_id),
    CONSTRAINT chk_no_self_guardian CHECK (user_id <> guardian_id)
);

COMMENT ON TABLE  user_guardians             IS '보호자 계정 연결 (FBF-11)';
COMMENT ON COLUMN user_guardians.user_id     IS '피보호자 (환자)';
COMMENT ON COLUMN user_guardians.guardian_id IS '보호자 (부모/보호인)';

CREATE INDEX idx_guardians_user_id     ON user_guardians (user_id);
CREATE INDEX idx_guardians_guardian_id ON user_guardians (guardian_id);

-- =============================================================
--  4. HEALTH_BASIC  —  기본 건강 정보
--     HLT01 FBF-13
-- =============================================================

CREATE TABLE health_basic (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID        NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    birthdate   DATE,
    gender      gender_type,
    height_cm   NUMERIC(5,1) CHECK (height_cm BETWEEN 50 AND 250),
    weight_kg   NUMERIC(5,1) CHECK (weight_kg BETWEEN 10 AND 300),
    blood_type  blood_type,
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  health_basic           IS '기본 건강 정보 (HLT01 FBF-13)';
COMMENT ON COLUMN health_basic.height_cm IS '신장 (cm), 50~250 범위';
COMMENT ON COLUMN health_basic.weight_kg IS '체중 (kg), 10~300 범위';

CREATE TRIGGER trg_health_basic_updated_at
    BEFORE UPDATE ON health_basic
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================
--  5. MEDICATIONS  —  복용 약물 / 영양제
--     HLT01 FBF-14
-- =============================================================

CREATE TABLE medications (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name        VARCHAR(200) NOT NULL,
    dose        VARCHAR(100),                    -- '100mg', '1정' 등
    start_date  DATE,
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ
);

COMMENT ON TABLE  medications           IS '복용 약물 / 영양제 (HLT01 FBF-14)';
COMMENT ON COLUMN medications.dose      IS '복용 용량 (예: 100mg, 1정, 2캡슐)';
COMMENT ON COLUMN medications.is_active IS 'FALSE 면 복용 중단';

CREATE INDEX idx_medications_user_id ON medications (user_id) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_medications_updated_at
    BEFORE UPDATE ON medications
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 복용 시간 (약물 1개 : 시간대 N개)
CREATE TABLE medication_times (
    id            UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    medication_id UUID         NOT NULL REFERENCES medications(id) ON DELETE CASCADE,
    time_slot     med_time_slot NOT NULL,

    CONSTRAINT uq_medication_time UNIQUE (medication_id, time_slot)
);

COMMENT ON TABLE medication_times IS '복용 시간대 (아침/점심/저녁/취침 전)';

CREATE INDEX idx_med_times_med_id ON medication_times (medication_id);

-- =============================================================
--  6. ALLERGIES  —  알러지 정보
--     HLT01 FBF-15
-- =============================================================

CREATE TABLE allergies (
    id           UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    allergy_type allergy_type NOT NULL,          -- drug | food
    name         VARCHAR(200) NOT NULL,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_allergy UNIQUE (user_id, allergy_type, name)
);

COMMENT ON TABLE  allergies              IS '알러지 정보 (HLT01 FBF-15)';
COMMENT ON COLUMN allergies.allergy_type IS 'drug=약물알러지, food=식품알러지';

-- 공백 정규화 UNIQUE: 앞뒤 공백이 달라도 중복 방지
CREATE UNIQUE INDEX uq_allergy_normalized
    ON allergies (user_id, allergy_type, TRIM(name));
CREATE INDEX idx_allergies_user_id ON allergies (user_id, allergy_type);

-- =============================================================
--  7. DISEASE_MASTER  —  지병 마스터 (시스템 정의 15개)
--     HLT01 FBF-16
-- =============================================================

CREATE TABLE disease_master (
    id         SMALLSERIAL  PRIMARY KEY,
    name       VARCHAR(100) NOT NULL UNIQUE,
    category   VARCHAR(50),
    sort_order SMALLINT     NOT NULL DEFAULT 0
);

COMMENT ON TABLE disease_master IS '지병 마스터 데이터 (시스템 정의)';

-- 마스터 데이터 삽입
INSERT INTO disease_master (name, category, sort_order) VALUES
    ('당뇨(제1형)',       '내분비',    1),
    ('당뇨(제2형)',       '내분비',    2),
    ('고혈압',            '심혈관',    3),
    ('고지혈증',          '심혈관',    4),
    ('심장질환',          '심혈관',    5),
    ('뇌혈관질환',        '신경',      6),
    ('갑상선질환',        '내분비',    7),
    ('신장질환',          '비뇨기',    8),
    ('간질환',            '소화기',    9),
    ('폐질환',            '호흡기',   10),
    ('암(악성종양)',       '종양',     11),
    ('골다공증',          '근골격',   12),
    ('천식',              '호흡기',   13),
    ('관절염',            '근골격',   14),
    ('우울증/불안장애',   '정신건강', 15);

-- =============================================================
--  8. USER_DISEASES  —  사용자별 지병 (선택 + 직접입력)
--     HLT01 FBF-16
-- =============================================================

CREATE TABLE user_diseases (
    id                UUID     PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           UUID     NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    disease_master_id SMALLINT REFERENCES disease_master(id),  -- NULL 이면 직접 입력
    custom_name       VARCHAR(200),                            -- 직접 입력 질환명
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_disease_source CHECK (
        (disease_master_id IS NOT NULL AND custom_name IS NULL)
        OR
        (disease_master_id IS NULL AND custom_name IS NOT NULL AND TRIM(custom_name) <> '')
    ),
    CONSTRAINT uq_user_master_disease UNIQUE (user_id, disease_master_id)
);

COMMENT ON TABLE  user_diseases                  IS '사용자별 지병 목록 (HLT01 FBF-16)';
COMMENT ON COLUMN user_diseases.disease_master_id IS 'NULL이면 직접 입력 질환';
COMMENT ON COLUMN user_diseases.custom_name       IS '마스터 목록 외 직접 입력 질환명';

CREATE INDEX idx_user_diseases_user_id ON user_diseases (user_id);

-- =============================================================
--  9. VACCINATIONS  —  접종 이력
--     HLT01 FBF-17
-- =============================================================

CREATE TABLE vaccinations (
    id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name           VARCHAR(200) NOT NULL,
    vaccinated_at  DATE,
    hospital       VARCHAR(200),
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    deleted_at     TIMESTAMPTZ
);

COMMENT ON TABLE  vaccinations              IS '예방접종 이력 (HLT01 FBF-17)';
COMMENT ON COLUMN vaccinations.vaccinated_at IS '접종 날짜';

-- 날짜 내림차순 정렬 포함 (앱의 최신순 정렬 최적화)
CREATE INDEX idx_vaccinations_user_id
    ON vaccinations (user_id, vaccinated_at DESC) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_vaccinations_updated_at
    BEFORE UPDATE ON vaccinations
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================
--  10. MEDICAL_RECORDS  —  진료 기록
--      MED01 FBF-18, FFJ-05
-- =============================================================

CREATE TABLE medical_records (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    visited_at  DATE        NOT NULL,                -- 진료 날짜
    hospital    VARCHAR(200) NOT NULL,
    department  dept_type,
    symptoms    TEXT,                                -- 주증상 (자유 입력)
    diagnosis   TEXT,                               -- 진단 내용
    notes       TEXT,                               -- 메모/특이사항
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ
);

COMMENT ON TABLE  medical_records            IS '진료 기록 (MED01 FBF-18)';
COMMENT ON COLUMN medical_records.visited_at IS '병원 방문 날짜';
COMMENT ON COLUMN medical_records.department IS '진료과';

CREATE INDEX idx_medical_records_user_id    ON medical_records (user_id, visited_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_medical_records_hospital   ON medical_records USING gin (hospital gin_trgm_ops);

CREATE TRIGGER trg_medical_records_updated_at
    BEFORE UPDATE ON medical_records
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================
--  11. RECORD_PRESCRIPTIONS  —  처방 약물 (진료기록 연관)
--      MED01 FBF-20
-- =============================================================

CREATE TABLE record_prescriptions (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    record_id  UUID        NOT NULL REFERENCES medical_records(id) ON DELETE CASCADE,
    drug_name  VARCHAR(200) NOT NULL,
    sort_order SMALLINT    NOT NULL DEFAULT 0
);

COMMENT ON TABLE  record_prescriptions          IS '진료 기록별 처방 약물 (MED01 FBF-20)';
COMMENT ON COLUMN record_prescriptions.drug_name IS '처방 약물명';

CREATE INDEX idx_prescriptions_record_id ON record_prescriptions (record_id);

-- =============================================================
--  12. FILES  —  파일 메타데이터
--      SVR01 FBF-22/23/25
-- =============================================================

CREATE TABLE files (
    id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       UUID          NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    record_id     UUID          REFERENCES medical_records(id) ON DELETE SET NULL,
    category      file_category NOT NULL DEFAULT 'other',
    original_name VARCHAR(500)  NOT NULL,
    s3_key        VARCHAR(1000) NOT NULL UNIQUE,     -- S3 객체 키
    s3_url        TEXT          NOT NULL,             -- CloudFront / S3 URL
    mime_type     VARCHAR(100),
    size_bytes    BIGINT,
    ocr_text      TEXT,                              -- OCR 추출 텍스트 (FBF-24)
    vaccination_id UUID,                              -- 접종 파일 (증명서 등)
    created_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_files_target CHECK (
        NOT (record_id IS NOT NULL AND vaccination_id IS NOT NULL)
    ),
    CONSTRAINT fk_files_vaccination
        FOREIGN KEY (vaccination_id) REFERENCES vaccinations(id) ON DELETE SET NULL
);

COMMENT ON TABLE  files               IS '업로드 파일 메타데이터 (SVR01 FBF-22/23/25)';
COMMENT ON COLUMN files.s3_key   IS 'AWS S3 객체 경로';
COMMENT ON COLUMN files.ocr_text IS 'EasyOCR 추출 텍스트 (RAG용)';

CREATE INDEX idx_files_user_id        ON files (user_id);
CREATE INDEX idx_files_record_id      ON files (record_id);
CREATE INDEX idx_files_vaccination_id ON files (vaccination_id);
CREATE INDEX idx_files_ocr_text  ON files USING gin (to_tsvector('simple', COALESCE(ocr_text,'')));

-- =============================================================
--  13. NOTIFICATIONS  —  알림 정보
--      NTF01 FBF-15 (알림)
-- =============================================================

CREATE TABLE notifications (
    id                UUID              PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id           UUID              NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type              notification_type NOT NULL,
    title             VARCHAR(200)      NOT NULL,
    body              TEXT,
    scheduled_at      TIMESTAMPTZ,                   -- 발송 예정 시각
    sent_at           TIMESTAMPTZ,                   -- 실제 발송 시각
    is_read           BOOLEAN           NOT NULL DEFAULT FALSE,
    related_record_id UUID              REFERENCES medical_records(id) ON DELETE SET NULL,
    related_med_id    UUID              REFERENCES medications(id)      ON DELETE SET NULL,
    created_at        TIMESTAMPTZ       NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  notifications              IS '알림 정보 (NTF01)';
COMMENT ON COLUMN notifications.scheduled_at IS 'Celery Beat 발송 예약 시각';

CREATE INDEX idx_notifications_user_id      ON notifications (user_id, is_read);
CREATE INDEX idx_notifications_scheduled_at ON notifications (scheduled_at) WHERE sent_at IS NULL;

-- =============================================================
--  14. FCM_TOKENS  —  디바이스 FCM 토큰
--      MOB01 FFM-02
-- =============================================================

CREATE TABLE fcm_tokens (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token       TEXT        NOT NULL UNIQUE,
    device_info VARCHAR(500),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE fcm_tokens IS 'Firebase Cloud Messaging 디바이스 토큰 (MOB01 FFM-02)';

CREATE INDEX idx_fcm_tokens_user_id ON fcm_tokens (user_id);

CREATE TRIGGER trg_fcm_tokens_updated_at
    BEFORE UPDATE ON fcm_tokens
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================
--  15. CHAT_HISTORIES  —  챗봇 채팅 이력
--      CHT01 FBF-14 (채팅)
-- =============================================================

CREATE TABLE chat_sessions (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title      VARCHAR(300),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE chat_messages (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id  UUID        NOT NULL REFERENCES chat_sessions(id) ON DELETE CASCADE,
    role        VARCHAR(20) NOT NULL CHECK (role IN ('user','assistant')),
    content     TEXT        NOT NULL,
    tokens_used INT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  chat_sessions         IS '챗봇 대화 세션 (CHT01)';
COMMENT ON TABLE  chat_messages         IS '챗봇 메시지 (CHT01 FBF-14)';
COMMENT ON COLUMN chat_messages.role    IS 'user | assistant';

CREATE INDEX idx_chat_messages_session ON chat_messages (session_id, created_at);
CREATE INDEX idx_chat_sessions_user_id ON chat_sessions (user_id, updated_at DESC);

CREATE TRIGGER trg_chat_sessions_updated_at
    BEFORE UPDATE ON chat_sessions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- =============================================================
--  16. LLM_AUDIT_LOGS  —  LLM 요청/응답 감사 로그
--      PLT01 FBF-26
-- =============================================================

CREATE TABLE llm_audit_logs (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID        REFERENCES users(id) ON DELETE SET NULL,
    feature         VARCHAR(100) NOT NULL,            -- 'ocr','stt','chat','summary' 등
    model_name      VARCHAR(100) NOT NULL,            -- 'gpt-4o', 'whisper-large-v3' 등
    prompt_tokens   INT,
    completion_tokens INT,
    request_hash    VARCHAR(64),                      -- 요청 중복 추적
    response_status VARCHAR(20) NOT NULL DEFAULT 'success',  -- success/error/filtered
    latency_ms      INT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  llm_audit_logs         IS 'LLM 요청/응답 감사 로그 (PLT01 FBF-26)';
COMMENT ON COLUMN llm_audit_logs.feature IS 'ocr | stt | chat | summary | drug_check 등';

CREATE INDEX idx_llm_logs_user_id    ON llm_audit_logs (user_id, created_at DESC);
CREATE INDEX idx_llm_logs_feature    ON llm_audit_logs (feature, created_at DESC);

-- =============================================================
--  ERD 관계 요약 (주석)
-- =============================================================
/*
  users (1)
    ├── (1:1) health_basic
    ├── (1:N) medications
    │              └── (1:N) medication_times
    ├── (1:N) allergies
    ├── (1:N) user_diseases ──(N:1)── disease_master
    ├── (1:N) vaccinations
    ├── (1:N) medical_records
    │              └── (1:N) record_prescriptions
    │              └── (1:N) files
    ├── (N:M) user_guardians (self-join)
    ├── (1:N) sessions
    ├── (1:N) notifications
    ├── (1:N) fcm_tokens
    ├── (1:N) chat_sessions
    │              └── (1:N) chat_messages
    └── (1:N) llm_audit_logs
*/
