-- Links the game to the streamer's Twitch account on bot.andy-balatro.com,
-- once for all of Andy's mods (Progress Tracker and Andy's Chat). Each mod
-- comes with the same copy of this file. The first one in the game's main.lua
-- runs and the others skip themselves, so there's one link and one network
-- thread however many are installed.
--
-- Linking works like a TV app's sign-in: the server hands out a code, the
-- streamer types it on the site, and asking every few seconds gets the game's
-- token once they have. Requests go over HTTPS, on a background thread so
-- the game never waits on the network.
if not AndysLink then
  -- Set ANDYS_MODS_URL to try the mods against another server.
  local SERVER = os.getenv("ANDYS_MODS_URL") or "https://bot.andy-balatro.com"
  local LINK_FILE = "config/andys-link.jkr"
  local LINK_POLL_SECONDS = 3

  AndysLink = { server = SERVER, host = (SERVER:gsub("^https?://", "")) }

  -- Saved link ----------------------------------------------------------------

  -- { token = the game's token, login = Twitch login it's linked to }
  local function load_saved()
    local ok, saved = pcall(function()
      local file = love.filesystem.read(LINK_FILE)
      return file and STR_UNPACK(file)
    end)
    return ok and type(saved) == "table" and saved or {}
  end

  local saved = load_saved()

  local function save()
    if not love.filesystem.getInfo("config") then love.filesystem.createDirectory("config") end
    love.filesystem.write(LINK_FILE, STR_PACK(saved))
  end

  function AndysLink.is_linked()
    return saved.token ~= nil
  end

  -- The Twitch login the game is linked to, or nil.
  function AndysLink.login()
    return saved.login
  end

  -- Mods that want to know when the game gets linked or unlinked:
  -- fn(linked) with linked true or false.
  local listeners = {}
  function AndysLink.on_change(fn)
    listeners[#listeners + 1] = fn
  end
  local function changed()
    for _, fn in ipairs(listeners) do fn(AndysLink.is_linked()) end
  end

  -- Shown instead of "Not linked", e.g. why linking failed.
  local message = nil

  local function unlinked(why)
    if not saved.token then return end
    saved = {}
    save()
    message = why
    changed()
  end

  -- The server says the login changed, e.g. after a Twitch rename.
  function AndysLink.set_login(login)
    if saved.token and type(login) == "string" and login ~= saved.login then
      saved.login = login
      save()
    end
  end

  -- JSON ----------------------------------------------------------------------

  local function json_string(s)
    local escaped = tostring(s):gsub('[%c"\\]', function(c)
      return string.format("\\u%04x", c:byte())
    end)
    return '"' .. escaped .. '"'
  end

  -- Flat tables of strings, numbers and booleans are all requests need.
  function AndysLink.encode(fields)
    local parts = {}
    for key, value in pairs(fields) do
      local kind = type(value)
      local encoded = (kind == "number" or kind == "boolean") and tostring(value) or json_string(value)
      parts[#parts + 1] = json_string(key) .. ":" .. encoded
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end

  -- The server's linking answers are small flat objects, so matching beats a
  -- parser. Only for values without quotes or escapes, which is all it sends.
  function AndysLink.field(body, name)
    return type(body) == "string" and body:match('"' .. name .. '":"([^"\\]*)"') or nil
  end

  -- Network -------------------------------------------------------------------

  -- A chunk that returns a module with https.request(url, options), for
  -- background threads to load with loadstring. It's the "https" module
  -- Balatro ships on Windows. The Mac and Linux builds don't have it, so there
  -- it's libcurl, which they come with, through LuaJIT's FFI. Errors if
  -- neither loads.
  AndysLink.HTTPS = [==[
  local has_https, https = pcall(require, "https")
  if has_https then return https end

  local ffi = require("ffi")
  local loaded, curl
  for _, name in ipairs({ "libcurl", "libcurl.4.dylib", "/usr/lib/libcurl.4.dylib", "libcurl.so.4" }) do
    loaded, curl = pcall(ffi.load, name)
    if loaded then break end
  end
  if not loaded then error("no https module (" .. tostring(https) .. ") and no libcurl (" .. tostring(curl) .. ")") end

  ffi.cdef([[
    typedef void CURL;
    struct curl_slist;
    typedef size_t (*andys_curl_write)(char *data, size_t size, size_t count, void *user);
    CURL *curl_easy_init(void);
    int curl_easy_setopt(CURL *curl, int option, ...);
    int curl_easy_perform(CURL *curl);
    int curl_easy_getinfo(CURL *curl, int info, ...);
    void curl_easy_cleanup(CURL *curl);
    const char *curl_easy_strerror(int code);
    struct curl_slist *curl_slist_append(struct curl_slist *list, const char *s);
    void curl_slist_free_all(struct curl_slist *list);
  ]])

  -- Option and info numbers from curl.h.
  local URL, WRITEFUNCTION, HTTPHEADER, CUSTOMREQUEST = 10002, 20011, 10023, 10036
  local POSTFIELDS, POSTFIELDSIZE, ACCEPT_ENCODING = 10015, 60, 10102
  local FOLLOWLOCATION, NOSIGNAL, CONNECTTIMEOUT, TIMEOUT = 52, 99, 78, 13
  local RESPONSE_CODE = 2097154

  -- Numbers passed through setopt's "..." have to be C longs.
  local function long(n) return ffi.cast("long", n) end

  -- Answers like the https module: the status code and body, or 0 and why.
  local function request(url, options)
    options = options or {}
    local handle = curl.curl_easy_init()
    if handle == nil then return 0, "curl_easy_init failed" end
    local chunks = {}
    local write = ffi.cast("andys_curl_write", function(data, size, count)
      local n = tonumber(size * count)
      chunks[#chunks + 1] = ffi.string(data, n)
      return n
    end)
    local headers = nil
    for key, value in pairs(options.headers or {}) do
      headers = curl.curl_slist_append(headers, key .. ": " .. tostring(value))
    end
    curl.curl_easy_setopt(handle, URL, url)
    curl.curl_easy_setopt(handle, WRITEFUNCTION, write)
    curl.curl_easy_setopt(handle, FOLLOWLOCATION, long(1))
    curl.curl_easy_setopt(handle, NOSIGNAL, long(1))
    curl.curl_easy_setopt(handle, ACCEPT_ENCODING, "")
    curl.curl_easy_setopt(handle, CONNECTTIMEOUT, long(15))
    curl.curl_easy_setopt(handle, TIMEOUT, long(60))
    if headers ~= nil then curl.curl_easy_setopt(handle, HTTPHEADER, headers) end
    if options.data then
      curl.curl_easy_setopt(handle, POSTFIELDSIZE, long(#options.data))
      curl.curl_easy_setopt(handle, POSTFIELDS, options.data)
    end
    if options.method then curl.curl_easy_setopt(handle, CUSTOMREQUEST, options.method) end
    local result = curl.curl_easy_perform(handle)
    local status = ffi.new("long[1]")
    if result == 0 then curl.curl_easy_getinfo(handle, RESPONSE_CODE, status) end
    curl.curl_easy_cleanup(handle)
    curl.curl_slist_free_all(headers)
    write:free()
    if result ~= 0 then return 0, ffi.string(curl.curl_easy_strerror(result)) end
    return tonumber(status[0]), table.concat(chunks)
  end
  -- LuaJIT can't call back into Lua (the write function) from compiled code.
  jit.off(request)

  return { request = request }
  ]==]

  local NETWORK_THREAD = [==[
  local has_https, https = pcall(loadstring((...)))
  local requests = love.thread.getChannel("andys_link_requests")
  local responses = love.thread.getChannel("andys_link_responses")

  while true do
    local request = requests:demand()
    local code, body
    if has_https then
      local headers = { ["Content-Type"] = "application/json", ["User-Agent"] = "andys-mods" }
      if request.token then headers["Authorization"] = "Bearer " .. request.token end
      local ok, c, b = pcall(https.request, request.url, { method = "POST", headers = headers, data = request.body })
      if ok then code, body = c, b else code, body = 0, tostring(c) end
    else
      code, body = 0, tostring(https)
    end
    responses:push({ id = request.id, code = code or 0, body = body or "" })
  end
  ]==]

  local requests = love.thread.getChannel("andys_link_requests")
  local responses = love.thread.getChannel("andys_link_responses")
  -- Kept referenced so the thread is never garbage collected.
  AndysLink.thread = love.thread.newThread(NETWORK_THREAD)
  AndysLink.thread:start(AndysLink.HTTPS)

  local callbacks, next_id = {}, 1

  -- POSTs `fields` as JSON to `path` on the server, with the game's token
  -- once linked, then calls on_done(code, body) from the game's update. code
  -- is 0 when the request didn't get an answer at all. A 401 means the site
  -- unlinked the game, so the link is dropped before on_done.
  function AndysLink.post(path, fields, on_done)
    local id = next_id
    next_id = next_id + 1
    local token = saved.token
    callbacks[id] = function(code, body)
      if code == 401 and token and token == saved.token then unlinked("Unlinked on the site. Press Link to link again.") end
      if on_done then on_done(code, body) end
    end
    requests:push({ id = id, url = SERVER .. path, body = AndysLink.encode(fields or {}), token = token })
  end

  local function receive()
    while true do
      local response = responses:pop()
      if not response then return end
      local on_done = callbacks[response.id]
      callbacks[response.id] = nil
      if on_done then on_done(response.code, response.body) end
    end
  end

  -- Linking -------------------------------------------------------------------

  -- What the mods' settings tabs show. Their text nodes follow these fields.
  AndysLink.status = { line = "", code = "", hint = "", link_button = "Link" }

  -- { code, secret, url, next_poll, waiting } while a code is showing.
  local link = nil
  -- Until when copying the code says so.
  local copied_until = 0

  function AndysLink.showing_code()
    return link ~= nil and link.code ~= nil
  end

  local function start_link()
    if link and link.waiting then return end
    link = { waiting = true }
    message = "Asking for a code..."
    AndysLink.post("/api/game/link", {}, function(code, body)
      local link_code, secret = AndysLink.field(body, "code"), AndysLink.field(body, "secret")
      if code ~= 200 or not link_code or not secret then
        link = nil
        message = "Couldn't reach the site" .. (code ~= 0 and " (" .. code .. ")" or "")
        print("[andys-link] link failed: " .. tostring(code) .. " " .. tostring(body))
        return
      end
      message = nil
      link = {
        code = link_code,
        secret = secret,
        url = AndysLink.field(body, "url") or (SERVER .. "/link"),
        next_poll = love.timer.getTime() + LINK_POLL_SECONDS,
      }
    end)
  end

  -- The page to type the code on, with the code filled in.
  local function open_link_page()
    love.system.openURL(link.url .. "?code=" .. link.code)
  end

  -- "Link", or "Open the page" while a code is showing.
  function AndysLink.press_link()
    if AndysLink.showing_code() then open_link_page() else start_link() end
  end

  -- So it can be pasted on the site.
  function AndysLink.copy_code()
    if not AndysLink.showing_code() then return end
    love.system.setClipboardText(link.code)
    copied_until = love.timer.getTime() + 2
  end

  function AndysLink.just_copied()
    return love.timer.getTime() < copied_until
  end

  local function poll_link(now)
    if not link or link.waiting or not link.secret or now < link.next_poll then return end
    link.waiting = true
    AndysLink.post("/api/game/link-status", { secret = link.secret }, function(code, body)
      if not link then return end
      link.waiting = false
      link.next_poll = love.timer.getTime() + LINK_POLL_SECONDS
      local status = AndysLink.field(body, "status")
      if code == 200 and status == "linked" then
        saved = { token = AndysLink.field(body, "token"), login = AndysLink.field(body, "login") }
        save()
        link, message = nil, nil
        changed()
      elseif code == 200 and status == "expired" then
        link = nil
        message = "The code expired. Press Link for a new one."
      end
    end)
  end

  -- Every frame ---------------------------------------------------------------

  local function update_status()
    local status = AndysLink.status
    if AndysLink.showing_code() then
      status.line = "Type this code on the site:"
      status.code = link.code
      status.hint = AndysLink.host .. "/link"
      status.link_button = "Open the page"
    elseif AndysLink.is_linked() then
      status.line = "Linked to " .. tostring(saved.login)
      status.code = ""
      status.hint = ""
      status.link_button = "Link again"
    else
      status.line = message or "Not linked"
      status.code = ""
      status.hint = "Press Link, then type the code on " .. AndysLink.host
      status.link_button = "Link"
    end
  end

  local update_ref = Game.update
  function Game:update(dt)
    update_ref(self, dt)
    receive()
    poll_link(love.timer.getTime())
    update_status()
  end
end
