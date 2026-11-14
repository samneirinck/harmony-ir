local ir = require('ir')
local M = {}

function M.load_module(name, symbol, predicate)
  local ok, value = pcall(require, name)
  if ok and predicate(value) then return value, 'require(' .. name .. ')' end
  local loader, err = package.loadlib('/opt/lib/luaworks.so', symbol)
  if not loader then return nil, tostring(err) end
  ok, value = pcall(loader, name)
  if ok and predicate(value) then return value, '/opt/lib/luaworks.so:' .. symbol end
  return nil, tostring(value)
end

function M.modules()
  local socket, socket_source = M.load_module('socket.core', 'luaopen_socket_core',
    function(v) return type(v) == 'table' and type(v.tcp) == 'function'
      and type(v.gettime) == 'function' and type(v.select) == 'function' end)
  local json, json_source = M.load_module('json', 'luaopen_json',
    function(v) return type(v) == 'table' and type(v.decode) == 'function' end)
  return socket, json, socket_source, json_source
end

function M.exchange(socket, request, hello, timeout_seconds, on_submitted)
  local fd, err = socket.tcp()
  assert(fd, err)
  local ok, result = pcall(function()
    local deadline = socket.gettime() + (timeout_seconds or 2)
    local function timeout()
      local remaining = deadline - socket.gettime()
      assert(remaining > 0, 'HAL transaction timed out')

      assert(fd:settimeout(remaining, 't'))
    end
    timeout()
    assert(fd:connect('127.0.0.1', 16716))
    local data = string.char(hello or 6) .. ir.frame(request)
    local pos = 1
    while pos <= #data do
      timeout()
      local sent, why = fd:send(data, pos)
      assert(sent, 'HAL send failed: ' .. tostring(why) .. '; NOT retried')
      assert(sent >= pos, 'HAL send made no progress')
      pos = sent + 1
    end

    if on_submitted then on_submitted(fd) end
    local response = ''
    while #response < 32768 do
      timeout()
      local chunk, why, partial = fd:receive(64)
      response = response .. (chunk or partial or '')
      assert(#response <= 32768, 'HAL response too large')
      local reply, parse_error = ir.reply(response)
      if reply then
        assert(reply.request_id == 0, 'unexpected LTCP reply ID')
        return reply.payload
      end
      assert(parse_error == 'incomplete', tostring(parse_error)
        .. '; reply hex (first 128 bytes): ' .. ir.hex(response:sub(1, 128)))
      if not chunk then
        assert(why == 'timeout', 'HAL receive failed: ' .. tostring(why)
          .. '; reply hex (first 128 bytes): ' .. ir.hex(response:sub(1, 128)))
        local remaining = deadline - socket.gettime()
        assert(remaining > 0, 'HAL transaction timed out')
        local ready, _, err = socket.select({fd}, nil, remaining)
        if not ready or #ready == 0 then
          assert(err ~= 'timeout' and socket.gettime() < deadline, 'HAL transaction timed out')
          error('HAL receive wait failed: ' .. tostring(err))
        end
      end
    end
    error('HAL response too large')
  end)
  pcall(function() fd:close() end)
  if not ok then error(result, 0) end
  return result
end

function M.check_reply(json, raw, expected_id)
  local response = json.decode(raw)
  assert(type(response) == 'table' and response.id == expected_id,
    'unrecognized HAL response/request ID')

  assert(response.code == 200, 'HAL rejected request: ' .. raw)
  return response
end

function M.capture(socket, json, timeout_seconds, on_submitted)
  timeout_seconds = timeout_seconds or 10
  assert(type(timeout_seconds) == 'number' and timeout_seconds == math.floor(timeout_seconds)
    and timeout_seconds >= 1 and timeout_seconds <= 30, 'capture timeout must be 1..30 seconds')
  local request = '{"id":1,"cmd":"ir.cap","data":{},"timeout":'
    .. (timeout_seconds * 1000) .. '}'
  local ok, raw = pcall(M.exchange, socket, request, nil, timeout_seconds, on_submitted)
  if not ok then
    if tostring(raw):find('HAL transaction timed out', 1, true) then return nil end
    error(raw, 0)
  end

  local response, consumed = json.decode(raw)
  assert(type(response) == 'table' and response.id == 1, 'unexpected capture reply ID')
  assert(response.code == 200, 'HAL rejected capture: ' .. tostring(response.code))
  assert(type(consumed) == 'number' and consumed == math.floor(consumed)
    and consumed > 0 and consumed <= #raw, 'JSON decoder must report consumed prefix length for capture')
  return ir.decode_capture(raw:sub(consumed + 1))
end

function M.transmit(socket, json, payload, duration_us, hello)

  assert(type(socket.sleep) == 'function', 'socket.sleep unavailable')
  local ok, result = pcall(function()
    local raw = M.exchange(socket, ir.request(payload, true, 1), hello)
    M.check_reply(json, raw, 1)

    socket.sleep(duration_us / 1000000 + 0.05)
    return raw
  end)

  local cancel_ok, cancel_result = pcall(function()
    local raw = M.exchange(socket, ir.request(nil, false, 2), hello)
    M.check_reply(json, raw, 2)
    return raw
  end)
  if not ok then
    error(tostring(result) .. (cancel_ok and '; cancellation acknowledged'
      or '; cancellation UNCONFIRMED: ' .. tostring(cancel_result)), 0)
  end
  assert(cancel_ok, 'transmission accepted, cancellation UNCONFIRMED: ' .. tostring(cancel_result))
  return result, cancel_result
end

return M
