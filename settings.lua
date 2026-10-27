-- The "Chat" tab of the game's settings menu (Options → Settings): the
-- channel, the panel's height, keyboard shortcuts for the streamer, and
-- linking the game for channel point redemptions.
-- A shortcut is a set of keys held together, like Cartomancer's: click its
-- button, press the keys, and letting go of one saves it. Escape clears it.
do
  local ACTIONS = {
    { name = "toggle_chat", label = "Show/hide chat", default = { f7 = true }, run = function() AndysChat.toggle() end },
    { name = "clear_chat", label = "Clear chat", default = { f8 = true }, run = function() AndysChat.clear() end },
  }

  local keybinds = AndysChat.settings.keybinds
  for _, action in ipairs(ACTIONS) do
    if type(keybinds[action.name]) ~= "table" then keybinds[action.name] = action.default end
  end

  -- Keybinds ------------------------------------------------------------------

  local MODIFIERS = { lctrl = 1, rctrl = 1, lshift = 2, rshift = 2, lalt = 3, ralt = 3, lgui = 4, rgui = 4 }

  -- "LCTRL+F7", modifiers first.
  local function keys_text(keys)
    local list = {}
    for key in pairs(keys) do list[#list + 1] = key end
    if #list == 0 then return "None" end
    table.sort(list, function(a, b)
      local ma, mb = MODIFIERS[a] or 5, MODIFIERS[b] or 5
      if ma ~= mb then return ma < mb end
      return a < b
    end)
    return string.upper(table.concat(list, "+"))
  end

  local function is_held(controller, keys)
    if next(keys) == nil then return false end
    for key in pairs(keys) do
      if not controller.held_keys[key] then return false end
    end
    return true
  end

  -- Actions that ran and whose keys haven't all been let go of yet, so holding
  -- the keys runs them once.
  local active = {}

  -- The keybind being set: { name, label, element, keys }. Its keys don't
  -- reach the game.
  local recording

  local function stop_recording(keys)
    if keys then
      keybinds[recording.name] = keys
      AndysChat.save_settings()
    end
    recording.label.text = keys_text(keybinds[recording.name])
    recording = nil
  end

  -- Leaving the tab or the menu removes the button, which cancels recording.
  local function check_recording()
    if recording and (recording.element.REMOVED or not G.OVERLAY_MENU) then recording = nil end
  end

  local key_press_ref = Controller.key_press
  function Controller:key_press(key)
    check_recording()
    if recording then
      if key == "escape" then
        stop_recording({})
      else
        recording.keys[key] = true
        recording.label.text = keys_text(recording.keys)
      end
      return
    end

    key_press_ref(self, key)
    -- Typing a seed or the channel shouldn't trigger shortcuts.
    if self.text_input_hook then return end
    for _, action in ipairs(ACTIONS) do
      if not active[action.name] and is_held(self, keybinds[action.name]) then
        active[action.name] = true
        action.run()
      end
    end
  end

  local key_release_ref = Controller.key_release
  function Controller:key_release(key)
    key_release_ref(self, key)
    check_recording()
    if recording and recording.keys[key] then stop_recording(recording.keys) end
    for _, action in ipairs(ACTIONS) do
      if not is_held(self, keybinds[action.name]) then active[action.name] = nil end
    end
  end

  -- Channel -------------------------------------------------------------------

  -- What the channel box shows. The channel changes once typing stops
  -- (Enter, Esc or clicking elsewhere), not on every letter.
  local channel_input = { text = AndysChat.settings.channel }
  local typing = false

  local function is_typing_channel()
    local hook = G.CONTROLLER and G.CONTROLLER.text_input_hook
    return hook ~= nil and hook.config.ref_table and hook.config.ref_table.andys_chat_channel == true
  end

  -- The game turns a typed 0 into an o (its seeds have no zeros), but
  -- channels can have them.
  local text_input_key_ref = G.FUNCS.text_input_key
  G.FUNCS.text_input_key = function(args)
    if not (args and args.key == "0" and is_typing_channel()) then return text_input_key_ref(args) end
    local text = G.CONTROLLER.text_input_hook.config.ref_table.text
    if #text.ref_table[text.ref_value] >= 25 then return end
    TRANSPOSE_TEXT_INPUT(0)
    MODIFY_TEXT_INPUT({ letter = "0", text_table = text, pos = text.current_position + 1 })
    TRANSPOSE_TEXT_INPUT(1)
  end

  -- Height --------------------------------------------------------------------

  -- Set while the slider is being dragged, and saved once it's let go.
  local height_changed = false

  G.FUNCS.andys_chat_height = function(slider)
    AndysChat.set_height(slider.ref_table[slider.ref_value])
    height_changed = true
  end

  -- Link ----------------------------------------------------------------------

  -- Text the tab shows besides AndysLink.status. Its text nodes follow these.
  local status = { second_button = "", redemptions = "" }

  G.FUNCS.andys_chat_link = function()
    AndysLink.press_link()
  end

  -- Copies the code while one shows, and otherwise opens the site, where
  -- redemptions are turned on.
  G.FUNCS.andys_chat_second = function()
    if AndysLink.showing_code() then AndysLink.copy_code() else love.system.openURL(AndysLink.server) end
  end

  local function update_status()
    if AndysLink.showing_code() then
      status.second_button = AndysLink.just_copied() and "Copied!" or "Copy code"
    else
      status.second_button = "Open the site"
    end
    if not AndysLink.is_linked() then
      status.redemptions = "Link to show channel point redemptions too"
    elseif AndysChat.redemptions then
      status.redemptions = "Showing channel point redemptions"
    else
      status.redemptions = "Turn on redemptions on " .. AndysLink.host .. " to show them"
    end
  end

  local update_ref = Game.update
  function Game:update(dt)
    update_ref(self, dt)
    local now_typing = is_typing_channel()
    if typing and not now_typing then channel_input.text = AndysChat.set_channel(channel_input.text) end
    typing = now_typing
    if height_changed and not (G.CONTROLLER and G.CONTROLLER.dragging.target) then
      height_changed = false
      AndysChat.save_settings()
    end
    update_status()
  end

  -- Settings tab --------------------------------------------------------------

  local LABEL_WIDTH = 2.6
  local CONTROL_WIDTH = 4.2

  local function text(value, scale, colour)
    return { n = G.UIT.T, config = { text = value, scale = scale, colour = colour or G.C.UI.TEXT_LIGHT, shadow = true } }
  end

  local function ref_text(ref_table, field, scale, colour)
    return { n = G.UIT.T, config = { ref_table = ref_table, ref_value = field, scale = scale, colour = colour or G.C.UI.TEXT_LIGHT, shadow = true } }
  end

  local function centred_row(node, padding)
    return { n = G.UIT.R, config = { align = "cm", padding = padding or 0.03 }, nodes = { node } }
  end

  -- A label on the left and a control on the right, like the game's settings.
  local function setting_row(label, control)
    return {
      n = G.UIT.R,
      config = { align = "cm", padding = 0.06 },
      nodes = {
        { n = G.UIT.C, config = { align = "cl", minw = LABEL_WIDTH }, nodes = { text(label, 0.4) } },
        { n = G.UIT.C, config = { align = "cm", minw = CONTROL_WIDTH }, nodes = { control } },
      },
    }
  end

  G.FUNCS.andys_chat_record_keybind = function(e)
    check_recording()
    if recording then stop_recording() end
    local ref = e.config.ref_table
    recording = { name = ref.name, label = ref.label, element = e, keys = {} }
    ref.label.text = "Press keys..."
  end

  local function keybind_button(action)
    local label = { text = keys_text(keybinds[action.name]) }
    return {
      n = G.UIT.C,
      config = {
        align = "cm",
        minw = CONTROL_WIDTH,
        minh = 0.55,
        r = 0.1,
        colour = G.C.RED,
        hover = true,
        shadow = true,
        button = "andys_chat_record_keybind",
        ref_table = { name = action.name, label = label },
      },
      nodes = { ref_text(label, "text", 0.4) },
    }
  end

  local function button(field, func, colour)
    return {
      n = G.UIT.C,
      config = { align = "cm", minw = 3.2, minh = 0.6, r = 0.1, colour = colour, hover = true, shadow = true, button = func },
      nodes = { ref_text(field.table, field.value, 0.4) },
    }
  end

  local function settings_tab_contents()
    channel_input.text = AndysChat.settings.channel
    local rows = {
      setting_row("Channel", create_text_input({
        w = CONTROL_WIDTH - 0.2,
        h = 0.55,
        max_length = 25,
        extended_corpus = true,
        prompt_text = AndysLink.login() or "Your Twitch name",
        ref_table = channel_input,
        ref_value = "text",
        andys_chat_channel = true,
      })),
      setting_row("Height", create_slider({
        w = CONTROL_WIDTH - 1.1,
        h = 0.4,
        min = AndysChat.MIN_HEIGHT,
        max = AndysChat.MAX_HEIGHT,
        ref_table = AndysChat.settings,
        ref_value = "height",
        callback = "andys_chat_height",
      })),
    }
    for _, action in ipairs(ACTIONS) do rows[#rows + 1] = setting_row(action.label, keybind_button(action)) end
    local hints = {
      "Leave the channel empty for the linked account's.",
      "Click a shortcut, then press its keys. Esc clears it.",
    }
    for _, hint in ipairs(hints) do rows[#rows + 1] = centred_row(text(hint, 0.3, G.C.UI.TEXT_INACTIVE), 0.02) end
    rows[#rows + 1] = { n = G.UIT.R, config = { minh = 0.2 } }
    rows[#rows + 1] = centred_row(ref_text(AndysLink.status, "line", 0.4))
    rows[#rows + 1] = centred_row(ref_text(AndysLink.status, "code", 0.8, G.C.GOLD))
    rows[#rows + 1] = centred_row(ref_text(AndysLink.status, "hint", 0.3, G.C.UI.TEXT_INACTIVE))
    rows[#rows + 1] = {
      n = G.UIT.R,
      config = { align = "cm", padding = 0.1 },
      nodes = {
        button({ table = AndysLink.status, value = "link_button" }, "andys_chat_link", G.C.RED),
        { n = G.UIT.C, config = { minw = 0.2 } },
        button({ table = status, value = "second_button" }, "andys_chat_second", G.C.BLUE),
      },
    }
    rows[#rows + 1] = centred_row(ref_text(status, "redemptions", 0.3, G.C.UI.TEXT_INACTIVE))
    return { n = G.UIT.ROOT, config = { align = "cm", padding = 0.05, colour = G.C.CLEAR }, nodes = rows }
  end

  -- lovely.toml adds this to the tabs of the game's settings menu.
  function AndysChat.settings_tab()
    return { label = "Chat", tab_definition_function = settings_tab_contents }
  end
end
