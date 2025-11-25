------------------------------------------------------------
-- ProPresenter Remote Control via Clicker + HTTP Server
-- (with persistent globals so GC can't kill it)
------------------------------------------------------------

-- Global namespace to keep references alive across reloads
proRemote = proRemote or {}

------------------------------------------------------------
-- CONFIG
------------------------------------------------------------

proRemote.nextSlideKey = 69     -- E key
proRemote.prevSlideKey = 78     -- N key

proRemote.PROPRESENTER_PRESENTATION_BASE = "http://localhost:49232/v1/presentation/active"
proRemote.PROPRESENTER_SLIDE_INDEX_URL   = "http://localhost:49232/v1/presentation/slide_index"
proRemote.PROPRESENTER_FOCUSED_BASE      = "http://localhost:49232/v1/presentation/focused"

-- Base for thumbnails
proRemote.PROPRESENTER_THUMBNAIL_BASE    = "http://localhost:49232/v1/presentation"

proRemote.HTTP_SERVER_PORT      = 1337
proRemote.HTTP_SERVER_INTERFACE = "localhost"

------------------------------------------------------------
-- ProPresenter Helpers
------------------------------------------------------------

-- Trigger next slide
local function triggerNextSlide()
    hs.http.asyncGet(
        proRemote.PROPRESENTER_PRESENTATION_BASE .. "/next/trigger",
        { ["accept"] = "*/*" },
        function() end
    )
end

-- Trigger previous slide
local function triggerPreviousSlide()
    hs.http.asyncGet(
        proRemote.PROPRESENTER_PRESENTATION_BASE .. "/previous/trigger",
        { ["accept"] = "*/*" },
        function() end
    )
end

-- Jump to a specific slide index in the focused presentation
local function triggerFocusedSlide(index)
    if type(index) ~= "number" or index < 0 then return end
    local url = string.format("%s/%d/trigger", proRemote.PROPRESENTER_FOCUSED_BASE, index)

    hs.http.asyncGet(url, { ["accept"] = "*/*" }, function() end)
end

-- JSON endpoint: active presentation
local function fetchActivePresentationJSON()
    local ok, status, body = pcall(function()
        return hs.http.get(
            proRemote.PROPRESENTER_PRESENTATION_BASE,
            { ["accept"] = "application/json" }
        )
    end)

    if not ok or status ~= 200 or not body or body == "" then
        return '{"error":"no response from ProPresenter"}'
    end
    return body
end

-- JSON endpoint: slide index
local function fetchSlideIndexJSON()
    local ok, status, body = pcall(function()
        return hs.http.get(
            proRemote.PROPRESENTER_SLIDE_INDEX_URL,
            { ["accept"] = "application/json" }
        )
    end)

    if not ok or status ~= 200 or not body or body == "" then
        return '{"error":"no response from ProPresenter"}'
    end
    return body
end

------------------------------------------------------------
-- PNG Thumbnail Fetcher (binary passthrough)
------------------------------------------------------------
local function fetchThumbnail(uuid, index)
    if not uuid or not index then
        return "Missing uuid/index\n", 400, "text/plain; charset=utf-8"
    end

    local url = string.format(
        "%s/%s/thumbnail/%d?quality=800&thumbnail_type=png",
        proRemote.PROPRESENTER_THUMBNAIL_BASE,
        uuid,
        index
    )

    -- Force PNG output
    local status, body, headers = hs.http.getBinary(url, {
        ["accept"] = "image/png"
    })

    if status ~= 200 or not body then
        return "Thumbnail unavailable\n", 500, "text/plain; charset=utf-8"
    end

    local contentType = headers["Content-Type"] or "image/png"

    return body, 200, contentType
end

------------------------------------------------------------
-- Clicker eventtap
------------------------------------------------------------

if proRemote.clickerTap then
    proRemote.clickerTap:stop()
end

proRemote.clickerTap = hs.eventtap.new(
    { hs.eventtap.event.types.keyDown },
    function(event)
        local ok, keyCode = pcall(function()
            return event:getKeyCode()
        end)

        if not ok or not keyCode then return false end

        if keyCode == proRemote.nextSlideKey then
            triggerNextSlide()
        elseif keyCode == proRemote.prevSlideKey then
            triggerPreviousSlide()
        end

        return false
    end
)

proRemote.clickerTap:start()

------------------------------------------------------------
-- HTTP server routing
------------------------------------------------------------

local function cleanPath(path)
    local p = path and path:match("^[^?]+") or ""
    return p ~= "" and p or "/"
end

local function parseQuery(path)
    local q = path:match("%?(.*)$") or ""
    local params = {}
    for key, value in string.gmatch(q, "([^&=]+)=([^&=]+)") do
        params[key] = value
    end
    return params
end

-- router returns body, status, contentType
local function handleHttpPath(rawPath)
    local p      = cleanPath(rawPath)
    local params = parseQuery(rawPath)

    if p == "/next" then
        triggerNextSlide()
        return "OK: next\n", 200, "text/plain; charset=utf-8"

    elseif p == "/previous" or p == "/prev" then
        triggerPreviousSlide()
        return "OK: previous\n", 200, "text/plain; charset=utf-8"

    elseif p == "/focus" then
        local idx = tonumber(params["index"])
        if not idx then return "Bad index\n", 400, "text/plain; charset=utf-8" end
        triggerFocusedSlide(idx)
        return string.format("OK: focus %d\n", idx), 200, "text/plain; charset=utf-8"

    elseif p == "/thumbnail" then
        local uuid  = params["uuid"]
        local index = tonumber(params["index"])
        return fetchThumbnail(uuid, index)

    elseif p == "/active-presentation" then
        return fetchActivePresentationJSON(), 200, "application/json; charset=utf-8"

    elseif p == "/slide-index" then
        return fetchSlideIndexJSON(), 200, "application/json; charset=utf-8"

    elseif p == "/health" then
        return "OK\n", 200, "text/plain; charset=utf-8"

    else
        return "Not found\n", 404, "text/plain; charset=utf-8"
    end
end

------------------------------------------------------------
-- HTTP server wrapper
------------------------------------------------------------

local function httpCallback(method, path, headers, body)
    local baseHeaders = {
        ["Access-Control-Allow-Origin"]  = "*",
        ["Access-Control-Allow-Methods"] = "GET, OPTIONS",
        ["Access-Control-Allow-Headers"] = "Content-Type",
    }

    if method == "OPTIONS" then
        return "", 204, baseHeaders
    end

    local ok, bodyData, statusCode, contentType = pcall(handleHttpPath, path)

    if not ok then
        print("HTTP handler error:", bodyData)
        bodyData    = "Internal error\n"
        statusCode  = 500
        contentType = "text/plain; charset=utf-8"
    end

    baseHeaders["Content-Type"] = contentType

    return bodyData, statusCode, baseHeaders
end

-- Restart server cleanly on reload
if proRemote.server then
    proRemote.server:stop()
end

proRemote.server = hs.httpserver.new(false, false)
proRemote.server:setPort(proRemote.HTTP_SERVER_PORT)
proRemote.server:setInterface(proRemote.HTTP_SERVER_INTERFACE)
proRemote.server:setCallback(httpCallback)
proRemote.server:start()

------------------------------------------------------------
-- Startup notification
------------------------------------------------------------

hs.alert.show(("ProPresenter Remote Ready (HTTP + thumbnails on %s:%d)")
    :format(proRemote.HTTP_SERVER_INTERFACE, proRemote.HTTP_SERVER_PORT))
