mb = require("libmodbus")
print("using libmodbus runtime version: ", mb.version())
print("using lua-libmodbus compiled against libmodbus: ", mb.VERSION_STRING)

HOST="broker.hivemq.com"
PORT=1883
TOPIC="LTRX/test"

dev = mb.new_tcp_pi("localhost", 1502)
print(dev:get_byte_timeout())
print(dev:get_response_timeout())
print(dev)
dev:set_debug()
ok, err = dev:connect()
if not ok then error("Couldn't connect: " .. err) end
dev:set_slave(2)
t = dev:read_input_registers(4096,2)
dev:close()
for k,v in pairs(t) do
    print(k,v)
end
print(t[1])
print(t[2])
ts = os.time(os.date("!*t"))
f = io.open("/tmp/sysinfo/imei", "r")
imei = f:read("*a")
f:close()
payload = '{"ts":' .. ts .. ', "imei":' .. imei .. ', "modbus": {"reg4096":' .. t[1] .. ',"reg4097":' .. t[2] ..'}}'
--print(payload)
cmd = string.format("mosquitto_pub -h %s -p %d -i %s -t %s -m '%s'", HOST, PORT, imei, TOPIC, payload)
print(cmd)
os.execute(cmd)


This is an example of what I am receiving on the MQTT broker:
{"ts":1775811518, "imei":353634110190666, "modbus": {"reg1":17248,"reg2":30182}}
{"ts":1775811646, "imei":353634110190666, "modbus": {"reg1":17249,"reg2":18120}}
