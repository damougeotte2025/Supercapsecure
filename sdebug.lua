-- supercap_debug.lua
-- Minimal X300 debug app:
-- 1) Connects to X300's Modbus RTU -> Modbus TCP bridge
-- 2) Reads a few registers from the SuperCap battery
-- 3) Publishes one simple MQTT message using mosquitto_pub

local mb = require("libmodbus")

-- ===== CONFIG =====
local MODBUS_HOST = "127.0.0.1"   -- try localhost first when script runs on X300
local MODBUS_PORT = 502           -- change if you configured a different TCP port
local SLAVE_ID    = 1             -- battery Modbus address

-- Adjust these to match your battery map
local REG_START   = 0x1000
local REG_COUNT   = 6

local MQTT_HOST   = "mqtt.supercapsecure.com"   -- replace later with your broker
local MQTT_PORT   = 8883
local MQTT_TOPIC  = "LTRX/test/supercap"

local function shell_quote(s)
  s = tostring(s)
  s = s:gsub("'", "'\\''")
  return "'" .. s .. "'"
end

local function publish_mqtt(payload)
  local cmd = string.format(
    "mosquitto_pub -h %s -p %d -t %s -m %s",
    shell_quote(MQTT_HOST),
    MQTT_PORT,
    shell_quote(MQTT_TOPIC),
    shell_quote(payload)
  )
  print("MQTT cmd: " .. cmd)
  return os.execute(cmd)
end

local function regs_to_json(regs)
  local parts = {}
  for i, v in ipairs(regs) do
    parts[#parts + 1] = string.format("\"r%d\":%d", i - 1 + REG_START, v)
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function main()
  print("Creating Modbus TCP context to " .. MODBUS_HOST .. ":" .. MODBUS_PORT)
  local dev = mb.new_tcp_pi(MODBUS_HOST, MODBUS_PORT)
  assert(dev, "Failed to create Modbus TCP context")

  dev:set_slave(SLAVE_ID)

  local ok, err = pcall(function()
    dev:connect()
  end)

  if not ok then
    error("Couldn't connect to Modbus TCP bridge: " .. tostring(err))
  end

  print(string.format("Connected. Reading %d registers starting at 0x%X", REG_COUNT, REG_START))
  local regs = dev:read_registers(REG_START, REG_COUNT)
  if not regs then
    dev:close()
    error("Failed to read holding registers")
  end

  for i, v in ipairs(regs) do
    print(string.format("Reg 0x%X = %d", REG_START + i - 1, v))
  end

  local payload = regs_to_json(regs)
  print("Publishing MQTT payload: " .. payload)
  publish_mqtt(payload)

  dev:close()
  print("Done")
end

main()