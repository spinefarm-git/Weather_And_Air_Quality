-----------------------------------------------------------------------
-- init.lua
--  - 드라이버 엔트리 포인트
--  - 디바이스 생성/설정변경 라이프사이클 처리
--  - Health 주기 타이머 설정
--  - Capability 명령을 command_handlers.lua로 연결
--  - API 키 입력 및 설정 변경 라이프사이클 처리
--  - 온보딩 프로파일 → 메인 프로파일 전환 처리
-----------------------------------------------------------------------

local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"

local discovery = require "discovery"
local commands = require "command_handlers"

local statusMessage_cap = capabilities["achievedictionary39087.debugMessage"]
local cardMessage_cap   = capabilities["achievedictionary39087.cardMessage"]
local setupCard_cap     = capabilities["samplecircle50208.setupCard"]
local SETUP_PROFILE     = "weather-and-air-quality-setup"
local MAIN_PROFILE      = "weather-and-air-quality-main"
local CHILD_PROFILE     = "weather-and-air-quality-child"

-----------------------------------------------------------------------
-- [0] 타이머 설정 변수
--  초단기실황: 매시간 :10에 발행 → 마진 포함 :15, :45에 30분 간격 갱신
--  단기예보는 8회/일 발행 (02, 05, 08, 11, 14, 17, 20, 23시)
--  하지만 API 호출 최소화를 위해 하루 1회 (02시)만 갱신
--  (최저기온 TMN은 02시 발표에만 포함, 최고기온 TMX는 02~14시 발표에 포함)
-----------------------------------------------------------------------
-- 갱신 주기별 시간 내 분(minute) 목록
-- 10분: 6회/시, 20분: 3회/시, 30분: 2회/시(:15,:45), 60분: 1회/시(:15)
local REFRESH_MINUTES_MAP = {
  ["10"] = {0, 10, 20, 30, 40, 50},
  ["20"] = {0, 20, 40},
  ["30"] = {15, 45},
  ["60"] = {15},
}
local DEFAULT_INTERVAL    = "30"
local VILAGE_REFRESH_HOUR = 2       -- 단기예보 갱신: N시 (0~23)
local AIRKOREA_FRCST_REFRESH_HOUR = 6 -- 먼지예보 갱신 (06:15경)

local function get_refresh_minutes(device)
  local pref = device.preferences and device.preferences.refreshInterval
  return REFRESH_MINUTES_MAP[pref] or REFRESH_MINUTES_MAP[DEFAULT_INTERVAL]
end

-----------------------------------------------------------------------
-- [1] 디바이스 구분 헬퍼
-----------------------------------------------------------------------

-- main/child 판별
local function is_main_device(device)
  return device.device_network_id == "weather-api-spinefarm-01"
end

-- child 디바이스에서 main 디바이스를 찾아 api_key + proxy_url 동기화
local function sync_from_main(driver, device)
  local need_key = not (device:get_field("api_key") and device:get_field("api_key") ~= "")
  local need_url = not (device:get_field("proxy_url") and device:get_field("proxy_url") ~= "")

  if not need_key and not need_url then
    return
  end

  for _, d in ipairs(driver:get_devices()) do
    if is_main_device(d) then
      if need_key then
        local main_key = d:get_field("api_key")
        if main_key and main_key ~= "" then
          device:set_field("api_key", main_key, { persist = true })
          log.info(string.format("[%s] api_key 동기화 완료", device.id))
        end
      end
      if need_url then
        local main_url = d.preferences.proxyUrl
        if main_url and main_url ~= "" then
          device:set_field("proxy_url", main_url, { persist = true })
          log.info(string.format("[%s] proxy_url 동기화 완료: %s", device.id, main_url))
        end
      end
      return
    end
  end
  log.warn(string.format("[%s] main 디바이스를 찾을 수 없어 동기화 실패", device.id))
end

-- API 키/proxy_url 저장 후 모든 child 디바이스에 전파
local function propagate_to_children(driver, api_key, proxy_url)
  for _, d in ipairs(driver:get_devices()) do
    if d.parent_device_id ~= nil then
      if api_key   then d:set_field("api_key",   api_key,   { persist = true }) end
      if proxy_url then d:set_field("proxy_url", proxy_url, { persist = true }) end
      log.info(string.format("[%s] children에 전파 완료", d.id))
    end
  end
end

-----------------------------------------------------------------------
-- [2] 표준 emit_status 헬퍼
-----------------------------------------------------------------------
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
-- [4] 온보딩 프로파일 헬퍼
-----------------------------------------------------------------------

-- setupCard 컴포넌트 존재 여부 확인
local function has_setup_card(device)
  if not device.profile or not device.profile.components then return false end
  for _, comp in pairs(device.profile.components) do
    if comp.capabilities and comp.capabilities["samplecircle50208.setupCard"] then return true end
  end
  return false
end

-- 온보딩 카드에 API 포털 링크 표시 (컴포넌트별 링크 1개씩)
local function show_setup_card(device)
  if not has_setup_card(device) then return end
  if not (setupCard_cap and setupCard_cap.info) then
    log.warn(string.format("[%s] setupCard capability not loaded", device.id))
    return
  end
  local FS1 = "font-size:0.9em"
  local FS2 = "font-size:0.8em"

  local cards = {
    { comp_id = "kmaApi",
      url  = "https://www.data.go.kr/data/15084084/openapi.do",
      text = "기상청 단기예보 신청 ›" },
    { comp_id = "airkoreaApi",
      url  = "https://www.data.go.kr/data/15073861/openapi.do",
      text = "에어코리아 대기오염정보 신청 ›" },
  }

  for _, card in ipairs(cards) do
    local comp = device.profile.components[card.comp_id]
    if comp then
      local html_str = string.format(
        "<center>"
        .. "<a href='%s' target='_blank'"
        .. " style='%s;color:#ffffff;font-weight:600;text-decoration:none'>%s</a><br/>"
        .. "<span style='%s;color:#aaaaaa'>API KEY 발급 후 기기 설정에서 입력</span>"
        .. "</center>",
        card.url, FS1, card.text, FS2)
      local ok, err = pcall(device.emit_component_event, device, comp,
        setupCard_cap.info({ value = { html = html_str } }))
      if not ok then
        log.warn(string.format("[%s] setupCard emit 실패 (%s): %s", device.id, card.comp_id, tostring(err)))
      end
    end
  end
end

-- 메인 프로파일로 전환 요청 (device_init 재호출로 나머지 처리)
local function activate_main(device)
  device:try_update_metadata({ profile = MAIN_PROFILE })
end

-----------------------------------------------------------------------
-- [6] 주기 타이머 설정
-----------------------------------------------------------------------
local function reschedule_timers(device)
  local old_timer = device:get_field("RefreshTimer")
  if old_timer then
    device.thread:cancel_timer(old_timer)
    device:set_field("RefreshTimer", nil, { persist = false })
  end

  local now_utc = os.time()
  local now_kst = now_utc + (9 * 60 * 60)
  local kst_time = os.date("*t", now_kst)

  local current_min = kst_time.min
  local stagger_sec = device:get_field("refresh_stagger") or 0
  local minutes_until_next
  for _, target_min in ipairs(get_refresh_minutes(device)) do
    local diff = current_min < target_min
      and (target_min - current_min)
      or  (60 - current_min + target_min)
    if not minutes_until_next or diff < minutes_until_next then
      minutes_until_next = diff
    end
  end

  local seconds_until_next = minutes_until_next * 60 + stagger_sec

  local refresh_timer = device.thread:call_with_delay(seconds_until_next, function()
    local success, err = pcall(function()
      commands.refresh_ultra(nil, device)

      local exec_time = os.date("*t", os.time() + (9 * 60 * 60))
      if exec_time.hour == VILAGE_REFRESH_HOUR then
        commands.refresh_vilage(nil, device)
        log.info(string.format("[%s] 단기예보 갱신 실행 (%02d시)", device.id, VILAGE_REFRESH_HOUR))
      end
      
      if exec_time.hour == AIRKOREA_FRCST_REFRESH_HOUR then
        commands.refresh_airkorea_frcst(nil, device)
        log.info(string.format("[%s] 먼지예보 갱신 실행 (%02d시)", device.id, AIRKOREA_FRCST_REFRESH_HOUR))
      end
    end)
    if not success then
      log.error(string.format("[%s] 갱신 실패: %s", device.id, tostring(err)))
    end
    reschedule_timers(device)
  end)
  device:set_field("RefreshTimer", refresh_timer, { persist = false })
  log.info(string.format("[%s] 갱신 타이머: %d분 %d초 후 실행 (현재 %02d:%02d, 주기 %s분, 오프셋 +%d초)",
    device.id, minutes_until_next, stagger_sec, kst_time.hour, kst_time.min,
    (device.preferences and device.preferences.refreshInterval) or DEFAULT_INTERVAL,
    stagger_sec))
end

-----------------------------------------------------------------------
-- [6-2] Ping 타이머 (10분 고정)
-----------------------------------------------------------------------
local HEALTH_CHECK_INTERVAL = 600

local function reschedule_health_check(driver, device)
  local old_timer = device:get_field("health_check_timer")
  if old_timer then
    device.thread:cancel_timer(old_timer)
    device:set_field("health_check_timer", nil)
  end

  local timer = device.thread:call_with_delay(HEALTH_CHECK_INTERVAL, function()
    local ok, err = pcall(function()
      commands.ping(driver, device)
    end)
    if not ok then
      log.error(string.format("[%s] ping 타이머 오류: %s", device.id, tostring(err)))
    end
    reschedule_health_check(driver, device)
  end)

  device:set_field("health_check_timer", timer)
  log.info(string.format("[%s] ping 타이머 설정: %d초 후", device.id, HEALTH_CHECK_INTERVAL))
end

-----------------------------------------------------------------------
-- [7] 초기값 emit (메인 프로파일 전용)
-----------------------------------------------------------------------
local function emit_initial_values(device)
  local ok, err = pcall(function()
    local main = device.profile.components.main
    device:emit_component_event(main, capabilities.temperatureMeasurement.temperature({ value = 0, unit = "C" }))
    device:emit_component_event(main, capabilities.relativeHumidityMeasurement.humidity({ value = 0, unit = "%" }))

    local windInfo_cap = capabilities["achievedictionary39087.windInfo"]
    device:emit_component_event(main, windInfo_cap.direction({ value = 0, unit = "deg" }))
    device:emit_component_event(main, windInfo_cap.speed({ value = 0, unit = "m/s" }))

    local dust_cap = capabilities.dustSensor
    if dust_cap then
      device:emit_component_event(main, dust_cap.dustLevel({ value = 0 }))
      device:emit_component_event(main, dust_cap.fineDustLevel({ value = 0 }))
    end

    if cardMessage_cap then
      device:emit_component_event(main, cardMessage_cap.message({ value = "초기화 중..." }))
    end

    local precipLive_cap = capabilities["achievedictionary39087.precipitationLive"]
    if precipLive_cap then
      device:emit_component_event(main, precipLive_cap.type({ value = "0" }))
      device:emit_component_event(main, precipLive_cap.rate({ value = 0, unit = "mm" }))
    end

    local skytype_cap = capabilities["achievedictionary39087.skyType"]
    local precip_cap = capabilities["achievedictionary39087.precipitationInfo"]
    local tempRange_cap = capabilities["achievedictionary39087.temperatureRange"]
    local ak_frcst_cap = capabilities["achievedictionary39087.dustForecast"]

    for _, comp_id in ipairs({ "todayForecast", "tomorrowForecast" }) do
      local comp = device.profile.components[comp_id]
      if comp then
        device:emit_component_event(comp, skytype_cap.skyType({ value = "1" }))
        device:emit_component_event(comp, precip_cap.type({ value = "0" }))
        device:emit_component_event(comp, precip_cap.probability({ value = 0, unit = "%" }))
        device:emit_component_event(comp, precip_cap.rate({ value = "강수없음" }))
        device:emit_component_event(comp, tempRange_cap.minimum({ value = 0, unit = "C" }))
        device:emit_component_event(comp, tempRange_cap.maximum({ value = 0, unit = "C" }))
        if ak_frcst_cap then
          device:emit_component_event(comp, ak_frcst_cap.dustGrade({ value = "-" }))
          device:emit_component_event(comp, ak_frcst_cap.fineDustGrade({ value = "-" }))
        end
      end
    end
  end)
  if not ok then
    log.warn(string.format("[%s] 초기값 emit 실패: %s", device.id, tostring(err)))
  end
end

-----------------------------------------------------------------------
-- [8] 디바이스 라이프 사이클 핸들러
-----------------------------------------------------------------------

local function device_removed(driver, device)
  local timer = device:get_field("RefreshTimer")
  if timer then device.thread:cancel_timer(timer) end
  local health_timer = device:get_field("health_check_timer")
  if health_timer then device.thread:cancel_timer(health_timer) end
  -- EDGE_CHILD 자식 기기는 플랫폼이 자동 삭제
end

local function device_init(driver, device)
  log.info(string.format("[%s] 기기 초기화 (DNI: %s)", device.id, tostring(device.device_network_id)))

  if not is_main_device(device) then
    sync_from_main(driver, device)
  end

  local api_key = device:get_field("api_key")

  -- API 키 미설정 처리
  if not api_key or api_key == "" then
    if is_main_device(device) then
      -- main: 온보딩 프로파일로 전환하고 설정 카드 표시
      device:try_update_metadata({ profile = SETUP_PROFILE })
      show_setup_card(device)
      log.warn(string.format("[%s] API 키 미설정 — 카드의 링크에서 키를 발급하세요", device.id))
    else
      local hint = "API 키 미설정 — main 디바이스에서 먼저 설정해주세요"
      log.warn(string.format("[%s] %s", device.id, hint))
      emit_status(device, hint)
    end
    return
  end

  -- API 키 설정됨 → main은 메인 프로파일로 전환, child는 그대로
  if is_main_device(device) then
    device:try_update_metadata({ profile = MAIN_PROFILE })
  end

  emit_initial_values(device)

  local msg = "초기화 완료 (API 키 설정됨)"
  log.info(string.format("[%s] %s", device.id, msg))
  emit_status(device, msg)

  -- child 장치의 갱신 시각 분산: DNI 순서 기준 20초씩 지연
  local stagger_sec = 0
  if not is_main_device(device) then
    local earlier_count = 0
    for _, d in ipairs(driver:get_devices()) do
      if not is_main_device(d) and d.device_network_id < device.device_network_id then
        earlier_count = earlier_count + 1
      end
    end
    stagger_sec = (earlier_count + 1) * 20
  end
  device:set_field("refresh_stagger", stagger_sec, { persist = false })

  commands.refresh(driver, device)
  reschedule_timers(device)
  reschedule_health_check(driver, device)
end

local function device_info_changed(driver, device, _, args)
  log.info(string.format("[%s] 설정 변경됨 (Preferences Updated)", device.id))

  local old_prefs = args.old_st_store and args.old_st_store.preferences or {}

  -- child 디바이스는 main 전용 설정 변경 무시
  if not is_main_device(device) then
    log.debug(string.format("[%s] child 디바이스 - main 전용 설정 변경 무시", device.id))
    local api_key = device:get_field("api_key")
    if api_key and api_key ~= "" then
      commands.refresh(driver, device)
      reschedule_timers(device)
    end
    return
  end

  -- '장치 추가' 스위치 (main 전용)
  if device.preferences.createAnother == true and old_prefs.createAnother ~= true then
    log.info("장치 추가 스위치 ON 감지 -> 새 장치 생성 시도")

    local next_num = (device:get_field("child_count") or 0) + 1
    device:set_field("child_count", next_num)

    local child_key = string.format("weather-child-%d-%d", os.time(), math.random(1000, 9999))
    local metadata = {
      type = "EDGE_CHILD",
      parent_device_id = device.id,
      parent_assigned_child_key = child_key,
      label = string.format("Weather and Air Quality Spinefarm (Child %d)", next_num),
      profile = CHILD_PROFILE,
      vendor_provided_label = "Child Device"
    }

    emit_status(device, string.format("Child %d 장치 생성 요청됨", next_num))
    driver:try_create_device(metadata)
    log.info(string.format("새 장치 생성 요청 완료: key=%s", child_key))
  end

  -- apiKey 필드 변경 감지 (ST 설정 메뉴에서 직접 입력한 경우)
  local old_api_key_pref = old_prefs.apiKey or ""
  local new_api_key_pref = device.preferences.apiKey or ""
  if new_api_key_pref ~= old_api_key_pref and new_api_key_pref ~= "" then
    log.info(string.format("[%s] 설정 메뉴에서 API 키 변경 감지", device.id))
    device:set_field("api_key", new_api_key_pref, { persist = true })
    propagate_to_children(driver, new_api_key_pref, nil)
    emit_status(device, "설정 메뉴에서 API 키 업데이트됨")
  end

  -- proxyUrl 변경 시 child에도 전파
  local old_proxy = old_prefs.proxyUrl or ""
  local new_proxy = device.preferences.proxyUrl or ""
  if new_proxy ~= old_proxy and new_proxy ~= "" then
    log.info(string.format("[%s] proxyUrl 변경 감지 -> children에 전파", device.id))
    propagate_to_children(driver, nil, new_proxy)
  end

  -- API 키 설정 여부: 온보딩 중이면 메인 전환, 이미 메인이면 즉시 갱신
  local api_key = device:get_field("api_key")
  if api_key and api_key ~= "" then
    if device.profile.components["todayForecast"] then
      -- 이미 메인 프로파일 → 즉시 갱신
      commands.refresh(driver, device)
      reschedule_timers(device)
    else
      -- 온보딩 프로파일 → 메인으로 전환
      -- 전환 후 발생하는 두 번째 infoChanged 이벤트에서 refresh를 처리합니다.
      activate_main(device)
    end
  end
end

-----------------------------------------------------------------------
-- [9] 드라이버 정의 및 실행
-----------------------------------------------------------------------
local spinefarm_driver = Driver("weather-and-air-quality", {
  discovery = discovery.handle_discovery,
  lifecycle_handlers = {
    init        = device_init,
    removed     = device_removed,
    infoChanged = device_info_changed,
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = function(driver, device)
        commands.refresh(driver, device)
        reschedule_timers(device)
      end,
    },
    [capabilities.healthCheck.ID] = {
      [capabilities.healthCheck.commands.ping.NAME] = commands.ping,
    }
  }
})

spinefarm_driver:run()
