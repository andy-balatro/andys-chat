-- Stacks skip tags up the left margin instead of the right one, so something can sit in the
-- bottom-right corner (e.g. a chat panel) without covering them. Tags that follow each other and
-- are the same can be collapsed into one with a count.
--
-- Andy's Chat comes with a copy of this mod, so both can be installed: the first copy in the
-- game's main.lua runs, and the other skips itself.

-- Lovely appends this to the game's main.lua, so the block keeps these locals out of the
-- game's and other mods' way.
if not LeftTags then
  LeftTags = {}

  -- Small enough to fit between the window's edge and the HUD at 16:9.
  local TAG_SIZE = 0.6
  -- Game:start_run puts the HUD's left edge this far into the left margin.
  local HUD_LEFT = -0.7

  -- A tag UIBox is 0.05 of padding around its sprite.
  local TAG_WIDTH = TAG_SIZE + 0.1

  -- Orbital Tags level up different hands, so they're only the same if the hand is.
  local function same_tag(a, b)
    return a and b and a.key == b.key and (a.ability or {}).orbital_hand == (b.ability or {}).orbital_hand
  end

  -- The game hides a tag while it's being used, then removes it. Only boxes hidden here are
  -- shown again, so a tag that's being used stays hidden.
  local function set_shown(box, shown)
    if shown then
      if box.left_tags_hidden then
        box.states.visible = true
        box.left_tags_hidden = nil
      end
    elseif box.states.visible then
      box.states.visible = false
      box.left_tags_hidden = true
    end
  end

  -- The count sits on the sprite's bottom-right corner. As the sprite's child it's drawn over
  -- it, only while the sprite is, and removed with it.
  local function set_count(box, count)
    local sprite = box.left_tags_sprite
    if not sprite or (box.left_tags_count or 1) == count then return end
    box.left_tags_count = count
    if sprite.children.left_tags_count then sprite.children.left_tags_count:remove() end
    sprite.children.left_tags_count = nil
    if count < 2 then return end
    local badge = UIBox({
      definition = { n = G.UIT.ROOT, config = { align = "cm", padding = 0.03, r = 0.05, colour = G.C.BLACK }, nodes = {
        { n = G.UIT.T, config = { text = "x" .. count, scale = 0.28, colour = G.C.WHITE, shadow = true } },
      } },
      config = { align = "bri", offset = { x = 0.04, y = 0.04 }, parent = sprite },
    })
    badge.states.collide.can = false
    sprite.children.left_tags_count = badge
  end

  -- Stacks the tags up from the bottom of the left margin. With collapsing on, a run of the same
  -- tag shows only its first one, with the count. It's the one the game uses first, so the next
  -- one takes its place. The others sit hidden behind it, where the game's "used" text covers.
  -- Bonds are Weak so tags slide to their new places: with a Strong bond the drawn box only
  -- follows offset changes while its anchor moves, and the room stands still.
  function LeftTags.layout()
    if not (G.HUD_tags and G.GAME and G.GAME.tags) then return end
    local tag_of = {}
    for _, tag in ipairs(G.GAME.tags) do
      if tag.HUD_tag then tag_of[tag.HUD_tag] = tag end
    end

    local below
    local i = 1
    while i <= #G.HUD_tags do
      local first = G.HUD_tags[i]
      local last = i
      if LeftTags.settings.collapse then
        while G.HUD_tags[last + 1] and same_tag(tag_of[first], tag_of[G.HUD_tags[last + 1]]) do last = last + 1 end
      end

      if below then
        first:set_alignment({ major = below, type = "tm", offset = { x = 0, y = 0 }, bond = "Weak" })
      else
        first:set_alignment({
          major = G.ROOM_ATTACH,
          type = "bli",
          offset = { x = HUD_LEFT - 0.05 - TAG_WIDTH, y = 0 },
          bond = "Weak",
        })
      end
      set_shown(first, true)
      set_count(first, last - i + 1)

      for k = i + 1, last do
        local box = G.HUD_tags[k]
        box:set_alignment({ major = first, type = "cm", offset = { x = 0, y = 0 }, bond = "Weak" })
        set_shown(box, false)
        set_count(box, 1)
      end

      below = first
      i = last + 1
    end
  end

  -- The game's add_tag, except that the first tag is anchored in the left margin and tags are
  -- smaller. It's created in place, since a box created in the right margin would slide over.
  function add_tag(_tag)
    G.HUD_tags = G.HUD_tags or {}
    local tag_sprite_ui, tag_sprite = _tag:generate_UI(TAG_SIZE)
    -- Its tooltip opens to the right, see Node:hover below.
    tag_sprite.config.left_tags_hud_tag = true
    local previous = G.HUD_tags[#G.HUD_tags]
    local box = UIBox({
      definition = { n = G.UIT.ROOT, config = { align = "cm", padding = 0.05, colour = G.C.CLEAR }, nodes = {
        tag_sprite_ui,
      } },
      config = previous and { align = "tm", offset = { x = 0, y = 0 }, major = previous } or {
        align = "bli",
        offset = { x = HUD_LEFT - 0.05 - TAG_WIDTH, y = 0 },
        major = G.ROOM_ATTACH,
      },
    })
    -- Other screens make their own sprites for the same tag, so _tag.tag_sprite can change.
    box.left_tags_sprite = tag_sprite
    G.HUD_tags[#G.HUD_tags + 1] = box
    discover_card(G.P_TAGS[_tag.key])

    for i = 1, #G.GAME.tags do
      G.GAME.tags[i]:apply_to_run({ type = "tag_add", tag = _tag })
    end

    G.GAME.tags[#G.GAME.tags + 1] = _tag
    _tag.HUD_tag = box

    LeftTags.layout()
    -- A tag that joins a collapsed one shows as its count going up.
    if box.left_tags_hidden and box.role.major and box.role.major.left_tags_sprite then
      box.role.major.left_tags_sprite:juice_up()
    end
  end

  -- The game opens a tag's tooltip to its left, which is off screen now. Its hover handler sets
  -- where the tooltip goes right before calling Node.hover, which creates it.
  local node_hover_ref = Node.hover
  function Node:hover(...)
    if self.config and self.config.left_tags_hud_tag and self.config.h_popup_config then
      self.config.h_popup_config.align = "cr"
      self.config.h_popup_config.offset = { x = 0.1, y = 0 }
    end
    return node_hover_ref(self, ...)
  end

  -- Using up a tag re-anchors the next one, the first one to the right margin.
  local remove_ref = Tag.remove
  function Tag:remove(...)
    local result = remove_ref(self, ...)
    LeftTags.layout()
    return result
  end
end
