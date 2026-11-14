local ir = require('ir')
local M = {}

function M.handle(request, socket, json, client)
  local function result(status, data) return status, json.encode(data) end
  if request.path == '/health' then
    if request.method ~= 'GET' then return result(405, {error = 'use GET'}) end
    if #request.body > 0 then return result(400, {error = 'unexpected body'}) end
    return result(200, {api_version = 1, transmitter = 'harmony-hal',
      authenticated = false, max_duration_us = 1000000, max_timings = 2048,
      min_carrier_hz = 10000, max_carrier_hz = 60000, ports = 7,
      capture_supported = true, capture_decoder_version = 2,
      max_capture_timeout_s = 30})
  end
  if request.path ~= '/transmit' and request.path ~= '/capture' then
    return result(404, {error = 'not found'})
  end
  if request.method ~= 'POST' then return result(405, {error = 'use POST'}) end
  local content_type = (request.headers['content-type'] or ''):lower()
  if not content_type:match('^application/json%s*;') and content_type ~= 'application/json' then
    return result(415, {error = 'Content-Type must be application/json'})
  end
  if request.path == '/capture' then
    local valid, timeout = pcall(function()
      assert(request.body:match('^%s*{'), 'expected JSON object')
      local input = json.decode(request.body)
      assert(type(input) == 'table', 'expected JSON object')
      for key in pairs(input) do assert(key == 'timeout_s', 'unknown capture field') end
      local seconds = input.timeout_s
      if seconds == nil then seconds = 10 end
      assert(type(seconds) == 'number' and seconds == math.floor(seconds)
        and seconds >= 1 and seconds <= 30, 'timeout_s must be an integer in 1..30')
      return seconds
    end)
    if not valid then return result(400, {error = tostring(timeout)}) end
    local ok, captured = pcall(client.capture, socket, json, timeout)
    if not ok then return result(502, {error = tostring(captured)}) end
    if not captured then
      return result(504, {error = 'capture timed out; HAL connection closed',
        capture_timeout = true, timeout_s = timeout})
    end
    return result(200, captured)
  end
  local ok, payload, duration = pcall(function()
    local input = json.decode(request.body)
    assert(type(input) == 'table', 'expected JSON object')
    for key in pairs(input) do
      assert(key == 'carrier_hz' or key == 'timings_us' or key == 'duty_percent',
        'unknown request field')
    end
    if input.duty_percent ~= nil then
      assert(type(input.duty_percent) == 'number', 'duty_percent must be numeric')
    end
    assert(type(input.timings_us) == 'table', 'expected timings_us array')
    local n = #input.timings_us
    assert(n > 0 and n <= 2048, 'expected 1..2048 timings')
    local count = 0
    for key in pairs(input.timings_us) do
      assert(type(key) == 'number' and key == math.floor(key) and key >= 1 and key <= n,
        'expected contiguous timings array')
      count = count + 1
    end
    assert(count == n, 'expected contiguous timings array')
    return ir.encode(input.carrier_hz, input.timings_us, input.duty_percent)
  end)
  if not ok then return result(400, {error = tostring(payload)}) end
  local accepted, err = pcall(client.transmit, socket, json, payload, duration)
  if not accepted then
    return result(502, {error = tostring(err), transmission_uncertain = true,
      retry_safe = false})
  end
  return result(200, {accepted = true, cancellation_acknowledged = true,
    duration_us = duration, appliance_reception_verified = false})
end

return M
