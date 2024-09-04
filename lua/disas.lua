do
	local function deep_copy(t)
		local nt = {};
		for k, v in pairs(t) do
			if type(v) == 'table' then
				nt[k] = setmetatable(deep_copy(v), getmetatable(v));
			else
				nt[k] = v;
			end
		end

		return nt;
	end

	local 	 _cfg;
	local    _compilation_database = {};

	-- Attempts to remove the compilation database's source root path from the beginning of the passed in string
	-- If it succeeds then it returns the absolute path with the root path removed
	-- If it fails it returns nil
	function _compilation_database:denormalize_file_path(absolute_file_path)
		local escaped_source_root = self.source_root:gsub("(%W)", "%%%1");
		local denormalized_path = absolute_file_path:gsub("^" .. escaped_source_root, '');

		if denormalized_path ~= absolute_file_path then -- success if we actually made the substitution
			if denormalized_path:sub(1,1) == '/' or denormalized_path:sub(1,1) == '\\' then
				return denormalized_path:sub(2, #denormalized_path);
			end

			return denormalized_path;
		end
	end

	-- Parses the wrapped file if it hasn't been parsed already
	-- If it's wrapping a compile_flags.txt then it simply returns the content of that file
	-- If it's a compilation database, it searches the database for the given relative file path
	-- 	  and returns its compilation command
	-- The relative file path must be relative to the compilation_database.source_root path
	-- On success returns true  and the compile command string
	-- On failure returns false and an error message
	function _compilation_database:get_command_for_file(relative_file_path) -- file path must be relative to the root of the source tree
		return pcall(function()
			if self.content == nil then assert(self:reparse()); end
			if self.is_cflags then
				return self.content;
			else
				for _, entry in ipairs(self.content) do
					if entry.file == relative_file_path then
						if entry.command then
							return entry.command;
						elseif entry.arguments then
							local command = '';

							for _, s in ipairs(entry.arguments) do
								command = command .. ' ' .. s;
							end

							return command;
						else
							error("Encountered invalid compilation database entry for file "
							.. tostring(entry.file) .. " (" .. tostring(relative_file_path) .. ")");
						end
					end
				end
			end
			error("Couldn't find compile command for file " .. tostring(relative_file_path));
		end)
	end


	-- Parses the file currently wrapped by the compilation database object
	-- On success it returns true
	-- On failure it returns false and the error message
	function _compilation_database:reparse()
		return pcall(function()
			local compdb_file    = assert(io.open(self.absolute_path, "r"));
			local compdb_content = compdb_file:read("*all");

			if self.is_cflags then
				self.content = compdb_content;
			else
				local temp_content = vim.json.decode(compdb_content, { luanil = { object = true, array = true }});
				if temp_content == nil or #temp_content == 0 then
					compdb_file:close();

					error(self.absolute_file_path .. " is not a valid JSON compilation database or compile_commands.txt");
				end

				self.content = temp_content;
			end

			compdb_file:close();
		end)
	end

	-- inc ref count
	function _compilation_database:inc_ref_count()
		self.ref_count = self.ref_count + 1;
	end

	-- dec ref count, if it hits zero we free our external connections
	function _compilation_database:dec_ref_count()
		self.ref_count = self.ref_count - 1;
		if self.ref_count == 0 then
			-- TODO: REMOVE LOOP ENTRY that monitors for compilation database changes
		end
	end


	-- Create a compilation database object from the given parameters
	-- Expects the given path paremeters to be normalized already
	-- Returns the object
	function _compilation_database.new(absolute_path, source_root, is_cflags)
		return setmetatable({
			absolute_path = absolute_path,
			source_root	  = source_root,
			is_cflags 	  = is_cflags,
			ref_count	  = 0,
			content 	  = nil -- either a string containing the compiler flags, or a table that decodes the compilation database
		}, { __index = _compilation_database });
	end

	-- Perform an upward search for either compile_commands.json or compile_flags.txt starting from the [current_directory] parameter
	-- On success it returns true  and a new compilation_database object wrapping the found database
	-- On failure it returns false and the error message
	function _compilation_database.find_compilation_database(current_directory)
		return pcall(function()
			local compilation_database = vim.fs.find({ 'compile_commands.json', 'compile_flags.txt'}, {
				path = current_directory,
				type = "file",
				upward = true
			});

			if #compilation_database == 0 then
				error("Unable to find compilation database in parent directories starting from " .. vim.fs.normalize(current_directory));
			end

			return _compilation_database.new(
			compilation_database[1],
			vim.fs.normalize(vim.fs.dirname(compilation_database[1])),
			vim.fs.basename(compilation_database[1]) == "compile_flags.txt");
		end)
	end



	local _linked_buffers = {by_source = {}};

	function _linked_buffers.new(source_buffnr, generated_buffnr, compilation_database, denormalized_file_path)
		local linked_buffers = setmetatable({
			source_buffnr = source_buffnr,
			generated_buffnr = generated_buffnr,
			compilation_database = compilation_database,
			denormalized_file_path = denormalized_file_path,
			cfg = deep_copy(_cfg.per_buffer)
		}, { __index = _linked_buffers });

		_linked_buffers.by_source[source_buffnr] = linked_buffers;

		vim.api.nvim_buf_attach(generated_buffnr, false, { on_detach = function() linked_buffers:close();  end }); -- remove the buffer link on generated buffer close
		vim.api.nvim_buf_attach(source_buffnr, false, {
			on_detach = function() vim.schedule(function() vim.api.nvim_buf_delete(generated_buffnr, { force = true }); end) end,
			on_reload = function() linked_buffers:reload(); end,
			on_lines  = function() linked_buffers:reload(); end
		});

		return linked_buffers;
	end

	function _linked_buffers:close()
		_linked_buffers.by_source[self.source_buffnr] = nil;
		self.compilation_database:dec_ref_count();
	end

	function _linked_buffers:reload()
		local _, command = assert(self.compilation_database:get_command_for_file(self.denormalized_file_path));
		if self.compilation_database.is_cflags then
			print("is_cflags");

			local file_name = vim.fs.basename(self.denormalized_file_path);
			local o_file = file_name:gsub("%.(%w+)$", ".o");

			command = command .. " " .. file_name .. " -o " .. o_file;

			print("new cmd", command);
		end

		return assert(self:generate(command));
	end

	function _linked_buffers:disassemble(output_file)
		local absolute_target_path = vim.fs.joinpath(self.compilation_database.source_root, output_file);
		local objdump_command = "objdump -d ";

		objdump_command = objdump_command .. (_cfg.objdump.flavor == "intel" and "-M intel " or "-M att ");
		objdump_command = objdump_command .. (_cfg.objdump.demangle and "-C " or "");
		objdump_command = objdump_command .. (self.cfg.interleave and "-S " or "");
		objdump_command = objdump_command .. '"' .. absolute_target_path .. '"';

		self:clear();

		vim.fn.jobstart(objdump_command, {
			cwd = self.compilation_database.source_root,
			on_exit   = function(_, exit_code)
				if exit_code ~= 0 then
					vim.schedule(function() self:append({"EXIT CODE " .. exit_code .. " - Disassembly Failed"}); end);
				end

				os.execute("rm " .. absolute_target_path);
			end,
			on_stdout = function(_, data) vim.schedule(function() self:append(data); end) end,
			on_stderr = function(_, data) vim.schedule(function() self:append(data); end) end
		});
	end

	function _linked_buffers:generate(command)
		return pcall(function()
			local expected_output = command:match("%-o%s+(%S+)");

			local configured_command = command;
			configured_command = configured_command .. " -c";
			configured_command = configured_command .. (self.cfg.interleave and " -g" or ""); -- add -g to get DWARF information into the object file so that objdump's -S flag can display it

			self:clear();

			vim.fn.jobstart(configured_command, {
				cwd = self.compilation_database.source_root, -- compiles in the working directory. This may have side effects
				on_exit = function(_, exit_code)
					vim.schedule(function()
						if exit_code ~= 0 then
							vim.schedule(function()self:append({"EXIT CODE " .. exit_code .. " - Compilation Failed"}); end);
						else
							vim.schedule(function()self:disassemble(expected_output); end);
						end
					end)
				end,
				on_stdout = function(_, data) vim.schedule(function() self:append(data); end) end,
				on_stderr = function(_, data) vim.schedule(function() self:append(data); end) end
			});
		end)
	end

	function _linked_buffers:append(lines, adjust_window)
		vim.api.nvim_set_option_value("readonly", false, { buf = self.generated_buffnr });

		vim.api.nvim_buf_set_lines(self.generated_buffnr, -1, -1, true, lines);

		vim.api.nvim_set_option_value("readonly", true, { buf = self.generated_buffnr });
		vim.api.nvim_set_option_value("modified", false, { buf = self.generated_buffnr });

		if adjust_window then
			vim.api.nvim_win_set_cursor(self.generated_buffnr, { vim.api.nvim_buf_line_count(self.generated_buffnr), 0 });
		end
	end

	function _linked_buffers:clear()
		vim.api.nvim_set_option_value("readonly", false, { buf = self.generated_buffnr });

		vim.api.nvim_buf_set_lines(self.generated_buffnr, 0, -1, true, {});

		vim.api.nvim_set_option_value("readonly", true, { buf = self.generated_buffnr });
		vim.api.nvim_set_option_value("modified", false, { buf = self.generated_buffnr });
	end

	local function find_existing_compilation_database(source_file_path)
		for _, linked_buffers in pairs(_linked_buffers.by_source) do
			local denormalized_file_path = linked_buffers.compilation_database:denormalize_file_path(source_file_path);
			if denormalized_file_path then
				local success, command = linked_buffers.compilation_database:get_command_for_file(denormalized_file_path);
				if success then
					return linked_buffers.compilation_database, denormalized_file_path, command;
				end
			end
		end
	end

	local function buff_is_visible(buffnr)
		for _, window in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_is_valid(window) and vim.api.nvim_win_get_buf(window) == buffnr then
				return true;
			end
		end

		return false;
	end

	local function create_disassembly_buffer(display)
		return pcall(function()
			local source_buffnr = vim.api.nvim_get_current_buf();

			if _linked_buffers.by_source[source_buffnr] then
				--vim.print("Linked buffer already found, no need to open a new buffer.");
				assert(_linked_buffers.by_source[source_buffnr]:reload());
				if not buff_is_visible(_linked_buffers.by_source[source_buffnr].generated_buffnr) then
					display(_linked_buffers.by_source[source_buffnr]);
				end

				return;
			end

			local source_file_path = vim.api.nvim_buf_get_name(source_buffnr);
			if source_file_path == nil then
				error("Attempt to open disassembly view on a memory only buffer.");
			end

			local existing_compilation_database, denormalized_file_path, command = find_existing_compilation_database(source_file_path);
			if not existing_compilation_database then
				local _, found_compilation_database = assert(_compilation_database.find_compilation_database(vim.fs.dirname(source_file_path)));
				denormalized_file_path = found_compilation_database:denormalize_file_path(source_file_path);
				existing_compilation_database = found_compilation_database;
				_, command = assert(existing_compilation_database:get_command_for_file(denormalized_file_path));
			end

			existing_compilation_database:inc_ref_count();

			local generated_buffnr = vim.api.nvim_create_buf(false, true);

			vim.api.nvim_buf_set_name(generated_buffnr, "DISASSEMBLY - " .. vim.fs.basename(source_file_path));
			vim.api.nvim_set_option_value("filetype", "asm", { buf = generated_buffnr });

			-- create the linked buffer and store it
			local linked_buffers = _linked_buffers.new(source_buffnr, generated_buffnr, existing_compilation_database, denormalized_file_path);
			linked_buffers:generate(command);

			display(linked_buffers);

			return linked_buffers;
		end)
	end

	local function open_disassembly_view_inline()
		local function display(res)
			vim.api.nvim_win_set_buf(0, res.generated_buffnr);
			vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(res.generated_buffnr), 0 });
		end

		local success, res = create_disassembly_buffer(display);
		if not success or not res then
			vim.print(res);
			return;
		end
	end

	local function open_disassembly_view_split(parameters)
		local function display(res)
			local vsp_win = vim.api.nvim_open_win(res.generated_buffnr, false, parameters);
			vim.api.nvim_win_set_cursor(vsp_win, { vim.api.nvim_buf_line_count(res.generated_buffnr), 0 });
		end

		local success, res = create_disassembly_buffer(display);
		if not success or not res then
			vim.print(res);
			return;
		end

	end

	local function open_disassembly_view_vsplit_left() return open_disassembly_view_split({split = 'left', win = 0}); end
	local function open_disassembly_view_vsplit_right() return open_disassembly_view_split({split = 'right', win = 0}); end
	local function open_disassembly_view_split_down() return open_disassembly_view_split({split = 'below', win = 0}); end
	local function open_disassembly_view_split_up() return open_disassembly_view_split({split = 'above', win = 0}); end

	local function toggle_interleave()
		local generated_buffnr = vim.api.nvim_get_current_buf();
		for _, v in pairs(_linked_buffers.by_source) do
			if v.generated_buffnr == generated_buffnr then
				v.cfg.interleave = not v.cfg.interleave;

				local success, res = pcall(v.reload, v);
				if not success then
					vim.print(res);
				end

				break;
			end
		end
	end

	local function setup(config)
		vim.api.nvim_create_user_command('DisassembleCurrentBufferInline', open_disassembly_view_inline, {
			desc = "Disassemble the current buffer and display it inline"
		});

		vim.api.nvim_create_user_command('DisassembleCurrentBufferSplitLeft', open_disassembly_view_vsplit_left, {
			desc = "Disassemble the current buffer and display it in a new left vertical split"
		});

		vim.api.nvim_create_user_command('DisassembleCurrentBufferSplitRight', open_disassembly_view_vsplit_right, {
			desc = "Disassemble the current buffer and display it in a new right vertical split"
		});

		vim.api.nvim_create_user_command('DisassembleCurrentBufferSplitDown', open_disassembly_view_split_down, {
			desc = "Disassemble the current buffer and display it in a new down horizontal split"
		});

		vim.api.nvim_create_user_command('DisassembleCurrentBufferSplitUp', open_disassembly_view_split_up, {
			desc = "Disassemble the current buffer and display it in a new up horizontal split"
		});

		vim.api.nvim_create_user_command('DisassemblerToggleInterleave', toggle_interleave, {
			desc = "Toggles source/asm interleaving for the current buffer"
		});

		_cfg = config;
	end

	return { setup = setup };
end
