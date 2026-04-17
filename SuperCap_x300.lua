-- SuperCap_x300.lua
-- x300-compatible rewrite of SuperCap.lua
-- Uses lua-libmodbus + mosquitto_pub
--
-- Notes:
-- 1) Adjust Modbus transport section below:
--      - USE_MODBUS_TCP = true  => connect to localhost:1502 style bridge
--      - USE_MODBUS_TCP = false => direct RTU serial port
-- 2) Adjust MQTT settings as needed
-- 3) GPS is not pulled from x300 here; latitude/longitude default to 0
--    or can be set from config/static site values

local mb = require("libmodbus")

----------------------------------------------------------------------
-- Configuration
----------------------------------------------------------------------

-- MQTT
local MQTT_HOST  = "broker.hivemq.com"
local MQTT_PORT  = 1883
local MQTT_TOPIC = "devices/%s/messages/events/"
local MQTT_QOS   = nil      -- set to 1 or 2 if you want to add -q
local MQTT_RETAIN = false   -- true adds -r

-- Modbus transport
local USE_MODBUS_TCP = false

-- If using Modbus TCP bridge/service on x300
local MODBUS_TCP_HOST = "localhost"
local MODBUS_TCP_PORT = 1502

-- If using direct RTU serial
local MODBUS_RTU_DEVICE   = "/dev/ttyS1"   -- adjust as needed
local MODBUS_RTU_BAUD     = 9600
local MODBUS_RTU_PARITY   = "N"            -- "N", "E", or "O"
local MODBUS_RTU_DATABITS = 8
local MODBUS_RTU_STOPBITS = 1

-- Polling
local POLL_SECONDS = 180
local PER_REGISTER_DELAY_MS = 50

-- Optional static site coordinates
local STATIC_LAT = 0
local STATIC_LON = 0

-- Module/slave scan range
local FIRST_SLAVE = 2
local LAST_SLAVE  = 15

-- IMEI source on x300 example
local IMEI_FILE = "/tmp/sysinfo/imei"

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

local message_sequence = 0

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function sleep_ms(ms)
  os.execute("sleep " .. string.format("%.3f", ms / 1000))
end

local function shell_quote(s)
  -- Safe single-quote escaping for shell command strings
  s = tostring(s or "")
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function trim(s)
  if not s then return "" end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

local function get_imei()
  local s = read_file(IMEI_FILE)
  if not s then
    return "unknown"
  end
  s = trim(s)
  if s == "" then
    return "unknown"
  end
  return s
end

local function utc_iso8601()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function utc_epoch()
  return os.time(os.date("!*t"))
end

local function reg_to_offset(reg)
  -- Example:
  -- 304097 -> 4096
  -- 304098 -> 4097
  -- 308217 -> 8216
  return reg - 300001
end

local function to_s16(v)
  if v >= 0x8000 then
    return v - 0x10000
  end
  return v
end

local function get_bit_value(word, bit)
  if word == nil then
    return 0
  end
  return math.floor(word / (2 ^ bit)) % 2
end

----------------------------------------------------------------------
-- Scaling logic preserved from original
----------------------------------------------------------------------

local function scale_register(reg, raw)
  if reg == 304097 or reg == 304099 or reg == 304100 then
    return raw * 0.01
  elseif reg == 304098 then
    return raw * 0.01
  elseif reg == 304101 then
    return raw * 10
  elseif reg == 304102 or reg == 304103 then
    return raw * 0.1
  elseif reg == 304104 or reg == 304111 then
    return raw
  elseif reg == 304105 or reg == 304107 or reg == 304108 then
    return raw * 0.001
  elseif reg == 304106 or reg == 304109 or reg == 304110 then
    return (raw * 0.1) - 273.1
  elseif reg >= 308217 and reg <= 308218 then
    return (raw * 0.1) - 273.1
  else
    return raw
  end
end

----------------------------------------------------------------------
-- Modbus connection
----------------------------------------------------------------------

local function new_modbus_device()
  local dev

  if USE_MODBUS_TCP then
    dev = mb.new_tcp_pi(MODBUS_TCP_HOST, MODBUS_TCP_PORT)
  else
    dev = mb.new_rtu(
      MODBUS_RTU_DEVICE,
      MODBUS_RTU_BAUD,
      MODBUS_RTU_PARITY,
      MODBUS_RTU_DATABITS,
      MODBUS_RTU_STOPBITS
    )
  end

  if not dev then
    error("Failed to create libmodbus device")
  end

  -- Optional debug
  -- dev:set_debug()

  local ok, err = dev:connect()
  if not ok then
    error("Couldn't connect to Modbus device: " .. tostring(err))
  end

  return dev
end

local function read_scaled(dev, slave, reg)
  local offset = reg_to_offset(reg)

  local ok, err = dev:set_slave(slave)
  if not ok then
    return nil, false, "set_slave failed for slave " .. tostring(slave) .. ": " .. tostring(err)
  end

  -- Original script used 3xxxx/0x04 style input registers
  local t, rerr = dev:read_input_registers(offset, 1)
  if not t then
    return nil, false, "read_input_registers failed for reg " .. tostring(reg) .. ": " .. tostring(rerr)
  end

  local raw = t[1]
  if raw == nil then
    return nil, false, "No data returned for reg " .. tostring(reg)
  end

  if reg == 304098 then
    raw = to_s16(raw)
  end

  return scale_register(reg, raw), true, nil
end

----------------------------------------------------------------------
-- Data collection
----------------------------------------------------------------------

local function collect_module_values(dev, slave)
  local values = {}

  -- Probe first register to determine whether module exists
  local probe, ok = read_scaled(dev, slave, 304097)
  if not ok then
    return nil
  end

  local idx = 1

  for reg = 304097, 304111 do
    local v, vok = read_scaled(dev, slave, reg)
    if not vok then
      return nil
    end
    values[idx] = v
    idx = idx + 1
    sleep_ms(PER_REGISTER_DELAY_MS)
  end

  for reg = 308217, 308218 do
    local v, vok = read_scaled(dev, slave, reg)
    if not vok then
      return nil
    end
    values[idx] = v
    idx = idx + 1
    sleep_ms(PER_REGISTER_DELAY_MS)
  end

  return values
end

----------------------------------------------------------------------
-- JSON build
----------------------------------------------------------------------

local function build_json(slave, values, lat, lon, imei)
  local parts = {}
  parts[#parts + 1] = '{"data":{'
  parts[#parts + 1] = '"fox3Timestamp_utc":"' .. utc_iso8601() .. '",'
  parts[#parts + 1] = '"fox3Profile":"Device(7.68KWh)(75AH)",'
  parts[#parts + 1] = '"fox3SerialNumber":"' .. tostring(imei) .. '",'
  parts[#parts + 1] = '"Latitude":' .. tostring(lat) .. ','
  parts[#parts + 1] = '"Longitude":' .. tostring(lon) .. ','
  parts[#parts + 1] = '"messageSequenceNumber":' .. tostring(message_sequence) .. ','
  parts[#parts + 1] = '"module":"' .. tostring(slave) .. '"'
  parts[#parts + 1] = ',"Total_Voltage":' .. tostring(values[1] or 0)
  parts[#parts + 1] = ',"Current":' .. tostring(values[2] or 0)
  parts[#parts + 1] = ',"Remaining_Capacity":' .. tostring(values[3] or 0)
  parts[#parts + 1] = ',"Total_Capacity":' .. tostring(values[4] or 0)
  parts[#parts + 1] = ',"Total_Discharge_Capacity":' .. tostring(values[5] or 0)
  parts[#parts + 1] = ',"State_of_Charge":' .. tostring(values[6] or 0)
  parts[#parts + 1] = ',"State_of_Health":' .. tostring(values[7] or 0)
  parts[#parts + 1] = ',"Cycled":' .. tostring(values[8] or 0)
  parts[#parts + 1] = ',"Ave_Cell_Voltage":' .. tostring(values[9] or 0)
  parts[#parts + 1] = ',"Ave_Cell_Temp":' .. tostring(values[10] or 0)
  parts[#parts + 1] = ',"Max_Cell_Voltage":' .. tostring(values[11] or 0)
  parts[#parts + 1] = ',"Min_Cell_Voltage":' .. tostring(values[12] or 0)
  parts[#parts + 1] = ',"Max_Cell_Temp":' .. tostring(values[13] or 0)
  parts[#parts + 1] = ',"Min_Cell_Temp":' .. tostring(values[14] or 0)
  parts[#parts + 1] = ',"System_Events_Code":' .. tostring(values[15] or 0)
  parts[#parts + 1] = ',"Over_voltage":' .. tostring(get_bit_value(values[15],0))
  parts[#parts + 1] = ',"Under_voltage":' .. tostring(get_bit_value(values[15],1))
  parts[#parts + 1] = ',"Charge_over_current":' .. tostring(get_bit_value(values[15],2))
  parts[#parts + 1] = ',"Discharge_over_current":' .. tostring(get_bit_value(values[15],3))
  parts[#parts + 1] = ',"Short_Inverse_current":' .. tostring(get_bit_value(values[15],4))
  parts[#parts + 1] = ',"High_temperature":' .. tostring(get_bit_value(values[15],5))
  parts[#parts + 1] = ',"Low_temperature":' .. tostring(get_bit_value(values[15],6))
  parts[#parts + 1] = ',"Residual_capacity_of_battery_alarm":' .. tostring(get_bit_value(values[15],7))
  parts[#parts + 1] = ',"Discharging":' .. tostring(get_bit_value(values[15],8))
  parts[#parts + 1] = ',"Charging":' .. tostring(get_bit_value(values[15],9))
  parts[#parts + 1] = ',"Charge_Online":' .. tostring(get_bit_value(values[15],10))
  parts[#parts + 1] = ',"Environment_Temp":' .. tostring(values[16] or 0)
  parts[#parts + 1] = ',"Power_Temp":' .. tostring(values[17] or 0)
  parts[#parts + 1] = '}}'
  return table.concat(parts)
end

----------------------------------------------------------------------
-- MQTT publish
----------------------------------------------------------------------

local function publish_module(slave, values, lat, lon, imei)
  local topic = string.format(MQTT_TOPIC, imei)
  local payload = build_json(slave, values, lat, lon, imei)

  local cmd_parts = {
    "mosquitto_pub",
    "-h", MQTT_HOST,
    "-p", tostring(MQTT_PORT),
    "-i", imei,
    "-t", shell_quote(topic),
    "-m", shell_quote(payload)
  }

  if MQTT_QOS ~= nil then
    table.insert(cmd_parts, "-q")
    table.insert(cmd_parts, tostring(MQTT_QOS))
  end

  if MQTT_RETAIN then
    table.insert(cmd_parts, "-r")
  end

  local cmd = table.concat(cmd_parts, " ")
  local rc = os.execute(cmd)

  message_sequence = message_sequence + 1
  return rc
end

----------------------------------------------------------------------
-- Main poll cycle
----------------------------------------------------------------------

local function supercap(dev)
  local lat = STATIC_LAT
  local lon = STATIC_LON
  local imei = get_imei()

  for slave = FIRST_SLAVE, LAST_SLAVE do
    local values = collect_module_values(dev, slave)
    if values ~= nil then
      publish_module(slave, values, lat, lon, imei)
    end
  end
end

----------------------------------------------------------------------
-- Main loop
----------------------------------------------------------------------

local dev = new_modbus_device()

while true do
  local ok, err = pcall(function()
    supercap(dev)
  end)

  if not ok then
    print("Poll cycle failed: " .. tostring(err))

    -- Attempt reconnect on next cycle
    pcall(function() dev:close() end)
    sleep_ms(1000)
    dev = new_modbus_device()
  end

  os.execute("sleep " .. tostring(POLL_SECONDS))
end