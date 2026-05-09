-----------------------------------------------------------------------
-- kma_api.lua
-- 기상청 API 관련 모든 로직
-----------------------------------------------------------------------

local capabilities = require "st.capabilities"
local log = require "log"
local cosock = require "cosock"
local http = cosock.asyncify "socket.http"
local ltn12 = require "ltn12"
local dkjson = require "dkjson"

local kma_api = {}

-----------------------------------------------------------------------
-- [1] Capability 정의
-----------------------------------------------------------------------
local windInfo_cap = capabilities["achievedictionary39087.windInfo"]
local skytype_cap = capabilities["achievedictionary39087.skyType"]
local precipitation_cap = capabilities["achievedictionary39087.precipitationInfo"]
local temperatureRange_cap = capabilities["achievedictionary39087.temperatureRange"]
local cardMessage_cap = capabilities["achievedictionary39087.cardMessage"]
local precipitationLive_cap = capabilities["achievedictionary39087.precipitationLive"]

-----------------------------------------------------------------------
-- [2] API 설정 및 상수
-----------------------------------------------------------------------
-- 초단기실황 카테고리 매핑 (main 컴포넌트)
local ultra_categories = {
  {cat = "T1H", name = "기온", unit = "C", 
   emit = function(device, val) 
     device:emit_component_event(device.profile.components.main, 
       capabilities.temperatureMeasurement.temperature({ value = val, unit = "C" }))
   end},
  {cat = "REH", name = "습도", unit = "%", 
   emit = function(device, val) 
     device:emit_component_event(device.profile.components.main, 
       capabilities.relativeHumidityMeasurement.humidity({ value = val, unit = "%" }))
   end},
  {cat = "VEC", name = "풍향", unit = "deg"},
  {cat = "WSD", name = "풍속", unit = "m/s"},
  {cat = "PTY", name = "강수형태", unit = ""},
  {cat = "RN1", name = "1시간 강수량", unit = "mm"}
}

-- API 타입별 기본 설정
local API_CONFIG = {
  ultra = {
    real_api_base = "http://apis.data.go.kr/1360000/VilageFcstInfoService_2.0",
    endpoint = "/getUltraSrtNcst",
    numOfRows = 10
  },
  vilage = {
    real_api_base = "http://apis.data.go.kr/1360000/VilageFcstInfoService_2.0",
    endpoint = "/getVilageFcst",
    numOfRows = 1000
  }
}

-----------------------------------------------------------------------
-- [3-0] cardMessage 헬퍼
-- main 컴포넌트에 {온도, 습도, 하늘상태} 카드를 emit
-- device field에 각 값을 캐싱: "card_temp", "card_humidity", "card_sky"
-----------------------------------------------------------------------

-- skyType 코드 → 한국어 텍스트
local SKY_LABEL = { ["1"] = "맑음", ["3"] = "구름많음", ["4"] = "흐림" }

local function update_card_message(device)
  local temp     = device:get_field("card_temp")
  local humidity = device:get_field("card_humidity")
  local sky_code = device:get_field("card_sky")

  -- 세 값 중 하나라도 없으면 아직 초기화 전이므로 스킵
  if not temp or not humidity or not sky_code then
    log.debug(string.format("[%s] cardMessage: 값 부족 (temp=%s, hum=%s, sky=%s) - 스킵",
      device.id, tostring(temp), tostring(humidity), tostring(sky_code)))
    return
  end

  local sky_label = SKY_LABEL[tostring(sky_code)] or sky_code
  local msg = string.format("%d°C, %d%%, %s", math.floor(temp + 0.5), math.floor(humidity + 0.5), sky_label)

  if cardMessage_cap then
    device:emit_component_event(
      device.profile.components.main,
      cardMessage_cap.message({ value = msg })
    )
    log.info(string.format("[%s] cardMessage 업데이트: %s", device.id, msg))
  end
end

-----------------------------------------------------------------------
-- [3] 유틸리티 함수 (최빈값, 최대값, 최소값 계산)
-----------------------------------------------------------------------

-- 최빈값 계산
-- 동률이면 더 큰 값 반환 (더 나쁜 날씨 우선)
local function get_mode_value(values)
  if not values or #values == 0 then return nil end
  
  local counts = {}
  for _, val in ipairs(values) do
    local num = tonumber(val)
    if num then
      counts[num] = (counts[num] or 0) + 1
    end
  end
  
  local max_count = 0
  local mode_val = nil
  for val, count in pairs(counts) do
    if count > max_count or (count == max_count and val > (mode_val or 0)) then
      max_count = count
      mode_val = val
    end
  end
  
  return mode_val
end

-- 최대값 계산
local function get_max_value(values)
  if not values or #values == 0 then return nil end
  
  local max_val = nil
  for _, val in ipairs(values) do
    local num = tonumber(val)
    if num and (not max_val or num > max_val) then
      max_val = num
    end
  end
  
  return max_val
end

-- 최소값 계산
local function get_min_value(values)
  if not values or #values == 0 then return nil end
  
  local min_val = nil
  for _, val in ipairs(values) do
    local num = tonumber(val)
    if num and (not min_val or num < min_val) then
      min_val = num
    end
  end
  
  return min_val
end

-----------------------------------------------------------------------
-- [4] Base Time 계산
-----------------------------------------------------------------------

-- API 타입별 base_date, base_time 계산
-- ultra: 현재 시각의 정시 (예: 21:15 → 21:00)
-- vilage: 02시 발표 기준 (02:30 이전이면 어제 02시, 이후면 오늘 02시)

-- 기준분(초단기/단기 공통, 예: 15분)
-- 이거 init.lua의 REFRESH_MINUTE와 동일하게 유지해야 함
local KMA_BASE_MINUTE = 15

local function get_kma_base_info(api_type)
  local now_utc = os.time()
  local now_kst = now_utc + (9 * 60 * 60)  -- KST 보정

  if api_type == "ultra" then
    local hour = tonumber(os.date("%H", now_kst))
    local min = tonumber(os.date("%M", now_kst))
    local base_hour = hour
    local base_date = os.date("%Y%m%d", now_kst)
    if min < KMA_BASE_MINUTE then
      base_hour = hour - 1
      if base_hour < 0 then
        base_hour = 23
        base_date = os.date("%Y%m%d", now_kst - 24 * 60 * 60)
      end
    end
    return {
      base_date = base_date,
      base_time = string.format("%02d00", base_hour)
    }
  elseif api_type == "vilage" then
    local hour = tonumber(os.date("%H", now_kst))
    local min = tonumber(os.date("%M", now_kst))

    local base_date
    if hour < 2 or (hour == 2 and min < KMA_BASE_MINUTE) then
      base_date = os.date("%Y%m%d", now_kst - 24 * 60 * 60)  -- 어제
    else
      base_date = os.date("%Y%m%d", now_kst)  -- 오늘
    end

    return {
      base_date = base_date,
      base_time = "0200"
    }
  end
end

-----------------------------------------------------------------------
-- [5] URL 구성
-----------------------------------------------------------------------

-- API 호출을 위한 프록시 URL 구성
-- Edge Bridge 형식: /api/forward?url=<target_url>
-- 반환: config 테이블, 또는 nil (api_key 미설정 시)
local function get_config(device, api_type)
  local p = device.preferences
  local time_info = get_kma_base_info(api_type)
  
  -- proxyUrl: preferences 우선, child는 field(proxy_url)에서 fallback
  local raw_proxy = (p.proxyUrl and p.proxyUrl ~= "") and p.proxyUrl
                    or device:get_field("proxy_url")
  if not raw_proxy or raw_proxy == "" then
    log.warn(string.format("[%s] proxyUrl 미설정", device.id))
    return nil
  end
  local proxy_base = raw_proxy:gsub("/+$", "")
  local config = API_CONFIG[api_type]
  
  -- 영구저장소에서 API 키 직접 읽기
  local service_key = device:get_field("api_key")
  if not service_key or service_key == "" then
    log.warn(string.format("[%s] API 키 미설정 - 웹서버에서 키를 먼저 입력하세요", device.id))
    return nil
  end
  
  -- 실제 기상청 API URL 구성 (인코딩된 키를 그대로 사용)
  local real_api_url = config.real_api_base .. config.endpoint
  local query = string.format(
    "?serviceKey=%s&pageNo=1&numOfRows=%d&dataType=JSON&base_date=%s&base_time=%s&nx=%d&ny=%d",
    service_key, config.numOfRows, time_info.base_date, time_info.base_time, p.gridX, p.gridY
  )
  
  local target_url = real_api_url .. query
  local proxy_url = proxy_base .. "/api/forward?url=" .. target_url
  
  return {
    PROXY_URL = proxy_url,
    TARGET_URL = target_url,
    TIMEOUT = p.timeoutSec or 10
  }
end

-----------------------------------------------------------------------
-- [6] HTTP 요청 및 응답 처리
-----------------------------------------------------------------------

-- 공통 HTTP 요청 함수
-- 프록시를 통해 기상청 API 호출 후 JSON 파싱
-- 반환: body, http_ok, error_msg, error_type
-- error_type: "network" (네트워크 오류, offline 처리), "api" (API 오류, online 유지), nil (성공)
local function fetch_kma_data(device, proxy_url, target_url, timeout, api_name)
  log.info(string.format("[%s] %s 요청 -> %s (via proxy)", device.id, api_name, target_url))
  
  local resp_chunks = {}
  local _, code, _, status_line = http.request({
    url = proxy_url,
    method = "GET",
    sink = ltn12.sink.table(resp_chunks),
    timeout = timeout
  })
  
  local http_ok = (code ~= nil and tonumber(code) == 200)
  
  if not http_ok then
    local err_msg
    local err_type = "network"
    
    -- code를 문자열로 변환하여 파싱
    local code_str = tostring(code)
    local code_num = tonumber(code)
    
    if code == nil or not code_num then
      -- 1단계: 연결 실패 (네트워크 에러)
      err_type = "network"
      
      -- status_line 또는 code_str에서 에러 패턴 찾기
      local search_str = string.lower(status_line or code_str)
      
      if string.find(search_str, "unreachable") then
        err_msg = "네트워크 연결 불가 (unreachable)"
      elseif string.find(search_str, "refused") then
        err_msg = "연결 거부됨 (connection refused)"
      elseif string.find(search_str, "timeout") then
        err_msg = "연결 시간 초과 (timeout)"
      else
        err_msg = "네트워크 오류 (unknown)"
      end
    else
      -- 2단계: HTTP 응답 에러
      if code_num == 429 then
        -- 429: Rate Limit (API 에러, online 유지 - 자동 복구 대기)
        err_type = "api"
        err_msg = "요청 횟수 초과 (429 - Rate Limit)"
      else
        -- 나머지 모든 HTTP 에러 (네트워크 에러, offline)
        err_type = "network"
        if code_num == 400 then
          err_msg = "잘못된 요청 (400)"
        elseif code_num == 403 then
          err_msg = "접근 거부됨 (403)"
        elseif code_num == 404 then
          err_msg = "엔드포인트 없음 (404)"
        elseif code_num == 500 then
          err_msg = "서버 오류 (500)"
        elseif code_num == 502 then
          err_msg = "게이트웨이 오류 (502)"
        elseif code_num == 503 then
          err_msg = "서비스 이용 불가 (503)"
        else
          err_msg = string.format("HTTP 오류 (%d)", code_num)
        end
      end
    end
    
    log.warn(string.format("[%s] %s API 호출 실패: %s", device.id, api_name, err_msg))
    return nil, http_ok, err_msg, err_type
  end
  
  local body = table.concat(resp_chunks)
  
  -- XML 에러 응답 체크 (API가 에러를 XML로 반환하는 경우)
  if string.find(body, "<resultCode>") then
    local result_code = string.match(body, "<resultCode>([^<]+)</resultCode>")
    local result_msg = string.match(body, "<resultMsg>([^<]+)</resultMsg>")
    
    if result_code and result_code ~= "00" then
      local err_msg = string.format("%s (%s)", result_msg or "알 수 없는 오류", result_code)
      log.error(string.format("[%s] %s API 오류: %s", device.id, api_name, err_msg))
      return nil, true, err_msg, "api"
    end
  end
  
  -- JSON 파싱
  local data, _, err = dkjson.decode(body)
  
  if err then
    local err_msg = "JSON 파싱 오류"
    log.error(string.format("[%s] %s: %s", device.id, api_name, err_msg))
    return nil, http_ok, err_msg, "api"
  end
  
  -- API 에러 체크 (resultCode != "00")
  if data.response and data.response.header then
    local header = data.response.header
    if header.resultCode ~= "00" then
      local err_msg = string.format("%s (%s)", header.resultMsg or "알 수 없는 오류", header.resultCode)
      log.error(string.format("[%s] %s API 오류: %s", device.id, api_name, err_msg))
      return nil, true, err_msg, "api"
    end
  end
  
  if not data.response or not data.response.body then
    local err_msg = "응답 데이터 없음"
    log.error(string.format("[%s] %s: %s", device.id, api_name, err_msg))
    return nil, http_ok, err_msg, "api"
  end
  
  return data.response.body, http_ok, nil, nil
end

-----------------------------------------------------------------------
-- [7] 초단기실황 (Ultra Short-term Forecast) 처리
-----------------------------------------------------------------------

-- 초단기실황 데이터 가져오기 및 디바이스 업데이트
-- 반환: items, base_info, http_ok, error_msg, error_type
local function fetch_ultra_srt_ncst(device)
  local C_ultra = get_config(device, "ultra")
  if not C_ultra then
    return nil, nil, false, "API 키 미설정", "api"
  end
  local request_base_info = get_kma_base_info("ultra")
  local body, http_ok, err_msg, err_type = fetch_kma_data(device, C_ultra.PROXY_URL, C_ultra.TARGET_URL, C_ultra.TIMEOUT, "초단기실황")
  
  if not body then
    return nil, nil, http_ok, err_msg, err_type
  end

  local items = body.items.item
  
  -- -999 값 체크 (잘못된 격자 좌표)
  for _, item in ipairs(items) do
    local val = tonumber(item.obsrValue)
    if val == -999 then
      local err_msg = "잘못된 격자 좌표 (99)"
      log.error(string.format("[%s] 초단기실황 데이터에 -999 값 감지 - 격자 좌표를 확인하세요", device.id))
      return nil, nil, true, err_msg, "api"
    end
  end
  
  -- 로컬 변수로 풍향/풍속/강수 저장 (디바이스별 독립적)
  local wind_direction = nil
  local wind_speed = nil
  local precip_type = nil
  local precip_rate = nil
  
  -- 카테고리별 데이터 추출 및 업데이트
  for _, config in ipairs(ultra_categories) do
    local found = false
    for _, item in ipairs(items) do
      if item.category == config.cat then
        local raw_val = item.obsrValue
        local val = tonumber(raw_val)

        -- 강수량(RN1)은 숫자가 아닐 수 있으므로 별도 처리
        if config.cat == "RN1" then
          if raw_val == "강수없음" or raw_val == "0" then
            precip_rate = 0
          elseif string.find(raw_val, "미만") then
            -- "1.0mm 미만" 등 -> 숫자 추출 후 절반값(0.5)으로 처리하여 0보다는 크게 만듦
            local num = tonumber(string.match(raw_val, "[%d%.]+"))
            precip_rate = num and (num / 2) or 0.1
          else
            precip_rate = tonumber(string.match(raw_val, "[%d%.]+")) or 0
          end
          log.info(string.format("[%s] %s 수집: %.1f %s", device.id, config.name, precip_rate, config.unit))
          found = true
          break
        end

        if val then
          -- 풍향/풍속/강수형태는 나중에 함께 처리하기 위해 저장만
          if config.cat == "VEC" then
            wind_direction = val
            log.info(string.format("[%s] %s 수집: %.0f %s", device.id, config.name, val, config.unit))
          elseif config.cat == "WSD" then
            wind_speed = val
            log.info(string.format("[%s] %s 수집: %.1f %s", device.id, config.name, val, config.unit))
          elseif config.cat == "PTY" then
            precip_type = tostring(math.floor(val))
            log.info(string.format("[%s] %s 수집: %s", device.id, config.name, precip_type))
          else
            -- 기온, 습도는 즉시 emit + field 캐시 저장
            config.emit(device, val)
            log.info(string.format("[%s] %s 업데이트: %.1f %s", device.id, config.name, val, config.unit))
            if config.cat == "T1H" then
              device:set_field("card_temp", val)
            elseif config.cat == "REH" then
              device:set_field("card_humidity", val)
            end
          end
          found = true
          break
        end
      end
    end
    if not found then
      log.warn(string.format("[%s] 초단기실황 데이터에 %s(%s) 정보가 없습니다.", device.id, config.name, config.cat))
    end
  end
  
  -- 풍향/풍속 모두 수집되었으면 함께 emit
  if wind_direction and wind_speed then
    device:emit_component_event(device.profile.components.main,
      windInfo_cap.direction({ value = wind_direction, unit = "deg" }))
    device:emit_component_event(device.profile.components.main,
      windInfo_cap.speed({ value = wind_speed, unit = "m/s" }))
    log.info(string.format("[%s] 바람 정보 업데이트: 풍향 %.0f°, 풍속 %.1f m/s", device.id, wind_direction, wind_speed))
  end

  -- 실시간 강수 정보 emit
  if precip_type and precip_rate then
    if precipitationLive_cap then
      device:emit_component_event(device.profile.components.main,
        precipitationLive_cap.type({ value = precip_type }))
      device:emit_component_event(device.profile.components.main,
        precipitationLive_cap.rate({ value = precip_rate, unit = "mm" }))
      log.info(string.format("[%s] 실시간 강수 업데이트: 형태 %s, 강수량 %.1f mm", device.id, precip_type, precip_rate))
    end
  end

  -- 기온/습도 캐시가 갱신됐으므로 cardMessage 업데이트
  update_card_message(device)

  return items, request_base_info, http_ok, nil, nil
end

-----------------------------------------------------------------------
-- [8] 단기예보 (Short-term Forecast) 처리
-----------------------------------------------------------------------

-- 수집된 예보 데이터를 처리하여 최종 값 결정
-- 입력: data_all = { SKY = {val1, val2, ...}, PTY = {...}, ... }
-- 출력: { SKY = {fcstValue = "3"}, PTY = {fcstValue = "1"}, ... }
--
-- 처리 규칙:
-- - SKY (하늘상태): 최빈값, 동률이면 더 나쁜 쪽 (큰 값)
-- - PTY (강수형태): 0 제외하고 최빈값, 동률이면 더 나쁜 쪽
-- - POP (강수확률): 최대값
-- - PCP/SNO (강수량/적설량): 최대값
-- - TMN (최저기온): 최소값
-- - TMX (최고기온): 최대값
local function process_forecast_data(data_all)
  local result = {}
  
  for cat, values in pairs(data_all) do
    if cat == "SKY" then
      -- 하늘상태: 최빈값, 동률이면 더 나쁜 쪽
      local mode = get_mode_value(values)
      if mode then
        result[cat] = { fcstValue = tostring(mode) }
      end
      
    elseif cat == "PTY" then
      -- 강수형태: 0 제외하고 최빈값
      local non_zero = {}
      for _, val in ipairs(values) do
        local num = tonumber(val)
        if num and num ~= 0 then
          table.insert(non_zero, val)
        end
      end
      
      if #non_zero > 0 then
        local mode = get_mode_value(non_zero)
        if mode then
          result[cat] = { fcstValue = tostring(mode) }
        end
      else
        result[cat] = { fcstValue = "0" }
      end
      
    elseif cat == "POP" then
      -- 강수확률: 최대값
      local max_val = get_max_value(values)
      if max_val then
        result[cat] = { fcstValue = tostring(max_val) }
      end
      
    elseif cat == "PCP" or cat == "SNO" then
      -- 강수량/적설량: 최대값 (문자열 처리)
      local max_val = values[1]
      for _, val in ipairs(values) do
        if val ~= "강수없음" and val ~= "적설없음" then
          local num1 = tonumber(string.match(tostring(max_val), "%d+%.?%d*"))
          local num2 = tonumber(string.match(tostring(val), "%d+%.?%d*"))
          if num2 and (not num1 or num2 > num1) then
            max_val = val
          end
        end
      end
      result[cat] = { fcstValue = max_val }
      
    elseif cat == "TMN" then
      -- 최저기온: 최소값
      local min_val = get_min_value(values)
      if min_val then
        result[cat] = { fcstValue = tostring(min_val) }
      end
      
    elseif cat == "TMX" then
      -- 최고기온: 최대값
      local max_val = get_max_value(values)
      if max_val then
        result[cat] = { fcstValue = tostring(max_val) }
      end
      
    else
      -- 기타: 첫 번째 값 사용
      result[cat] = { fcstValue = values[1] }
    end
  end
  
  return result
end

-- 예보 데이터를 디바이스 컴포넌트에 업데이트
local function update_forecast_component(device, component, data, label)
  -- SKY (하늘상태)
  if data["SKY"] then
    local val = tonumber(data["SKY"].fcstValue)
    if val and skytype_cap then
      device:emit_component_event(component, skytype_cap.skyType({ value = tostring(val) }))
      log.info(string.format("[%s] [%s] 하늘상태 업데이트: %s", device.id, label, tostring(val)))
      -- todayForecast 업데이트 시에만 cardMessage용 skyType 캐시 저장
      if label == "오늘" then
        device:set_field("card_sky", tostring(val))
      end
    end
  end
  
  -- 강수정보 (POP, PTY, PCP, SNO)
  local pop = tonumber(data["POP"] and data["POP"].fcstValue or "0") or 0
  local pty = data["PTY"] and tostring(tonumber(data["PTY"].fcstValue) or 0) or "0"
  local pcp = data["PCP"] and data["PCP"].fcstValue or "강수없음"
  local sno = data["SNO"] and data["SNO"].fcstValue or "적설없음"
  
  -- PTY에 따라 표시할 강수/적설량 결정
  -- 0: 없음, 1: 비, 2: 비/눈, 3: 눈
  local display_rate
  local pty_num = tonumber(pty) or 0
  if pty_num == 0 or pty_num == 1 then
    display_rate = pcp
  elseif pty_num == 2 then
    display_rate = string.format("비 %s / 눈 %s", pcp, sno)
  elseif pty_num == 3 then
    display_rate = sno
  else
    display_rate = pcp
  end
  
  device:emit_component_event(component, precipitation_cap.type({ value = pty }))
  device:emit_component_event(component, precipitation_cap.probability({ value = pop, unit = "%" }))
  device:emit_component_event(component, precipitation_cap.rate({ value = display_rate }))
  log.info(string.format("[%s] [%s] 강수정보 - 형태: %s, 확률: %d %%, 표시: %s", 
    device.id, label, pty, pop, display_rate))

  -- 최저/최고 기온
  local tmn = data["TMN"] and tonumber(data["TMN"].fcstValue)
  local tmx = data["TMX"] and tonumber(data["TMX"].fcstValue)
  
  if tmn then
    device:emit_component_event(component, temperatureRange_cap.minimum({ value = tmn, unit = "C" }))
    log.info(string.format("[%s] [%s] 최저기온: %.1f °C", device.id, label, tmn))
  end
  
  if tmx then
    device:emit_component_event(component, temperatureRange_cap.maximum({ value = tmx, unit = "C" }))
    log.info(string.format("[%s] [%s] 최고기온: %.1f °C", device.id, label, tmx))
  end
end

-- 단기예보 데이터 가져오기 및 디바이스 업데이트
-- 반환: {today_data, tomorrow_data}, base_info, http_ok, error_msg, error_type
local function fetch_vilage_fcst(device)
  local C_vilage = get_config(device, "vilage")
  if not C_vilage then
    return nil, nil, false, "API 키 미설정", "api"
  end
  local request_base_info = get_kma_base_info("vilage")
  local body, http_ok, err_msg, err_type = fetch_kma_data(device, C_vilage.PROXY_URL, C_vilage.TARGET_URL, C_vilage.TIMEOUT, "단기예보")
  
  if not body then
    return nil, nil, http_ok, err_msg, err_type
  end

  local items = body.items.item
  
  -- -999 값 체크 (잘못된 격자 좌표)
  for _, item in ipairs(items) do
    local val = tonumber(item.fcstValue)
    if val == -999 then
      local err_msg = "잘못된 격자 좌표 (99)"
      log.error(string.format("[%s] 단기예보 데이터에 -999 값 감지 - 격자 좌표를 확인하세요", device.id))
      return nil, nil, true, err_msg, "api"
    end
  end
  
  -- 오늘/내일 날짜 계산 (KST 기준)
  local now_utc = os.time()
  local now_kst = now_utc + (9 * 60 * 60)
  local today_date = os.date("%Y%m%d", now_kst)
  local tomorrow_date = os.date("%Y%m%d", now_kst + 24 * 60 * 60)
  
  -- 날짜별로 모든 데이터 수집
  local today_data_all = {}
  local tomorrow_data_all = {}
  
  for _, item in ipairs(items) do
    local cat = item.category
    local fcst_date = item.fcstDate
    local fcst_value = item.fcstValue
    
    if fcst_date == today_date then
      today_data_all[cat] = today_data_all[cat] or {}
      table.insert(today_data_all[cat], fcst_value)
    elseif fcst_date == tomorrow_date then
      tomorrow_data_all[cat] = tomorrow_data_all[cat] or {}
      table.insert(tomorrow_data_all[cat], fcst_value)
    end
  end
  
  -- 수집된 데이터를 처리하여 최종 값 결정
  local today_data = process_forecast_data(today_data_all)
  local tomorrow_data = process_forecast_data(tomorrow_data_all)
  
  -- 디바이스 업데이트
  update_forecast_component(device, device.profile.components.todayForecast, today_data, "오늘")
  update_forecast_component(device, device.profile.components.tomorrowForecast, tomorrow_data, "내일")

  -- todayForecast SKY 캐시가 갱신됐으므로 cardMessage 업데이트
  update_card_message(device)

  return {today_data = today_data, tomorrow_data = tomorrow_data}, request_base_info, http_ok, nil, nil
end

-----------------------------------------------------------------------
-- [9] Public API
-----------------------------------------------------------------------

function kma_api.fetch_ultra_srt_ncst(device)
  return fetch_ultra_srt_ncst(device)
end

function kma_api.fetch_vilage_fcst(device)
  return fetch_vilage_fcst(device)
end

return kma_api
