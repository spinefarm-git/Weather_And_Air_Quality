-----------------------------------------------------------------------
-- command_handlers.lua
-- SmartThings Capability Command Handler
-----------------------------------------------------------------------

local cosock = require "cosock"
local capabilities = require "st.capabilities"
local log = require "log"
local http = cosock.asyncify "socket.http"
local ltn12 = require "ltn12"
local kma_api = require "kma_api"
local airkorea_api = require "airkorea_api"

local handler = {}

-- status capability
local statusMessage_cap = capabilities["achievedictionary39087.debugMessage"]

-- [표준] emit_status 헬퍼
local function emit_status(device, msg)
  local comp = device.profile.components.status
  if comp and statusMessage_cap then
    local ok, err = pcall(function()
      device:emit_component_event(comp, statusMessage_cap.message({ value = msg }))
    end)
    if not ok then
      log.warn(string.format("[%s] emit_status 실패: %s", device.id, tostring(err)))
    end
  end
end

-----------------------------------------------------------------------
-- Health Check (healthCheck.ping 커맨드 핸들러 + ping 타이머 콜백)
-----------------------------------------------------------------------
function handler.ping(driver, device)
  local proxy_url = device.preferences.proxyUrl or device:get_field("proxy_url")
  if not proxy_url or proxy_url == "" then
    log.warn("[ping] proxyUrl 미설정")
    emit_status(device, "연결 실패 — proxyUrl을 설정해주세요")
    device:offline()
    return
  end

  local url = proxy_url:gsub("/+$", "") .. "/api/ping"
  local resp_chunks = {}
  local code
  local ok, err = pcall(function()
    local _, c = http.request({
      url     = url,
      method  = "POST",
      source  = ltn12.source.string(""),
      headers = { ["content-length"] = "0" },
      sink    = ltn12.sink.table(resp_chunks),
      timeout = 10,
    })
    code = c
  end)

  if ok and tonumber(code) == 200 then
    log.info("[ping] EB OK → online")
    device:online()
  else
    log.warn("[ping] EB 응답 없음: " .. tostring(ok and code or err))
    emit_status(device, "연결 실패 — Edge Bridge를 확인해주세요")
    device:offline()
  end
end

-----------------------------------------------------------------------
-- Refresh (데이터 갱신)
-----------------------------------------------------------------------
-- -----------------------------------------------------------------------
-- Request Queue Logic (Serialized Processing)
-- -----------------------------------------------------------------------
local request_queue = {}
local is_processing = false

local function process_next()
  if #request_queue == 0 then
    is_processing = false
    return
  end

  is_processing = true
  local task = table.remove(request_queue, 1)

  cosock.spawn(function()
    local device = task.device
    local fetch_ultra = task.fetch_ultra
    local fetch_vilage = task.fetch_vilage
    local fetch_airkorea_live = task.fetch_airkorea_live
    local fetch_airkorea_frcst = task.fetch_airkorea_frcst

    log.info(string.format("[%s] 큐 처리 시작 (대기열: %d)", device.id, #request_queue))

    -- 1. 데이터 가져오기
    local ultra_items, ultra_base, ultra_http_ok, ultra_err, ultra_err_type
    local vilage_data, vilage_base, vilage_http_ok, vilage_err, vilage_err_type
    local ak_live_items, ak_live_base, ak_live_http_ok, ak_live_err, ak_live_err_type
    local ak_frcst_items, ak_frcst_base, ak_frcst_http_ok, ak_frcst_err, ak_frcst_err_type
    
    if fetch_ultra then
      ultra_items, ultra_base, ultra_http_ok, ultra_err, ultra_err_type = kma_api.fetch_ultra_srt_ncst(device)
      cosock.socket.sleep(2.0)
    end
    
    if fetch_airkorea_live then
      ak_live_items, ak_live_base, ak_live_http_ok, ak_live_err, ak_live_err_type = airkorea_api.fetch_live(device)
      cosock.socket.sleep(2.0)
    end
    
    if fetch_vilage then
      vilage_data, vilage_base, vilage_http_ok, vilage_err, vilage_err_type = kma_api.fetch_vilage_fcst(device)
      cosock.socket.sleep(2.0)
    end

    if fetch_airkorea_frcst then
      ak_frcst_items, ak_frcst_base, ak_frcst_http_ok, ak_frcst_err, ak_frcst_err_type = airkorea_api.fetch_forecast(device)
    end
    
    -- 2. 연결 상태 판단 (네트워크 에러만 offline 처리)
    local has_network_error = (ultra_err_type == "network") or (vilage_err_type == "network") or (ak_live_err_type == "network") or (ak_frcst_err_type == "network")
    local has_success = (ultra_http_ok and not ultra_err) or (vilage_http_ok and not vilage_err) or (ak_live_http_ok and not ak_live_err) or (ak_frcst_http_ok and not ak_frcst_err)
    
    log.info(string.format("[%s] 상태 판단: network_error=%s, success=%s, ultra_err_type=%s, vilage_err_type=%s", 
      device.id, tostring(has_network_error), tostring(has_success), 
      tostring(ultra_err_type), tostring(vilage_err_type)))
    
    -- 3. status 컴포넌트에 메시지 업데이트
    local now_utc = os.time()
    local now_kst = now_utc + (9 * 60 * 60)
    local kst_time = os.date("*t", now_kst)
    local current_time = string.format("%02d:%02d", kst_time.hour, kst_time.min)
    
    local messages = {}
    
    -- Helper: base_info를 "M/D H시" 형식으로 변환
    local function format_base_info(base_info, is_airkorea)
      if not base_info then return "" end
      local month, day, hour
      if is_airkorea then
        local t = base_info.base_time or ""
        -- "YYYY-MM-DD HH:MM"
        local y, mo, d, h = t:match("(%d%d%d%d)-(%d%d)-(%d%d) (%d%d):%d%d")
        if y then
          month, day, hour = tonumber(mo), tonumber(d), tonumber(h)
        else
          -- "YYYY-MM-DD" (시간 없음)
          y, mo, d = t:match("(%d%d%d%d)-(%d%d)-(%d%d)")
          if y then
            month, day = tonumber(mo), tonumber(d)
          end
        end
      else
        if not base_info.base_date or base_info.base_date == "" then return "" end
        month = tonumber(string.sub(base_info.base_date, 5, 6))
        day   = tonumber(string.sub(base_info.base_date, 7, 8))
        hour  = tonumber(string.sub(base_info.base_time, 1, 2))
      end
      if not month then return "" end
      if hour then
        return string.format("%d/%d %d시", month, day, hour)
      else
        return string.format("%d/%d", month, day)
      end
    end
    
    -- Helper: 상태 메시지 생성
    local success_parts = {}
    local error_parts = {}
    local has_network_error = false

    local function add_result(label, http_ok, base_info, err, err_type, is_airkorea)
      if http_ok and not err then
        local formatted = format_base_info(base_info, is_airkorea)
        if formatted ~= "" then
          table.insert(success_parts, string.format("%s:%s", label, formatted))
        else
          table.insert(success_parts, label)
        end
        log.info(string.format("[%s] %s 업데이트 성공", device.id, label))
      elseif err_type == "network" then
        has_network_error = true
        log.warn(string.format("[%s] %s 네트워크 에러", device.id, label))
      else
        table.insert(error_parts, string.format("%s실패", label))
        log.warn(string.format("[%s] %s 실패: %s", device.id, label, tostring(err)))
      end
    end

    if fetch_ultra then add_result("실황", ultra_http_ok, ultra_base, ultra_err, ultra_err_type, false) end
    if fetch_airkorea_live then add_result("먼지", ak_live_http_ok, ak_live_base, ak_live_err, ak_live_err_type, true) end
    if fetch_vilage then add_result("예보", vilage_http_ok, vilage_base, vilage_err, vilage_err_type, false) end
    if fetch_airkorea_frcst then add_result("먼지예보", ak_frcst_http_ok, ak_frcst_base, ak_frcst_err, ak_frcst_err_type, true) end

    if has_network_error then
      handler.ping(nil, device)
    else
      local msg_list = {}
      if #success_parts > 0 then
        table.insert(msg_list, "완료[" .. table.concat(success_parts, ", ") .. "]")
      end
      if #error_parts > 0 then
        table.insert(msg_list, table.concat(error_parts, ", "))
      end
      local combined_msg = string.format("%s 갱신 - %s", current_time, table.concat(msg_list, " / "))
      emit_status(device, combined_msg)
    end

    -- 다음 요청 처리 전 잠시 대기 (Rate Limit 보호)
    cosock.socket.sleep(2.0)
    process_next()
  end, "kma-worker")
end

local function do_refresh(device, fetch_ultra, fetch_vilage, fetch_airkorea_live, fetch_airkorea_frcst)
  table.insert(request_queue, { device = device, fetch_ultra = fetch_ultra, fetch_vilage = fetch_vilage, fetch_airkorea_live = fetch_airkorea_live, fetch_airkorea_frcst = fetch_airkorea_frcst })
  if not is_processing then
    process_next()
  end
end

-- 수동 Refresh: 초단기 + 먼지실황 + 단기 + 먼지예보 모두
function handler.refresh(driver, device)
  do_refresh(device, true, true, true, true)
end

-- 초단기실황 + 먼지실황 (타이머용)
function handler.refresh_ultra(driver, device)
  do_refresh(device, true, false, true, false)
end

-- 단기예보 (타이머용)
function handler.refresh_vilage(driver, device)
  do_refresh(device, false, true, false, false)
end

-- 먼지예보 (타이머용)
function handler.refresh_airkorea_frcst(driver, device)
  do_refresh(device, false, false, false, true)
end

return handler