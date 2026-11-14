local directory = (arg[0] or ''):match('^(.*[/\\])') or './'
package.path = directory .. '?.lua;' .. package.path
local client, ir = require('client'), require('ir')

local function service_stopped()
  for _, name in ipairs({'child.pid', 'lock/pid'}) do
    local f = io.open('/tmp/harmony-ir-service/' .. name, 'rb')
    if f then
      local pid = (f:read('*a') or ''):match('^%s*(%d+)%s*$'); f:close()
      if pid then
        f = io.open('/proc/' .. pid .. '/cmdline', 'rb')
        if f then
          local command = f:read('*a'):gsub('%z', ' '); f:close()
          assert(not command:find('/server.lua --listen ', 1, true)
            and not command:find('/service.sh supervise', 1, true),
            'stop /data/harmony-ir/service before this diagnostic')
        end
      end
    end
  end
end

local function compare(expected, actual)
  local ne, na = #expected, #actual

  if expected[ne] < 0 then ne = ne - 1 end
  if actual[na] < 0 then na = na - 1 end
  local mismatches, maximum = 0, 0
  for i = 1, math.min(ne, na) do
    local delta = math.abs(math.abs(expected[i]) - math.abs(actual[i]))
    maximum = math.max(maximum, delta)
    if (expected[i] > 0) ~= (actual[i] > 0)
      or delta > math.max(100, math.abs(expected[i]) * 0.2) then
      mismatches = mismatches + 1
    end
  end
  return {expected_intervals = ne, captured_intervals = na,
    mismatched_intervals = mismatches, max_error_us = maximum,
    timing_match = ne == na and mismatches == 0,
    absolute_tolerance_us = 100, relative_tolerance = 0.2,
    trailing_silence_ignored = true}
end

local function run()
  local mode = arg[1]
  assert((mode == '--dry-run' or mode == '--send-and-capture') and not arg[2],
    'usage: lua diagnose.lua --dry-run | --send-and-capture < REQUEST.json')
  if mode == '--send-and-capture' then service_stopped() end
  local text = io.read(32769)
  assert(text and #text <= 32768, 'expected request JSON on stdin, at most 32 KiB')
  local socket, json, socket_source, json_source = client.modules()
  assert(socket, socket_source); assert(json, json_source)
  assert(text:match('^%s*{'), 'expected JSON object')
  local request = json.decode(text)
  assert(type(request) == 'table', 'expected JSON object')
  for key in pairs(request) do
    assert(key == 'carrier_hz' or key == 'duty_percent' or key == 'timings_us',
      'unknown request field')
  end
  local payload, duration = ir.encode(request.carrier_hz, request.timings_us, request.duty_percent)
  local report = {experimental = true, transmission_attempted = false,
    appliance_reception_verified = false, capture_arming_acknowledged = false,
    requested_carrier_hz = request.carrier_hz, duty_percent = request.duty_percent or 33,
    requested_duration_us = duration, requested_intervals = #request.timings_us}
  if mode == '--dry-run' then
    report.dry_run = true
    print(json.encode(report))
    io.stderr:write('Dry run: no connections opened or IR transmitted.\n')
    return
  end
  io.stderr:write('EXPERIMENTAL: this WILL submit one waveform on all IR outputs.\n'
    .. 'Keep stock Harmony, other bridges and handheld remotes idle. Do not interrupt.\n'
    .. 'The Hub learning receiver may not see its own emitters; a missing capture is inconclusive.\n')
  local ok, captured = pcall(client.capture, socket, json, 8, function(fd)

    socket.sleep(0.25)
    local ready, _, err = socket.select({fd}, nil, 0)
    assert(ready, 'capture preflight failed: ' .. tostring(err))
    assert(#ready == 0, 'capture replied before transmission; no waveform submitted')
    report.transmission_attempted = true
    local sent, accepted = pcall(client.transmit, socket, json, payload, duration)
    if sent then
      report.accepted = true
      report.cancellation_acknowledged = true
    else
      report.transmission_error = tostring(accepted)
      report.transmission_uncertain = true
    end
  end)
  if not ok then report.capture_error = tostring(captured)
  elseif not captured then report.capture_timeout = true
  else
    report.capture = captured
    if captured.timings_us then
      report.comparison = compare(request.timings_us, captured.timings_us)
      local hz = captured.carrier_hz_estimate
      if hz then
        report.comparison.carrier_error_hz = hz - request.carrier_hz
        report.comparison.carrier_match = math.abs(hz - request.carrier_hz) <= request.carrier_hz * 0.05
        report.comparison.carrier_tolerance = 0.05
        report.comparison.duty_percent_estimate = captured.first_pulse_us * hz / 10000
      end
      report.signal_match = report.comparison.timing_match and report.comparison.carrier_match == true
    end
  end
  print(json.encode(report))
  if not report.cancellation_acknowledged or not report.signal_match then
    io.stderr:write('Diagnostic incomplete or mismatched; inspect JSON. No transmission was retried.\n')
    return false
  end
end

local ok, result = pcall(run)
if not ok then io.stderr:write(tostring(result) .. '\n'); os.exit(1) end
if result == false then os.exit(1) end
