local test_directory = (arg[0] or ''):match('^(.*[/\\])') or './'
local repository_directory = test_directory .. '../../'
package.path = repository_directory .. 'hub/?.lua;' .. package.path
local ir, client = require('ir'), require('client')
local passed = 0

local function test(name, run)
  local success, failure = pcall(run)
  assert(success, name .. ': ' .. tostring(failure))
  passed = passed + 1
  print('ok ' .. passed .. ' - ' .. name)
end

local function native_capture(words)
  local bytes = {}
  for _, word in ipairs(words) do
    bytes[#bytes + 1] = string.char(math.floor(word / 256), word % 256)
  end
  return table.concat(bytes)
end

local function rejects(run)
  assert(not pcall(run), 'expected rejection')
end

local synthetic_capture = native_capture({
  9, 3300, 126, 4900, 420, 840, 420, 1620, 420,
  32768, 0, 32768, 0, 32768, 0, 32768, 0, 32768, 0, 32768, 0, 3812,
})

test('first mark and actual spaces are reconstructed', function()
  local capture = ir.decode_capture(synthetic_capture)
  assert(capture.decoder_version == 2 and not capture.decoding_error)
  assert(table.concat(capture.timings_us, ',') == '3300,-1600,420,-420,420,-1200,420,-200000')
  assert(capture.duration_us == 207780)
  assert(capture.leading_space_us == nil)
  assert(capture.native_capture_hex == ir.hex(synthetic_capture))
  assert(capture.carrier_hz_estimate > 37000 and capture.carrier_hz_estimate < 39000)
end)

test('malformed captures fail or retain undecodable native data', function()
  for _, data in ipairs({'', 'x', string.rep('x', 4102)}) do
    rejects(function() ir.decode_capture(data) end)
  end
  for _, words in ipairs({
    {9, 3300, 126, 2000, 420, 20420},
    {9, 3300, 126, 4900, 32768, 20420},
    {9, 0, 0, 0},
  }) do
    local capture = ir.decode_capture(native_capture(words))
    assert(capture.decoding_error and not capture.timings_us and capture.native_capture_hex)
  end
end)

test('capture timeout is bounded and does not submit a transmission', function()
  local original_exchange = client.exchange
  local requests = {}
  client.exchange = function(_, request, hello, timeout)
    requests[#requests + 1] = request
    assert(timeout == 3)
    error('HAL transaction timed out')
  end
  local success, captured = pcall(client.capture, {}, {}, 3)
  client.exchange = original_exchange
  assert(success and captured == nil and #requests == 1)
  assert(requests[1]:find('"cmd":"ir.cap"', 1, true))
  assert(not requests[1]:find('ir.send', 1, true))
end)

test('capture decodes JSON prefix and binary separately', function()
  local original_exchange = client.exchange
  local prefix = '{"id":1,"code":200}'
  client.exchange = function() return prefix .. synthetic_capture end
  local json = {decode = function(raw)
    assert(raw:sub(1, #prefix) == prefix)
    return {id = 1, code = 200}, #prefix
  end}
  local success, capture = pcall(client.capture, {}, json, 2)
  client.exchange = original_exchange
  assert(success and capture.timings_us[1] == 3300)
end)

test('invalid capture deadlines never connect', function()
  for _, timeout in ipairs({0, 31, 1.5, '10'}) do
    rejects(function() client.capture({}, {}, timeout) end)
  end
end)

print('Passed ' .. passed .. ' capture tests; no device I/O.')
