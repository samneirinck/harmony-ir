local M = {}
local char, byte, floor = string.char, string.byte, math.floor

local function validate_integer(n, lo, hi, name)
  assert(type(n) == 'number' and n == floor(n) and n >= lo and n <= hi,
    'invalid ' .. name)
  return n
end
local function encode_u16_be(n) return char(floor(n / 256), n % 256) end
local function encode_u32_be(n) return encode_u16_be(floor(n / 65536)) .. encode_u16_be(n % 65536) end

function M.encode(frequency, timings, duty)
  validate_integer(frequency, 10000, 60000, 'carrier frequency (10000..60000 Hz)')
  if duty == nil then duty = 33 end
  validate_integer(duty, 1, 50, 'duty cycle (1..50)')
  assert(type(timings) == 'table' and #timings > 0 and #timings <= 2048,
    'expected 1..2048 signed microsecond timings')
  local count = 0
  for key in pairs(timings) do
    validate_integer(key, 1, #timings, 'timing index')
    count = count + 1
  end
  assert(count == #timings, 'expected contiguous timings array')
  validate_integer(timings[1], 1, 1000000, 'first mark')
  local words, duration = {}, 0
  for _, timing in ipairs(timings) do
    validate_integer(timing, -1000000, 1000000, 'timing')
    assert(timing ~= 0, 'zero timing')
    duration = duration + math.abs(timing)
    assert(duration <= 1000000, 'signal exceeds one second')
    local flag, remaining = timing > 0 and 32768 or 0, math.abs(timing)
    while remaining > 0 do
      local n = math.min(remaining, 32767)
      words[#words + 1] = encode_u16_be(flag + n)
      remaining = remaining - n
    end
  end

  local header = char(1) .. encode_u32_be(floor(1000000000 / frequency + 0.5))
    .. char(duty) .. encode_u16_be(0) .. char(0, 0) .. encode_u16_be(16) .. encode_u16_be(0) .. encode_u16_be(0)
  return header .. encode_u16_be(#words) .. table.concat(words), duration
end

function M.decode_capture(raw_capture)
  assert(type(raw_capture) == 'string' and #raw_capture >= 8 and #raw_capture <= 4100 and #raw_capture % 2 == 0,
    'invalid native capture length')
  local function read_word(offset) return byte(raw_capture, offset) * 256 + byte(raw_capture, offset + 1) end
  local first_pulse_us, first_mark_us, pulse_count = read_word(1), read_word(3), read_word(5)
  local result = {experimental = true, decoder_version = 2, native_capture_hex = M.hex(raw_capture),
    first_pulse_us = first_pulse_us, first_mark_us = first_mark_us, first_mark_pulses = pulse_count}
  if pulse_count > 1 and first_mark_us > first_pulse_us then
    result.carrier_hz_estimate = floor(1000000 * (pulse_count - 1) / (first_mark_us - first_pulse_us) + 0.5)
  end
  local ok, timings_or_error, duration_us = pcall(function()
    assert(first_mark_us > 0, 'capture contains no first mark')
    local native_intervals, is_mark = {}, false
    for offset = 7, #raw_capture, 2 do
      local interval_us = read_word(offset)
      assert(interval_us <= 32768, 'unsupported native capture duration')

      assert(not (is_mark and interval_us == 32768), 'long capture marks are not yet supported')
      if interval_us > 0 then
        local signed_interval = is_mark and interval_us or -interval_us
        if #native_intervals > 0 and (native_intervals[#native_intervals] > 0) == is_mark then
          native_intervals[#native_intervals] = native_intervals[#native_intervals] + signed_interval
        else
          native_intervals[#native_intervals + 1] = signed_interval
        end
      end

      is_mark = not is_mark
    end
    assert(#native_intervals > 0 and native_intervals[1] < 0 and native_intervals[#native_intervals] < 0,
      'capture has incomplete mark-to-mark periods')
    local timings, previous_mark_us = {first_mark_us}, first_mark_us
    local function append_timing(interval)
      if interval == 0 then return end
      if (timings[#timings] > 0) == (interval > 0) then
        timings[#timings] = timings[#timings] + interval
      else
        timings[#timings + 1] = interval
      end
    end
    for _, interval in ipairs(native_intervals) do
      if interval < 0 then
        local space_us = -interval - previous_mark_us
        assert(space_us >= 0, 'capture period is shorter than its mark')
        append_timing(-space_us)
      else
        append_timing(interval)
        previous_mark_us = interval
      end
    end
    local total_duration_us = 0
    for _, interval in ipairs(timings) do total_duration_us = total_duration_us + math.abs(interval) end
    return timings, total_duration_us
  end)
  if ok then
    result.timings_us, result.duration_us = timings_or_error, duration_us
  else
    result.decoding_error = tostring(timings_or_error)
  end
  return result
end

function M.request(payload, enabled, id)
  validate_integer(id or 1, 1, 65535, 'request ID')
  return string.format('{"id":%d,"cmd":"ir.send","data":{"enable":%s,"keyLatency":0,"ports":7},"timeout":2000}',
    id or 1, enabled and 'true' or 'false') .. (payload or '')
end

function M.frame(payload)
  assert(type(payload) == 'string' and #payload > 0 and #payload <= 16383,
    'LTCP payload must contain 1..16383 bytes')
  local length = #payload
  local secondary = char(1)
    .. (length > 63 and char(192 + floor(length / 256), length % 256)
      or char(128 + length))
  local data = char(255, 8, 0, 1, 1, 2) .. secondary .. payload

  return data .. string.rep(char(0), (64 - #data % 64) % 64)
end

function M.hex(data)
  return (data:gsub('.', function(c) return string.format('%02x', byte(c)) end))
end

function M.reply(reply_bytes)
  local cursor = 1
  local function read_bytes(byte_count)
    if cursor + byte_count - 1 > #reply_bytes then error('incomplete', 0) end
    local value = reply_bytes:sub(cursor, cursor + byte_count - 1)
    cursor = cursor + byte_count
    return value
  end
  local function read_number(byte_count)
    local value = 0
    for character in read_bytes(byte_count):gmatch('.') do value = value * 256 + byte(character) end
    return value
  end
  local function parse()
    local header = read_bytes(4)
    assert(byte(header, 1) == 255 and byte(header, 2) == 8, 'unexpected LTCP service/operation')
    local request_id = byte(header, 3)
    assert(request_id >= 128 and request_id < 254, 'not a command reply')
    local parameter_count = byte(header, 4)
    assert(parameter_count < 64, 'unsupported LTCP flags')
    assert(parameter_count >= 1 and parameter_count <= 3, 'invalid parameter count')
    local parameters = {}
    for i = 1, parameter_count do
      local tag = read_number(1)
      assert(tag > 0 and tag < 64 and tag <= 4, 'unsupported LTCP parameter')
      parameters[i] = read_number(tag)
    end
    assert(parameters[1] >= 1 and parameters[1] <= 64, 'invalid packet count')
    local payload_chunks, payload_size = {}, 0
    for _ = 1, parameters[1] - 1 do

      if byte(reply_bytes, cursor) == 0 then
        local boundary = floor((cursor - 1) / 64 + 1) * 64
        if #reply_bytes < boundary then error('incomplete', 0) end
        if reply_bytes:sub(cursor, boundary) == string.rep(char(0), boundary - cursor + 1) then
          cursor = boundary + 1
        end
      end
      local sequence_id, payload_length = read_number(1), read_number(1)

      assert(sequence_id % 128 < 64, string.format('invalid secondary sequence: %02x', sequence_id))
      payload_length = payload_length % 128
      if payload_length >= 64 then payload_length = (payload_length - 64) * 256 + read_number(1) end
      payload_size = payload_size + payload_length
      assert(payload_size <= 32768, 'response too large')
      payload_chunks[#payload_chunks + 1] = read_bytes(payload_length)
    end
    return {request_id = request_id % 128, payload = table.concat(payload_chunks)}
  end
  local ok, result = pcall(parse)
  if ok then return result end
  return nil, tostring(result)
end

return M
