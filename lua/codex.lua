local librarian_ok, librarian = pcall(require, "librarian.init")
local ToolView = require("maki.tool_view")
local truncate = require("maki.truncate")
local CODEX_BASE = "https://chatgpt.com/backend-api/codex"
local CODEX_RESET_CREDITS_URL = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"

local function credentials()
  local state_dir = maki.env.state_dir()
  if not state_dir then return nil, "could not determine Maki state directory" end
  local text, err = maki.fs.read(maki.fs.joinpath(state_dir, "auth", "openai.json"))
  if not text then return nil, "could not read OpenAI authentication: " .. err end
  local auth, decode_err = maki.json.decode(text)
  if not auth or not auth.access or not auth.account_id then
    return nil, "OpenAI Codex authentication is unavailable: " .. (decode_err or "missing access token or account id")
  end
  return auth
end

local function describe_http_error(status, body)
  local decoded = maki.json.decode(body or "")
  local err = decoded and decoded.error
  if err and err.type == "usage_limit_reached" then
    local parts = { "Codex usage limit reached" }
    if err.resets_in_seconds then
      parts[#parts + 1] = "resets in " .. maki.ui.humantime(err.resets_in_seconds)
    end
    if err.resets_at then
      parts[#parts + 1] = "at " .. os.date("%Y-%m-%d %H:%M:%S %Z", err.resets_at)
    end
    parts[#parts + 1] = "check /usage or redeem a reset with /codex-reset"
    return table.concat(parts, "; ")
  end
  if err and err.message then
    local kind = err.type and (err.type .. ": ") or ""
    return "Codex request failed (HTTP " .. status .. "): " .. kind .. err.message
  end
  return "Codex request failed (HTTP " .. status .. ")"
end

local function request(path, body, timeout)
  local auth, auth_err = credentials()
  if not auth then return nil, auth_err end
  local encoded, encode_err = maki.json.encode(body)
  if not encoded then return nil, encode_err end
  local response, err = maki.net.request(CODEX_BASE .. path, {
    method = "POST",
    timeout = timeout or 120,
    headers = {
      ["Authorization"] = "Bearer " .. auth.access,
      ["chatgpt-account-id"] = auth.account_id,
      ["content-type"] = "application/json",
      ["accept"] = "text/event-stream",
      ["originator"] = "codex_cli_rs",
      ["User-Agent"] = "codex_cli_rs/0.0.0 (maki)",
    },
    body = encoded,
  })
  if not response then return nil, err end
  if response.status < 200 or response.status >= 300 then
    return nil, describe_http_error(response.status, response.body)
  end
  return response.body
end

local function show_modal(title, lines, footer)
  local buffer = maki.ui.buf()
  for _, line in ipairs(lines) do buffer:line(line) end
  local window = maki.ui.open_win(buffer, {
    title = title,
    width = "70%",
    height = math.min(#lines + 2, 20),
    footer = footer or { { "Any key", "close" } },
  })
  local key
  while true do
    local event = window:recv()
    if not event or event.type == "close" then break end
    if event.type == "key" then
      key = event.key
      break
    end
  end
  window:close()
  return key
end

local function reset_credits()
  local auth, auth_err = credentials()
  if not auth then return nil, auth_err end
  local response, err = maki.net.request(CODEX_RESET_CREDITS_URL, {
    headers = {
      ["Authorization"] = "Bearer " .. auth.access,
      ["chatgpt-account-id"] = auth.account_id,
      ["accept"] = "application/json",
      ["originator"] = "codex_cli_rs",
      ["User-Agent"] = "codex_cli_rs/0.0.0 (maki)",
    },
  })
  if not response then return nil, err end
  if response.status < 200 or response.status >= 300 then
    return nil, describe_http_error(response.status, response.body)
  end
  local credits, decode_err = maki.json.decode(response.body)
  if not credits then return nil, "could not parse Codex reset credits response: " .. decode_err end
  return credits
end

local function redemption_id()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return template:gsub("[xy]", function(character)
    local value = math.random(0, 15)
    if character == "y" then value = value % 4 + 8 end
    return string.format("%x", value)
  end)
end

local function consume_reset(credit_id)
  local auth, auth_err = credentials()
  if not auth then return nil, auth_err end
  local body, encode_err = maki.json.encode({ credit_id = credit_id, redeem_request_id = redemption_id() })
  if not body then return nil, encode_err end
  local response, err = maki.net.request(CODEX_RESET_CREDITS_URL .. "/consume", {
    method = "POST",
    headers = {
      ["Authorization"] = "Bearer " .. auth.access,
      ["chatgpt-account-id"] = auth.account_id,
      ["content-type"] = "application/json",
      ["accept"] = "application/json",
      ["originator"] = "codex_cli_rs",
      ["User-Agent"] = "codex_cli_rs/0.0.0 (maki)",
    },
    body = body,
  })
  if not response then return nil, err end
  if response.status < 200 or response.status >= 300 then
    return nil, describe_http_error(response.status, response.body)
  end
  local outcome, decode_err = maki.json.decode(response.body)
  if not outcome then return nil, "could not parse Codex reset response: " .. decode_err end
  return outcome
end

local function sse_events(body)
  local events, errors = {}, {}
  for frame in (body .. "\n\n"):gmatch("(.-)\r?\n\r?\n") do
    local data = {}
    local event_type
    for line in frame:gmatch("[^\r\n]+") do
      if line:sub(1, 6) == "event:" then event_type = line:sub(7):match("^%s*(.-)%s*$") end
      if line:sub(1, 5) == "data:" then data[#data + 1] = line:sub(6):match("^%s?(.*)$") end
    end
    local raw = table.concat(data, "\n")
    if raw ~= "" and raw ~= "[DONE]" then
      local value, decode_err = maki.json.decode(raw)
      if value then
        events[#events + 1] = { type = event_type, value = value }
      else
        errors[#errors + 1] = "could not decode " .. (event_type or "unnamed") .. " SSE event: " .. tostring(decode_err)
      end
    end
  end
  return events, errors
end

local function web_view_opts(ctx)
  local lines = ctx:tool_output_lines()
  return { max_lines = (lines and lines.web) or 3, keep = "head" }
end

local function codex_search_header(input)
  local queries = type(input) == "table" and input.queries or nil
  if type(queries) ~= "table" or #queries == 0 then return "web search" end
  if #queries == 1 and type(queries[1]) == "string" and queries[1] ~= "" then return queries[1] end
  return tostring(#queries) .. " web searches"
end

local function compact(value, maximum)
  if type(value) ~= "string" then return nil end
  value = value:gsub("%s+", " "):match("^%s*(.-)%s*$")
  if #value <= maximum then return value end
  return value:sub(1, maximum - 1) .. "…"
end

local function event_error(event)
  local value = event.value
  local response = type(value) == "table" and value.response or nil
  local err = type(value) == "table" and (value.error or (type(response) == "table" and response.error)) or nil
  if type(err) == "table" then
    local kind = type(err.type) == "string" and (err.type .. ": ") or ""
    return kind .. tostring(err.message or err.code or event.type)
  end
  if type(err) == "string" then return err end
  if event.type == "response.incomplete" then
    local details = type(response) == "table" and response.incomplete_details or nil
    if type(details) == "table" then return "response incomplete: " .. tostring(details.reason or "unknown reason") end
    return "response incomplete"
  end
  if event.type == "response.failed" or event.type == "error" then return event.type end
end

local function utf8_position(text, character_index)
  if character_index <= 0 then return 1 end
  local byte_index, characters = 1, 0
  while byte_index <= #text and characters < character_index do
    local byte = text:byte(byte_index)
    if byte < 0x80 then
      byte_index = byte_index + 1
    elseif byte < 0xE0 then
      byte_index = byte_index + 2
    elseif byte < 0xF0 then
      byte_index = byte_index + 3
    else
      byte_index = byte_index + 4
    end
    characters = characters + 1
  end
  return byte_index
end

local function citation_number(annotation, sources, source_numbers)
  if type(annotation) ~= "table" or annotation.type ~= "url_citation" or type(annotation.url) ~= "string" then return nil end
  local number = source_numbers[annotation.url]
  if number then return number end
  number = #sources + 1
  source_numbers[annotation.url] = number
  sources[number] = { title = compact(annotation.title, 240) or annotation.url, url = annotation.url }
  return number
end

local function annotate_citations(text, annotations, sources, source_numbers)
  local inserts = {}
  for _, annotation in ipairs(annotations or {}) do
    local number = citation_number(annotation, sources, source_numbers)
    local ending = type(annotation) == "table" and tonumber(annotation.end_index) or nil
    if number and ending and ending >= 0 then
      inserts[#inserts + 1] = { position = utf8_position(text, ending), marker = " [" .. number .. "]" }
    end
  end
  table.sort(inserts, function(left, right) return left.position > right.position end)
  local index = 1
  while index <= #inserts do
    local position, markers = inserts[index].position, {}
    while index <= #inserts and inserts[index].position == position do
      markers[#markers + 1] = inserts[index].marker
      index = index + 1
    end
    text = text:sub(1, position - 1) .. table.concat(markers) .. text:sub(position)
  end
  return text
end

local function collect_search_response(body)
  local events, parse_errors = sse_events(body)
  local text_parts, sources, source_numbers, errors = {}, {}, {}, {}
  for _, parse_error in ipairs(parse_errors) do errors[#errors + 1] = "protocol: " .. parse_error end
  for _, event in ipairs(events) do
    local message = event_error(event)
    if message then errors[#errors + 1] = "backend: " .. message end
    if event.type == "response.output_item.done" and type(event.value.item) == "table" then
      local item = event.value.item
      if item.type == "message" then
        for _, part in ipairs(item.content or {}) do
          if part.type == "output_text" and type(part.text) == "string" then
            text_parts[#text_parts + 1] = annotate_citations(part.text, part.annotations, sources, source_numbers)
          end
        end
      end
    end
  end
  if #text_parts == 0 then
    local deltas = {}
    for _, event in ipairs(events) do
      if event.type == "response.output_text.delta" and type(event.value.delta) == "string" then deltas[#deltas + 1] = event.value.delta end
    end
    if #deltas > 0 then text_parts[1] = table.concat(deltas) end
  end
  if #text_parts == 0 then
    return nil, (#errors > 0 and table.concat(errors, "; ") or "Codex returned no search answer")
  end
  return { text = table.concat(text_parts, "\n\n"), sources = sources, errors = errors, events = events }
end

local function wants_evidence(input)
  for _, selector in ipairs(input.include or {}) do
    if selector == "web_search_call.results" or selector == "web_search_call.action.sources" then return true end
  end
  return false
end

local function collect_evidence(events)
  local evidence, seen, visited = {}, {}, {}
  local function add(source)
    if type(source) ~= "table" then return end
    local url = source.url or source.link
    if type(url) ~= "string" or url == "" or seen[url] then return end
    seen[url] = true
    evidence[#evidence + 1] = {
      title = compact(source.title or source.name, 240) or url,
      url = url,
      snippet = compact(source.snippet or source.text or source.content, 360),
    }
  end
  local function inspect(value)
    if type(value) ~= "table" or visited[value] then return end
    visited[value] = true
    if value.type == "web_search_call" then
      for _, source in ipairs(value.results or {}) do add(source) end
      for _, source in ipairs((value.action or {}).sources or {}) do add(source) end
      for _, source in ipairs(value.sources or {}) do add(source) end
    end
    for _, child in pairs(value) do inspect(child) end
  end
  for _, event in ipairs(events) do inspect(event.value) end
  return evidence
end

local function append_sources(lines, heading, sources, include_snippets)
  if #sources == 0 then return end
  lines[#lines + 1] = ""
  lines[#lines + 1] = heading
  for index, source in ipairs(sources) do
    lines[#lines + 1] = tostring(index) .. ". " .. source.title
    lines[#lines + 1] = "   " .. source.url
    if include_snippets and source.snippet then lines[#lines + 1] = "   " .. source.snippet end
  end
end

local function search_result_text(result, evidence)
  local lines = { result.text }
  append_sources(lines, "Sources:", result.sources)
  append_sources(lines, "Evidence:", evidence, true)
  if #result.errors > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Warnings:"
    for _, message in ipairs(result.errors) do lines[#lines + 1] = "- " .. message end
  end
  return table.concat(lines, "\n")
end

local function query_label(query)
  return compact(query, 240) or "web search"
end

local function default_model()
  local auth, auth_err = credentials()
  if not auth then return nil, auth_err end
  local response, err = maki.net.request(CODEX_BASE .. "/models?client_version=0.153.4", {
    headers = {
      ["Authorization"] = "Bearer " .. auth.access,
      ["chatgpt-account-id"] = auth.account_id,
      ["accept"] = "application/json",
      ["originator"] = "codex_cli_rs",
      ["User-Agent"] = "codex_cli_rs/0.0.0 (maki)",
    },
  })
  if not response then return nil, "could not fetch Codex models: " .. tostring(err) end
  if response.status < 200 or response.status >= 300 then
    return nil, describe_http_error(response.status, response.body)
  end
  local catalog, decode_err = maki.json.decode(response.body)
  if type(catalog) ~= "table" or type(catalog.models) ~= "table" then
    return nil, "invalid Codex models response: " .. tostring(decode_err or "missing models")
  end
  local selected
  for _, model in ipairs(catalog.models) do
    if type(model) == "table" and model.visibility == "list" and type(model.slug) == "string" and model.slug ~= "" then
      if not selected or (tonumber(model.priority) or math.huge) < (tonumber(selected.priority) or math.huge) then
        selected = model
      end
    end
  end
  if not selected then return nil, "Codex models response listed no available models" end
  return selected.slug
end

local function iso_to_epoch(value)
  local year, month, day, hour, min, sec = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):?(%d*)")
  if not year then return nil end
  local t = {
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec) or 0,
  }
  local utc_offset = os.difftime(os.time(), os.time(os.date("!*t")))
  return os.time(t) - utc_offset
end

local function pretty_expiry(value)
  local timestamp = tonumber(value)
  if not timestamp or timestamp < 100000 then
    timestamp = iso_to_epoch(value)
  end
  if not timestamp then return tostring(value) end
  local remaining = timestamp - os.time()
  local date = os.date("%b %d %H:%M", timestamp)
  if remaining < 0 then return "expired (" .. date .. ")" end
  return "in " .. maki.ui.humantime(remaining) .. " (" .. date .. ")"
end

maki.api.register_command({
  name = "codex-reset",
  description = "Show available Codex usage-limit resets; press y to use one.",
  handler = function()
    local credits, err = reset_credits()
    if not credits then
      maki.ui.flash("Could not load Codex reset credits: " .. err)
      return
    end
    local available = {}
    for _, credit in ipairs(credits.credits or {}) do
      if credit.status == "available" and credit.reset_type == "codex_rate_limits" and credit.id then
        available[#available + 1] = credit
      end
    end
    table.sort(available, function(a, b)
      local ea = iso_to_epoch(a.expires_at or "") or 0
      local eb = iso_to_epoch(b.expires_at or "") or 0
      return ea < eb
    end)
    local lines = { "Codex resets: " .. tostring(credits.available_count or #available) .. " available" }
    if #available == 0 then
      lines[#lines + 1] = "Press any key to close."
    else
      local last_key
      for _, credit in ipairs(available) do
        local key = (credit.title or "Full reset") .. "\n" .. (credit.description or "")
        if key ~= last_key then
          last_key = key
          lines[#lines + 1] = credit.title or "Full reset"
          if credit.description then lines[#lines + 1] = credit.description end
        end
        lines[#lines + 1] = "- expires " .. (pretty_expiry(credit.expires_at) or tostring(credit.expires_at))
      end
    end
    local key = show_modal("Codex resets", lines, { { "y", "use next-expiring reset" }, { "Any key", "close" } })
    if key ~= "y" or #available == 0 then return end
    local outcome, consume_err = consume_reset(available[1].id)
    if not outcome then
      maki.ui.flash("Could not redeem Codex reset: " .. consume_err)
      return
    end
    local message = outcome.code == "reset" and "Codex usage limits reset." or outcome.code == "already_redeemed" and "This Codex reset was already redeemed." or outcome.code == "nothing_to_reset" and "Codex usage does not need a reset." or "No Codex reset was redeemed."
    if outcome.windows_reset ~= nil then message = message .. " Windows reset: " .. tostring(outcome.windows_reset) .. "." end
    maki.ui.flash(message)
  end,
})

if librarian_ok then librarian.register_extension("codex_search") end

maki.api.register_tool({
  name = "codex_search",
  kind = "web",
  description = "Search the web using the configured ChatGPT Codex subscription. Use for current or source-backed information.",
  schema = {
    type = "object",
    properties = {
      queries = { type = "array", items = { type = "string" }, description = "One or more web-search queries." },
      search_context_size = { type = "string", enum = { "low", "medium", "high" }, description = "Web context amount; defaults to medium." },
      include = { type = "array", items = { type = "string", enum = { "file_search_call.results", "web_search_call.results", "web_search_call.action.sources", "message.input_image.image_url", "computer_call_output.output.image_url", "code_interpreter_call.outputs", "reasoning.encrypted_content", "message.output_text.logprobs" } }, description = "Optional extra response data. Omit unless the requested selector is useful; most web searches use web_search_call.results or web_search_call.action.sources." },
    },
    required = { "queries" },
  },
  timeout = 120,
  header = codex_search_header,
  restore = function(_input, output, _is_error, ctx)
    return ToolView.restore(output, web_view_opts(ctx))
  end,
  handler = function(input, ctx)
    if type(input.queries) ~= "table" or #input.queries == 0 then
      return { llm_output = "error: queries is required", is_error = true }
    end
    if #input.queries > 5 then
      return { llm_output = "error: at most 5 queries are allowed", is_error = true }
    end
    for index, query in ipairs(input.queries) do
      if type(query) ~= "string" or query:match("^%s*$") then
        return { llm_output = "error: query " .. tostring(index) .. " must be a nonempty string", is_error = true }
      end
    end

    local model, model_err = default_model()
    if not model then return { llm_output = "error: " .. model_err, is_error = true } end

    local sections, failures = {}, 0
    for _, query in ipairs(input.queries) do
      local payload = {
        model = model,
        instructions = "You are a concise web search assistant. Use web search, answer the query, and preserve source citations from annotations.",
        input = { { type = "message", role = "user", content = { { type = "input_text", text = query } } } },
        tools = { { type = "web_search", external_web_access = true, search_context_size = input.search_context_size or "medium" } },
        tool_choice = "required",
        parallel_tool_calls = true,
        store = false,
        stream = true,
      }
      if input.include and #input.include > 0 then payload.include = input.include end

      local body, request_err = request("/responses", payload)
      if not body then
        failures = failures + 1
        sections[#sections + 1] = "Search failed: " .. query_label(query) .. "\nerror: " .. tostring(request_err)
      else
        local result, result_err = collect_search_response(body)
        if not result then
          failures = failures + 1
          sections[#sections + 1] = "Search failed: " .. query_label(query) .. "\nerror: " .. tostring(result_err)
        else
          local evidence = wants_evidence(input) and collect_evidence(result.events) or {}
          local heading = #input.queries > 1 and ("Search: " .. query_label(query) .. "\n\n") or ""
          sections[#sections + 1] = heading .. search_result_text(result, evidence)
        end
      end
    end

    local output = table.concat(sections, "\n\n")
    if failures == #input.queries then return { llm_output = "error: " .. output, is_error = true } end
    local max_lines = tonumber(ctx:config("max_output_lines", 2000)) or 2000
    local max_bytes = tonumber(ctx:config("max_output_bytes", 50 * 1024)) or 50 * 1024
    return {
      llm_output = truncate(output, max_lines, max_bytes),
      body = ToolView.restore(output, web_view_opts(ctx)),
    }
  end,
})

local function image_header(input)
  return compact(type(input) == "table" and input.prompt or nil, 240) or "generate image"
end

local function generated_images(events)
  local images, seen, visited = {}, {}, {}
  local function inspect(value)
    if type(value) ~= "table" or visited[value] then return end
    visited[value] = true
    if value.type == "image_generation_call" and type(value.result or value.b64_json) == "string" then
      local data = value.result or value.b64_json
      local key = tostring(value.id or "") .. "\0" .. data
      if not seen[key] then
        seen[key] = true
        images[#images + 1] = value
      end
    end
    for _, child in pairs(value) do inspect(child) end
  end
  for _, event in ipairs(events) do inspect(event.value) end
  return images
end

local function image_format_info(bytes)
  local info, err = maki.image.probe(bytes)
  if not info then return nil, "generated payload is not a recognized image: " .. tostring(err) end
  local format = type(info.format) == "string" and info.format:lower() or nil
  local media_types = { png = "image/png", jpeg = "image/jpeg", jpg = "image/jpeg", webp = "image/webp", gif = "image/gif" }
  local extensions = { png = "png", jpeg = "jpg", jpg = "jpg", webp = "webp", gif = "gif" }
  if not media_types[format] then return nil, "generated payload has unsupported image format: " .. tostring(info.format) end
  return { format = format, media_type = media_types[format], extension = extensions[format], width = info.width, height = info.height }
end

local function input_image_type(bytes)
  local info, err = image_format_info(bytes)
  if not info then return nil, err end
  return info.media_type
end

local function ensure_directory(path)
  local meta, metadata_err = maki.fs.metadata(path)
  if metadata_err then return nil, "could not stat output directory: " .. metadata_err end
  if meta then
    if not meta.is_dir then return nil, "output path is not a directory: " .. path end
    return true
  end
  local ok, mkdir_err = maki.fs.mkdir(path, { parents = true })
  if not ok then return nil, "could not create output directory: " .. mkdir_err end
  return true
end

local function image_directory()
  return maki.fs.joinpath(maki.env.state_dir(), "generated_images", "maki")
end

local function safe_image_id(value)
  local id = tostring(value or "image"):gsub("[^%w%-%_]", "_")
  return id ~= "" and id or "image"
end

local function write_binary(path, bytes)
  local direct_ok, direct = pcall(maki.fs.write, path, bytes)
  if direct_ok and direct then return true end
  local staged = path .. ".b64.tmp"
  local stage_ok, stage_err = maki.fs.write(staged, maki.base64.encode(bytes))
  if not stage_ok then return nil, "could not stage image data: " .. stage_err end
  local job_ok, job_id = pcall(maki.fn.jobstart, { "sh", "-c", "base64 -d \"$1\" > \"$2\"", "codex-image-writer", staged, path }, {})
  if not job_ok or type(job_id) ~= "number" then
    pcall(maki.fs.rm, staged)
    return nil, "could not start image writer: " .. tostring(job_id)
  end
  local wait_ok, result = pcall(maki.fn.jobwait, job_id, 30000)
  pcall(maki.fs.rm, staged)
  if not wait_ok then return nil, "image writer failed: " .. tostring(result) end
  if not result then return nil, "image writer timed out after 30s" end
  if result.exit_code ~= 0 then
    local detail = type(result.stderr) == "string" and result.stderr ~= "" and (": " .. result.stderr) or ""
    return nil, "image writer exited with code " .. tostring(result.exit_code) .. detail
  end
  return true
end

local function output_path(directory, id, extension)
  for suffix = 0, 999 do
    local name = id .. (suffix == 0 and "" or "-" .. tostring(suffix)) .. "." .. extension
    local path = maki.fs.joinpath(directory, name)
    local meta, metadata_err = maki.fs.metadata(path)
    if metadata_err then return nil, "could not stat output path: " .. metadata_err end
    if not meta then return path end
  end
  return nil, "could not choose an unused output path"
end

maki.api.register_tool({
  name = "image_generation",
  kind = "image",
  description = "Generate or edit raster images through the ChatGPT Codex subscription. Saves the completed image under the Maki state directory (generated_images/).",
  schema = {
    type = "object",
    properties = {
      prompt = { type = "string", description = "Image generation or editing prompt." },
      images = { type = "array", items = { type = "string" }, description = "Optional local image paths to edit or use as references." },
      output_format = { type = "string", enum = { "png", "jpeg", "webp" }, description = "Output format; defaults to png." },
      model = { type = "string", description = "Optional Codex model; defaults to the account's default Codex model." },
    },
    required = { "prompt" },
  },
  timeout = 120,
  header = image_header,
  handler = function(input)
    if type(input.prompt) ~= "string" or input.prompt:match("^%s*$") then
      return { llm_output = "error: prompt must be a nonempty string", is_error = true }
    end
    if type(input.images) == "table" and #input.images > 8 then
      return { llm_output = "error: at most 8 reference images are allowed", is_error = true }
    end

    local format = input.output_format or "png"
    local content = { { type = "input_text", text = input.prompt } }
    for _, path in ipairs(input.images or {}) do
      if type(path) ~= "string" or path == "" then
        return { llm_output = "error: image paths must be nonempty strings", is_error = true }
      end
      local bytes, read_err = maki.fs.read_bytes(path)
      if not bytes then return { llm_output = "error: could not read image " .. path .. ": " .. read_err, is_error = true } end
      local media_type, type_err = input_image_type(bytes)
      if not media_type then return { llm_output = "error: could not use image " .. path .. ": " .. type_err, is_error = true } end
      content[#content + 1] = { type = "input_image", detail = "auto", image_url = "data:" .. media_type .. ";base64," .. maki.base64.encode(bytes) }
    end

    local model = input.model
    if not model or model == "" then
      local discovered, model_err = default_model()
      if not discovered then return { llm_output = "error: " .. model_err, is_error = true } end
      model = discovered
    end

    local body, request_err = request("/responses", {
      model = model,
      instructions = "",
      input = { { role = "user", content = content } },
      tools = { { type = "image_generation", output_format = format } },
      tool_choice = { type = "image_generation" },
      parallel_tool_calls = false,
      store = false,
      stream = true,
    }, 120)
    if not body then return { llm_output = "error: " .. request_err, is_error = true } end

    local events, parse_errors = sse_events(body)
    local backend_errors = {}
    for _, parse_error in ipairs(parse_errors) do backend_errors[#backend_errors + 1] = "protocol: " .. parse_error end
    for _, event in ipairs(events) do
      local message = event_error(event)
      if message then backend_errors[#backend_errors + 1] = "backend: " .. message end
    end
    local images = generated_images(events)
    if #images == 0 then
      local reason = #backend_errors > 0 and table.concat(backend_errors, "; ") or "Codex did not return an image"
      return { llm_output = "error: " .. reason, is_error = true }
    end

    local data = images[1].result or images[1].b64_json
    data = data:match("^data:[^;]+;base64,(.*)$") or data
    local decoded_ok, decoded_or_err = pcall(maki.base64.decode, data)
    if not decoded_ok or type(decoded_or_err) ~= "string" then
      return { llm_output = "error: invalid image base64: " .. tostring(decoded_or_err), is_error = true }
    end
    local info, info_err = image_format_info(decoded_or_err)
    if not info then return { llm_output = "error: " .. info_err, is_error = true } end

    local directory, directory_err = image_directory()
    if not directory then return { llm_output = "error: " .. directory_err, is_error = true } end
    local directory_ok, directory_err = ensure_directory(directory)
    if not directory_ok then return { llm_output = "error: " .. directory_err, is_error = true } end
    local path, path_err = output_path(directory, safe_image_id(images[1].id), info.extension)
    if not path then return { llm_output = "error: " .. path_err, is_error = true } end
    local write_ok, write_err = write_binary(path, decoded_or_err)
    if not write_ok then return { llm_output = "error: could not save image: " .. write_err, is_error = true } end

    local dimensions = info.width and info.height and (tostring(info.width) .. "×" .. tostring(info.height)) or "unknown dimensions"
    local extras = #images > 1 and ("; " .. tostring(#images - 1) .. " additional image" .. (#images == 2 and " was" or "s were") .. " returned but not saved") or ""
    if #backend_errors > 0 then extras = extras .. "; warnings: " .. table.concat(backend_errors, "; ") end
    return {
      llm_output = "Generated " .. info.media_type .. " image (" .. dimensions .. ") saved to: " .. path .. extras,
      written_path = path,
      image = { media_type = info.media_type, data = data },
    }
  end,
})
