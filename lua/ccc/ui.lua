local api = vim.api

local set_hl = api.nvim_set_hl
local add_hl = api.nvim_buf_add_highlight

local Color = require("ccc.color")
local config = require("ccc.config")
local utils = require("ccc.utils")
local prev_colors = require("ccc.prev_colors")

---@class UI
---@field color Color
---@field pickers ColorPicker[]
---@field before_color string # HEX
---@field bufnr integer
---@field win_id integer
---@field win_height integer
---@field win_width integer
---@field ns_id integer
---@field row integer 1-index
---@field start_col integer 1-index
---@field end_col integer 1-index
---@field is_insert boolean
---@field prev_colors PrevColors
local UI = {}

function UI:init()
    if self.color == nil or not config.get("preserve") then
        self.color = Color.new(self.input_mode, self.output_mode)
    else
        self.color = self.color:copy()
    end
    self.input_mode = self.input_mode or self.color.input.name
    self.output_mode = self.output_mode or self.color.output.name
    self:set_default_color()
    self.win_height = 2 + #self.color.input.value
    if self.bufnr == nil then
        self.bufnr = api.nvim_create_buf(false, true)
        api.nvim_buf_set_option(self.bufnr, "buftype", "nofile")
        api.nvim_buf_set_option(self.bufnr, "modifiable", false)
        api.nvim_buf_set_option(self.bufnr, "filetype", "ccc-ui")
        local mappings = config.get("mappings")
        for lhs, rhs in pairs(mappings) do
            vim.keymap.set("n", lhs, rhs, { nowait = true, buffer = self.bufnr })
        end
    end
    if self.ns_id == nil then
        self.ns_id = api.nvim_create_namespace("ccc")
    end
    self.row = utils.row()
    self.start_col = utils.col()
    self.prev_colors = self.prev_colors or prev_colors.new(self)
end

function UI:set_default_color()
    local default_color = config.get("default_color")
    local start, _, RGB = self:_pick(default_color)
    assert(start, "Invalid color format: " .. default_color)
    ---@cast RGB number[]
    self.color:set_rgb(RGB)
    self.before_color = self.color:hex()
end

function UI:_open()
    local win_opts = config.get("win_opts")
    win_opts.height = self.win_height
    win_opts.width = self.win_width
    self.win_id = api.nvim_open_win(self.bufnr, true, win_opts)
    api.nvim_win_set_hl_ns(self.win_id, self.ns_id)
end

---@param insert boolean
function UI:open(insert)
    if api.nvim_win_is_valid(self.win_id or -1) then
        return
    end

    self:init()
    self.is_insert = insert
    if insert then
        self.end_col = self.start_col - 1
        utils.feedkey("<Esc>")
    else
        self:pick()
    end
    self:update()
    self:_open()
    utils.cursor_set({ 2, 1 })
end

function UI:_close()
    api.nvim_win_close(self.win_id, true)
end

function UI:close()
    if not api.nvim_win_is_valid(self.win_id) then
        return
    end
    self:_close()
    if self.is_insert then
        vim.cmd("startinsert")
    end
end

function UI:refresh()
    if self.win_id and api.nvim_win_is_valid(self.win_id) then
        self:_close()
        self:_open()
    end
end

function UI:quit()
    self:close()
    if config.get("save_on_quit") then
        self.prev_colors:add(self.color)
    end
end

function UI:complete()
    if self.prev_colors.is_showed and utils.row() == self.win_height then
        local color = self.prev_colors:select()
        if color then
            self.color = color
            self:update()
        end
        return
    end
    self:close()
    self.prev_colors:add(self.color)
    if self.is_insert then
        utils.feedkey(self.color:str(), true)
    else
        local line = api.nvim_get_current_line()
        local new_line = line:sub(1, self.start_col - 1)
            .. self.color:str()
            .. line:sub(self.end_col + 1)
        api.nvim_set_current_line(new_line)
    end
end

function UI:update()
    local end_ = self.prev_colors.is_showed and -2 or -1
    local prev_width = self.win_width
    utils.set_lines(self.bufnr, 0, end_, self:buffer())
    self:highlight()
    if self.win_width ~= prev_width then
        self:refresh()
    end
end

local function update_end(is_point, start, bar_char_len, point_char_len)
    if is_point then
        return start + point_char_len
    else
        return start + bar_char_len
    end
end

---@param value number
---@param min number
---@param max number
---@param bar_len integer
---@return integer
local function ratio(value, min, max, bar_len)
    value = value - min
    max = max - min
    return utils.round(value / max * bar_len)
end

---@param value number
---@param min number
---@param max number
---@param bar_len integer
---@return string
local function create_bar(value, min, max, bar_len)
    local ratio_ = ratio(value, min, max, bar_len)
    local bar_char = config.get("bar_char")
    local point_char = config.get("point_char")
    if ratio_ == 0 then
        return point_char .. string.rep(bar_char, bar_len - 1)
    end
    return string.rep(bar_char, ratio_ - 1) .. point_char .. string.rep(bar_char, bar_len - ratio_)
end

---@param length integer
---@param lhs string
---@param mid string
---@param rhs string
local function fill_in_blank(length, lhs, mid, rhs)
    local len_lhs = api.nvim_strwidth(lhs)
    local len_mid = api.nvim_strwidth(mid)
    local len_rhs = api.nvim_strwidth(rhs)
    local num_blank = length - len_lhs - len_mid - len_rhs
    local left_blank = 2
    local right_blank = num_blank - left_blank
    return lhs .. string.rep(" ", left_blank) .. mid .. string.rep(" ", right_blank) .. rhs
end

function UI:buffer()
    local bar_len = config.get("bar_len")
    local color = self.color:str()

    local buffer = { self.input_mode }
    local width
    local input = self.color.input
    for i, v in ipairs(self.color:get()) do
        local line = input.bar_name[i]
            .. " : "
            .. input.format(v, i)
            .. " "
            .. create_bar(v, input.min[i], input.max[i], bar_len)
        table.insert(buffer, line)
        if i == 1 then
            width = api.nvim_strwidth(line)
        end
    end
    self.win_width = width
    local line = fill_in_blank(self.win_width, self.before_color, "=>", color)
    table.insert(buffer, line)
    return buffer
end

function UI:highlight()
    api.nvim_buf_clear_namespace(self.bufnr, self.ns_id, 0, -1)
    local value = self.color:get()

    local bar_char = config.get("bar_char")
    local point_char = config.get("point_char")
    local bar_len = config.get("bar_len")
    for i, v in ipairs(value) do
        local max = self.color.input.max[i]
        local min = self.color.input.min[i]
        local point_idx = ratio(v, min, max, bar_len)
        local bar_name_len = api.nvim_strwidth(self.color.input.bar_name[1])
        -- See ColorInput.format()
        local value_len = 6
        -- 3 means ' : ', 1 means ' '
        local start = bar_name_len + 3 + value_len + 1
        local end_
        for j = 0, bar_len - 1 do
            end_ = update_end(j == point_idx, start, #bar_char, #point_char)

            local new_value = (j + 0.5) / bar_len * (max - min) + min
            local hex = self.color:hex(i, new_value)
            local color_name = "CccBar" .. i .. "_" .. j
            set_hl(self.ns_id, color_name, { fg = hex })
            add_hl(self.bufnr, self.ns_id, color_name, i, start, end_)

            start = end_
        end
    end

    local output_row = #value + 1

    local before_bg = self.before_color
    local before_fg = before_bg > "#800000" and "#000000" or "#ffffff"
    set_hl(self.ns_id, "CccBefore", { fg = before_fg, bg = before_bg })
    add_hl(self.bufnr, self.ns_id, "CccBefore", output_row, 0, 7)

    local output_bg = self.color:hex()
    local output_fg = output_bg > "#800000" and "#000000" or "#ffffff"
    set_hl(self.ns_id, "CccOutput", { fg = output_fg, bg = output_bg })
    local start_output = self.win_width - #self.color:str()
    add_hl(self.bufnr, self.ns_id, "CccOutput", output_row, start_output, -1)

    if self.prev_colors.is_showed then
        local start_prev, end_prev = 0, 7
        for i, color in ipairs(self.prev_colors.colors) do
            local pre_row = output_row + 1
            local pre_bg = color:hex()
            local pre_fg = pre_bg > "#800000" and "#000000" or "#ffffff"
            set_hl(self.ns_id, "CccPrev" .. i, { fg = pre_fg, bg = pre_bg })
            add_hl(self.bufnr, self.ns_id, "CccPrev" .. i, pre_row, start_prev, end_prev)
            start_prev = end_prev + 1
            end_prev = start_prev + 7
        end
    end
end

---@param d integer
function UI:delta(d)
    local index = utils.row() - 1
    if index < 1 or #self.color.input.value < index then
        return
    end
    local value = self.color.input.value[index]
    local input = self.color.input
    local delta = input.delta[index] * d
    local new_value = utils.fix_overflow(value + delta, input.min[index], input.max[index])
    self.color.input:callback(index, new_value)
    self:update()
end

function UI:set_percent(percent)
    local index = utils.row() - 1
    if index < 1 or #self.color.input.value < index then
        return
    end
    local max = self.color.input.max[index]
    local min = self.color.input.min[index]
    local new_value = (max - min) * percent / 100 + min
    self.color.input:callback(index, new_value)
    self:update()
end

---comment
---@param s string
---@return integer? start
---@return integer? end_
---@return number[]? RGB
function UI:_pick(s)
    for _, picker in ipairs(config.get("pickers")) do
        local start, end_, RGB = picker.parse_color(s)
        if start then
            return start, end_, RGB
        end
    end
    return nil
end

function UI:pick()
    ---@type string
    local current_line = api.nvim_get_current_line()
    local start, end_, RGB = self:_pick(current_line)
    local cursor_col = utils.col()
    if start and start <= cursor_col and cursor_col <= end_ then
        ---@cast end_ integer
        ---@cast RGB number[]
        self.start_col = start
        self.end_col = end_
        self.color:set_rgb(RGB)
        self.before_color = self.color:hex()
    else
        self.end_col = self.start_col - 1
    end
end

function UI:toggle_input_mode()
    self.color:toggle_input()
    self.input_mode = self.color.input.name
    if self.win_height ~= 2 + #self.color.input.value then
        self.win_height = 2 + #self.color.input.value
        self:refresh()
    end
    self:update()
end

function UI:toggle_output_mode()
    self.color:toggle_output()
    self.output_mode = self.color.output.name
    self:update()
end

return UI
