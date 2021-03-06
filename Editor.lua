local BaseEditor = require "lualib.BaseEditor.BaseEditor"
local Connector = require "Connector"

local M = {}

local Editor = {}
local super = BaseEditor.class
setmetatable(Editor, { __index = super })

function M.new()
  local self = BaseEditor.new("beltlayer")
  self.valid_editor_types = { "transport-belt", "underground-belt" }
  return M.restore(self)
end

function M.restore(self)
  return setmetatable(self, { __index = Editor })
end

local debug = function() end
-- debug = log

local function find_in_area(args)
  local area = args.area
  if area.left_top.x >= area.right_bottom.x or area.left_top.y >= area.right_bottom.y then
    args.position = area.left_top
    args.area = nil
  end
  local surface = args.surface
  args.surface = nil
  return surface.find_entities_filtered(args)
end

local function is_connector_name(name)
  return name:find("%-beltlayer%-connector$")
end

local function is_connector(entity)
  return is_connector_name(entity.name)
end

local function is_connector_or_ghost(entity)
  return is_connector(entity) or (entity.name == "entity-ghost" and is_connector_name(entity.ghost_name))
end

local function is_surface_connector(self, entity)
  return is_connector(entity) and self:is_valid_aboveground_surface(entity.surface)
end

local function connector_in_area(surface, area)
  local entities = find_in_area{surface = surface, area = area}
  for _, entity in ipairs(entities) do
    if is_connector_or_ghost(entity) then
      return true
    end
  end
  return false
end

local function opposite_type(loader_type)
  if loader_type == "input" then
    return "output"
  end
  return "input"
end

local function surface_counterpart(entity)
  local editor_surface = self:editor_surface_for_aboveground_surface(entity.surface)
  if is_connector(entity) then
    return editor_surface.find_entity(entity.name, entity.position)
  end
  return editor_surface.find_entity("beltlayer-bpproxy-"..name, entity.position)
end

local function on_built_surface_connector(self, creator, entity, stack)
  local position = entity.position
  local force = entity.force

  local direction = entity.direction
  local loader_type = opposite_type(entity.loader_type)
  local editor_surface = self:editor_surface_for_aboveground_surface(entity.surface)
  -- check for existing underground connector ghost
  local underground_ghost = editor_surface.find_entity("entity-ghost", position)
  if underground_ghost and underground_ghost.ghost_type == "loader" then
    direction = underground_ghost.direction
    loader_type = underground_ghost.loader_type
    entity.loader_type = opposite_type(loader_type)
  end

  local underground_connector = editor_surface.create_entity{
    name = entity.name,
    position = position,
    direction = direction,
    type = loader_type,
    force = force,
  }

  if not underground_connector then
    self.abort_build(creator, entity, stack, {"beltlayer-error.underground-obstructed"})
    return
  end

  underground_connector.minable = false

  -- create buffer containers
  local above_container = entity.surface.create_entity{
    name = "beltlayer-buffer",
    position = position,
    force = force,
  }
  above_container.destructible = false
  local below_container = editor_surface.create_entity{
    name = "beltlayer-buffer",
    position = position,
    force = force,
  }
  below_container.destructible = false

  Connector.new(entity, above_container, below_container)
end

function Editor:on_built_entity(event)
  local entity = event.created_entity
  if not entity.valid then return end
  super.on_built_entity(self, event)
  if not entity.valid then return end

  local player = game.players[event.player_index]
  local stack = event.stack
  local surface = entity.surface

  if is_connector(entity) then
    if self:is_valid_aboveground_surface(surface) then
      on_built_surface_connector(self, player, entity, stack)
    else
      self.abort_build(player, entity, stack, {"beltlayer-error.bad-surface-for-connector"})
    end
  end
end

function Editor:script_raised_built(event)
  local entity = event.created_entity
  if entity and entity.name == "entity-ghost" then
    super.on_built_entity(self, event)
  end
end

function Editor:on_robot_built_entity(event)
  local entity = event.created_entity
  if not entity.valid then return end
  super.on_robot_built_entity(self, event)
  if not entity.valid then return end

  if is_surface_connector(self, entity) then
    on_built_surface_connector(self, event.robot, entity, event.stack)
  end
end

local function insert_container_inventory_to_buffer(container, buffer)
  local inv = container.get_inventory(defines.inventory.chest)
  for i=1,#inv do
    local stack = inv[i]
    if stack.valid_for_read then
      buffer.insert(stack)
      stack.clear()
    end
  end
end

local function insert_transport_lines_to_buffer(entity, buffer)
  for i=1,2 do
    local tl = entity.get_transport_line(i)
    for j=1,#tl do
      buffer.insert(tl[j])
    end
    tl.clear()
  end
end

local function on_mined_surface_connector(self, entity, buffer)
  local above_container = entity.surface.find_entity("beltlayer-buffer", entity.position)
  local editor_surface = self:editor_surface_for_aboveground_surface(entity.surface)
  local below_container = editor_surface.find_entity("beltlayer-buffer", entity.position)
  local underground_connector = editor_surface.find_entity(entity.name, entity.position)
  if buffer then
    insert_container_inventory_to_buffer(above_container, buffer)
    insert_container_inventory_to_buffer(below_container, buffer)
    insert_transport_lines_to_buffer(underground_connector, buffer)
  end
  above_container.destroy()
  below_container.destroy()
  underground_connector.destroy()
end

function Editor:on_player_mined_entity(event)
  super.on_player_mined_entity(self, event)
  local entity = event.entity
  if entity.valid and is_surface_connector(self, entity) then
    on_mined_surface_connector(self, entity, event.buffer)
  end
end

function Editor:on_robot_mined_entity(event)
  super.on_robot_mined_entity(self, event)
  local entity = event.entity
  if entity.valid and is_surface_connector(self, entity) then
    on_mined_surface_connector(self, entity, event.buffer)
  end
end

local handling_rotation = false
function Editor:on_player_rotated_entity(event)
  if handling_rotation then return end
  local entity = event.entity
  if not entity or not entity.valid then return end
  if is_connector(entity) then
    handling_rotation = true
    local surface = entity.surface
    if self:is_editor_surface(surface) then
      local aboveground_surface = self:aboveground_surface_for_editor_surface(surface)
      local above_connector = aboveground_surface.find_entity(entity.name, entity.position)
      if above_connector then
        above_connector.rotate{by_player = event.player_index}
        Connector.for_entity(above_connector):rotate()
      end
    elseif self:is_valid_aboveground_surface(surface) then
      local editor_surface = self:editor_surface_for_aboveground_surface(surface)
      local below_connector = editor_surface.find_entity(entity.name, entity.position)
      if below_connector then
        below_connector.rotate{by_player = event.player_index}
      end
      Connector.for_entity(entity):rotate()
    end
    handling_rotation = false
  end
end

function Editor:on_entity_died(event)
  local entity = event.entity
  if not entity or not entity.valid then return end
  if is_surface_connector(self, entity) then
    on_mined_surface_connector(self, entity, nil)
  end
end

------------------------------------------------------------------------------------------------------------------------
-- deconstruction

-- Set whenever a constructor ghost is deconstructed, e.g. by deconstruction tool,
-- so we can decide whether to deconstruct underground also.
local previous_connector_ghost_deconstruction_tick
local previous_connector_ghost_deconstruction_player_index

local function on_player_deconstructed_surface_area(self, player, aboveground_surface, area, tool)
  if not connector_in_area(player.surface, area) and
     (player.index ~= previous_connector_ghost_deconstruction_player_index or
     game.tick ~= previous_connector_ghost_deconstruction_tick) then
    -- no connectors present, and no connector ghosts deconstructed this tick by this player
    return
  end
  local editor_surface = self:editor_surface_for_aboveground_surface(aboveground_surface)
  local underground_entities = self:order_underground_deconstruction(player, editor_surface, area, tool)
  if next(underground_entities) and
     settings.get_player_settings(player)["beltlayer-deconstruction-warning"].value then
    player.print({"beltlayer-message.marked-for-deconstruction", #underground_entities})
  end
end

local function on_player_deconstructed_underground_area(self, player, editor_surface, area, tool)
  local underground_entities = self:order_underground_deconstruction(player, editor_surface, area, tool)
  for _, entity in ipairs(underground_entities) do
    if is_connector(entity) then
      local counterpart = surface_counterpart(entity)
      if counterpart then
        entity.order_deconstruction(player.force, player)
      end
      local bpproxy = self:surface_counterpart_bpproxy(entity)
      if bpproxy then
        bpproxy.destroy()
      end
    end
  end
end

function Editor:on_player_deconstructed_area(event)
  if event.alt then return end
  local player = game.players[event.player_index]
  local tool = player.cursor_stack
  if not tool or not tool.valid_for_read or not tool.is_deconstruction_item then return end
  local surface = player.surface
  if self:is_valid_aboveground_surface(surface) then
    return on_player_deconstructed_surface_area(self, player, surface, event.area, tool)
  elseif self:is_editor_surface(surface) then
    return on_player_deconstructed_underground_area(self, player, surface, event.area, tool)
  end
end

function Editor:on_pre_ghost_deconstructed(event)
  local ghost = event.ghost
  if is_connector_name(ghost.ghost_name) and self:is_valid_aboveground_surface(ghost.surface) then
    -- connector ghost deconstructed, so if this is the result of a deconstruction tool,
    -- we want to deconstruct underground too, but by the time on_player_deconstructed_area is raised
    -- there will be no ghosts, and if there were only ghosts we need to keep track of that fact.
    previous_connector_ghost_deconstruction_player_index = event.player_index
    previous_connector_ghost_deconstruction_tick = event.tick
  end
  super.on_pre_ghost_deconstructed(self, event)
end

function Editor:on_player_setup_blueprint(event)
  local surface = game.players[event.player_index].surface
  local area = event.area

  if connector_in_area(surface, area) then
    super.capture_underground_entities_in_blueprint(self, event)
  end
end

return M