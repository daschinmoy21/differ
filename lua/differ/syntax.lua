-- Treesitter highlights for text that isn't in its own buffer. A diff row shows
-- one line of a file, but parsing has to see the whole file (think multi-line
-- strings), so each file side is parsed once and its tokens stored per line.
local M = {}

local config = require("differ.config")

local function lang_for(path, text)
  local ok, ft = pcall(vim.filetype.match, { filename = path, contents = vim.split(text:sub(1, 2048), "\n", { plain = true }) })
  if not ok or not ft then
    return nil
  end
  local lang = vim.treesitter.language.get_lang(ft) or ft
  if not pcall(vim.treesitter.language.add, lang) then
    return nil
  end
  local has, query = pcall(vim.treesitter.query.get, lang, "highlights")
  if not has or not query then
    return nil
  end
  return lang, query
end

local function tokens(path, text)
  local result = {}
  if text == "" or #text > config.options.max_syntax_bytes then
    return result
  end
  local lang, query = lang_for(path, text)
  if not lang then
    return result
  end
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok then
    return result
  end
  local trees = parser:parse()
  local root = trees and trees[1] and trees[1]:root()
  if not root then
    return result
  end
  local hl_ids = {}
  for id, node in query:iter_captures(root, text) do
    local name = query.captures[id]
    if name:sub(1, 1) ~= "_" and name ~= "spell" and name ~= "nospell" and name ~= "conceal" then
      local hl = hl_ids[id]
      if not hl then
        hl = vim.api.nvim_get_hl_id_by_name("@" .. name .. "." .. lang)
        hl_ids[id] = hl
      end
      local sr, sc, er, ec = node:range()
      for r = sr, er do
        local line = result[r + 1]
        if not line then
          line = {}
          result[r + 1] = line
        end
        line[#line + 1] = { r == sr and sc or 0, r == er and ec or nil, hl, name:sub(1, 7) == "comment" }
      end
    end
  end
  return result
end

--- Token list for a file side, cached under `cache[key]`.
function M.get(cache, key, path, text)
  local entry = cache[key]
  if entry and entry.text == text then
    return entry.tokens
  end
  local ok, t = pcall(tokens, path, text or "")
  entry = { text = text, tokens = ok and t or {} }
  cache[key] = entry
  return entry.tokens
end

return M
