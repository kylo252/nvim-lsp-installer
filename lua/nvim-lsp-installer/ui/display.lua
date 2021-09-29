local Ui = require "nvim-lsp-installer.ui"
local log = require "nvim-lsp-installer.log"
local process = require "nvim-lsp-installer.process"
local state = require "nvim-lsp-installer.ui.state"

local function get_styles(line, render_context)
    local indentation = 0

    for i = 1, #render_context.applied_block_styles do
        local styles = render_context.applied_block_styles[i]
        for j = 1, #styles do
            local style = styles[j]
            if style == Ui.CascadingStyle.INDENT then
                indentation = indentation + 2
            elseif style == Ui.CascadingStyle.CENTERED then
                local padding = math.floor((render_context.context.win_width - #line) / 2)
                indentation = math.max(0, padding) -- CENTERED overrides any already applied indentation
            end
        end
    end

    return {
        indentation = indentation,
    }
end

local function create_popup_window_opts()
    local win_height = vim.o.lines - vim.o.cmdheight - 2 -- Add margin for status and buffer line
    local win_width = vim.o.columns
    local popup_layout = {
        relative = "editor",
        height = math.floor(win_height * 0.9),
        width = math.floor(win_width * 0.8),
        style = "minimal",
        border = "rounded",
    }
    popup_layout.row = math.floor((win_height - popup_layout.height) / 2)
    popup_layout.col = math.floor((win_width - popup_layout.width) / 2)

    return popup_layout
end

local Display = {}

local redraw_by_win_id = {}


function Display:new(opts)
    opts = opts or {}

    local buf_opts = {
        modifiable = false,
        swapfile = false,
        textwidth = 0,
        buftype = "nofile",
        bufhidden = "wipe",
        buflisted = false,
        filetype = "lsp-installer",
    }

    local win_opts = {
        number = false,
        relativenumber = false,
        wrap = false,
        spell = false,
        foldenable = false,
        signcolumn = "no",
        colorcolumn = "",
        cursorline = true,
    }

    local obj = {
        name = opts.name or "LSP servers",
        renderer = nil,
        layout = create_popup_window_opts(),
        bufnr = nil,
        win_id = nil,
        buf_opts = buf_opts,
        win_opts = win_opts,
        mutate_state = nil,
        get_state = nil,
        unsubscribe = nil,
        has_initiated = false,
        namespace = vim.api.nvim_create_namespace(("lsp_installer_%s"):format(self.name)),
    }

    Display.__index = Display
    setmetatable(obj, Display)

    return obj
end

function Display:init(initial_state)
    assert(self.renderer ~= nil, "No view function has been registered. Call .view() before .init().")
    self.has_initiated = true

    self.mutate_state, self.get_state, self.unsubscribe = state.create_state_container(
        initial_state,
        function(new_state)
            self.draw(self.renderer(new_state))
        end
    )
    return self.mutate_state, self.get_state
end

function Display:redraw_win()
    if vim.api.nvim_win_is_valid(self.win_id) then
        self.draw(self.renderer(self.get_state()))
        vim.api.nvim_win_set_config(self.win_id, create_popup_window_opts())
    end
end

function Display:delete_win_buf()
    pcall(vim.api.nvim_win_close, self.win_id, true)
    pcall(vim.api.nvim_buf_delete, self.bufnr, { force = true })
    if redraw_by_win_id[self.win_id] then
        redraw_by_win_id[self.win_id] = nil
    end
end

function Display:open(opts)
    vim.schedule_wrap(function()
        log.debug "Opening window"
        assert(self.has_initiated, "Display has not been initiated, cannot open.")

        if self.win_id and vim.api.nvim_win_is_valid(self.win_id) then
            -- window is already open
            return
        end

        self.unsubscribe(false)

        log.debug "Creating window"

        self.bufnr = vim.api.nvim_create_buf(false, true)
        self.win_id = vim.api.nvim_open_win(self.bufnr, true, self.layout)

        if not vim.api.nvim_win_is_valid(self.win_id) then
            -- invalid win_id
            return
        end

        opts = opts or {}
        opts.buf_opts = opts.buf_opts or {}
        opts.win_opts = opts.win_opts or {}

        assert(self.has_initiated, "Display has not been initiated, cannot open.")
        self.buf_opts = vim.tbl_deep_extend("force", self.buf_opts, opts.buf_opts)
        self.win_opts = vim.tbl_deep_extend("force", self.win_opts, opts.win_opts)

        log.debug "opening window"
        -- window options
        for key, value in pairs(self.win_opts) do
            vim.api.nvim_win_set_option(self.win_id, key, value)
        end

        -- buffer options
        for key, value in pairs(self.buf_opts) do
            vim.api.nvim_buf_set_option(self.buffer, key, value)
        end

        vim.cmd(
            ("autocmd VimResized <buffer> lua require('nvim-lsp-installer.ui.display'):redraw_win(%d)"):format(
                self.win_id
            )
        )
        vim.cmd(
            (
                "autocmd WinLeave,BufHidden,BufLeave <buffer> ++once lua require('nvim-lsp-installer.ui.display'):delete_win_buf(%d, %d)"
            ):format(self.win_id, self.bufnr)
        )

        log.debug "Opening window"
        self.draw(self.renderer(self.get_state()))
        self.redraw_win()
    end)
end

function Display:render_node(context, node, _render_context, _output)
    local render_context = _render_context or {
        context = context,
        applied_block_styles = {},
    }
    local output = _output or {
        lines = {},
        virt_texts = {},
        highlights = {},
    }

    if node.type == Ui.NodeType.VIRTUAL_TEXT then
        output.virt_texts[#output.virt_texts + 1] = {
            line = #output.lines - 1,
            content = node.virt_text,
        }
    elseif node.type == Ui.NodeType.HL_TEXT then
        for i = 1, #node.lines do
            local line = node.lines[i]
            local line_highlights = {}
            local full_line = ""
            for j = 1, #line do
                local span = line[j]
                local content, hl_group = span[1], span[2]
                local col_start = #full_line
                full_line = full_line .. content
                line_highlights[#line_highlights + 1] = {
                    hl_group = hl_group,
                    line = #output.lines,
                    col_start = col_start,
                    col_end = col_start + #content,
                }
            end

            local active_styles = get_styles(full_line, render_context)

            -- apply indentation
            full_line = (" "):rep(active_styles.indentation) .. full_line
            for j = 1, #line_highlights do
                local highlight = line_highlights[j]
                highlight.col_start = highlight.col_start + active_styles.indentation
                highlight.col_end = highlight.col_end + active_styles.indentation
                output.highlights[#output.highlights + 1] = highlight
            end

            output.lines[#output.lines + 1] = full_line
        end
    elseif node.type == Ui.NodeType.NODE or node.type == Ui.NodeType.CASCADING_STYLE then
        if node.type == Ui.NodeType.CASCADING_STYLE then
            render_context.applied_block_styles[#render_context.applied_block_styles + 1] = node.styles
        end
        for i = 1, #node.children do
            self.render_node(context, node.children[i], render_context, output)
        end
        if node.type == Ui.NodeType.CASCADING_STYLE then
            render_context.applied_block_styles[#render_context.applied_block_styles] = nil
        end
    end

    return output
end

function Display:draw()
    process.debounced(function(view)
        local win_valid = self.win_id ~= nil and vim.api.nvim_win_is_valid(self.win_id)
        local buf_valid = self.bufnr ~= nil and vim.api.nvim_buf_is_valid(self.bufnr)
        log.fmt_debug("got bufnr=%s", self.bufnr)
        log.fmt_debug("got win_id=%s", self.win_id)

        if not win_valid or not buf_valid then
            -- the window has been closed or the buffer is somehow no longer valid
            self.unsubscribe(true)
            return
        end

        local win_width = vim.api.nvim_win_get_width(self.win_id)
        local context = {
            win_width = win_width,
        }
        local output = self.render_node(context, view)
        local lines, virt_texts, highlights = output.lines, output.virt_texts, output.highlights

        vim.api.nvim_buf_clear_namespace(0, self.namespace, 0, -1)
        vim.api.nvim_buf_set_option(self.bufnr, "modifiable", true)
        vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
        vim.api.nvim_buf_set_option(self.bufnr, "modifiable", false)

        for i = 1, #virt_texts do
            local virt_text = virt_texts[i]
            vim.api.nvim_buf_set_extmark(self.bufnr, self.namespace, virt_text.line, 0, {
                virt_text = virt_text.content,
            })
        end
        for i = 1, #highlights do
            local highlight = highlights[i]
            vim.api.nvim_buf_add_highlight(
                self.bufnr,
                self.namespace,
                highlight.hl_group,
                highlight.line,
                highlight.col_start,
                highlight.col_end
            )
        end
    end)
end

function Display:view(x)
    self.renderer = x
end

return Display
