-- Andy's Chat: shows a Twitch chat in the bottom-right corner, where the deck
-- normally sits. The deck still works but is hidden under the panel, so a
-- button at the bottom of the panel (deck name and cards left) opens the
-- deck view instead, and shows the deck preview when hovered.
-- Keys set in the settings menu (F7 and F8 by default) hide the panel,
-- showing the deck again, and clear the chat. The panel's height is set there
-- too, and so is the channel, which is the linked Twitch account's unless
-- another is typed in.
--
-- Chat is read anonymously over Twitch IRC on a background thread, so a slow
-- or dead connection never stalls the game. Channel point redemptions, which
-- anonymous chat can't see, come from bot.andy-balatro.com once the game is
-- linked (andys_link.lua).

-- Wrapped in do ... end, like the other files, since lovely.toml appends them
-- all to the game's main.lua, whose locals are limited.
do
local SETTINGS_FILE = "config/andys-chat.jkr"

local CHAT_THREAD = [==[
local socket = require("socket")
require("love.timer")
local inbox = love.thread.getChannel("andys_chat_inbox")
-- The channel to show, sent by the game whenever it changes. "" for none.
local channels = love.thread.getChannel("andys_chat_channel")

-- Tag values write spaces as \s, semicolons as \: and so on.
local TAG_ESCAPES = { s = " ", [":"] = ";", ["\\"] = "\\", r = "\r", n = "\n" }

-- Twitch pings about every 5 minutes, so longer silence means a dead connection.
local SILENCE_SECONDS = 360

-- "@tags :prefix COMMAND params" -> tags, prefix, command, params
local function parse(line)
  local tags = {}
  if line:sub(1, 1) == "@" then
    local raw
    raw, line = line:match("^@(%S+) (.*)$")
    if not raw then return end
    for key, value in raw:gmatch("([^;=]+)=([^;]*)") do
      tags[key] = value:gsub("\\(.?)", function(c) return TAG_ESCAPES[c] or c end)
    end
  end
  local prefix, command, params = line:match("^:(%S+) (%S+) ?(.*)$")
  if not prefix then command, params = line:match("^(%S+) ?(.*)$") end
  return tags, prefix or "", command, params or ""
end

local function handle(tcp, line)
  local tags, prefix, command, params = parse(line)
  if command == "PING" then
    tcp:send("PONG " .. params .. "\r\n")
  elseif command == "JOIN" then
    inbox:push({ kind = "status", text = "connected" })
  elseif command == "ROOMSTATE" then
    -- The channel's user ID, for its FrankerFaceZ, BetterTTV and 7TV emotes.
    if tags["room-id"] then inbox:push({ kind = "room", id = tags["room-id"] }) end
  elseif command == "NOTICE" and tags["msg-id"] == "msg_channel_suspended" then
    -- Also what Twitch says for channels that don't exist.
    inbox:push({ kind = "status", text = "missing" })
  elseif command == "PRIVMSG" or command == "USERNOTICE" then
    -- USERNOTICE is a sub, raid, watch streak and so on, with an optional
    -- message from the viewer.
    local notice = command == "USERNOTICE"
    local text = params:match("^%S+ :(.*)$") or ""
    local action = text:match("^\1ACTION (.*)\1$")
    local name = tags["display-name"]
    if not name or name == "" then name = prefix:match("^([^!]+)") or "?" end
    local msg_id = tags["msg-id"]
    -- Notices from other channels in a shared chat keep their kind here.
    if msg_id == "sharedchatnotice" then msg_id = tags["source-msg-id"] end
    -- A gift of several subs is followed by a notice for each one.
    if msg_id == "subgift" and tags["msg-param-community-gift-id"] then return end
    inbox:push({
      kind = "message",
      id = tags.id,
      user_id = tags["user-id"],
      name = name,
      color = tags.color,
      -- "id:from-to,from-to/id:from-to", in code points of the text.
      emotes = tags.emotes,
      text = action or text,
      action = action ~= nil,
      notice = notice,
      msg_id = msg_id,
      -- What Twitch says happened, e.g. "x subscribed at Tier 1."
      system = tags["system-msg"],
      announcement_colour = tags["msg-param-color"],
      bits = tonumber(tags.bits or ""),
      -- Set when the message came with a channel points redemption.
      reward_id = tags["custom-reward-id"],
      first = tags["first-msg"] == "1",
      -- The message this one replies to. Its text starts with "@<their name> ".
      reply_id = tags["reply-parent-msg-id"],
      reply_login = tags["reply-parent-user-login"],
      reply_name = tags["reply-parent-display-name"],
      reply_body = tags["reply-parent-msg-body"],
    })
  elseif command == "CLEARMSG" then
    inbox:push({ kind = "delete", id = tags["target-msg-id"] })
  elseif command == "CLEARCHAT" then
    -- Without a target user the whole chat was cleared.
    inbox:push({ kind = "clear", user_id = tags["target-user-id"] })
  elseif command == "RECONNECT" then
    return "Twitch asked to reconnect"
  end
end

-- The newest channel the game sent, or nil if it sent none.
local function newest_channel()
  local newest
  while true do
    local name = channels:pop()
    if name == nil then return newest end
    newest = name
  end
end

-- Reads `name`'s chat until the connection drops, which returns why, or the
-- game picks another channel, which returns that channel too.
local function read_chat(name)
  local tcp = socket.tcp()
  tcp:settimeout(10)
  local ok, err = tcp:connect("irc.chat.twitch.tv", 6667)
  if not ok then return err end
  -- justinfanNNNNN is Twitch's anonymous, read-only login.
  tcp:send("CAP REQ :twitch.tv/tags twitch.tv/commands\r\n")
  tcp:send("NICK justinfan" .. math.random(10000, 99999) .. "\r\n")
  tcp:send("JOIN #" .. name .. "\r\n")
  -- Short waits, so a new channel is picked up quickly. A line cut off by
  -- one is carried into the next.
  tcp:settimeout(1)
  local partial, heard = "", love.timer.getTime()
  while true do
    local line, receive_err, rest = tcp:receive("*l", partial)
    local stop
    if line then
      partial, heard = "", love.timer.getTime()
      stop = handle(tcp, line)
    elseif receive_err == "timeout" then
      if rest and rest ~= partial then heard = love.timer.getTime() end
      partial = rest or ""
      local next_name = newest_channel()
      if next_name and next_name ~= name then
        tcp:close()
        return "switching channel", next_name
      end
      if love.timer.getTime() - heard > SILENCE_SECONDS then stop = "no answer from Twitch" end
    else
      stop = receive_err
    end
    if stop then
      tcp:close()
      return stop
    end
  end
end

math.randomseed(os.time())
local name = ""
while true do
  name = newest_channel() or name
  if name == "" then
    inbox:push({ kind = "status", text = "no channel" })
    name = channels:demand()
  else
    inbox:push({ kind = "status", text = "connecting" })
    local ok, why, next_name = pcall(read_chat, name)
    if ok and next_name then
      name = next_name
    else
      print("[andys-chat] chat disconnected: " .. tostring(why))
      love.timer.sleep(5)
    end
  end
end
]==]

-- JSON text -> Lua value (null becomes nil). Kept as source so the emote
-- thread can load it too.
local JSON_DECODER = [==[
local ESCAPES = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function utf8_char(c)
  if c < 0x80 then return string.char(c) end
  if c < 0x800 then return string.char(0xC0 + math.floor(c / 0x40), 0x80 + c % 0x40) end
  if c < 0x10000 then
    return string.char(0xE0 + math.floor(c / 0x1000), 0x80 + math.floor(c / 0x40) % 0x40, 0x80 + c % 0x40)
  end
  return string.char(0xF0 + math.floor(c / 0x40000), 0x80 + math.floor(c / 0x1000) % 0x40,
    0x80 + math.floor(c / 0x40) % 0x40, 0x80 + c % 0x40)
end

return function(s)
  local pos = 1
  local function fail() error("bad JSON at byte " .. pos) end
  local function skip() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
  local function char() return s:sub(pos, pos) end

  local function str()
    local parts = {}
    pos = pos + 1
    while true do
      local _, to, chunk, stop = s:find('^([^"\\]*)(["\\])', pos)
      if not to then fail() end
      parts[#parts + 1] = chunk
      pos = to + 1
      if stop == '"' then return table.concat(parts) end
      local escape = char()
      if escape == "u" then
        local code = tonumber(s:sub(pos + 1, pos + 4), 16) or fail()
        pos = pos + 5
        -- Characters past U+FFFF come as a pair of surrogates.
        local low = code >= 0xD800 and code < 0xDC00 and s:match("^\\u(%x%x%x%x)", pos)
        if low then
          code = 0x10000 + (code - 0xD800) * 0x400 + (tonumber(low, 16) - 0xDC00)
          pos = pos + 6
        end
        parts[#parts + 1] = utf8_char(code)
      else
        parts[#parts + 1] = ESCAPES[escape] or escape
        pos = pos + 1
      end
    end
  end

  local value
  -- Calls item() for each element of an object or array, until `close`.
  local function each(close, item)
    pos = pos + 1
    skip()
    if char() == close then pos = pos + 1; return end
    while true do
      item()
      skip()
      local separator = char()
      pos = pos + 1
      if separator == close then return end
      if separator ~= "," then fail() end
    end
  end

  function value()
    skip()
    local c = char()
    if c == "{" then
      local object = {}
      each("}", function()
        skip()
        if char() ~= '"' then fail() end
        local key = str()
        skip()
        if char() ~= ":" then fail() end
        pos = pos + 1
        object[key] = value()
      end)
      return object
    elseif c == "[" then
      local array, n = {}, 0
      each("]", function()
        n = n + 1
        array[n] = value()
      end)
      return array
    elseif c == '"' then
      return str()
    end
    local literal = s:match("^[%w%.%+%-]+", pos) or fail()
    pos = pos + #literal
    if literal == "true" then return true end
    if literal == "false" then return false end
    if literal == "null" then return nil end
    return tonumber(literal) or fail()
  end

  return value()
end
]==]

-- Downloads emote images one at a time, off the main thread. "https" is the
-- module Balatro ships for its own requests. Ids starting with "emoji:" are
-- Twemoji images of Unicode emoji, "ffz:", "bttv:" and "7tv:" are
-- FrankerFaceZ, BetterTTV and 7TV emotes, "cheer:" are cheermotes, the rest
-- are Twitch emotes. "sets:<channel user ID>" asks for the names of the
-- FrankerFaceZ, BetterTTV and 7TV emotes usable in that channel instead.
local EMOTE_THREAD = [==[
local json_decoder = ...
local decode_json = loadstring(json_decoder)()
-- Without it every emote fails, and chat shows their names instead.
local has_https, https = pcall(require, "https")
local bit = require("bit")
require("love.image")
require("love.filesystem")
local requests = love.thread.getChannel("andys_chat_emote_requests")
local results = love.thread.getChannel("andys_chat_emotes")

-- Long animations are cut short rather than taking up lots of memory.
local MAX_FRAMES = 200

local function url(id)
  local kind, rest = id:match("^(%w+):(.+)$")
  if kind == "emoji" then return "https://cdn.jsdelivr.net/gh/jdecked/twemoji@17.0.3/assets/72x72/" .. rest .. ".png" end
  -- "2x" is a GIF for animated emotes and a PNG for the rest.
  if kind == "bttv" then return "https://cdn.betterttv.net/emote/" .. rest .. "/2x" end
  -- "<id>/2x.gif" or "<id>/2x.png": 7TV's default is WebP, which LOVE can't read.
  if kind == "7tv" then return "https://cdn.7tv.app/emote/" .. rest end
  -- "<id>/animated/2.gif" or "<id>/2", a PNG.
  if kind == "ffz" then return "https://cdn.frankerfacez.com/emote/" .. rest end
  -- "<prefix>/<tier>". Only Twitch's own cheermotes are here; a channel's
  -- custom ones fail, and show as text.
  if kind == "cheer" then
    local prefix, tier = rest:match("^(.+)/(%d+)$")
    return "https://d3aqoihi2n8ty8.cloudfront.net/actions/" .. prefix .. "/dark/animated/" .. tier .. "/2.gif"
  end
  -- "default" is a GIF for animated emotes and a PNG for the rest.
  return "https://static-cdn.jtvnw.net/emoticons/v2/" .. id .. "/default/dark/2.0"
end

local function get_json(link)
  if not has_https then error(https) end
  local code, body = https.request(link)
  if code ~= 200 then error("HTTP " .. tostring(code)) end
  return decode_json(body)
end

-- BetterTTV doesn't mark the emotes drawn over the one before, so clients
-- list them by name.
local BTTV_OVERLAYS = {
  SoSnowy = true, IceCold = true, SantaHat = true, TopHat = true,
  ReinDeer = true, CandyCane = true, cvMask = true, cvHazmat = true,
}

-- Emote name -> { id = emote id, overlay = whether it's drawn over the
-- emote before it }, for every FrankerFaceZ, BetterTTV and 7TV emote usable
-- in the channel.
local function emote_sets(room_id)
  local emotes = {}
  local function add_bttv(list)
    for _, emote in ipairs(list or {}) do
      -- Modifiers like "w!" change the next emote, and aren't images.
      if not emote.modifier then
        emotes[emote.code] = { id = "bttv:" .. emote.id, overlay = BTTV_OVERLAYS[emote.code] or false }
      end
    end
  end
  -- FrankerFaceZ sets are keyed by set ID.
  local function add_ffz(sets, ids)
    for _, id in ipairs(ids) do
      for _, emote in ipairs(sets[tostring(id)] and sets[tostring(id)].emoticons or {}) do
        -- Modifiers (ffzSpin and so on) are effects on the emote before them.
        if not emote.modifier then
          local file = emote.animated and "/animated/2.gif" or "/2"
          emotes[emote.name] = { id = "ffz:" .. emote.id .. file, overlay = false }
        end
      end
    end
  end
  local function add_7tv(set)
    for _, emote in ipairs(set and set.emotes or {}) do
      local file = emote.data and emote.data.animated and "/2x.gif" or "/2x.png"
      -- Flag 1 marks zero-width emotes.
      emotes[emote.name] = { id = "7tv:" .. emote.id .. file, overlay = (emote.flags or 0) % 2 == 1 }
    end
  end
  -- Later lists win: channel emotes over global ones, then 7TV over
  -- BetterTTV over FrankerFaceZ. A channel without one answers 404, so each
  -- list can fail.
  local lists = {
    function()
      local global = get_json("https://api.frankerfacez.com/v1/set/global")
      add_ffz(global.sets, global.default_sets)
    end,
    function() add_bttv(get_json("https://api.betterttv.net/3/cached/emotes/global")) end,
    function() add_7tv(get_json("https://7tv.io/v3/emote-sets/global")) end,
    function()
      local room = get_json("https://api.frankerfacez.com/v1/room/id/" .. room_id)
      local ids = {}
      for id in pairs(room.sets) do ids[#ids + 1] = id end
      add_ffz(room.sets, ids)
    end,
    function()
      local user = get_json("https://api.betterttv.net/3/cached/users/twitch/" .. room_id)
      add_bttv(user.sharedEmotes)
      add_bttv(user.channelEmotes)
    end,
    function() add_7tv(get_json("https://7tv.io/v3/users/twitch/" .. room_id).emote_set) end,
  }
  for _, add in ipairs(lists) do
    local ok, err = pcall(add)
    if not ok then print("[andys-chat] emote list failed: " .. tostring(err)) end
  end
  return emotes
end

-- GIF image data -> palette indices, one per pixel, row by row.
local function lzw_decode(data, min_size, pixel_count)
  local clear = bit.lshift(1, min_size)
  local finish = clear + 1
  -- Each code stands for the string prev's string + suffix.
  local prefix, suffix, first, length = {}, {}, {}, {}
  for i = 0, clear - 1 do suffix[i], first[i], length[i] = i, i, 1 end
  local size, next_code, prev = min_size + 1, clear + 2, nil
  local out, n = {}, 0
  local bits, bit_count, pos = 0, 0, 1
  while n < pixel_count do
    while bit_count < size do
      local byte = data:byte(pos)
      if not byte then return out end
      bits = bits + bit.lshift(byte, bit_count)
      pos, bit_count = pos + 1, bit_count + 8
    end
    local code = bit.band(bits, bit.lshift(1, size) - 1)
    bits, bit_count = bit.rshift(bits, size), bit_count - size
    if code == clear then
      size, next_code, prev = min_size + 1, clear + 2, nil
    elseif code == finish then
      break
    else
      local new_code, extra = code, nil
      -- The one code the decoder can't know yet: prev's string + its first byte.
      if prev and code == next_code then code, extra = prev, first[prev] end
      if not length[code] then break end
      local c = code
      for i = n + length[code], n + 1, -1 do
        out[i] = suffix[c]
        c = prefix[c]
      end
      n = n + length[code]
      if extra then n = n + 1; out[n] = extra end
      if prev and next_code < 4096 then
        prefix[next_code], suffix[next_code] = prev, first[code]
        first[next_code], length[next_code] = first[prev], length[prev] + 1
        next_code = next_code + 1
        if next_code == bit.lshift(1, size) and size < 12 then size = size + 1 end
      end
      prev = new_code
    end
  end
  return out
end

-- Interlaced images store rows 0, 8, 16..., then 4, 12..., then 2, 6...,
-- then 1, 3...
local function row_order(height, interlaced)
  local rows = {}
  if not interlaced then
    for y = 0, height - 1 do rows[#rows + 1] = y end
    return rows
  end
  for _, pass in ipairs({ { 0, 8 }, { 4, 8 }, { 2, 4 }, { 1, 2 } }) do
    for y = pass[1], height - 1, pass[2] do rows[#rows + 1] = y end
  end
  return rows
end

-- A GIF -> its fully drawn frames as ImageData, and how long each shows, in
-- seconds.
local function decode_gif(s)
  local pos = 7
  local function u8() pos = pos + 1; return s:byte(pos - 1) end
  local function u16() pos = pos + 2; return s:byte(pos - 2) + s:byte(pos - 1) * 256 end
  local function palette(size)
    local colours = {}
    for i = 0, size - 1 do
      local r, g, b = s:byte(pos + i * 3, pos + i * 3 + 2)
      colours[i] = { r / 255, g / 255, b / 255 }
    end
    pos = pos + size * 3
    return colours
  end
  local function sub_blocks()
    local parts = {}
    while true do
      local size = u8()
      if not size or size == 0 then return table.concat(parts) end
      parts[#parts + 1] = s:sub(pos, pos + size - 1)
      pos = pos + size
    end
  end

  local width, height, flags = u16(), u16(), u8()
  pos = pos + 2
  local global = bit.band(flags, 0x80) ~= 0 and palette(bit.lshift(2, bit.band(flags, 7))) or nil
  local canvas = love.image.newImageData(width, height)
  local frames, delays = {}, {}
  local delay, disposal, transparent = 0, 0, nil

  while #frames < MAX_FRAMES do
    local block = u8()
    if block == 0x21 then
      local label = u8()
      local body = sub_blocks()
      if label == 0xF9 and #body >= 4 then
        local packed = body:byte(1)
        disposal = bit.band(bit.rshift(packed, 2), 7)
        delay = body:byte(2) + body:byte(3) * 256
        transparent = bit.band(packed, 1) ~= 0 and body:byte(4) or nil
      end
    elseif block == 0x2C then
      local left, top, w, h, image_flags = u16(), u16(), u16(), u16(), u8()
      local colours = bit.band(image_flags, 0x80) ~= 0 and palette(bit.lshift(2, bit.band(image_flags, 7))) or global
      local min_size = u8()
      local pixels = lzw_decode(sub_blocks(), min_size, w * h)
      local previous = disposal == 3 and canvas:clone()
      local i = 0
      for _, y in ipairs(row_order(h, bit.band(image_flags, 0x40) ~= 0)) do
        for x = 0, w - 1 do
          local index = pixels[i + x + 1]
          local colour = index and index ~= transparent and colours and colours[index]
          local cx, cy = left + x, top + y
          if colour and cx < width and cy < height then
            canvas:setPixel(cx, cy, colour[1], colour[2], colour[3], 1)
          end
        end
        i = i + w
      end
      frames[#frames + 1] = canvas:clone()
      -- Browsers play delays this short at 10 frames a second.
      delays[#delays + 1] = delay <= 1 and 0.1 or delay / 100
      if disposal == 2 then
        for y = top, math.min(top + h, height) - 1 do
          for x = left, math.min(left + w, width) - 1 do canvas:setPixel(x, y, 0, 0, 0, 0) end
        end
      elseif disposal == 3 then
        canvas = previous
      end
      delay, disposal, transparent = 0, 0, nil
    else
      -- 0x3B ends the file; anything else means it's broken.
      break
    end
  end
  if #frames == 0 then error("GIF has no frames") end
  return frames, delays
end

local function download(id)
  if not has_https then error(https) end
  local code, body = https.request(url(id))
  if code ~= 200 then error("HTTP " .. tostring(code)) end
  if body:sub(1, 4) == "GIF8" then return decode_gif(body) end
  return { love.image.newImageData(love.filesystem.newFileData(body, "emote.png")) }, { 1 }
end

while true do
  local id = requests:demand()
  local room_id = id:match("^sets:(.+)$")
  if room_id then
    results:push({ id = id, sets = emote_sets(room_id) })
  else
    local ok, frames, delays = pcall(download, id)
    if not ok then print("[andys-chat] emote " .. id .. " failed: " .. tostring(frames)) end
    results:push({ id = id, frames = ok and frames or nil, delays = ok and delays or nil })
  end
end
]==]

local utf8 = require("utf8")
local decode_json = loadstring(JSON_DECODER)()
local inbox = love.thread.getChannel("andys_chat_inbox")
local channel_requests = love.thread.getChannel("andys_chat_channel")
local emote_requests = love.thread.getChannel("andys_chat_emote_requests")
local emote_results = love.thread.getChannel("andys_chat_emotes")
local MAX_MESSAGES = 50
-- The panel's height setting, in % of the tallest it gets.
local MIN_HEIGHT, MAX_HEIGHT = 30, 100

-- Settings ------------------------------------------------------------------

-- { channel = Twitch login, "" for the linked account's, height = see
-- MIN_HEIGHT, keybinds = see settings.lua }
local function load_settings()
  local ok, saved = pcall(function()
    local file = love.filesystem.read(SETTINGS_FILE)
    return file and STR_UNPACK(file)
  end)
  local settings = ok and type(saved) == "table" and saved or {}
  if type(settings.channel) ~= "string" or not settings.channel:match("^[a-z0-9_]*$") then settings.channel = "" end
  if type(settings.height) ~= "number" then settings.height = MAX_HEIGHT end
  settings.height = math.min(MAX_HEIGHT, math.max(MIN_HEIGHT, settings.height))
  if type(settings.keybinds) ~= "table" then settings.keybinds = {} end
  return settings
end

-- channel: the one being shown ("" for none); status: "no channel",
-- "connecting", "connected" or "missing" (no such channel); redemptions:
-- whether the site says they're on.
AndysChat = { messages = {}, channel = "", status = "no channel", visible = true, redemptions = false }
AndysChat.settings = load_settings()

function AndysChat.save_settings()
  if not love.filesystem.getInfo("config") then love.filesystem.createDirectory("config") end
  love.filesystem.write(SETTINGS_FILE, STR_PACK(AndysChat.settings))
end

-- Kept referenced so the thread objects are never garbage collected.
AndysChat.thread = love.thread.newThread(CHAT_THREAD)
AndysChat.thread:start()
AndysChat.emote_thread = love.thread.newThread(EMOTE_THREAD)
AndysChat.emote_thread:start(JSON_DECODER)

-- The channel typed in the settings, or else the linked account's.
local function wanted_channel()
  if AndysChat.settings.channel ~= "" then return AndysChat.settings.channel end
  return AndysLink.login() or ""
end

-- Tells the chat thread when the channel to show changes. A new channel
-- starts with an empty panel.
local function follow_channel()
  local wanted = wanted_channel()
  if wanted == AndysChat.channel then return end
  AndysChat.channel = wanted
  AndysChat.messages = {}
  channel_requests:push(wanted)
end

-- "#Andy_Balatro", "twitch.tv/andy_balatro" and so on -> "andy_balatro".
function AndysChat.set_channel(text)
  local login = tostring(text or ""):lower():gsub("^.*/", ""):gsub("[^a-z0-9_]", ""):sub(1, 25)
  AndysChat.settings.channel = login
  AndysChat.save_settings()
  follow_channel()
  return login
end

-- Emote id -> { frames = Images, delays = seconds each, duration = total
-- seconds }, "loading", or false when the download failed.
local emote_images = {}
-- Bumped when an emote loads or fails, so messages lay it out at its width,
-- or as its name instead.
local emote_version = 0
-- FrankerFaceZ, BetterTTV and 7TV emotes by name, as { id, overlay } (see
-- EMOTE_THREAD).
-- Asked for once the channel's user ID is known, and again after reconnecting
-- to pick up new ones.
local named_emotes = {}
local named_emotes_room = nil

local function emote_image(id)
  if emote_images[id] == nil then
    emote_images[id] = "loading"
    emote_requests:push(id)
  end
  return emote_images[id]
end

-- Every copy of an animated emote plays in step, like on Twitch.
local function current_frame(emote)
  local t = love.timer.getTime() % emote.duration
  for i, delay in ipairs(emote.delays) do
    if t < delay then return emote.frames[i] end
    t = t - delay
  end
  return emote.frames[#emote.frames]
end

local function receive_emotes()
  while true do
    local result = emote_results:pop()
    if not result then return end
    if result.sets then
      named_emotes = result.sets
    elseif result.frames then
      local frames, duration = {}, 0
      for i, data in ipairs(result.frames) do
        local image = love.graphics.newImage(data, { mipmaps = true })
        -- Emotes are drawn much smaller than they are, so smooth them.
        image:setFilter("linear", "linear")
        image:setMipmapFilter("linear")
        frames[i] = image
        duration = duration + result.delays[i]
      end
      emote_images[result.id] = { frames = frames, delays = result.delays, duration = duration }
      emote_version = emote_version + 1
    else
      emote_images[result.id] = false
      emote_version = emote_version + 1
    end
  end
end

-- Twitch's picks for users who never chose a colour. Any stable pick works.
local DEFAULT_COLOURS = {
  "FF0000", "0000FF", "008000", "B22222", "FF7F50", "9ACD32", "FF4500", "2E8B57",
  "DAA520", "D2691E", "5F9EA0", "1E90FF", "FF69B4", "8A2BE2", "00FF7F",
}

local function name_colour(hex, name)
  hex = hex and hex:match("^#(%x%x%x%x%x%x)$")
  if not hex then
    local sum = 0
    for i = 1, #name do sum = sum + name:byte(i) end
    hex = DEFAULT_COLOURS[sum % #DEFAULT_COLOURS + 1]
  end
  local colour = HEX(hex)
  -- Dark names are unreadable on the dark panel.
  local luminance = 0.299 * colour[1] + 0.587 * colour[2] + 0.114 * colour[3]
  if luminance < 0.45 then colour = mix_colours(G.C.WHITE, colour, 0.45) end
  return colour
end

-- Symbols below U+1F000 that are emoji even without U+FE0F after them. The
-- rest (hearts, arrows, (c) and so on) are text unless U+FE0F follows.
local EMOJI_PRESENTATION = {
  { 0x231A, 0x231B }, { 0x23E9, 0x23EC }, { 0x23F0, 0x23F0 }, { 0x23F3, 0x23F3 }, { 0x25FD, 0x25FE },
  { 0x2614, 0x2615 }, { 0x2648, 0x2653 }, { 0x267F, 0x267F }, { 0x2693, 0x2693 }, { 0x26A1, 0x26A1 },
  { 0x26AA, 0x26AB }, { 0x26BD, 0x26BE }, { 0x26C4, 0x26C5 }, { 0x26CE, 0x26CE }, { 0x26D4, 0x26D4 },
  { 0x26EA, 0x26EA }, { 0x26F2, 0x26F3 }, { 0x26F5, 0x26F5 }, { 0x26FA, 0x26FA }, { 0x26FD, 0x26FD },
  { 0x2705, 0x2705 }, { 0x270A, 0x270B }, { 0x2728, 0x2728 }, { 0x274C, 0x274C }, { 0x274E, 0x274E },
  { 0x2753, 0x2755 }, { 0x2757, 0x2757 }, { 0x2795, 0x2797 }, { 0x27B0, 0x27B0 }, { 0x27BF, 0x27BF },
  { 0x2B1B, 0x2B1C }, { 0x2B50, 0x2B50 }, { 0x2B55, 0x2B55 },
}

local function is_keycap_base(c)
  return c == 0x23 or c == 0x2A or (c >= 0x30 and c <= 0x39)
end

local function is_flag_letter(c)
  return c and c >= 0x1F1E6 and c <= 0x1F1FF
end

local function starts_emoji(codes, i)
  local c, after = codes[i], codes[i + 1]
  if c >= 0x1F000 and c <= 0x1FAFF then return true end
  if is_keycap_base(c) then return after == 0x20E3 or (after == 0xFE0F and codes[i + 2] == 0x20E3) end
  if after == 0xFE0F and c >= 0xA9 then return true end
  for _, range in ipairs(EMOJI_PRESENTATION) do
    if c >= range[1] and c <= range[2] then return true end
  end
  return false
end

-- How many code points the emoji at i takes: two flag letters, or emoji with
-- their modifiers (U+FE0F, skin tones, keycap, tags), joined by U+200D.
local function emoji_length(codes, i)
  if is_flag_letter(codes[i]) then return is_flag_letter(codes[i + 1]) and 2 or 1 end
  local j = i
  while true do
    j = j + 1
    local c = codes[j]
    while c and (c == 0xFE0F or c == 0x20E3 or (c >= 0x1F3FB and c <= 0x1F3FF) or (c >= 0xE0020 and c <= 0xE007F)) do
      j = j + 1
      c = codes[j]
    end
    if not (c == 0x200D and codes[j + 1] and codes[j + 1] >= 0x2000) then return j - i end
    j = j + 1
  end
end

-- Splits text into { text = ... } and { emote = "emoji:<twemoji name>", text =
-- the emoji } parts. Phones send plain Unicode emoji, which the chat fonts
-- can't draw.
local function split_emoji(text)
  local codes, starts = {}, {}
  for pos, code in utf8.codes(text) do
    codes[#codes + 1], starts[#starts + 1] = code, pos
  end
  starts[#codes + 1] = #text + 1

  local parts, i, text_from = {}, 1, 1
  while i <= #codes do
    if starts_emoji(codes, i) then
      local last = i + emoji_length(codes, i) - 1
      if text_from < i then parts[#parts + 1] = { text = text:sub(starts[text_from], starts[i] - 1) } end
      -- Twemoji names leave out U+FE0F, except in sequences joined by U+200D.
      local joined = false
      for k = i, last do joined = joined or codes[k] == 0x200D end
      local name = {}
      for k = i, last do
        if joined or codes[k] ~= 0xFE0F then name[#name + 1] = string.format("%x", codes[k]) end
      end
      parts[#parts + 1] = { emote = "emoji:" .. table.concat(name, "-"), text = text:sub(starts[i], starts[last + 1] - 1) }
      i, text_from = last + 1, last + 1
    else
      i = i + 1
    end
  end
  if text_from <= #codes then parts[#parts + 1] = { text = text:sub(starts[text_from]) } end
  return parts
end

-- Bits tiers, highest first, with the colour Twitch writes their amount in.
local CHEER_TIERS = {
  { 100000, "F3A71A" }, { 10000, "F43021" }, { 5000, "0099FE" }, { 1000, "1DB2A5" }, { 100, "9C3EE8" }, { 1, "979797" },
}

-- "Cheer100" -> a part for the cheermote's image, named by its prefix, with
-- the amount to write after it. nil for words that aren't a cheer.
local function cheermote(word)
  local prefix, amount = word:match("^(%w-%a)(%d+)$")
  if not prefix or tonumber(amount) < 1 then return end
  for _, tier in ipairs(CHEER_TIERS) do
    if tonumber(amount) >= tier[1] then
      return { emote = "cheer:" .. prefix:lower() .. "/" .. tier[1], text = prefix, amount = amount, amount_colour = tier[2] }
    end
  end
end

-- Splits text into { text = ... } and { emote = id, text = name, overlay = ...
-- } parts for FrankerFaceZ, BetterTTV and 7TV emotes, which are whole words,
-- cheermotes when `cheers` is set, and Unicode emoji.
local function split_named_emotes(text, cheers)
  local parts, pending, pos = {}, "", 1
  local function flush()
    for _, part in ipairs(split_emoji(pending)) do parts[#parts + 1] = part end
    pending = ""
  end
  while true do
    local _, to, space, word = text:find("^(%s*)(%S+)", pos)
    if not to then break end
    local emote = named_emotes[word]
    local cheer = cheers and cheermote(word)
    if emote or cheer then
      pending = pending .. space
      flush()
      parts[#parts + 1] = cheer or { emote = emote.id, text = word, overlay = emote.overlay }
    else
      pending = pending .. space .. word
    end
    pos = to + 1
  end
  pending = pending .. text:sub(pos)
  flush()
  return parts
end

-- Splits text into { text = ... } and { emote = id, text = name } parts, using
-- the emotes tag's code point ranges, then FrankerFaceZ, BetterTTV and 7TV
-- emotes, cheermotes and Unicode emoji in the rest. Ranges that overlap or run
-- past the text are ignored. `shift` is how many code points were cut from
-- the start of the text the ranges count in (a reply's "@name ").
local function split_emotes(text, emotes_tag, cheers, shift)
  local ranges = {}
  for id, positions in (emotes_tag or ""):gmatch("([%w_]+):([^/]+)") do
    for from, to in positions:gmatch("(%d+)%-(%d+)") do
      ranges[#ranges + 1] = { id = id, from = tonumber(from) - (shift or 0), to = tonumber(to) - (shift or 0) }
    end
  end
  table.sort(ranges, function(a, b) return a.from < b.from end)

  local parts, length, next_char = {}, utf8.len(text), 0
  -- Code points count from 0 in the tag, so code point i starts at this byte.
  local function byte_of(i) return utf8.offset(text, i + 1) end
  local function add_text(s)
    for _, part in ipairs(split_named_emotes(s, cheers)) do parts[#parts + 1] = part end
  end
  for _, range in ipairs(ranges) do
    if range.from >= next_char and range.from <= range.to and range.to < length then
      if range.from > next_char then
        add_text(text:sub(byte_of(next_char), byte_of(range.from) - 1))
      end
      parts[#parts + 1] = { emote = range.id, text = text:sub(byte_of(range.from), byte_of(range.to + 1) - 1) }
      next_char = range.to + 1
    end
  end
  if next_char < length then add_text(text:sub(byte_of(next_char))) end
  return parts
end

-- Adds text's words and emotes to atoms, each knowing whether a space comes
-- before it. Cheermotes (in messages with bits, `cheers`) are followed by
-- their amount, so one that fails to load still reads "Cheer100".
local function add_words(atoms, text, emotes_tag, colour, cheers, shift)
  local space_before = true
  for _, part in ipairs(split_emotes(text, emotes_tag, cheers, shift)) do
    if part.emote then
      atoms[#atoms + 1] = { emote = part.emote, overlay = part.overlay, text = part.text, colour = colour, gap = space_before }
      if part.amount then
        atoms[#atoms + 1] = {
          text = part.amount, colour = HEX(part.amount_colour), gap = false, cheer = part.emote, plain_colour = colour,
        }
      end
      space_before = false
    else
      local first = true
      for gap, word in part.text:gmatch("(%s*)(%S+)") do
        atoms[#atoms + 1] = { text = word, colour = colour, gap = gap ~= "" or (first and space_before) }
        first = false
      end
      space_before = part.text:match("%s$") ~= nil
    end
  end
  return atoms
end

-- A message as the user's name, then its words and emotes.
local function message_atoms(m, colour, shift)
  -- /me messages are all in the user's colour, like on Twitch.
  local text_colour = m.action and colour or G.C.UI.TEXT_LIGHT
  local name = { text = m.name .. (m.action and "" or ":"), colour = colour }
  return add_words({ name }, m.text, m.emotes, text_colour, m.bits ~= nil, shift)
end

-- Events (subs, raids, redemptions and so on) are marked with a bar and a
-- tint in their colour, and a line saying what happened above the viewer's
-- message, if they sent one. Colours are names in G.C, which doesn't exist
-- yet when this file runs.
-- USERNOTICE msg-ids that aren't about subs, which are purple.
local NOTICE_ACCENTS = { raid = "ORANGE", viewermilestone = "GOLD", bitsbadgetier = "BLUE", announcement = "RED" }
-- Announcements' msg-param-color. PRIMARY, the channel's colour, is red.
local ANNOUNCEMENT_ACCENTS = { BLUE = "BLUE", GREEN = "GREEN", ORANGE = "ORANGE", PURPLE = "PURPLE" }

local function header_colour(accent)
  return mix_colours(G.C.WHITE, G.C[accent], 0.45)
end

-- An event line starting with the viewer's name, e.g. "x cheered 100 bits".
local function name_header(name, colour, text, accent)
  return add_words({ { text = name, colour = colour } }, text, nil, header_colour(accent))
end

-- Chat colours by user ID, for redemptions from the bot, which has none.
local user_colours = {}

local function push_message(message)
  local messages = AndysChat.messages
  messages[#messages + 1] = message
  if #messages > MAX_MESSAGES then table.remove(messages, 1) end
end

-- The newest of the last `depth` (10 by default) messages that matches, e.g.
-- for joining a redemption from the site with its message from chat. Either
-- can come first.
local function find_recent(matches, depth)
  local messages = AndysChat.messages
  for i = #messages, math.max(1, #messages - (depth or 10) + 1), -1 do
    if matches(messages[i]) then return messages[i] end
  end
end

-- A reply starts with "@<their name> ", which its reply line says instead.
-- Returns that start, if it's there.
local function reply_mention(m)
  for _, name in ipairs({ m.reply_login or "", m.reply_name or "" }) do
    local mention = "@" .. name .. " "
    if name ~= "" and m.text:sub(1, #mention):lower() == mention:lower() then return mention end
  end
end

-- The line above a reply: "@name: their message", in grey and cut short to
-- fit (see layout). The message replied to brings its own emotes if it's
-- still in chat, since Twitch only sends where emotes are with the message.
local function reply_atoms(m)
  local colour = G.C.JOKER_GREY
  local replied_to = m.reply_id and find_recent(function(other) return other.id == m.reply_id end, MAX_MESSAGES)
  local source = replied_to and replied_to.source
  if not source then
    local body = m.reply_body
    source = { text = body:match("^\1ACTION (.*)\1$") or body }
  end
  local name = { text = "@" .. m.reply_name .. ":", colour = colour }
  return add_words({ name }, source.text, source.emotes, colour, false, source.shift)
end

local function add_message(m)
  -- LOVE errors on drawing invalid UTF-8, so such messages are dropped.
  for _, text in ipairs({ m.name, m.text, m.system or "", m.reply_name or "", m.reply_body or "" }) do
    if not utf8.len(text) then return end
  end
  if m.user_id and m.color and m.color ~= "" then user_colours[m.user_id] = m.color end
  local colour = name_colour(m.color, m.name)
  local message = { id = m.id, user_id = m.user_id }
  local shift = 0
  if m.reply_name and m.reply_body then
    local mention = reply_mention(m)
    if mention then
      m.text = m.text:sub(#mention + 1)
      shift = utf8.len(mention)
    end
    message.reply = reply_atoms(m)
  end
  -- For replies to this message.
  message.source = { text = m.text, emotes = m.emotes, shift = shift }
  if m.text:find("%S") then message.body = message_atoms(m, colour, shift) end

  local accent
  if m.notice then
    if m.msg_id == "announcement" then
      accent = ANNOUNCEMENT_ACCENTS[m.announcement_colour] or "RED"
    else
      accent = NOTICE_ACCENTS[m.msg_id] or "PURPLE"
    end
    local system = m.system and m.system:find("%S") and m.system or (m.msg_id == "announcement" and "Announcement")
    if system then message.header = add_words({}, system, nil, header_colour(accent)) end
  elseif m.bits then
    accent = "BLUE"
    message.header = name_header(m.name, colour, "cheered " .. m.bits .. (m.bits == 1 and " bit" or " bits"), accent)
  elseif m.reward_id then
    local redemption = find_recent(function(other)
      return other.awaiting_reward == m.reward_id and other.user_id == m.user_id
    end)
    if redemption then
      redemption.id, redemption.body, redemption.awaiting_reward, redemption.wrap = m.id, message.body, nil, nil
      return
    end
    accent, message.reward_id = "GREEN", m.reward_id
  elseif m.msg_id == "highlighted-my-message" then
    accent = "GREEN"
  elseif m.first then
    accent = "ETERNAL"
    message.header = add_words({}, "First message", nil, header_colour(accent))
  end
  if not (message.header or message.body) then return end
  message.accent = accent and G.C[accent]
  push_message(message)
end

-- An event from the site. Only channel point redemptions so far: anonymous
-- chat sees just the ones with a message, without the reward's name.
local function add_chat_event(event)
  if event.kind ~= "redeem" or type(event.user) ~= "string" or type(event.title) ~= "string" then return end
  if not (utf8.len(event.user) and utf8.len(event.title)) then return end
  local colour = name_colour(user_colours[event.user_id], event.user)
  local header = name_header(event.user, colour, "redeemed " .. event.title, "GREEN")
  if event.has_input then
    local message = find_recent(function(other)
      return other.reward_id == event.reward_id and other.user_id == event.user_id and not other.header
    end)
    if message then
      message.header, message.wrap = header, nil
      return
    end
  end
  push_message({
    user_id = event.user_id,
    accent = G.C.GREEN,
    header = header,
    -- Its message from chat joins it when it comes.
    awaiting_reward = event.has_input and event.reward_id or nil,
  })
end

-- Drops messages a moderator deleted, or all of a banned user's messages.
local function remove_messages(matches)
  local kept = {}
  for _, message in ipairs(AndysChat.messages) do
    if not matches(message) then kept[#kept + 1] = message end
  end
  AndysChat.messages = kept
end

local function receive_chat()
  while true do
    local m = inbox:pop()
    if not m then return end
    if m.kind == "message" then
      add_message(m)
    elseif m.kind == "status" then
      AndysChat.status = m.text
      if m.text == "connecting" then named_emotes_room = nil end
    elseif m.kind == "room" then
      -- Every mode change repeats the room ID, so it's only asked for once.
      if m.id ~= named_emotes_room then
        named_emotes_room = m.id
        emote_requests:push("sets:" .. m.id)
      end
    elseif m.kind == "delete" then
      remove_messages(function(message) return m.id and message.id == m.id end)
    elseif m.kind == "clear" then
      remove_messages(function(message) return not m.user_id or message.user_id == m.user_id end)
    end
  end
end

-- Asked for every few seconds while they're on, and now and then while
-- they're off, to see whether they've been turned on.
local REDEMPTIONS_POLL_SECONDS = 2
local REDEMPTIONS_OFF_POLL_SECONDS = 30
local next_redemptions_poll = 0
local asking_for_redemptions = false
-- The site numbers them; it's asked for the ones after the last that came.
local last_redemption = 0

local function poll_redemptions(now)
  if asking_for_redemptions or now < next_redemptions_poll or not AndysLink.is_linked() then return end
  asking_for_redemptions = true
  AndysLink.post("/api/game/chat-events", { after = last_redemption }, function(code, body)
    asking_for_redemptions = false
    local ok, answer = pcall(decode_json, body)
    if code ~= 200 or not ok or type(answer) ~= "table" then
      if code ~= 0 and code ~= 429 then print("[andys-chat] redemptions failed: " .. tostring(code) .. " " .. tostring(body)) end
      AndysChat.redemptions = false
      next_redemptions_poll = love.timer.getTime() + (code == 429 and REDEMPTIONS_POLL_SECONDS or REDEMPTIONS_OFF_POLL_SECONDS)
      return
    end
    AndysLink.set_login(answer.login)
    AndysChat.redemptions = answer.redemptions == true
    next_redemptions_poll = love.timer.getTime()
      + (AndysChat.redemptions and REDEMPTIONS_POLL_SECONDS or REDEMPTIONS_OFF_POLL_SECONDS)
    for _, event in ipairs(type(answer.events) == "table" and answer.events or {}) do
      if type(event) == "table" and type(event.id) == "number" and event.id > last_redemption then
        last_redemption = event.id
        add_chat_event(event)
      end
    end
  end)
end

-- A game linked or unlinked can change the channel, and whether there are
-- redemptions to ask for.
AndysLink.on_change(function(linked)
  next_redemptions_poll = 0
  if not linked then AndysChat.redemptions = false end
end)

-- In tiles, the game's layout unit.
local LINE_HEIGHT = 0.27
local MESSAGE_GAP = 0.08
local SHADOW_OFFSET = 0.025
-- Events: the bar on their left, how far their text is indented, and the
-- tint's margin above and below the text.
local ACCENT_BAR = 0.04
local ACCENT_INDENT = 0.1
local ACCENT_PADDING = 0.04
-- Replies: how far the reply line is indented, past the elbow drawn from it
-- down to the message, and how thick the elbow is.
local REPLY_INDENT = 0.16
local REPLY_ELBOW_X = 0.05
local REPLY_ELBOW_WIDTH = 0.02

local chat_font
local function get_chat_font()
  if not chat_font then
    -- The game renders its fonts this large and scales them down when drawing.
    local size = G.TILESIZE * 10
    chat_font = love.graphics.newFont("resources/fonts/m6x11plus.ttf", size)
    -- m6x11 has no Cyrillic, CJK and so on; GoNoto covers most of them.
    chat_font:setFallbacks(love.graphics.newFont("resources/fonts/GoNotoCurrent-Bold.ttf", size))
  end
  return chat_font
end

-- Splits a word too wide for a whole line into pieces that fit.
local function break_word(font, word, wrap)
  if font:getWidth(word) <= wrap then return { word } end
  local pieces, piece = {}, ""
  for _, code in utf8.codes(word) do
    local char = utf8.char(code)
    if piece ~= "" and font:getWidth(piece .. char) > wrap then
      pieces[#pieces + 1] = piece
      piece = ""
    end
    piece = piece .. char
  end
  pieces[#pieces + 1] = piece
  return pieces
end

-- Places a message's event line and words and emotes in lines at most `wrap`
-- wide, in unscaled font pixels. Emotes are as tall as a line, and square
-- until they load (FrankerFaceZ, BetterTTV, 7TV and cheer ones can be
-- wider); one that failed to download is shown as its name. Overlay emotes go
-- on top of the emote before them. Runs of same-coloured words become one
-- text.
local function layout(message, font, wrap)
  local emote_size, space = font:getHeight(), font:getWidth(" ")
  local items, x, line = {}, 0, 0
  local function start_of(gap)
    return (x > 0 and gap) and x + space or x
  end
  local function place(width, gap)
    local start = start_of(gap)
    if x > 0 and start + width > wrap then line, start = line + 1, 0 end
    x = start + width
    return start
  end
  -- Runs of same-coloured words on a line become one text. `spaced` says
  -- whether a space comes before the piece.
  local function add_text(colour, piece, start, spaced)
    local last = items[#items]
    if last and last.text and last.line == line and last.text[1] == colour then
      last.text[2] = last.text[2] .. (spaced and " " or "") .. piece
    else
      items[#items + 1] = { text = { colour, piece }, x = start, line = line }
    end
  end
  -- With `cut`, atoms stay on one line: the first one that doesn't fit is
  -- cut short with "...", and the rest are left out.
  local function place_atoms(atoms, cut)
    local limit = cut and wrap - font:getWidth("...") or wrap
    local function cut_here(colour, text, gap)
      local start, shortened = start_of(gap), ""
      for _, code in utf8.codes(text) do
        local char = utf8.char(code)
        if start + font:getWidth(shortened .. char) > limit then break end
        shortened = shortened .. char
      end
      add_text(colour, shortened .. "...", start, start > x)
    end
    for _, atom in ipairs(atoms) do
      local emote = atom.emote and emote_image(atom.emote)
      local last = items[#items]
      if emote ~= nil and emote ~= false and atom.overlay and last and last.emote then
        items[#items + 1] = { emote = atom.emote, x = last.x, w = last.w, line = last.line }
      elseif emote ~= nil and emote ~= false then
        local w = emote_size
        if emote ~= "loading" then
          local image = emote.frames[1]
          w = math.min(wrap, emote_size * image:getWidth() / image:getHeight())
        end
        if cut and start_of(atom.gap) + w > limit then return cut_here(atom.colour, "", atom.gap) end
        items[#items + 1] = { emote = atom.emote, x = place(w, atom.gap), w = w, line = line }
      else
        -- A word that only looked like a cheer reads as plain text.
        local colour = atom.cheer and emote_image(atom.cheer) == false and atom.plain_colour or atom.colour
        for i, piece in ipairs(cut and { atom.text } or break_word(font, atom.text, wrap)) do
          local gap = i == 1 and atom.gap
          if cut and start_of(gap) + font:getWidth(piece) > limit then return cut_here(colour, piece, gap) end
          local previous_x = x
          local start = place(font:getWidth(piece), gap)
          add_text(colour, piece, start, start > previous_x)
        end
      end
    end
  end
  local function next_line()
    if #items > 0 then line, x = line + 1, 0 end
  end
  place_atoms(message.header or {})
  if message.reply then
    next_line()
    message.reply_line = line
    x = REPLY_INDENT * font:getHeight() / LINE_HEIGHT
    place_atoms(message.reply, true)
  end
  if message.body then next_line() end
  place_atoms(message.body or {})
  message.items = items
  message.height = (line + 1) * LINE_HEIGHT + (message.accent and 2 * ACCENT_PADDING or 0)
end

local function draw_message(message, font, scale, x, y)
  for _, item in ipairs(message.items) do
    local left, top = x + item.x * scale, y + item.line * LINE_HEIGHT
    if item.text then
      love.graphics.print(item.text, font, left, top, 0, scale, scale)
    else
      local emote = emote_image(item.emote)
      if emote and emote ~= "loading" then
        local image = current_frame(emote)
        local w, h = image:getDimensions()
        local box = item.w * scale
        local fit = math.min(LINE_HEIGHT / h, box / w)
        love.graphics.draw(image, left + (box - w * fit) / 2, top + (LINE_HEIGHT - h * fit) / 2, 0, fit, fit)
      end
    end
  end
end

-- A line from the left of the reply line down to the message, like an
-- arrow saying what it answers. Drawn in the current colour.
local function draw_reply_elbow(message, x, y)
  if not message.reply_line then return end
  local middle = y + (message.reply_line + 0.5) * LINE_HEIGHT
  local left = x + REPLY_ELBOW_X
  love.graphics.rectangle("fill", left, middle, REPLY_ELBOW_WIDTH, LINE_HEIGHT * 0.5)
  love.graphics.rectangle("fill", left, middle, REPLY_INDENT - REPLY_ELBOW_X - 0.03, REPLY_ELBOW_WIDTH)
end

-- The tint behind an event and the bar on its left.
local function draw_accent(message, width, y)
  local accent = message.accent
  love.graphics.setColor(accent[1], accent[2], accent[3], 0.15)
  love.graphics.rectangle("fill", 0, y, width, message.height)
  love.graphics.setColor(accent[1], accent[2], accent[3], 1)
  love.graphics.rectangle("fill", 0, y, ACCENT_BAR, message.height)
end

-- Draws the newest messages that fit, bottom-up, with the game's text shadow.
local ChatLog = Moveable:extend()

function ChatLog:init(w, h)
  Moveable.init(self, 0, 0, w, h)
  self.states.collide.can = false
  self.states.hover.can = false
  self.states.click.can = false
  self.states.drag.can = false
end

function ChatLog:draw()
  prep_draw(self, 1)
  local font = get_chat_font()
  local scale = LINE_HEIGHT / font:getHeight()
  -- Text wraps before scaling, so the limit is in unscaled font pixels.
  local wrap = self.T.w / scale
  local messages = AndysChat.messages

  if #messages == 0 then
    local status = AndysChat.status
    local text = (status == "no channel" or AndysChat.channel == "") and "Type your channel in Options > Settings > Chat"
      or status == "missing" and "There's no channel called #" .. AndysChat.channel
      or (status == "connected" and "Connected to #" or "Connecting to #") .. AndysChat.channel
    local _, lines = font:getWrap(text, wrap)
    love.graphics.setColor(G.C.UI.TEXT_INACTIVE)
    love.graphics.printf(text, font, 0, (self.T.h - #lines * LINE_HEIGHT) / 2, wrap, "center", 0, scale, scale)
  end

  local y = self.T.h
  for i = #messages, 1, -1 do
    local message = messages[i]
    local left = message.accent and ACCENT_INDENT or 0
    if message.wrap ~= wrap or message.emote_version ~= emote_version then
      layout(message, font, wrap - left / scale)
      message.wrap, message.emote_version = wrap, emote_version
    end
    if y < message.height then break end
    y = y - message.height
    local top = y
    if message.accent then
      draw_accent(message, self.T.w, y)
      top = y + ACCENT_PADDING
    end
    -- Colours are multiplied by the current colour, so this draws text and
    -- emotes black.
    love.graphics.setColor(0, 0, 0, 0.3)
    draw_reply_elbow(message, left + SHADOW_OFFSET, top + SHADOW_OFFSET)
    draw_message(message, font, scale, left + SHADOW_OFFSET, top + SHADOW_OFFSET)
    love.graphics.setColor(G.C.JOKER_GREY)
    draw_reply_elbow(message, left, top)
    love.graphics.setColor(1, 1, 1, 1)
    draw_message(message, font, scale, left, top)
    y = y - MESSAGE_GAP
  end
  love.graphics.pop()
end

-- The panel covers the deck's spot and the letterbox margin right of it,
-- from the bottom of the screen up to just under the consumables at its
-- tallest. The height setting makes it shorter.
-- In tiles, from the room's left edge: the hand ends at 17.15.
local PANEL_LEFT = 17.45
local TALLEST_CHAT = 6.6
local deck_label = { text = "" }

local function update_deck_label()
  if G.deck and G.playing_cards then
    deck_label.text = G.GAME.selected_back.loc_name .. " " .. #G.deck.cards .. "/" .. #G.playing_cards
  end
end

local function create_chat_panel()
  update_deck_label()
  -- G.ROOM_ORIG.x is the width of the letterbox margins.
  local right = G.TILE_W + G.ROOM_ORIG.x - 0.12
  local inner_width = right - PANEL_LEFT - 0.16
  return UIBox({
    definition = {
      n = G.UIT.ROOT,
      config = { align = "cm", padding = 0.08, r = 0.1, colour = G.C.DYN_UI.MAIN, emboss = 0.05 },
      nodes = {
        {
          n = G.UIT.R,
          config = { align = "cm", minw = inner_width, minh = 0.5, r = 0.1, colour = G.C.RED, emboss = 0.05 },
          nodes = {
            { n = G.UIT.T, config = { text = "Chat", scale = 0.45, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
          },
        },
        {
          n = G.UIT.R,
          config = { align = "cm", padding = 0.08, r = 0.1, colour = G.C.DYN_UI.BOSS_DARK },
          nodes = {
            { n = G.UIT.O, config = { object = ChatLog(inner_width - 0.16, TALLEST_CHAT * AndysChat.settings.height / 100) } },
          },
        },
        {
          n = G.UIT.R,
          config = {
            align = "cm",
            minw = inner_width,
            -- Shrinks long deck names instead of widening the panel.
            maxw = inner_width - 0.2,
            minh = 0.5,
            r = 0.1,
            colour = G.C.BLUE,
            id = "andys_chat_deck_button",
            button = "deck_info",
            hover = true,
            shadow = true,
          },
          nodes = {
            {
              n = G.UIT.T,
              config = { ref_table = deck_label, ref_value = "text", scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true },
            },
          },
        },
      },
    },
    config = { align = "bri", offset = { x = right - G.TILE_W, y = 0.3 }, major = G.ROOM_ATTACH },
  })
end

-- Saturn puts its shortcut indicators above whatever UIBox it is docked to,
-- or in the left margin when it isn't docked.
local function dock_saturn(box)
  if Saturn and Saturn.create_status_ui then
    Saturn.status_ui_dock = box
    Saturn.create_status_ui()
  end
end

-- The height the panel was made for, so a new setting rebuilds it.
local panel_height = nil

local function show_chat_panel()
  if AndysChat.panel or G.STAGE ~= G.STAGES.RUN or not G.deck then return end
  G.deck.states.visible = false
  AndysChat.panel = create_chat_panel()
  panel_height = AndysChat.settings.height
  dock_saturn(AndysChat.panel)
end

local function hide_chat_panel()
  if not AndysChat.panel then return end
  AndysChat.panel:remove()
  AndysChat.panel = nil
  if G.deck then G.deck.states.visible = true end
  dock_saturn(nil)
end

local start_run_ref = Game.start_run
function Game:start_run(args)
  start_run_ref(self, args)
  if AndysChat.visible then show_chat_panel() end
end

-- Leaving a run removes every UIBox it created, the panel included.
local delete_run_ref = Game.delete_run
function Game:delete_run(...)
  AndysChat.panel = nil
  if Saturn then Saturn.status_ui_dock = nil end
  return delete_run_ref(self, ...)
end

-- Streamer shortcuts, bound to keys in settings.lua. Chat keeps arriving
-- while it's hidden.
function AndysChat.toggle()
  AndysChat.visible = not AndysChat.visible
  if AndysChat.visible then show_chat_panel() else hide_chat_panel() end
end

function AndysChat.clear()
  AndysChat.messages = {}
end

-- From the height slider in settings.lua, which saves it once it's let go.
function AndysChat.set_height(height)
  AndysChat.settings.height = math.floor(math.min(MAX_HEIGHT, math.max(MIN_HEIGHT, height)) + 0.5)
end
AndysChat.MIN_HEIGHT, AndysChat.MAX_HEIGHT = MIN_HEIGHT, MAX_HEIGHT

local function follow_height()
  if AndysChat.panel and panel_height ~= AndysChat.settings.height then
    hide_chat_panel()
    show_chat_panel()
  end
end

-- The game shows the deck preview while the top deck card is hovered. Hover is
-- worked out at the end of each update and read in the next, so hovering the
-- button can count as hovering the hidden deck.
local function hover_deck_with_button()
  local button = AndysChat.panel and AndysChat.panel:get_UIE_by_ID("andys_chat_deck_button")
  local top_card = G.deck and G.deck.cards[1]
  if button and top_card and button.states.collide.is then
    top_card.states.collide.is = true
  end
end

local update_ref = Game.update
function Game:update(dt)
  update_ref(self, dt)
  follow_channel()
  follow_height()
  hover_deck_with_button()
  receive_chat()
  receive_emotes()
  poll_redemptions(love.timer.getTime())
  update_deck_label()
end
end
