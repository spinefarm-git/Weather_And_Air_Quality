-----------------------------------------------------------------------
-- discovery.lua
--  - 디바이스 검색(추가) 단계에서 호출됨
--  - 실제 LAN 디바이스 탐색 대신, "가상 디바이스" 1개를 생성
-----------------------------------------------------------------------

local log = require "log"
local discovery = {}

-----------------------------------------------------------------------
-- [Discovery Handler]
--  - SmartThings 앱에서 "주변 기기 검색" 시 호출
--  - 여기서는 고정된 device_network_id로 디바이스 1개 생성
-----------------------------------------------------------------------
function discovery.handle_discovery(driver, _should_continue)
  log.info("weather-api-spinefarm 장치 찾기 시작")

  local metadata = {
    type = "LAN",
    device_network_id = "weather-api-spinefarm-01", -- 고정 ID (중복 생성 방지용)
    label = "Weather and Air Quality Spinefarm",
    profile = "weather-and-air-quality-setup",      -- 온보딩 프로파일로 시작 (API 키 등록 후 메인으로 전환)
    manufacturer = "SmartThings",
    model = "v1",
    vendor_provided_label = "Virtual"
  }

  -- 디바이스 생성 시도 (이미 있으면 무시될 수 있음)
  driver:try_create_device(metadata)
end

return discovery
