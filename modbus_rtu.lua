mb = require("libmodbus")

print("Using libmodbus runtime version:", mb.version())
print("Using lua-libmodbus compiled version:", mb.VERSION_STRING)

-- MQTT Config
HOST  = "192.168.1.1"
PORT  = 1883
TOPIC = "LTRX/test"

-- SERIAL PORT CONFIG (CHANGE THIS!)
SERIAL_PORT = "/dev/ttyS3"   -- or /dev/ttyS1, /dev/ttyXRUSB0 etc
BAUDRATE    = 9600
PARITY      = "N"              -- "N", "E", "O"
DATA_BITS   = 8
STOP_BITS   = 1
SLAVE_ID    = 2

-- Create RTU device
dev = mb.new_rtu(SERIAL_PORT, BAUDRATE, PARITY, DATA_BITS, STOP_BITS)

-- Optional debug
dev:set_debug()

-- IMPORTANT: Set serial mode (RS485 typically)
-- dev:rtu_set_serial_mode(mb.RTU_RS485)   -- uncomment if supported

-- Set slave ID
dev:set_slave(SLAVE_ID)

-- Connect
ok, err = dev:connect()
if not ok then
    error("RTU connect failed: " .. err)
end

print("Connected to Modbus RTU device")

-- Read registers
local cregs, err = dev:read_bits(4096, 2)
if not cregs then
    error("Read failed: " .. err)
end

-- Read registers
local iregs, err = dev:read_input_bits(4096, 2)
if not iregs then
    error("Read failed: " .. err)
end

-- Read registers
local hregs, err = dev:read_registers(4096, 2)
if not hregs then
    error("Read failed: " .. err)
end

-- Read registers
local regs, err = dev:read_input_registers(4096, 2)
if not regs then
    error("Read failed: " .. err)
end

-- Close device
dev:close()

-- Print values
for k, v in pairs(cregs) do
    print("Register", k, "=", v)
end

-- Print values
for k, v in pairs(iregs) do
    print("Register", k, "=", v)
end

-- Print values
for k, v in pairs(hregs) do
    print("Register", k, "=", v)
end

-- Print values
for k, v in pairs(regs) do
    print("Register", k, "=", v)
end

-- Get timestamp (UTC)
ts = os.time(os.date("!*t"))

-- Read IMEI
local f = io.open("/tmp/sysinfo/imei", "r")
local imei = f:read("*a")
f:close()

-- Clean IMEI (remove newline if any)
imei = imei:gsub("%s+", "")

-- Create JSON payload
payload = string.format(
    '{"ts":%d,"imei":"%s","modbus":{"reg1":%d,"reg2":%d}}',
    ts, imei, regs[1], regs[2]
)

print("Payload:", payload)

-- Publish via MQTT
cmd = string.format(
    "mosquitto_pub -h %s -p %d -i %s -t %s -m '%s'",
    HOST, PORT, imei, TOPIC, payload
)

print("Executing:", cmd)
os.execute(cmd)