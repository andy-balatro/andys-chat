-- The mod's settings, in a "Left Tags" tab of the game's settings menu: whether the same tags
-- collapse into one, and a shortcut that turns it on and off. A shortcut is a set of keys held
-- together, like Cartomancer's: click its button, press the keys, and letting go of one saves
-- it. Escape clears it.

-- Skipped by a second copy of the mod (see left_tags.lua), which finds the settings loaded.
if not LeftTags.settings then
  local SETTINGS_FILE = "config/left-tags.jkr"
  local DEFAULT_KEYBIND = { f6 = true }

  -- Settings ----------------------------------------------------------------

  local function load_settings()
    local ok, saved = pcall(function()
      local file = love.filesystem.read(SETTINGS_FILE)
      return file and STR_UNPACK(file)
    end)
    local settings = ok and type(saved) == "table" and saved or {}
    if type(settings.collapse) ~= "boolean" then settings.collapse = true end
    if type(settings.keybind) ~= "table" then settings.keybind = DEFAULT_KEYBIND end
    return settings
  end

  local function save_settings()
    if not love.filesystem.getInfo("config") then love.filesystem.createDirectory("config") end
    love.filesystem.write(SETTINGS_FILE, STR_PACK(LeftTags.settings))
  end

  LeftTags.settings = load_settings()

  local function toggle_collapse()
    LeftTags.settings.collapse = not LeftTags.settings.collapse
    save_settings()
    LeftTags.layout()
  end

  -- Keybind -----------------------------------------------------------------

  local MODIFIERS = { lctrl = 1, rctrl = 1, lshift = 2, rshift = 2, lalt = 3, ralt = 3, lgui = 4, rgui = 4 }

  -- "LCTRL+F6", modifiers first.
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

  -- Set when the shortcut ran and not all of its keys have been let go of yet, so holding the
  -- keys toggles once.
  local active = false

  -- The keybind being set: { label, element, keys }. Its keys don't reach the game.
  local recording

  local function stop_recording(keys)
    if keys then
      LeftTags.settings.keybind = keys
      save_settings()
    end
    recording.label.text = keys_text(LeftTags.settings.keybind)
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
    -- Typing a seed shouldn't trigger the shortcut.
    if self.text_input_hook then return end
    if not active and is_held(self, LeftTags.settings.keybind) then
      active = true
      toggle_collapse()
    end
  end

  local key_release_ref = Controller.key_release
  function Controller:key_release(key)
    key_release_ref(self, key)
    check_recording()
    if recording and recording.keys[key] then stop_recording(recording.keys) end
    if not is_held(self, LeftTags.settings.keybind) then active = false end
  end

  -- Settings tab ------------------------------------------------------------

  G.FUNCS.left_tags_record_keybind = function(e)
    check_recording()
    if recording then stop_recording() end
    local label = e.config.ref_table
    recording = { label = label, element = e, keys = {} }
    label.text = "Press keys..."
  end

  local function keybind_row()
    local label = { text = keys_text(LeftTags.settings.keybind) }
    return {
      n = G.UIT.R,
      config = { align = "cm", padding = 0.08 },
      nodes = {
        {
          n = G.UIT.C,
          config = { align = "cl", minw = 3.5 },
          nodes = { { n = G.UIT.T, config = { text = "Collapse shortcut", scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true } } },
        },
        {
          n = G.UIT.C,
          config = {
            align = "cm",
            minw = 3.5,
            minh = 0.6,
            r = 0.1,
            colour = G.C.RED,
            hover = true,
            shadow = true,
            button = "left_tags_record_keybind",
            ref_table = label,
          },
          nodes = {
            { n = G.UIT.T, config = { ref_table = label, ref_value = "text", scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
          },
        },
      },
    }
  end

  local function settings_tab_contents()
    return { n = G.UIT.ROOT, config = { align = "cm", padding = 0.05, colour = G.C.CLEAR }, nodes = {
      create_toggle({
        label = "Collapse the same tags",
        ref_table = LeftTags.settings,
        ref_value = "collapse",
        callback = function()
          save_settings()
          LeftTags.layout()
        end,
      }),
      {
        n = G.UIT.R,
        config = { align = "cm", padding = 0.05 },
        nodes = {
          { n = G.UIT.T, config = { text = "Only tags next to each other collapse, so their order stays.", scale = 0.32, colour = G.C.UI.TEXT_INACTIVE } },
        },
      },
      keybind_row(),
      {
        n = G.UIT.R,
        config = { align = "cm", padding = 0.2 },
        nodes = {
          { n = G.UIT.T, config = { text = "Click the shortcut, then press its keys. Esc clears it.", scale = 0.32, colour = G.C.UI.TEXT_INACTIVE } },
        },
      },
    } }
  end

  -- lovely.toml adds the tab to the game's settings menu. A second copy of the mod does too, so
  -- it's only added once.
  function LeftTags.add_settings_tab(tabs)
    for _, tab in ipairs(tabs) do
      if tab.left_tags then return end
    end
    tabs[#tabs + 1] = { label = "Left Tags", tab_definition_function = settings_tab_contents, left_tags = true }
  end
end
