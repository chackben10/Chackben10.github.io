------------------------------------------------------------
-- ProPresenter Remote Control via Clicker + HTTP Server
-- + Bible look enforcement
-- + Announcement watcher -> OBS Bridge
-- + HTTP API for HTML tools
------------------------------------------------------------

proRemote = proRemote or {}

------------------------------------------------------------
-- CONFIG
------------------------------------------------------------

-- Bible look enforcement
proRemote.check_for_bible = true
proRemote.BIBLE_CHECK_INTERVAL_SEC = 0.75
proRemote.BIBLE_MACRO_COOLDOWN_SEC = 2.5

-- Clicker keys
proRemote.nextSlideKey = 69
proRemote.prevSlideKey = 78

-- ProPresenter endpoints
proRemote.PROPRESENTER_ACTIVE_BASE  = "http://localhost:49232/v1/presentation/active"
proRemote.PROPRESENTER_FOCUSED_BASE = "http://localhost:49232/v1/presentation/focused"
proRemote.PROPRESENTER_UUID_BASE    = "http://localhost:49232/v1/presentation"
proRemote.PROPRESENTER_SLIDE_INDEX  = "http://localhost:49232/v1/presentation/slide_index"

proRemote.PROPRESENTER_LOOK_CURRENT = "http://localhost:49232/v1/look/current"
proRemote.BIBLE_LOOK_NAME           = "Bible"
proRemote.BIBLE_MACRO_TRIGGER_URL   = "http://localhost:49232/v1/macro/69293C79-69BB-4061-86E1-76F627CB3085/trigger"

proRemote.PROPRESENTER_PRESENTATION_BASE = proRemote.PROPRESENTER_ACTIVE_BASE

-- Announcement endpoints
proRemote.PROPRESENTER_ANNOUNCEMENT_ACTIVE = "http://localhost:49232/v1/announcement/active"
proRemote.ANNOUNCEMENT_CAMERA_KEYWORD = "camera"

-- Chunked streams
proRemote.USE_CHUNKED_STREAMS = true
proRemote.CURL_PATH = "/usr/bin/curl"
proRemote.STREAM_RESTART_DELAY_SEC = 1.0

-- Fallback poll (keeps working if stream drops)
proRemote.ANNOUNCEMENT_POLL_FALLBACK_SEC = 1.0

-- HTTP server
proRemote.HTTP_SERVER_PORT      = 1337
proRemote.HTTP_SERVER_INTERFACE = "localhost"

-- OBS Bridge (Node)
proRemote.OBS_BRIDGE_ENABLED = true
proRemote.OBS_BRIDGE_BASE    = "http://127.0.0.1:17777"

-- Set this to output of: which node
proRemote.NODE_PATH          = "/opt/homebrew/bin/node"
proRemote.OBS_BRIDGE_SCRIPT  = "/Users/icas/obs-bridge/server.mjs"
proRemote.OBS_BRIDGE_WORKDIR = "/Users/icas/obs-bridge"

-- OBS names
proRemote.OBS_SCENE_NAME          = "ProPresenter Slides"
proRemote.OBS_SOURCE_CAMERA       = "PTZ Camera"
proRemote.OBS_SOURCE_ANNOUNCEMENT = "Audience Camera"

------------------------------------------------------------
-- Utility
------------------------------------------------------------

local function trim(s)
  if type(s) ~= "string" then return "" end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function ltrim(s)
  if type(s) ~= "string" then return "" end
  return (s:gsub("^%s+", ""))
end

local function decodeJson(str)
  if type(str) ~= "string" or str == "" then return nil end
  str = ltrim(str)
  local first = str:sub(1,1)
  if first ~= "{" and first ~= "[" then return nil end
  local ok, result = pcall(function() return hs.json.decode(str) end)
  if ok then return result end
  return nil
end

local function nowSec()
  return hs.timer.secondsSinceEpoch()
end

------------------------------------------------------------
-- Auto-select ACTIVE vs FOCUSED based on slide_index
------------------------------------------------------------

local function refreshPresentationBase()
  local ok, status, body = pcall(function()
    return hs.http.get(proRemote.PROPRESENTER_SLIDE_INDEX, { ["accept"]="application/json" })
  end)

  if not ok or status ~= 200 or not body or body == "" then
    proRemote.PROPRESENTER_PRESENTATION_BASE = proRemote.PROPRESENTER_FOCUSED_BASE
    return
  end

  local data = decodeJson(body)
  if not data or not data.presentation_index or not data.presentation_index.index then
    proRemote.PROPRESENTER_PRESENTATION_BASE = proRemote.PROPRESENTER_FOCUSED_BASE
  else
    proRemote.PROPRESENTER_PRESENTATION_BASE = proRemote.PROPRESENTER_ACTIVE_BASE
  end
end

local function currentMode()
  return (proRemote.PROPRESENTER_PRESENTATION_BASE == proRemote.PROPRESENTER_ACTIVE_BASE) and "active" or "focused"
end

------------------------------------------------------------
-- Bible enforcement
------------------------------------------------------------

local function activePresentationHasSingleGroupWithColon()
  local ok, status, body = pcall(function()
    return hs.http.get(proRemote.PROPRESENTER_ACTIVE_BASE, { ["accept"]="application/json" })
  end)
  if not ok or status ~= 200 or not body or body == "" then return false end

  local data = decodeJson(body)
  local pres = data and data.presentation
  local groups = pres and pres.groups
  if type(groups) ~= "table" then return false end
  if #groups ~= 1 then return false end

  local gname = groups[1] and groups[1].name
  if type(gname) ~= "string" then return false end
  return gname:find(":", 1, true) ~= nil
end

proRemote._bible_lastCondition = proRemote._bible_lastCondition or false
proRemote._bible_lastMacroAt   = proRemote._bible_lastMacroAt or 0

local function enforceBibleLookIfNeeded()
  if not proRemote.check_for_bible then
    proRemote._bible_lastCondition = false
    return
  end

  local cond = activePresentationHasSingleGroupWithColon()
  local rising = (cond == true and proRemote._bible_lastCondition == false)
  proRemote._bible_lastCondition = cond
  if not rising then return end

  local now = nowSec()
  if (now - (proRemote._bible_lastMacroAt or 0)) < proRemote.BIBLE_MACRO_COOLDOWN_SEC then return end

  local ok, status, body = pcall(function()
    return hs.http.get(proRemote.PROPRESENTER_LOOK_CURRENT, { ["accept"]="application/json" })
  end)
  if not ok or status ~= 200 or not body or body == "" then return end

  local look = decodeJson(body)
  local lookName = look and look.id and look.id.name

  if lookName ~= proRemote.BIBLE_LOOK_NAME then
    proRemote._bible_lastMacroAt = now
    hs.http.asyncGet(proRemote.BIBLE_MACRO_TRIGGER_URL, {}, function() end)
  end
end

local function startBibleTimer()
  if proRemote.bibleTimer then proRemote.bibleTimer:stop() end
  proRemote.bibleTimer = hs.timer.doEvery(proRemote.BIBLE_CHECK_INTERVAL_SEC, function()
    pcall(enforceBibleLookIfNeeded)
  end)
end

------------------------------------------------------------
-- Slide actions
------------------------------------------------------------

local function triggerNextSlide()
  refreshPresentationBase()
  hs.http.asyncGet(proRemote.PROPRESENTER_PRESENTATION_BASE .. "/next/trigger", {}, function() end)
end

local function triggerPreviousSlide()
  refreshPresentationBase()
  hs.http.asyncGet(proRemote.PROPRESENTER_PRESENTATION_BASE .. "/previous/trigger", {}, function() end)
end

local function triggerFocusedSlide(index)
  if type(index) ~= "number" or index < 0 then return end
  refreshPresentationBase()
  local url = string.format("%s/%d/trigger", proRemote.PROPRESENTER_PRESENTATION_BASE, index)
  hs.http.asyncGet(url, {}, function() end)
end

------------------------------------------------------------
-- Unified Presentation Fetcher (ACTIVE or FOCUSED MODE)
------------------------------------------------------------

local function fetchFullPresentationJSON()
  refreshPresentationBase()

  if currentMode() == "active" then
    local ok, status, body = pcall(function()
      return hs.http.get(proRemote.PROPRESENTER_ACTIVE_BASE, { ["accept"]="application/json" })
    end)
    if ok and status == 200 and body then return body end
    return '{"error":"cannot fetch active presentation"}'
  end

  local ok1, status1, focusedBody = pcall(function()
    return hs.http.get(proRemote.PROPRESENTER_FOCUSED_BASE, { ["accept"]="application/json" })
  end)

  local focused = decodeJson(focusedBody)
  if not ok1 or status1 ~= 200 or not focused or not focused.uuid then
    return '{"error":"cannot fetch focused presentation"}'
  end

  local uuid = focused.uuid
  local fullURL = string.format("%s/%s", proRemote.PROPRESENTER_UUID_BASE, uuid)

  local ok2, status2, fullBody = pcall(function()
    return hs.http.get(fullURL, { ["accept"]="application/json" })
  end)

  if ok2 and status2 == 200 and fullBody then return fullBody end
  return '{"error":"cannot fetch presentation by uuid"}'
end

------------------------------------------------------------
-- Thumbnail Fetch
------------------------------------------------------------

local function fetchThumbnail(uuid, index)
  if not uuid or index == nil then
    return "Missing uuid or index", 400, "text/plain; charset=utf-8"
  end

  local url = string.format(
    "%s/%s/thumbnail/%d?quality=800&thumbnail_type=png",
    proRemote.PROPRESENTER_UUID_BASE, uuid, index
  )

  local status, body, headers = hs.http.doRequest(url, "GET", nil, { ["Accept"]="image/png" })
  if status ~= 200 or not body then
    return "Error fetching thumbnail", 500, "text/plain; charset=utf-8"
  end

  local contentType = (headers and headers["Content-Type"]) or "image/png"
  return body, 200, contentType
end

------------------------------------------------------------
-- OBS Bridge start/watch + set mode
------------------------------------------------------------

proRemote._bridge = proRemote._bridge or { task=nil, running=false }

local function bridgeHealth()
  if not proRemote.OBS_BRIDGE_ENABLED then return false end
  local status = hs.http.get(proRemote.OBS_BRIDGE_BASE .. "/health", { ["accept"]="application/json" })
  return status == 200
end

local function bridgeKillTask()
  if proRemote._bridge.task then
    pcall(function() proRemote._bridge.task:terminate() end)
    proRemote._bridge.task = nil
  end
end

local function bridgeStart()
  if not proRemote.OBS_BRIDGE_ENABLED then return end
  if bridgeHealth() then
    proRemote._bridge.running = true
    return
  end

  bridgeKillTask()

  local function streamFn(task, stdOut, stdErr) end

  local function exitFn(task, exitCode, stdOut, stdErr)
    proRemote._bridge.running = false
    hs.timer.doAfter(1.0, function() bridgeStart() end)
  end

  local t = hs.task.new(proRemote.NODE_PATH, exitFn, streamFn, { proRemote.OBS_BRIDGE_SCRIPT })
  if not t then return end

  if proRemote.OBS_BRIDGE_WORKDIR and proRemote.OBS_BRIDGE_WORKDIR ~= "" then
    pcall(function() t:setWorkingDirectory(proRemote.OBS_BRIDGE_WORKDIR) end)
  end

  proRemote._bridge.task = t
  t:start()

  hs.timer.doAfter(0.8, function()
    proRemote._bridge.running = bridgeHealth()
  end)
end

local function bridgeWatchdogStart()
  if proRemote.bridgeWatchdog then proRemote.bridgeWatchdog:stop() end
  proRemote.bridgeWatchdog = hs.timer.doEvery(4.0, function()
    if not bridgeHealth() then
      proRemote._bridge.running = false
      bridgeStart()
    else
      proRemote._bridge.running = true
    end
  end)
end

local function bridgeSetMode(mode)
  if not proRemote.OBS_BRIDGE_ENABLED then return end
  mode = tostring(mode or ""):lower()
  if mode ~= "none" and mode ~= "ann" and mode ~= "cam" then return end

  local url = string.format(
    "%s/set?mode=%s&scene=%s&srcAnn=%s&srcCam=%s",
    proRemote.OBS_BRIDGE_BASE,
    hs.http.encodeForQuery(mode),
    hs.http.encodeForQuery(proRemote.OBS_SCENE_NAME),
    hs.http.encodeForQuery(proRemote.OBS_SOURCE_ANNOUNCEMENT),
    hs.http.encodeForQuery(proRemote.OBS_SOURCE_CAMERA)
  )

  hs.http.asyncGet(url, {}, function() end)
end

------------------------------------------------------------
-- Announcement state + watcher
------------------------------------------------------------

proRemote._ann = proRemote._ann or { lastName="", lastDesired="none" }

local function announcementNameFromObj(obj)
  if type(obj) ~= "table" then return "" end
  local a = obj.announcement
  if a == nil then return "" end
  local nm = a and a.id and a.id.name
  if type(nm) ~= "string" then return "" end
  return nm
end

local function desiredFromAnnouncementName(name)
  name = (type(name) == "string") and name or ""
  if name == "" then return "none" end
  local lower = string.lower(name)
  if lower:find(string.lower(proRemote.ANNOUNCEMENT_CAMERA_KEYWORD), 1, true) ~= nil then
    return "cam"
  end
  return "ann"
end

local function applyAnnouncementState(name)
  local desired = desiredFromAnnouncementName(name)

  if name ~= proRemote._ann.lastName or desired ~= proRemote._ann.lastDesired then
    proRemote._ann.lastName = name
    proRemote._ann.lastDesired = desired
  end

  bridgeSetMode(desired)
end

local function bootstrapAnnouncementOnce()
  local ok, status, body = pcall(function()
    return hs.http.get(proRemote.PROPRESENTER_ANNOUNCEMENT_ACTIVE, { ["accept"]="application/json" })
  end)

  if not ok or status ~= 200 or not body or body == "" then
    applyAnnouncementState("")
    return
  end

  local obj = decodeJson(body)
  applyAnnouncementState(announcementNameFromObj(obj))
end

------------------------------------------------------------
-- Chunked record stream: JSON records separated by blank lines
------------------------------------------------------------

proRemote._streams = proRemote._streams or {}

local function startChunkedRecordStream(name, url, onJsonObj)
  local existing = proRemote._streams[name]
  if existing and existing.task then pcall(function() existing.task:terminate() end) end

  proRemote._streams[name] = { buffer = "" }

  local function restartLater()
    if not proRemote.USE_CHUNKED_STREAMS then return end
    hs.timer.doAfter(proRemote.STREAM_RESTART_DELAY_SEC, function()
      if proRemote.USE_CHUNKED_STREAMS then
        startChunkedRecordStream(name, url, onJsonObj)
      end
    end)
  end

  local function streamCallback(task, stdOut, stdErr)
    if not stdOut or stdOut == "" then return end

    local s = proRemote._streams[name]
    if not s then return end

    local chunk = stdOut:gsub("\r", "")
    s.buffer = (s.buffer or "") .. chunk

    while true do
      local sep = s.buffer:find("\n\n", 1, true)
      if not sep then break end

      local record = s.buffer:sub(1, sep - 1)
      s.buffer = s.buffer:sub(sep + 2)

      record = trim(record)
      if record ~= "" then
        local obj = decodeJson(record)
        if obj then pcall(onJsonObj, obj) end
      end
    end

    if #s.buffer > 200000 then
      s.buffer = s.buffer:sub(-20000)
    end
  end

  local function exitCallback(task, exitCode, stdOut, stdErr)
    restartLater()
  end

  local args = { "-sN", "-H", "Accept: application/json", url }
  local t = hs.task.new(proRemote.CURL_PATH, exitCallback, streamCallback, args)
  if not t then
    restartLater()
    return
  end

  proRemote._streams[name].task = t
  t:start()
end

local function startAnnouncementWatcher()
  if not proRemote.USE_CHUNKED_STREAMS then return end
  startChunkedRecordStream(
    "announcement_active",
    proRemote.PROPRESENTER_ANNOUNCEMENT_ACTIVE .. "?chunked=true",
    function(obj)
      applyAnnouncementState(announcementNameFromObj(obj))
    end
  )
end

local function startAnnouncementPollFallback()
  if proRemote.announcementPollTimer then proRemote.announcementPollTimer:stop() end
  proRemote.announcementPollTimer = hs.timer.doEvery(proRemote.ANNOUNCEMENT_POLL_FALLBACK_SEC, function()
    local ok, status, body = pcall(function()
      return hs.http.get(proRemote.PROPRESENTER_ANNOUNCEMENT_ACTIVE, { ["accept"]="application/json" })
    end)
    if not ok or status ~= 200 or not body or body == "" then return end
    local obj = decodeJson(body)
    if obj then applyAnnouncementState(announcementNameFromObj(obj)) end
  end)
end

------------------------------------------------------------
-- HTTP Helpers
------------------------------------------------------------

local function cleanPath(path)
  local p = path and path:match("^[^?]+") or ""
  return p ~= "" and p or "/"
end

local function parseQuery(path)
  local params = {}
  local q = path:match("%?(.*)$") or ""
  for k, v in q:gmatch("([^&=]+)=([^&=]+)") do params[k] = v end
  return params
end

------------------------------------------------------------
-- Route Handler
------------------------------------------------------------

local function handleHttpPath(rawPath)
  local p = cleanPath(rawPath)
  local params = parseQuery(rawPath)

  if p == "/next" then
    triggerNextSlide()
    return "OK\n", 200, "text/plain"

  elseif p == "/previous" or p == "/prev" then
    triggerPreviousSlide()
    return "OK\n", 200, "text/plain"

  elseif p == "/focus" then
    local idx = tonumber(params["index"])
    if not idx then return "Bad index", 400, "text/plain" end
    triggerFocusedSlide(idx)
    return "OK\n", 200, "text/plain"

  elseif p == "/active-presentation" then
    return fetchFullPresentationJSON(), 200, "application/json"

  elseif p == "/slide-index" then
    local ok, status, body = pcall(function()
      return hs.http.get(proRemote.PROPRESENTER_SLIDE_INDEX, { ["accept"]="application/json" })
    end)
    return body or "{}", 200, "application/json"

  elseif p == "/thumbnail" then
    return fetchThumbnail(params.uuid, tonumber(params.index))

  elseif p == "/current-base" then
    refreshPresentationBase()
    local out = string.format('{"mode":"%s","base_url":"%s"}', currentMode(), proRemote.PROPRESENTER_PRESENTATION_BASE)
    return out, 200, "application/json"

  elseif p == "/health" then
    return "OK", 200, "text/plain"
  end

  return "Not found", 404, "text/plain"
end

------------------------------------------------------------
-- HTTP server
------------------------------------------------------------

local function httpCallback(method, path, headers, body)
  local h = {
    ["Access-Control-Allow-Origin"]  = "*",
    ["Access-Control-Allow-Methods"] = "GET, OPTIONS",
    ["Access-Control-Allow-Headers"] = "Content-Type",
  }

  if method == "OPTIONS" then return "", 204, h end

  local ok, bodyData, status, contentType = pcall(handleHttpPath, path)
  if not ok then
    return "Internal error\n", 500, h
  end

  h["Content-Type"] = contentType
  return bodyData, status, h
end

if proRemote.server then proRemote.server:stop() end
proRemote.server = hs.httpserver.new(false, false)
proRemote.server:setPort(proRemote.HTTP_SERVER_PORT)
proRemote.server:setInterface(proRemote.HTTP_SERVER_INTERFACE)
proRemote.server:setCallback(httpCallback)
proRemote.server:start()

------------------------------------------------------------
-- STARTUP
------------------------------------------------------------

startBibleTimer()

bridgeStart()
bridgeWatchdogStart()

bootstrapAnnouncementOnce()
startAnnouncementWatcher()
startAnnouncementPollFallback()

hs.alert.show("ProPresenter remote ready")
