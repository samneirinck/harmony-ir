local M = {MAX_BODY = 32768, MAX_HEADERS = 8192}

function M.read(fd, socket)
  local deadline, used = socket.gettime() + 3, 0
  local function timeout()
    local left = deadline - socket.gettime()
    assert(left > 0, 'request timeout')
    assert(fd:settimeout(left, 't'))
  end
  local function receive(n)
    local parts, received = {}, 0
    while received < n do
      timeout()
      local data, why, partial = fd:receive(n - received)
      local chunk = data or partial or ''
      if #chunk > 0 then
        parts[#parts + 1] = chunk
        received = received + #chunk
      end
      if received == n then return table.concat(parts) end
      assert(why == 'timeout', 'request read failed: ' .. tostring(why))

      local remaining = deadline - socket.gettime()
      assert(remaining > 0, 'request timeout')
      local ready, _, err = socket.select({fd}, nil, remaining)
      assert(ready and #ready > 0, 'request read wait failed: ' .. tostring(err))
    end
  end
  local function line()

    local chars = {}
    while true do
      local c = receive(1)
      used = used + 1
      assert(used <= M.MAX_HEADERS, 'headers too large')
      if c == '\n' then
        assert(chars[#chars] == '\r', 'expected CRLF')
        chars[#chars] = nil
        return table.concat(chars)
      end
      chars[#chars + 1] = c
    end
  end
  local method, path, version = line():match('^(%u+) ([^ ]+) (HTTP/1%.[01])$')
  assert(method and #path <= 128, 'invalid request line')
  local headers, count = {}, 0
  while true do
    local value = line()
    if value == '' then break end
    count = count + 1
    assert(count <= 32, 'too many headers')
    local name, content = value:match('^([%w%-]+):%s*(.-)%s*$')
    assert(name, 'invalid header')
    name = name:lower()
    assert(not headers[name], 'duplicate header')
    headers[name] = content
  end
  assert(not headers['transfer-encoding'] and not headers.expect, 'unsupported transfer mode')
  local length = headers['content-length'] or '0'
  assert(length:match('^%d+$') and #length <= 5, 'invalid content length')
  length = tonumber(length)
  assert(length <= M.MAX_BODY, 'body too large')
  local body = ''
  if length > 0 then
    body = receive(length)
  end
  return {method = method, path = path, headers = headers, body = body, version = version}
end

function M.write(fd, socket, status, body)
  local reasons = {[200] = 'OK', [400] = 'Bad Request', [404] = 'Not Found',
    [405] = 'Method Not Allowed', [415] = 'Unsupported Media Type',
    [502] = 'Bad Gateway', [504] = 'Gateway Timeout'}
  local data = 'HTTP/1.1 ' .. status .. ' ' .. assert(reasons[status]) .. '\r\n'
    .. 'Content-Type: application/json\r\nContent-Length: ' .. #body .. '\r\n'
    .. 'Connection: close\r\nCache-Control: no-store\r\n'
    .. 'X-Content-Type-Options: nosniff\r\n\r\n' .. body
  local pos, deadline = 1, socket.gettime() + 3
  while pos <= #data do
    local remaining = deadline - socket.gettime()
    assert(remaining > 0, 'response timeout')
    assert(fd:settimeout(remaining, 't'))
    local sent, err = fd:send(data, pos)
    assert(sent and sent >= pos, 'response send failed: ' .. tostring(err))
    pos = sent + 1
  end
end

return M
