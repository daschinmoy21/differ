-- Commit graph layout. Feed commits newest-first (topo order); each call returns
-- the cells for that commit's row plus the "continuation" cells for any extra
-- rows the UI draws under it. Lanes stay stable across pages of history.
local M = {}

local bit = require("bit")

local U, D, L, R = 1, 2, 4, 8

-- Box-drawing glyph for each combination of edges.
local GLYPHS = {
  [0] = " ",
  [U] = "│",
  [D] = "│",
  [L] = "─",
  [R] = "─",
  [U + D] = "│",
  [L + R] = "─",
  [U + L] = "╯",
  [U + R] = "╰",
  [D + L] = "╮",
  [D + R] = "╭",
  [U + D + L] = "┤",
  [U + D + R] = "├",
  [U + L + R] = "┴",
  [D + L + R] = "┬",
  [U + D + L + R] = "┼",
}

local Graph = {}
Graph.__index = Graph

function M.new(opts)
  opts = opts or {}
  return setmetatable({ lanes = {}, palette = opts.palette or 6, next_color = 0 }, Graph)
end

function Graph:_color()
  self.next_color = self.next_color % self.palette + 1
  return self.next_color
end

function Graph:_free(reserved)
  local i = 1
  while true do
    if not self.lanes[i] and not reserved[i] then
      return i
    end
    i = i + 1
  end
end

function Graph:_find(hash)
  for i = 1, #self.lanes do
    if self.lanes[i] and self.lanes[i].hash == hash then
      return i
    end
  end
end

--- @return table row { cells = { {text, color}... }, cont = { ... }, col, color }
function Graph:add(hash, parents, kind)
  local lanes = self.lanes
  local node, incoming = nil, {}
  local reserved = {}

  local max_before = #lanes
  local before = {}
  for i = 1, max_before do
    if lanes[i] then
      before[i] = lanes[i].color
      if lanes[i].hash == hash then
        if node then
          incoming[#incoming + 1] = i
        else
          node = i
        end
      end
    end
  end

  local has_up = node ~= nil
  if not node then
    node = self:_free(reserved)
    lanes[node] = { hash = hash, color = self:_color() }
  end
  local color = lanes[node].color
  reserved[node] = true

  -- edges[col] = bitmask; link[col] = color of the connector drawn right of col.
  local edges, cell_color, link = {}, {}, {}
  local function add_edge(col, edge)
    edges[col] = bit.bor(edges[col] or 0, edge)
  end
  local function connect(col, lane_color)
    local lo, hi = math.min(col, node), math.max(col, node)
    for c = lo, hi do
      if c > lo then
        add_edge(c, L)
      end
      if c < hi then
        add_edge(c, R)
        link[c] = lane_color
      end
    end
  end

  -- Lanes merging into this commit end here.
  for _, col in ipairs(incoming) do
    add_edge(col, U)
    cell_color[col] = lanes[col].color
    connect(col, lanes[col].color)
    reserved[col] = true
    lanes[col] = false
  end

  -- First parent continues the node's lane.
  if parents[1] then
    lanes[node].hash = parents[1]
  else
    lanes[node] = false
  end

  -- Extra parents join an existing lane, or open a new one.
  for j = 2, #parents do
    local col = self:_find(parents[j])
    local lane_color
    if col then
      lane_color = lanes[col].color
    else
      col = self:_free(reserved)
      lane_color = self:_color()
      lanes[col] = { hash = parents[j], color = lane_color }
      cell_color[col] = lane_color
    end
    add_edge(col, D)
    connect(col, lane_color)
    reserved[col] = true
  end

  while #lanes > 0 and not lanes[#lanes] do
    lanes[#lanes] = nil
  end

  -- Lanes passing straight through this row.
  for i = 1, math.max(max_before, #lanes) do
    if i ~= node and before[i] and lanes[i] then
      local through = true
      for _, c in ipairs(incoming) do
        if c == i then
          through = false
        end
      end
      if through then
        add_edge(i, U)
        add_edge(i, D)
        cell_color[i] = before[i]
      end
    end
  end

  local width = math.max(max_before, #lanes, node)
  for c in pairs(edges) do
    width = math.max(width, c)
  end

  local glyph = kind == "head" and "◉" or (#parents > 1 and "⊙" or "●")
  local cells = {}
  for c = 1, width do
    if c == node then
      cells[#cells + 1] = { glyph, color }
    else
      local e = edges[c] or 0
      cells[#cells + 1] = { GLYPHS[e] or " ", cell_color[c] or link[c] or link[c - 1] or color }
    end
    if c < width then
      if link[c] then
        cells[#cells + 1] = { "─", link[c] }
      else
        cells[#cells + 1] = { " ", color }
      end
    end
  end

  return { cells = cells, cont = self:continuation(), col = node, color = color, has_up = has_up }
end

--- Cells for a row with no commit on it: just the live lanes.
function Graph:continuation()
  local cells = {}
  for c = 1, #self.lanes do
    local lane = self.lanes[c]
    cells[#cells + 1] = { lane and "│" or " ", lane and lane.color or 1 }
    if c < #self.lanes then
      cells[#cells + 1] = { " ", 1 }
    end
  end
  return cells
end

return M
