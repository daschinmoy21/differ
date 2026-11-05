-- Pure diff maths: no git, no UI, so all of it is unit-testable.
--
-- Lines are "raw": they keep their line ending, so rebuilding a file from them
-- is byte-exact (a missing final newline or CRLF survives partial staging).
--
-- A hunk is { as, ac, bs, bc }: region A is lines [as, as+ac) of the old text and
-- region B is lines [bs, bs+bc) of the new text. With a zero count the start is
-- the line the empty region sits in front of.
local M = {}

local text_diff = (vim.text and vim.text.diff) or vim.diff

function M.split(text)
  local out, pos, len = {}, 1, #text
  while pos <= len do
    local e = text:find("\n", pos, true)
    if not e then
      out[#out + 1] = text:sub(pos)
      break
    end
    out[#out + 1] = text:sub(pos, e)
    pos = e + 1
  end
  return out
end

--- Strip a raw line's ending, for display.
function M.strip(line)
  return (line:gsub("\r?\n$", ""))
end

function M.is_binary(text)
  return text ~= nil and text:sub(1, 8192):find("\0", 1, true) ~= nil
end

--- Line hunks between two texts.
function M.hunks(a, b)
  if a == b then
    return {}
  end
  local raw = text_diff(a, b, {
    result_type = "indices",
    algorithm = "histogram",
    ctxlen = 0,
    indent_heuristic = true,
  })
  local out = {}
  for i, h in ipairs(raw) do
    out[i] = {
      as = h[2] == 0 and h[1] + 1 or h[1], ac = h[2],
      bs = h[4] == 0 and h[3] + 1 or h[3], bc = h[4],
    }
  end
  return out
end

local function reversed(hunks)
  local out = {}
  for i, h in ipairs(hunks) do
    out[i] = { as = h.bs, ac = h.bc, bs = h.as, bc = h.ac }
  end
  return out
end
M.reversed = reversed

--- Do two ranges (start, count) overlap? A zero-length range is a point.
local function overlaps(s1, c1, s2, c2)
  local e1 = c1 > 0 and s1 + c1 - 1 or s1
  local e2 = c2 > 0 and s2 + c2 - 1 or s2
  return s1 <= e2 and s2 <= e1
end
M.overlaps = overlaps

--- Rebuild `base` with the chosen hunks of base→target applied.
--- `select(hunk)` returns nil to leave a hunk out, true to take all of it, or
--- { a = set, b = set }: drop those base lines and add those target lines.
function M.apply(base, target, hunks, select)
  local out, pos = {}, 1
  local function push(line)
    out[#out + 1] = line
  end
  for _, h in ipairs(hunks) do
    for i = pos, h.as - 1 do
      push(base[i])
    end
    local sel = select(h)
    for i = h.as, h.as + h.ac - 1 do
      if not sel or (sel ~= true and not sel.a[i]) then
        push(base[i])
      end
    end
    if sel then
      for i = h.bs, h.bs + h.bc - 1 do
        if sel == true or sel.b[i] then
          push(target[i])
        end
      end
    end
    pos = h.as + h.ac
  end
  for i = pos, #base do
    push(base[i])
  end
  -- A former last line without a newline may now sit mid-file.
  for i = 1, #out - 1 do
    if out[i]:sub(-1) ~= "\n" then
      out[i] = out[i] .. "\n"
    end
  end
  return table.concat(out)
end

--- Map a line of the old side to the new side; nil if the hunks changed it.
function M.map_line(hunks, line)
  local delta = 0
  for _, h in ipairs(hunks) do
    if line < h.as then
      break
    end
    if line < h.as + h.ac then
      return nil
    end
    delta = h.bs + h.bc - h.as - h.ac
  end
  return line + delta
end

local function map_set(hunks, set)
  local out = {}
  for line in pairs(set) do
    local mapped = M.map_line(hunks, line)
    if mapped then
      out[mapped] = true
    end
  end
  return out
end

--- Is a HEAD→worktree hunk "none", "partial" or "full"-y staged?
function M.stage_state(h, head_index, index_work)
  local pending, staged = false, false
  for _, o in ipairs(index_work) do
    if overlaps(h.bs, h.bc, o.bs, o.bc) then
      pending = true
      break
    end
  end
  if not pending then
    return "full"
  end
  for _, o in ipairs(head_index) do
    if overlaps(h.as, h.ac, o.as, o.ac) then
      staged = true
      break
    end
  end
  return staged and "partial" or "none"
end

-- The three operations below work on one HEAD→worktree hunk `h`. `lines`, when
-- given, narrows it to chosen lines: { a = set of HEAD lines, b = set of
-- worktree lines }. Each returns the new text of the side it rewrites.

--- New index text with the hunk (or lines) staged.
function M.stage(head, index, work, h, lines)
  local I, W = M.split(index), M.split(work)
  local iw = M.hunks(index, work)
  if lines then
    local hi = M.hunks(head, index)
    local sel = { a = map_set(hi, lines.a), b = lines.b }
    return M.apply(I, W, iw, function()
      return sel
    end)
  end
  return M.apply(I, W, iw, function(o)
    return overlaps(h.bs, h.bc, o.bs, o.bc) or nil
  end)
end

--- New index text with the hunk (or lines) unstaged.
function M.unstage(head, index, work, h, lines)
  local H, I = M.split(head), M.split(index)
  local ih = reversed(M.hunks(head, index))
  if lines then
    local wi = reversed(M.hunks(index, work))
    local sel = { a = map_set(wi, lines.b), b = lines.a }
    return M.apply(I, H, ih, function()
      return sel
    end)
  end
  return M.apply(I, H, ih, function(o)
    -- o is index→HEAD, so its B side is HEAD: compare with the hunk's A side.
    return overlaps(h.as, h.ac, o.bs, o.bc) or nil
  end)
end

--- New worktree text with the hunk (or lines) put back to HEAD.
function M.restore(head, work, h, lines)
  local H, W = M.split(head), M.split(work)
  local wh = reversed(M.hunks(head, work))
  if lines then
    return M.apply(W, H, wh, function()
      return { a = lines.b, b = lines.a }
    end)
  end
  return M.apply(W, H, wh, function(o)
    return (o.as == h.bs and o.ac == h.bc) or nil
  end)
end

-- Intra-line ("word") highlighting -----------------------------------------

--- Split into word, whitespace and single-punctuation tokens.
--- Returns a list of { start_byte, end_byte_exclusive } zero-based.
local function tokenize(line)
  local tokens, i, len = {}, 1, #line
  while i <= len do
    local c = line:byte(i)
    local j = i + 1
    local function is_word(b)
      return (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95 or b >= 128
    end
    if is_word(c) then
      while j <= len and is_word(line:byte(j)) do
        j = j + 1
      end
    elseif c == 32 or c == 9 then
      while j <= len and (line:byte(j) == 32 or line:byte(j) == 9) do
        j = j + 1
      end
    end
    tokens[#tokens + 1] = { i - 1, j - 1 }
    i = j
  end
  return tokens
end

local function stream(lines)
  local toks, parts = {}, {}
  for l, line in ipairs(lines) do
    for _, t in ipairs(tokenize(line)) do
      toks[#toks + 1] = { l, t[1], t[2] }
      parts[#parts + 1] = line:sub(t[1] + 1, t[2])
    end
    toks[#toks + 1] = { l, #line, #line } -- line break token
    parts[#parts + 1] = "\1"
  end
  return toks, table.concat(parts, "\n") .. "\n"
end

local function collect(toks, first, count, out)
  for i = first, first + count - 1 do
    local t = toks[i]
    if t and t[3] > t[2] then
      local ranges = out[t[1]]
      if not ranges then
        ranges = {}
        out[t[1]] = ranges
      end
      local last = ranges[#ranges]
      if last and last[2] == t[2] then
        last[2] = t[3]
      else
        ranges[#ranges + 1] = { t[2], t[3] }
      end
    end
  end
end

--- Changed byte ranges inside a block of old and new lines.
--- Returns old_ranges, new_ranges: { [line_index] = { {start, end_excl}, ... } }.
--- Blocks with little in common return nothing: they read better as whole lines.
function M.word_diff(old_lines, new_lines)
  local old_out, new_out = {}, {}
  if #old_lines == 0 or #new_lines == 0 or #old_lines + #new_lines > 400 then
    return old_out, new_out
  end
  local a_toks, a = stream(old_lines)
  local b_toks, b = stream(new_lines)
  local raw = text_diff(a, b, { result_type = "indices", algorithm = "minimal", ctxlen = 0 })
  local changed = 0
  for _, h in ipairs(raw) do
    for i = h[3], h[3] + h[4] - 1 do
      local t = b_toks[i]
      if h[4] > 0 and t then
        changed = changed + (t[3] - t[2])
      end
    end
  end
  local total = 0
  for _, line in ipairs(new_lines) do
    total = total + #line
  end
  if total == 0 or changed / total > 0.75 then
    return old_out, new_out
  end
  for _, h in ipairs(raw) do
    if h[2] > 0 then
      collect(a_toks, h[1], h[2], old_out)
    end
    if h[4] > 0 then
      collect(b_toks, h[3], h[4], new_out)
    end
  end
  return old_out, new_out
end

--- Merge hunks and extra ranges into the worktree ranges to show.
--- Returns a sorted list of { s, e } (1-based, inclusive; e may be s-1 if empty).
function M.excerpts(hunks, total, ctx, extras)
  local ranges = {}
  for _, h in ipairs(hunks) do
    local s = math.max(1, h.bs - ctx)
    local e = math.min(total, h.bs + math.max(h.bc, 0) - 1 + ctx)
    ranges[#ranges + 1] = { s = s, e = math.max(e, s - 1) }
  end
  for _, x in ipairs(extras or {}) do
    ranges[#ranges + 1] = { s = x.s, e = x.e }
  end
  table.sort(ranges, function(p, q)
    return p.s < q.s
  end)
  local out = {}
  for _, r in ipairs(ranges) do
    local last = out[#out]
    if last and r.s <= last.e + 1 then
      last.e = math.max(last.e, r.e)
    else
      out[#out + 1] = { s = r.s, e = r.e }
    end
  end
  return out
end

return M
