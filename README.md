# Weather API SpineFarm

SmartThings Edge Driver for 기상청 단기예보 API

## 개요

기상청 공공데이터포털의 **초단기실황** 및 **단기예보** API를 활용하여 실시간 날씨 정보를 SmartThings 디바이스로 제공하는 Edge Driver입니다.

**주요 특징:**
- ✅ **다중 디바이스 지원**: 여러 지역의 날씨를 동시에 모니터링
- ✅ **순차 처리 큐**: API 호출 충돌 방지 및 안정성 보장
- ✅ **자동 갱신**: 매시간 15분 20초에 초단기실황, 매일 02시 15분 20초에 단기예보 갱신
- ✅ **통계적 데이터 처리**: 하루치 예보 데이터를 집계하여 최적값 제공

## 주요 기능

### 📡 API 데이터 소스

#### 1. 초단기실황 (Ultra Short-term Realtime, `getUltraSrtNcst`)
**업데이트 주기:** 매시간 15분 20초에 실행 (현재 정시 기준 데이터)

| Category | 데이터 | Capability | 단위 |
|----------|--------|------------|------|
| T1H | 기온 | `temperatureMeasurement` | °C |
| REH | 습도 | `relativeHumidityMeasurement` | % |
| VEC | 풍향 | `achievedictionary39087.windInfo` | deg |
| WSD | 풍속 | `achievedictionary39087.windInfo` | m/s |

#### 2. 단기예보 (Short-term Forecast, `getVilageFcst`)
**업데이트 주기:** 매일 02시 15분 20초에 실행 (02:00 발표 기준)  
**데이터 처리:** 통계적 집계 (최빈값/최대값/최소값)

| Category | 데이터 | 처리 방식 | Capability | 값 범위 |
|----------|--------|----------|------------|---------|
| SKY | 하늘상태 | 최빈값 (동률시 나쁜 날씨) | `achievedictionary39087.skyType` | 1: 맑음<br>3: 구름많음<br>4: 흐림 |
| PTY | 강수형태 | 최빈값 (0 제외) | `achievedictionary39087.precipitationInfo` | 0: 없음<br>1: 비<br>2: 비/눈<br>3: 눈 |
| POP | 강수확률 | 최대값 | `achievedictionary39087.precipitationInfo` | 0-100% |
| PCP | 1시간 강수량 | 최대값 | `achievedictionary39087.precipitationInfo` | mm (문자열) |
| SNO | 1시간 적설량 | 최대값 | `achievedictionary39087.precipitationInfo` | cm (문자열) |
| TMN | 최저기온 | 최소값 | `achievedictionary39087.temperatureRange` | °C |
| TMX | 최고기온 | 최대값 | `achievedictionary39087.temperatureRange` | °C |

## 아키텍처

```
[SmartThings Hub] <-> [Edge Driver] <-> [Proxy Server] <-> [기상청 API]
                      (Request Queue)   (/api/forward)    (공공데이터포털)
                      (순차 처리)
```

### 핵심 설계

#### 1. **순차 처리 큐 (Serialized Queue)**
- 여러 디바이스가 동시에 갱신 요청 시 큐에 등록
- 한 번에 하나씩 순차 처리 (API 충돌 방지)
- 각 요청 완료 후 2초 대기 (Rate Limit 보호)

#### 2. **디바이스별 독립 데이터**
- 풍향/풍속 데이터를 로컬 변수로 관리 (전역 변수 제거)
- 여러 디바이스가 동시 처리되어도 데이터 섞임 방지

#### 3. **타이머 관리**
- 디바이스별 독립 타이머 (중복 실행 방지)
- 자동 재스케줄링 (에러 발생 시에도 계속 동작)

### 프록시 서버
- **권장:** [taustin/edge-bridge](https://github.com/toddaustin07/edge-bridge)
- **대안:** Node-RED 또는 다른 프록시 (`/api/forward?url=` 엔드포인트 제공 필요)

## 설정

### 1. 필수 설정값

| 설정 항목 | 설명 | 기본값 | 예시 |
|----------|------|--------|------|
| **proxyUrl** | Edge Bridge 프록시 서버 주소 | `http://192.168.0.60:1880` | 포트까지 입력 |
| **serviceKey** | 공공데이터포털 서비스키 (Decoded) | - | 포털에서 발급받은 키 |
| **gridX (nx)** | 격자 X 좌표 | 60 | 서울 기준 60 (범위: 21~144) |
| **gridY (ny)** | 격자 Y 좌표 | 127 | 서울 기준 127 (범위: 8~147) |
| **timeoutSec** | API 타임아웃 | 10초 | 5~30초 |
| **createAnother** | 추가 디바이스 생성 | false | ON으로 토글 시 새 디바이스 생성 |

### 2. 격자 좌표 확인
[기상청 격자 좌표 변환기](https://www.kma.go.kr/aboutkma/biz/forecast01.jsp) 또는 [좌표 변환 도구](https://github.com/search?q=kma+grid+converter) 활용

### 3. 서비스키 발급
1. [공공데이터포털](https://www.data.go.kr/) 회원가입
2. **단기예보 조회서비스** 신청
3. **Decoding된 서비스키** 복사하여 사용

### 4. 추가 디바이스 생성
1. 첫 번째 디바이스 생성 후 설정 열기
2. **"장치 추가"** 스위치를 ON으로 토글
3. 새 디바이스가 자동 생성됨 (고유 ID 부여)
4. 새 디바이스의 격자 좌표를 다른 지역으로 설정

## 설치

### 1. Edge Bridge 프록시 설정
```bash
# taustin/edge-bridge 설치 및 실행
# https://github.com/toddaustin07/edge-bridge
```

### 2. Driver 패키징 및 배포
```bash
# SmartThings CLI 사용
smartthings edge:drivers:package .
smartthings edge:drivers:install
```

### 3. SmartThings 채널 등록
1. SmartThings CLI 또는 개발자 포털에서 채널 생성
2. 패키지 업로드
3. 모바일 앱에서 Driver 설치
4. **디바이스 추가** → "Scan nearby" → `Weather API SpineFarm` 선택

## Capabilities 목록

### Standard Capabilities
- `refresh` - 수동 갱신 (초단기 + 단기 모두)
- `healthCheck` - 프록시 서버 연결 상태 확인
- `temperatureMeasurement` - 현재 기온
- `relativeHumidityMeasurement` - 현재 습도

### Custom Capabilities (achievedictionary39087)
- `windInfo` - 바람 정보 (풍향 + 풍속)
  - `direction`: 풍향 (0-360°)
  - `speed`: 풍속 (m/s)
- `skyType` - 하늘 상태 (1: 맑음, 3: 구름많음, 4: 흐림)
- `precipitationInfo` - 강수 정보 통합
  - `type`: 강수 형태 (0~3)
  - `probability`: 강수 확률 (%)
  - `rate`: 강수량/적설량 표시
- `temperatureRange` - 기온 범위
  - `minimum`: 최저기온 (°C)
  - `maximum`: 최고기온 (°C)
- `debugMessage` - 상태 메시지 (업데이트 시각, 에러 정보)

## 컴포넌트 구조

### main (현재 날씨)
- 기온, 습도, 바람 (풍향+풍속)
- Refresh, Health Check

### todayForecast (오늘 예보)
- 하늘상태, 강수정보, 기온범위

### tomorrowForecast (내일 예보)
- 하늘상태, 강수정보, 기온범위

### status (상태 메시지)
- debugMessage (초단기/단기 업데이트 상태, 에러 정보)

## 주의사항

⚠️ **API 호출 제한 및 Rate Limit 보호**
- 기상청 API는 과도한 호출 시 차단될 수 있음 (429 에러)
- 자동 갱신: **매시간 15분** (초단기), **매일 02시 15분** (단기)
- 순차 처리 큐로 동시 호출 방지
- 초단기와 단기예보 사이 2초 대기 (Rate Limit 방지)
- 디바이스 간 2초 간격 처리

⚠️ **Base Time 로직**
- **초단기실황**: 현재 정시 (예: 14:15 실행 → 14:00 기준)
  - 15분 미만이면 전 시간 데이터 (14:14 → 13:00 기준)
- **단기예보**: 02:00 발표 기준 (02:15 이전이면 전날 02:00)

⚠️ **프록시 서버 필수**
- Edge Driver에서 직접 기상청 API 호출 시 인증서 오류 발생
- Edge Bridge 또는 Node-RED 프록시 필수

⚠️ **통계적 데이터 처리**
- 단기예보는 하루치 여러 시간대 데이터를 통합 처리
- SKY/PTY: 최빈값 (가장 많이 나타나는 값, 동률시 나쁜 날씨 선택)
- POP/PCP/SNO/TMX: 최대값
- TMN: 최소값

⚠️ **다중 디바이스 사용 시**
- 각 디바이스는 독립적인 격자 좌표 설정 가능
- 모든 API 요청은 큐를 통해 순차 처리 (2초 간격)
- 동시에 10개 디바이스가 갱신 요청해도 안전하게 처리

## 트러블슈팅

### 1. 데이터가 업데이트되지 않음
- Edge Bridge 프록시 서버 정상 작동 확인
- 서비스키 유효성 확인 (Decoded 키 사용 필수)
- 격자 좌표 정확성 확인
- debugMessage 확인 (에러 코드 표시)

### 2. "업데이트 실패" 메시지
- status 컴포넌트의 debugMessage 확인
- **네트워크 에러** (디바이스 Offline):
  - "네트워크 연결 불가 (unreachable)" - IP 주소 확인
  - "연결 거부됨 (connection refused)" - 포트/프록시 서버 확인
  - "서버 오류 (500)" - 프록시 서버 재시작
- **API 에러** (디바이스 Online):
  - "요청 횟수 초과 (429)" - 잠시 대기 (자동 복구)
  - "엔드포인트 없음 (404)" - 프록시 설정 확인
  - "[메시지] (코드)" - 기상청 API 에러 (서비스키/좌표 확인)

### 3. 여러 디바이스 중 하나만 Offline
- 로그 확인: `smartthings edge:drivers:logcat`
- 해당 디바이스의 격자 좌표가 유효한지 확인
- 큐 처리 로그 확인 (대기열 상태)

### 4. 풍향/풍속 값이 이상함
- v1.1.0 이전 버전은 전역 변수 버그로 데이터 섞임 발생
- 최신 버전으로 업데이트 필요

## 파일 구조

```
weather-api-spinefarm/
├── config.yaml                  # 드라이버 메타데이터
├── profiles/
│   └── weather-api-spinefarm.yaml  # 디바이스 프로필 (4개 컴포넌트)
├── src/
│   ├── init.lua                 # 드라이버 엔트리포인트 + 타이머 + 디바이스 생성
│   ├── discovery.lua            # 디바이스 검색 로직 (초기 1개만)
│   ├── command_handlers.lua     # 순차 처리 큐 + Refresh 명령
│   └── kma_api.lua             # 기상청 API + 통계 처리 (로컬 변수 사용)
├── capability/                  # Custom Capability 정의
│   ├── windInfo/
│   ├── skyType/
│   ├── precipitationInfo/
│   ├── temperatureRange/
│   └── debugMessage/
└── README.md                    # 이 문서
```

## 변경 이력

### v1.2.0 (2026-01-22)
- ✅ **격자 좌표 유효성 검사**: -999 값 감지 시 명확한 에러 메시지 (99)
- ✅ **에러 분류 간소화**: 429만 API 에러, 나머지 HTTP 에러는 네트워크 에러
- ✅ **디버그 로깅 추가**: 상태 전환 추적 로그
- ✅ **nil 비교 에러 수정**: HTTP 코드 파싱 개선

### v1.1.0 (2026-01-22)
- ✅ **Status 컴포넌트 통합**: 모든 상태 메시지를 단일 컴포넌트로 통합
- ✅ **에러 처리 개선**: 3단계 에러 분류 (네트워크/HTTP/API)
- ✅ **Rate Limit 보호**: API 호출 사이 2초 대기 추가
- ✅ **코드 리팩토링**: 중복 코드 제거 (60줄 → 30줄)
- ✅ **온도 범위 개선**: 자동화에서 숫자 입력 지원 (-100~100°C)

### v1.0.2 (2026-01-22)
- ✅ **순차 처리 큐 구현**: 다중 디바이스 동시 API 호출 충돌 방지
- ✅ **전역 변수 버그 수정**: 풍향/풍속 데이터 섞임 현상 해결

### v1.0.1 (2026-01-21)
- ✅ **타이머 Race Condition 수정**: 중복 실행 방지
- ✅ **추가 디바이스 생성 기능**: 설정에서 토글로 새 디바이스 생성

### v1.0.0 (2026-01-20)
- 초기 릴리스

### v0.x.x (Pre-release)
- 초기 개발 및 PoC 단계
- 기본 API 통신 로직 구현 (초단기/단기)
- 프로토타입 UI 구성

## 참고 링크

- [기상청 단기예보 API 문서](https://www.data.go.kr/data/15084084/openapi.do)
- [SmartThings Edge Driver 개발 가이드](https://developer.smartthings.com/docs/devices/hub-connected/get-started)
- [격자 좌표 확인](https://www.kma.go.kr/aboutkma/biz/forecast01.jsp)
- [taustin/edge-bridge](https://github.com/toddaustin07/edge-bridge)

## 라이선스

MIT License

---

**버전:** v1.2.0  
**최종 업데이트:** 2026-01-22
