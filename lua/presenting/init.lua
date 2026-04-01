--- *presenting.nvim*
--- *Presenting*
---
--- MIT License Copyright (c) 2024 Stefan Otte
---
--- ==============================================================================
---
--- Present your markdown, org-mode, or asciidoc files in a nice way,
--- i.e. directly in nvim.

-- Module definition ==========================================================
local Presenting = {}
local H = {}
Presenting._state = nil

--- Module setup
---
---@param config table|nil
---@usage `require('presenting').setup({})`
Presenting.setup = function(config)
  _G.Presenting = Presenting
  config = H.setup_config(config)
  H.apply_config(config)

  vim.api.nvim_create_user_command("Presenting", Presenting.toggle, {})
  vim.api.nvim_create_user_command("PresentingDevMode", Presenting.dev_mode, {})

  local presenting_autocmd_group_id = vim.api.nvim_create_augroup("PresentingAutoGroup", {})
  vim.api.nvim_create_autocmd("WinResized", {
    group = presenting_autocmd_group_id,
    callback = function() Presenting.resize() end,
  })
end

--- Module config
---
--- Default values:
---@eval return MiniDoc.afterlines_to_code(MiniDoc.current.eval_section)
Presenting.config = {
  options = {
    -- The width of the slide buffer.
    width = 60,
    -- The width of the TOC sidebar (0 to disable).
    toc_width = 30,
  },
  separator = {
    -- Separators for different filetypes.
    -- You can add your own or oberwrite existing ones.
    -- Note: separators are lua patterns, not regexes.
    markdown = "^#+ ",
    org = "^*+ ",
    adoc = "^==+ ",
    asciidoctor = "^==+ ",
  },
  -- Keep the separator, useful if you're parsing based on headings.
  -- If you want to parse on a non-heading separator, e.g. `---` set this to false.
  keep_separator = true,
  --- Parse first section of frontmatter, from first `---` to second `---`
  parse_frontmatter = false,
  keymaps = {
    -- These are local mappings for the open slide buffer.
    -- Disable existing keymaps by setting them to `nil`.
    -- Add your own keymaps as you desire.
    ["n"] = function() Presenting.next() end,
    ["p"] = function() Presenting.prev() end,
    ["q"] = function() Presenting.quit() end,
    ["f"] = function() Presenting.first() end,
    ["l"] = function() Presenting.last() end,
    ["<CR>"] = function() Presenting.next() end,
    ["<BS>"] = function() Presenting.prev() end,
    ["t"] = function() Presenting.toggle_toc() end,
    ["+"] = function() Presenting.toc_wider(5) end,
    ["-"] = function() Presenting.toc_narrower(5) end,
    [">"] = function() Presenting.slide_wider(10) end,
    ["<"] = function() Presenting.slide_narrower(10) end,
  },
  -- A function that configures the slide buffer.
  -- If you want custom settings write your own function that accepts a buffer id as argument.
  configure_slide_buffer = function(buf) H.configure_slide_buffer(buf) end,
}
--minidoc_afterlines_end

--- ==============================================================================
--- # Core functionality

--- Toggle presenting mode on/off for the current buffer.
---@param separator string|nil
Presenting.toggle = function(separator)
  if H.in_presenting_mode() then
    Presenting.quit()
  else
    Presenting.start(separator)
  end
end

--- Start presenting the current buffer.
---@param separator string|nil Overwrite the default separator if specified.
Presenting.start = function(separator)
  if H.in_presenting_mode() then
    vim.notify("Already presenting")
    return
  end

  if type(separator) == "table" then
    separator = nil
  end

  local filetype = vim.bo.filetype
  separator = separator or Presenting.config.separator[filetype]

  if separator == nil then
    vim.notify(
      "presenting.nvim does not support filetype "
        .. filetype
        .. ". You can specify a separator manually: Presenting.start('---')"
    )
    return
  end

  Presenting._state = {
    filetype = filetype,
    slides = {},
    slide = 1,
    n_slides = nil,
    slide_buf = nil,
    slide_win = nil,
    background_buf = nil,
    background_win = nil,
    footer_buf = nil,
    footer_win = nil,
    toc_buf = nil,
    toc_win = nil,
    toc_entries = nil,
    toc_slide_map = nil,
    toc_ns = nil,
    view = nil,
  }

  -- content of slides
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  Presenting._state.slides = H.parse_slides(lines, separator, Presenting.config.keep_separator)
  Presenting._state.n_slides = #Presenting._state.slides
  Presenting._state.slide_headings = H.build_slide_headings(Presenting._state.slides)

  -- Build TOC data
  local toc_entries, toc_slide_map = H.build_toc(Presenting._state.slides)
  Presenting._state.toc_entries = toc_entries
  Presenting._state.toc_slide_map = toc_slide_map
  Presenting._state.toc_ns = vim.api.nvim_create_namespace("presenting_toc")

  H.create_slide_view(Presenting._state)
end

--- Quit the current presentation and go back to the normal buffer.
--- By default this is mapped to `q`.
Presenting.quit = function()
  if not H.in_presenting_mode() then
    vim.notify("Not in presenting mode")
    return
  end

  vim.api.nvim_buf_delete(Presenting._state.slide_buf, { force = true })
  vim.api.nvim_buf_delete(Presenting._state.footer_buf, { force = true })
  vim.api.nvim_buf_delete(Presenting._state.background_buf, { force = true })

  if Presenting._state.toc_buf and vim.api.nvim_buf_is_valid(Presenting._state.toc_buf) then
    vim.api.nvim_buf_delete(Presenting._state.toc_buf, { force = true })
  end

  Presenting._state = nil
end

--- Go to the next slide.
--- By default this is mapped to `<CR>` and `n`.
Presenting.next = function()
  if not H.in_presenting_mode() then
    vim.notify("Not presenting. Call `PresentingStart` first.")
    return
  end
  H.set_slide_content(
    Presenting._state,
    math.min(Presenting._state.slide + 1, Presenting._state.n_slides)
  )
end

--- Go to the previous slide.
--- By default this is mapped to `<BS>` and `p`.
Presenting.prev = function()
  if not H.in_presenting_mode() then
    vim.notify("Not presenting. Call `PresentingStart` first.")
    return
  end
  H.set_slide_content(Presenting._state, math.max(Presenting._state.slide - 1, 1))
end

--- Go to the first slide.
--- By default this is mapped to `f`.
Presenting.first = function()
  if not H.in_presenting_mode() then
    vim.notify("Not presenting. Call `PresentingStart` first.")
    return
  end
  H.set_slide_content(Presenting._state, 1)
end

--- Go to the last slide.
--- By default this is mapped to `l`.
Presenting.last = function()
  if not H.in_presenting_mode() then
    vim.notify("Not presenting. Call `PresentingStart` first.")
    return
  end
  H.set_slide_content(Presenting._state, Presenting._state.n_slides)
end

--- Toggle TOC sidebar visibility.
--- By default this is mapped to `t`.
Presenting.toggle_toc = function()
  if not H.in_presenting_mode() then return end
  local state = Presenting._state

  if state.toc_win and vim.api.nvim_win_is_valid(state.toc_win) then
    vim.api.nvim_win_close(state.toc_win, true)
    state.toc_win = nil
    state._saved_toc_width = Presenting.config.options.toc_width
    Presenting.config.options.toc_width = 0
    H.reposition_windows(state)
  else
    Presenting.config.options.toc_width = state._saved_toc_width or 40
    local window_config = H.get_win_configs()
    if window_config.toc then
      state.toc_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_option(state.toc_buf, "buftype", "nofile")
      vim.api.nvim_buf_set_option(state.toc_buf, "bufhidden", "wipe")
      vim.api.nvim_buf_set_option(state.toc_buf, "modifiable", false)
      state.toc_win = vim.api.nvim_open_win(state.toc_buf, false, window_config.toc)
      vim.api.nvim_win_set_option(state.toc_win, "wrap", true)
      vim.api.nvim_win_set_option(state.toc_win, "cursorline", false)
      H.render_toc(state)
      H.highlight_toc(state)
      H.setup_toc_keymaps(state)
    end
    H.reposition_windows(state)
  end
end

--- Increase TOC width by `delta` columns.
--- By default mapped to `+`.
Presenting.toc_wider = function(delta)
  if not H.in_presenting_mode() then return end
  local state = Presenting._state
  if not (state.toc_win and vim.api.nvim_win_is_valid(state.toc_win)) then return end
  Presenting.config.options.toc_width = Presenting.config.options.toc_width + (delta or 5)
  H.reposition_windows(state)
end

--- Decrease TOC width by `delta` columns.
--- By default mapped to `-`.
Presenting.toc_narrower = function(delta)
  if not H.in_presenting_mode() then return end
  local state = Presenting._state
  if not (state.toc_win and vim.api.nvim_win_is_valid(state.toc_win)) then return end
  Presenting.config.options.toc_width = math.max(10, Presenting.config.options.toc_width - (delta or 5))
  H.reposition_windows(state)
end

--- Increase slide width by `delta` columns.
--- By default mapped to `>`.
Presenting.slide_wider = function(delta)
  if not H.in_presenting_mode() then return end
  Presenting.config.options.width = Presenting.config.options.width + (delta or 10)
  H.reposition_windows(Presenting._state)
  H.set_slide_content(Presenting._state, Presenting._state.slide)
end

--- Decrease slide width by `delta` columns.
--- By default mapped to `<`.
Presenting.slide_narrower = function(delta)
  if not H.in_presenting_mode() then return end
  Presenting.config.options.width = math.max(40, Presenting.config.options.width - (delta or 10))
  H.reposition_windows(Presenting._state)
  H.set_slide_content(Presenting._state, Presenting._state.slide)
end

---Resize the slide window.
Presenting.resize = function()
  if not H.in_presenting_mode() then return end
  if
    (Presenting._state.background_win == nil)
    or (Presenting._state.slide_win == nil)
    or (Presenting._state.footer_win == nil)
  then
    return
  end

  local window_config = H.get_win_configs()
  vim.api.nvim_win_set_config(Presenting._state.background_win, window_config.background)
  vim.api.nvim_win_set_config(Presenting._state.footer_win, window_config.footer)
  vim.api.nvim_win_set_config(Presenting._state.slide_win, window_config.slide)
  if Presenting._state.toc_win and window_config.toc then
    vim.api.nvim_win_set_config(Presenting._state.toc_win, window_config.toc)
  end
end

Presenting.dev_mode = function()
  package.loaded["presenting"] = nil
  _G.Presenting = nil
  require("presenting").start()
end

--- ==============================================================================
--- Internal Helper
--- As end user you should not need to use these functions.
---@private
H.default_config = vim.deepcopy(Presenting.config)

---@param config table|nil
---@private
H.setup_config = function(config)
  vim.validate({ config = { config, "table", true } })
  return vim.tbl_deep_extend("force", vim.deepcopy(H.default_config), config or {})
end

---@param config table
---@private
H.apply_config = function(config)
  Presenting.config = config
end

---@return table
---@private
H.get_win_configs = function()
  local slide_width = Presenting.config.options.width
  local toc_width = Presenting.config.options.toc_width or 0
  local width = vim.api.nvim_get_option("columns")
  local height = vim.api.nvim_get_option("lines")

  -- Calculate layout: TOC on left, slide centered in remaining space
  local total_content_width = slide_width + toc_width + (toc_width > 0 and 2 or 0)
  local left_margin = math.max(0, math.ceil((width - total_content_width) / 2))
  local toc_col = left_margin
  local slide_col = toc_col + toc_width + (toc_width > 0 and 2 or 0)

  local configs = {
    background = {
      style = "minimal",
      relative = "editor",
      focusable = false,
      width = width,
      height = height,
      row = 0,
      col = 0,
      zindex = 1,
    },
    slide = {
      style = "minimal",
      relative = "editor",
      width = slide_width,
      height = height - 5,
      row = 0,
      col = slide_col,
      zindex = 10,
    },
    footer = {
      style = "minimal",
      relative = "editor",
      width = slide_width,
      height = 1,
      row = height - 1,
      col = slide_col,
      focusable = false,
      zindex = 2,
    },
  }

  if toc_width > 0 then
    configs.toc = {
      style = "minimal",
      relative = "editor",
      width = toc_width,
      height = height - 5,
      row = 0,
      col = toc_col,
      focusable = true,
      zindex = 5,
      border = "none",
    }
  end

  return configs
end

---@param state table
---@private
H.create_slide_view = function(state)
  local window_config = H.get_win_configs()

  state.background_buf = vim.api.nvim_create_buf(false, true)
  state.background_win =
    vim.api.nvim_open_win(state.background_buf, false, window_config.background)

  state.footer_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(state.footer_buf, 0, -1, false, { "" })
  state.footer_win = vim.api.nvim_open_win(state.footer_buf, false, window_config.footer)

  -- Create TOC sidebar
  if window_config.toc then
    state.toc_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(state.toc_buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(state.toc_buf, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(state.toc_buf, "modifiable", false)
    state.toc_win = vim.api.nvim_open_win(state.toc_buf, false, window_config.toc)
    -- Style the TOC window
    vim.api.nvim_win_set_option(state.toc_win, "wrap", true)
    vim.api.nvim_win_set_option(state.toc_win, "cursorline", false)
    -- Populate TOC content
    H.render_toc(state)
    H.setup_toc_keymaps(state)
  end

  state.slide_buf = vim.api.nvim_create_buf(false, true)
  state.slide_win = vim.api.nvim_open_win(state.slide_buf, true, window_config.slide)
  Presenting.config.configure_slide_buffer(state.slide_buf)
  H.set_slide_keymaps(state.slide_buf, Presenting.config.keymaps)

  H.set_slide_content(state, 1)
end

---@param lines table
---@param separator string
---@return table
---@private
H.parse_slides = function(lines, separator, keep_separator)
  -- Remove frontmatter if configured
  if Presenting.config.parse_frontmatter then
    local in_frontmatter = false
    local new_lines = {}
    local frontmatter_found = 0
    for _, line in ipairs(lines) do
      if line:match("^%-%-%-%s*$") then
        frontmatter_found = frontmatter_found + 1
        if frontmatter_found == 1 then
          in_frontmatter = true
        elseif frontmatter_found == 2 then
          in_frontmatter = false
          goto continue
        end
        goto continue
      end
      if not in_frontmatter then table.insert(new_lines, line) end
      ::continue::
    end
    lines = new_lines
    -- Remove leading blank lines after frontmatter
    while lines[1] and lines[1]:match("^%s*$") do
      table.remove(lines, 1)
    end
  end

  local slides = {}
  local slide = {}
  for _, line in ipairs(lines) do
    if line:match(separator) then
      if #slide > 0 then
        table.insert(slides, table.concat(slide, "\n"))
      elseif #slides == 0 then
        -- Skip leading separator after frontmatter
        if keep_separator then table.insert(slide, line) end
        goto continue
      end
      slide = {}
      if keep_separator then table.insert(slide, line) end
    else
      table.insert(slide, line)
    end
    ::continue::
  end
  if #slide > 0 then table.insert(slides, table.concat(slide, "\n")) end

  return slides
end

--- Build heading breadcrumb for each slide by scanning all slides sequentially.
---@param slides table
---@return table
---@private
H.build_slide_headings = function(slides)
  local heading_stack = {}
  local result = {}

  for _, slide_content in ipairs(slides) do
    local lines = vim.split(slide_content, "\n")
    for _, line in ipairs(lines) do
      local hashes, title = line:match("^(#+)%s+(.+)$")
      if hashes then
        local level = #hashes
        heading_stack[level] = title
        for l = level + 1, 6 do
          heading_stack[l] = nil
        end
      end
    end
    local parts = {}
    for l = 1, 6 do
      if heading_stack[l] then
        table.insert(parts, heading_stack[l])
      end
    end
    table.insert(result, table.concat(parts, " > "))
  end

  return result
end

--- Build TOC entries from slides.
--- Returns: toc_entries (list of {text, level, slide_idx}), toc_slide_map (slide_idx -> toc line index)
---@param slides table
---@return table, table
---@private
H.build_toc = function(slides)
  local entries = {}
  local slide_map = {}    -- slide_idx -> first toc line for that slide
  local seen_headings = {} -- deduplicate: level:title -> true

  for slide_idx, slide_content in ipairs(slides) do
    local lines = vim.split(slide_content, "\n")
    local first_entry_for_slide = nil
    for _, line in ipairs(lines) do
      local hashes, title = line:match("^(#+)%s+(.+)$")
      if hashes then
        local level = #hashes
        -- Remove trailing (续) or similar markers for dedup
        local dedup_key = level .. ":" .. title
        if not seen_headings[dedup_key] then
          seen_headings[dedup_key] = true
          local entry = { text = title, level = level, slide_idx = slide_idx }
          table.insert(entries, entry)
          if not first_entry_for_slide then
            first_entry_for_slide = #entries
          end
        end
      end
    end
    if first_entry_for_slide then
      slide_map[slide_idx] = first_entry_for_slide
    end
  end

  return entries, slide_map
end

--- Render TOC content into the TOC buffer
---@param state table
---@private
H.render_toc = function(state)
  if not state.toc_buf then return end

  local toc_lines = {}
  for _, entry in ipairs(state.toc_entries) do
    local indent = string.rep("  ", entry.level - 1)
    local line = indent .. entry.text
    table.insert(toc_lines, line)
  end

  vim.api.nvim_buf_set_option(state.toc_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(state.toc_buf, 0, -1, false, toc_lines)
  vim.api.nvim_buf_set_option(state.toc_buf, "modifiable", false)
end

--- Highlight the current slide's TOC entry
---@param state table
---@private
H.highlight_toc = function(state)
  if not state.toc_buf or not state.toc_ns then return end
  if not vim.api.nvim_buf_is_valid(state.toc_buf) then return end

  vim.api.nvim_buf_clear_namespace(state.toc_buf, state.toc_ns, 0, -1)

  -- Find which TOC entries belong to the current slide.
  -- Walk backwards from current slide to find the closest TOC entry.
  local active_toc_line = nil
  for s = state.slide, 1, -1 do
    if state.toc_slide_map[s] then
      active_toc_line = state.toc_slide_map[s]
      break
    end
  end

  if active_toc_line then
    local line_idx = active_toc_line - 1 -- 0-indexed
    vim.api.nvim_buf_add_highlight(state.toc_buf, state.toc_ns, "Visual", line_idx, 0, -1)
    -- Scroll TOC to keep active entry visible
    if state.toc_win and vim.api.nvim_win_is_valid(state.toc_win) then
      local toc_height = vim.api.nvim_win_get_height(state.toc_win)
      local target_top = math.max(0, line_idx - math.floor(toc_height / 2))
      vim.api.nvim_win_call(state.toc_win, function()
        vim.fn.winrestview({ topline = target_top + 1 })
      end)
    end
  end
end

--- Setup keymaps on TOC buffer for click-to-navigate
---@param state table
---@private
H.setup_toc_keymaps = function(state)
  if not state.toc_buf then return end
  local opts = { noremap = true, silent = true }

  local function jump_to_slide()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    if state.toc_entries and state.toc_entries[line] then
      H.set_slide_content(state, state.toc_entries[line].slide_idx)
      if state.slide_win and vim.api.nvim_win_is_valid(state.slide_win) then
        vim.api.nvim_set_current_win(state.slide_win)
      end
    end
  end

  vim.api.nvim_buf_set_keymap(state.toc_buf, "n", "<CR>", "", { callback = jump_to_slide, noremap = true, silent = true })
  vim.api.nvim_buf_set_keymap(state.toc_buf, "n", "<2-LeftMouse>", "", { callback = jump_to_slide, noremap = true, silent = true })
  vim.api.nvim_buf_set_keymap(state.toc_buf, "n", "q", "", { callback = function() Presenting.quit() end, noremap = true, silent = true })
end

--- Reposition all windows after TOC width change or toggle
---@param state table
---@private
H.reposition_windows = function(state)
  local window_config = H.get_win_configs()
  vim.api.nvim_win_set_config(state.slide_win, window_config.slide)
  vim.api.nvim_win_set_config(state.footer_win, window_config.footer)
  if state.toc_win and vim.api.nvim_win_is_valid(state.toc_win) and window_config.toc then
    vim.api.nvim_win_set_config(state.toc_win, window_config.toc)
  end
end

---@param buf integer
---@private
H.configure_slide_buffer = function(buf)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "filetype", Presenting._state.filetype)
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

---@param state table
---@param slide integer
---@private
H.set_slide_content = function(state, slide)
  local orig_modifiable = vim.api.nvim_buf_get_option(state.slide_buf, "modifiable")
  vim.api.nvim_buf_set_option(state.slide_buf, "modifiable", true)
  state.slide = slide
  local content_lines = vim.split(state.slides[state.slide], "\n")

  -- Vertical centering: add blank lines above content
  local win_height = vim.api.nvim_win_get_height(state.slide_win)
  local content_height = #content_lines
  local pad_top = math.max(0, math.floor((win_height - content_height) / 2))
  local padded_lines = {}
  for _ = 1, pad_top do
    table.insert(padded_lines, "")
  end
  for _, line in ipairs(content_lines) do
    table.insert(padded_lines, line)
  end

  vim.api.nvim_buf_set_lines(
    state.slide_buf,
    0,
    -1,
    false,
    padded_lines
  )
  vim.api.nvim_buf_set_option(state.slide_buf, "modifiable", orig_modifiable)

  -- Update footer with heading breadcrumb
  local heading_path = ""
  if state.slide_headings and state.slide_headings[state.slide] then
    heading_path = state.slide_headings[state.slide]
  end
  local footer_text = state.slide .. "/" .. state.n_slides .. "  " .. heading_path
  vim.api.nvim_buf_set_lines(state.footer_buf, 0, -1, false, { footer_text })

  -- Update TOC highlight
  H.highlight_toc(state)
end

---@param buf integer
---@param mappings table
---@private
H.set_slide_keymaps = function(buf, mappings)
  for k, v in pairs(mappings) do
    if type(v) == "string" then
      local cmd = ":lua require('presenting')." .. v .. "()<CR>"
      vim.api.nvim_buf_set_keymap(buf, "n", k, cmd, { noremap = true, silent = true })
    elseif type(v) == "function" then
      vim.api.nvim_buf_set_keymap(buf, "n", k, "", { callback = v, noremap = true, silent = true })
    end
  end
end

---@return boolean
H.in_presenting_mode = function() return Presenting._state ~= nil end

return Presenting
