-- Highlights are derived from the active colorscheme: line backgrounds are the
-- theme's add/delete colours blended into its Normal background, so they stay
-- legible on any theme instead of relying on its DiffAdd/DiffDelete.
local M = {}

local api = vim.api

local function rgb(c)
  return math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256
end

local function blend(fg, bg, alpha)
  local fr, fg_g, fb = rgb(fg)
  local br, bg_g, bb = rgb(bg)
  local function mix(a, b)
    return math.floor(a * alpha + b * (1 - alpha) + 0.5)
  end
  return mix(fr, br) * 65536 + mix(fg_g, bg_g) * 256 + mix(fb, bb)
end

local function color(names, attr, fallback)
  for _, name in ipairs(names) do
    local hl = api.nvim_get_hl(0, { name = name, link = false })
    if hl[attr] then
      return hl[attr]
    end
  end
  return fallback
end

function M.setup()
  local dark = vim.o.background ~= "light"
  local bg = color({ "Normal" }, "bg", dark and 0x0b0e14 or 0xffffff)
  local fg = color({ "Normal" }, "fg", dark and 0xe6e1cf or 0x202020)
  local dim = color({ "Comment" }, "fg", blend(fg, bg, 0.5))
  local add = color({ "Added", "GitSignsAdd", "diffAdded", "String" }, "fg", 0xaad94c)
  local del = color({ "Removed", "GitSignsDelete", "diffRemoved", "Error" }, "fg", 0xf07178)
  local chg = color({ "Changed", "GitSignsChange", "WarningMsg" }, "fg", 0xffb454)
  local accent = color({ "Function", "Directory" }, "fg", 0x59c2ff)
  local panel = color({ "NormalFloat", "Pmenu" }, "bg", blend(fg, bg, 0.04))
  local muted = blend(fg, bg, 0.62)

  local groups = {
    DifferAddLine = { bg = blend(add, bg, 0.13) },
    DifferDelLine = { bg = blend(del, bg, 0.13) },
    DifferAddLineStaged = { bg = blend(add, bg, 0.06) },
    DifferDelLineStaged = { bg = blend(del, bg, 0.06) },
    DifferAddWord = { bg = blend(add, bg, 0.38) },
    DifferDelWord = { bg = blend(del, bg, 0.38) },
    DifferEditLine = { bg = blend(chg, bg, 0.12) },
    DifferCommentChanged = { fg = blend(fg, bg, 0.68), italic = true },
    DifferFiller = { fg = blend(fg, bg, 0.12) },

    DifferAddText = { fg = add },
    DifferDelText = { fg = del },
    DifferChangeText = { fg = chg },

    DifferBarUnstaged = { fg = chg },
    DifferBarStaged = { fg = add },
    DifferBarPartial = { fg = blend(chg, add, 0.5) },
    DifferBarEdit = { fg = accent },

    DifferLnum = { fg = blend(fg, bg, 0.36) },
    DifferLnumAdd = { fg = blend(add, bg, 0.8) },
    DifferLnumCursor = { fg = chg, bold = true },

    DifferHeader = { bg = blend(fg, bg, 0.09), fg = fg },
    DifferHeaderName = { bg = blend(fg, bg, 0.09), fg = chg, bold = true },
    DifferHeaderDir = { bg = blend(fg, bg, 0.09), fg = muted },
    DifferHeaderDim = { bg = blend(fg, bg, 0.09), fg = muted },
    DifferHeaderDeleted = { bg = blend(fg, bg, 0.09), fg = del, strikethrough = true },
    DifferSep = { fg = dim, italic = true },
    DifferNote = { fg = muted, italic = true },
    DifferInfo = { fg = muted },
    DifferInfoTitle = { fg = fg, bold = true },
    DifferHint = { fg = bg, bg = accent, bold = true },
    DifferHintAlt = { fg = fg, bg = blend(fg, bg, 0.22) },

    DifferBar = { bg = panel, fg = muted },
    DifferBarTitle = { bg = panel, fg = fg, bold = true },
    DifferBarDim = { bg = panel, fg = muted },
    DifferBarAdd = { bg = panel, fg = add },
    DifferBarDel = { bg = panel, fg = del },
    DifferBarBtn = { bg = blend(fg, bg, 0.14), fg = fg },
    DifferBarBtnPrimary = { bg = accent, fg = bg, bold = true },
    DifferBarFile = { bg = panel, fg = chg, bold = true },

    DifferTab = { bg = panel, fg = muted },
    DifferTabActive = { bg = bg, fg = fg, bold = true, underline = true, sp = accent },

    DifferPanelSection = { fg = muted, bold = true },
    DifferPanelCount = { fg = muted },
    DifferPanelDir = { fg = muted },
    DifferPanelCurrent = { bg = blend(fg, bg, 0.11) },
    DifferPanelDeleted = { fg = del, strikethrough = true },
    DifferPanelCheck = { fg = muted },
    DifferPanelChecked = { fg = accent },

    DifferStatusM = { fg = chg },
    DifferStatusA = { fg = add },
    DifferStatusD = { fg = del },
    DifferStatusR = { fg = accent },
    DifferStatusU = { fg = add },
    DifferStatusC = { fg = del, bold = true },

    DifferCommitSubject = { fg = fg },
    DifferCommitMeta = { fg = muted },
    DifferRef = { fg = accent, bold = true },
    DifferRefHead = { fg = bg, bg = accent, bold = true },
    DifferRefRemote = { fg = muted, italic = true },
    DifferRefTag = { fg = chg, bold = true },
    DifferPlaceholder = { fg = dim, italic = true },
  }
  for name, spec in pairs(groups) do
    api.nvim_set_hl(0, name, spec)
  end

  -- Graph lanes, picked from the theme so they feel native.
  local palette = {
    color({ "Function" }, "fg", 0x59c2ff),
    color({ "Constant" }, "fg", 0xff8f40),
    color({ "Keyword", "Statement" }, "fg", 0xd2a6ff),
    color({ "String" }, "fg", 0xaad94c),
    color({ "Type" }, "fg", 0xffb454),
    color({ "Special" }, "fg", 0x95e6cb),
  }
  for i, c in ipairs(palette) do
    api.nvim_set_hl(0, "DifferGraph" .. i, { fg = c })
  end
end

return M
