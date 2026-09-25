-----------------------------------------------------------------------
-- airkorea_api.lua
-- 에어코리아(한국환경공단) 미세먼지 실황 및 예보 처리
-----------------------------------------------------------------------

local capabilities = require "st.capabilities"
local log = require "log"
local cosock = require "cosock"
local http = cosock.asyncify "socket.http"
local ltn12 = require "ltn12"
local dkjson = require "dkjson"

local airkorea_api = {}

-- Capability 정의
local dust_cap = capabilities.dustSensor
local forecast_grade_cap = capabilities["achievedictionary39087.dustForecast"]

-----------------------------------------------------------------------
-- 유틸리티
-----------------------------------------------------------------------
local function url_encode(str)
  if not str then return "" end
  str = string.gsub(str, "\n", "\r\n")
  str = string.gsub(str, "([^%w %-%_%.%~])",
      function(c) return string.format("%%%02X", string.byte(c)) end)
  str = string.gsub(str, " ", "+")
  return str
end

local function parse_grade(grade_num)
  grade_num = tonumber(grade_num)
  if grade_num == 1 then return "좋음"
  elseif grade_num == 2 then return "보통"
  elseif grade_num == 3 then return "나쁨"
  elseif grade_num == 4 then return "매우나쁨"
  end
  return "-"
end

-----------------------------------------------------------------------
-- API 공통 요청 함수
-----------------------------------------------------------------------
local function fetch_data(device, target_url, timeout, api_name)
  local p = device.preferences
  local raw_proxy = (p.proxyUrl and p.proxyUrl ~= "") and p.proxyUrl
                    or device:get_field("proxy_url")
  if not raw_proxy or raw_proxy == "" then
    return nil, false, "proxyUrl 미설정", "api"
  end
  
  local proxy_base = raw_proxy:gsub("/+$", "")
  local proxy_url = proxy_base .. "/api/forward?url=" .. target_url

  log.info(string.format("[%s] %s 요청 -> %s (via proxy)", device.id, api_name, target_url))

  local resp_chunks = {}
  local _, code, _, status_line = http.request({
    url = proxy_url,
    method = "GET",
    sink = ltn12.sink.table(resp_chunks),
    timeout = timeout or 10
  })

  local http_ok = (code ~= nil and tonumber(code) == 200)

  if not http_ok then
    local err_type = "network"
    local err_msg = string.format("HTTP 오류 (%s)", tostring(code))
    if tonumber(code) == 429 then
      err_type = "api"
      err_msg = "요청 횟수 초과 (429 - Rate Limit)"
    end
    log.warn(string.format("[%s] %s API 호출 실패: %s", device.id, api_name, err_msg))
    return nil, false, err_msg, err_type
  end

  local body = table.concat(resp_chunks)

  -- JSON 파싱
  local data, _, err = dkjson.decode(body)
  if err then
    local err_msg = "JSON 파싱 오류"
    log.error(string.format("[%s] %s: %s", device.id, api_name, err_msg))
    return nil, true, err_msg, "api"
  end

  if data.response and data.response.header then
    local header = data.response.header
    if header.resultCode ~= "00" then
      local err_msg = string.format("%s (%s)", header.resultMsg or "알 수 없는 오류", header.resultCode)
      log.error(string.format("[%s] %s API 오류: %s", device.id, api_name, err_msg))
      return nil, true, err_msg, "api"
    end
  end

  if not data.response or not data.response.body or not data.response.body.items then
    return nil, true, "응답 데이터(items) 없음", "api"
  end

  return data.response.body.items, true, nil, nil
end

-----------------------------------------------------------------------
-- [1] 실황: getMsrstnAcctoRltmMesureDnsty
-----------------------------------------------------------------------
function airkorea_api.fetch_live(device)
  local service_key = device:get_field("api_key")
  local station_name = device.preferences.stationName
  
  if not service_key or service_key == "" then
    return nil, nil, false, "API 키 미설정", "api"
  end
  if not station_name or station_name == "" then
    return nil, nil, false, "측정소명 미설정", "api"
  end

  local endpoint = "https://apis.data.go.kr/B552584/ArpltnInforInqireSvc/getMsrstnAcctoRltmMesureDnsty"
  local query = string.format("?serviceKey=%s&returnType=json&numOfRows=1&pageNo=1&stationName=%s&dataTerm=DAILY&ver=1.3",
    service_key, url_encode(station_name))
  local target_url = endpoint .. query

  local items, http_ok, err_msg, err_type = fetch_data(device, target_url, device.preferences.timeoutSec, "에어코리아 실황")
  if not items then
    return nil, nil, http_ok, err_msg, err_type
  end

  local item = items[1]
  if not item then
    return nil, nil, http_ok, "실황 결과값 비어있음", "api"
  end

  local pm10 = tonumber(item.pm10Value)
  local pm25 = tonumber(item.pm25Value)
  local data_time = item.dataTime -- "2024-05-06 14:00"

  if pm10 then
    device:emit_component_event(device.profile.components.main, dust_cap.dustLevel({ value = pm10 }))
  end
  if pm25 then
    device:emit_component_event(device.profile.components.main, dust_cap.fineDustLevel({ value = pm25 }))
  end

  log.info(string.format("[%s] 대기질 실황 업데이트: PM10=%s, PM2.5=%s (%s 기준)", device.id, tostring(pm10), tostring(pm25), tostring(data_time)))

  local base_info = { base_date = "", base_time = data_time }
  return items, base_info, http_ok, nil, nil
end

-----------------------------------------------------------------------
-- [2] 예보: getMinuDustFrcstDspth
-----------------------------------------------------------------------
local REGION_MAP = {
  seoul = "서울", jeju = "제주", jeonnam = "전남", jeonbuk = "전북",
  gwangju = "광주", gyeongnam = "경남", gyeongbuk = "경북", ulsan = "울산",
  daegu = "대구", busan = "부산", chungnam = "충남", chungbuk = "충북",
  sejong = "세종", daejeon = "대전", yeongdong = "영동", yeongseo = "영서",
  gyeonggiSouth = "경기남부", gyeonggiNorth = "경기북부", incheon = "인천"
}

-- informGrade 문자열(예: "서울 : 보통,제주 : 나쁨,...")에서 해당 권역 등급 추출
local function extract_grade_from_string(inform_grade, target_region)
  if not inform_grade then return "-" end
  for region, grade in string.gmatch(inform_grade, "([^:,]+)%s*:%s*([^:,]+)") do
    if region:match("^%s*(.-)%s*$") == target_region then
      return grade:match("^%s*(.-)%s*$")
    end
  end
  return "-"
end

function airkorea_api.fetch_forecast(device)
  local service_key = device:get_field("api_key")
  local pref_region = device.preferences.regionName or "seoul"
  local region_name = REGION_MAP[pref_region] or "서울"
  
  if not service_key or service_key == "" then
    return nil, nil, false, "API 키 미설정", "api"
  end

  local now_utc = os.time()
  local now_kst = now_utc + (9 * 60 * 60)
  local kst_time = os.date("*t", now_kst)
  
  local query_time = now_kst
  if kst_time.hour < 5 then
    query_time = now_kst - (24 * 60 * 60)
  end
  
  local search_date = os.date("%Y-%m-%d", query_time)
  local today_date = os.date("%Y-%m-%d", now_kst)
  local tomorrow_date = os.date("%Y-%m-%d", now_kst + 24 * 60 * 60)

  local endpoint = "https://apis.data.go.kr/B552584/ArpltnInforInqireSvc/getMinuDustFrcstDspth"
  local query = string.format("?serviceKey=%s&returnType=json&numOfRows=20&pageNo=1&searchDate=%s",
    service_key, search_date)
  local target_url = endpoint .. query

  local items, http_ok, err_msg, err_type = fetch_data(device, target_url, device.preferences.timeoutSec, "에어코리아 예보")
  if not items then
    return nil, nil, http_ok, err_msg, err_type
  end

  local today_data = { pm10 = "-", pm25 = "-" }
  local tomorrow_data = { pm10 = "-", pm25 = "-" }
  local data_time = nil

  for _, item in ipairs(items) do
    if not data_time and item.dataTime then
      data_time = item.dataTime
    end
    
    local code = item.informCode
    local target_date = item.informData
    local grade_str = item.informGrade

    if code == "PM10" or code == "PM25" then
      local extracted_grade = extract_grade_from_string(grade_str, region_name)
      if target_date == today_date then
        if code == "PM10" then today_data.pm10 = extracted_grade
        elseif code == "PM25" then today_data.pm25 = extracted_grade end
      elseif target_date == tomorrow_date then
        if code == "PM10" then tomorrow_data.pm10 = extracted_grade
        elseif code == "PM25" then tomorrow_data.pm25 = extracted_grade end
      end
    end
  end

  -- emit component events
  local today_comp = device.profile.components.todayForecast
  if today_comp and forecast_grade_cap then
    device:emit_component_event(today_comp, forecast_grade_cap.dustGrade({ value = today_data.pm10 }))
    device:emit_component_event(today_comp, forecast_grade_cap.fineDustGrade({ value = today_data.pm25 }))
  end

  local tomorrow_comp = device.profile.components.tomorrowForecast
  if tomorrow_comp and forecast_grade_cap then
    device:emit_component_event(tomorrow_comp, forecast_grade_cap.dustGrade({ value = tomorrow_data.pm10 }))
    device:emit_component_event(tomorrow_comp, forecast_grade_cap.fineDustGrade({ value = tomorrow_data.pm25 }))
  end

  log.info(string.format("[%s] 먼지예보 오늘(PM10:%s,PM2.5:%s) 내일(PM10:%s,PM2.5:%s)",
    device.id, today_data.pm10, today_data.pm25, tomorrow_data.pm10, tomorrow_data.pm25))

  local base_info = { base_date = "", base_time = data_time or "" }
  return items, base_info, http_ok, nil, nil
end

return airkorea_api
