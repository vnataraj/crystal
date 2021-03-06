require "option_parser"
require "file_utils"
require "socket"
require "colorize"
require "crypto/md5"

module Crystal
  @[Flags]
  enum Debug
    LineNumbers
    Variables
    Default     = LineNumbers
  end

  # Main interface to the compiler.
  #
  # A Compiler parses source code, type checks it and
  # optionally generates an executable.
  class Compiler
    CC = ENV["CC"]? || "cc"

    # A source to the compiler: it's filename and source code.
    record Source,
      filename : String,
      code : String

    # The result of a compilation: the program containing all
    # the type and method definitions, and the parsed program
    # as an ASTNode.
    record Result,
      program : Program,
      node : ASTNode

    # If `true`, doesn't generate an executable but instead
    # creates a `.o` file and outputs a command line to link
    # it in the target machine.
    property cross_compile = false

    # Compiler flags. These will be true when checked in macro
    # code by the `flag?(...)` macro method.
    property flags = [] of String

    # If `true`, the executable will be generated with debug code
    # that can be understood by `gdb` and `lldb`.
    property debug = Debug::Default

    # If `true`, `.ll` files will be generated in the default cache
    # directory for each generated LLVM module.
    property? dump_ll = false

    # Additional link flags to pass to the linker.
    property link_flags : String?

    # Sets the mcpu. Check LLVM docs to learn about this.
    property mcpu : String?

    # Sets the mattr (features). Check LLVM docs to learn about this.
    property mattr : String?

    # If `false`, color won't be used in output messages.
    property? color = true

    # If `true`, skip cleanup process on semantic analysis.
    property? no_cleanup = false

    # If `true`, no executable will be generated after compilation
    # (useful to type-check a prorgam)
    property? no_codegen = false

    # Maximum number of LLVM modules that are compiled in parallel
    property n_threads = 8

    # Default prelude file to use. This ends up adding a
    # `require "prelude"` (or whatever name is set here) to
    # the source file to compile.
    property prelude = "prelude"

    # If `true`, runs LLVM optimizations.
    property? release = false

    # If `true`, generates a single LLVM module. By default
    # one LLVM module is created for each type in a program.
    property? single_module = false

    # If `true`, prints time and memory stats to `stdout`.
    property? stats = false

    # Target triple to use in the compilation.
    # If not set, asks LLVM the default one for the current machine.
    property target_triple : String?

    # If `true`, prints the link command line that is performed
    # to create the executable.
    property? verbose = false

    # If `true`, doc comments are attached to types and methods
    # and can later be used to generate API docs.
    property? wants_doc = false

    # Can be set to an array of strings to emit other files other
    # than the executable file:
    # * asm: assembly files
    # * llvm-bc: LLVM bitcode
    # * llvm-ir: LLVM IR
    # * obj: object file
    property emit : Array(String)?

    # Base filename to use for `emit` output.
    property emit_base_filename : String?

    # By default the compiler cleans up the default cache directory
    # to keep the most recent 10 directories used. If this is set
    # to `false` that cleanup is not performed.
    property? cleanup = true

    # Default standard output to use in a compilation.
    property stdout : IO = STDOUT

    # Default standard error to use in a compilation.
    property stderr : IO = STDERR

    # Whether to show error trace
    property? show_error_trace = false

    # Compiles the given *source*, with *output_filename* as the name
    # of the generated executable.
    #
    # Raises `Crystal::Exception` if there's an error in the
    # source code.
    #
    # Raies `InvalidByteSequenceError` if the source code is not
    # valid UTF-8.
    def compile(source : Source | Array(Source), output_filename : String) : Result
      source = [source] unless source.is_a?(Array)
      program = new_program(source)
      node = parse program, source
      node = program.semantic node, cleanup: !no_cleanup?
      result = codegen program, node, source, output_filename unless @no_codegen
      print_macro_run_stats(program)
      print_codegen_stats(result)
      Result.new program, node
    end

    # Runs the semantic pass on the given source, without generating an
    # executable nor analyzing methods. The returned `Program` in the result will
    # contain all types and methods. This can be useful to generate
    # API docs, analyze type relationships, etc.
    #
    # Raises `Crystal::Exception` if there's an error in the
    # source code.
    #
    # Raies `InvalidByteSequenceError` if the source code is not
    # valid UTF-8.
    def top_level_semantic(source : Source | Array(Source)) : Result
      source = [source] unless source.is_a?(Array)
      program = new_program(source)
      node = parse program, source
      node, processor = program.top_level_semantic(node)
      print_macro_run_stats(program)
      Result.new program, node
    end

    private def new_program(sources)
      program = Program.new
      program.filename = sources.first.filename
      program.cache_dir = CacheDir.instance.directory_for(sources)
      program.target_machine = target_machine
      program.flags << "release" if release?
      program.flags << "debug" unless debug.none?
      program.flags.merge! @flags
      program.wants_doc = wants_doc?
      program.color = color?
      program.stdout = stdout
      program.show_error_trace = show_error_trace?
      program.wants_stats = @stats
      program
    end

    private def parse(program, sources : Array)
      Crystal.timing("Parse", @stats) do
        nodes = sources.map do |source|
          # We add the source to the list of required file,
          # so it can't be required again
          program.add_to_requires source.filename
          parse(program, source).as(ASTNode)
        end
        nodes = Expressions.from(nodes)

        # Prepend the prelude to the parsed program
        location = Location.new(program.filename, 1, 1)
        nodes = Expressions.new([Require.new(prelude).at(location), nodes] of ASTNode)

        # And normalize
        program.normalize(nodes)
      end
    end

    private def parse(program, source : Source)
      parser = Parser.new(source.code, program.string_pool)
      parser.filename = source.filename
      parser.wants_doc = wants_doc?
      parser.parse
    rescue ex : InvalidByteSequenceError
      stdout.print colorize("Error: ").red.bold
      stdout.print colorize("file '#{Crystal.relative_filename(source.filename)}' is not a valid Crystal source file: ").bold
      stdout.puts ex.message
      exit 1
    end

    private def bc_flags_changed?(output_dir)
      bc_flags_changed = true
      current_bc_flags = "#{@target_triple}|#{@mcpu}|#{@mattr}|#{@release}|#{@link_flags}"
      bc_flags_filename = "#{output_dir}/bc_flags"
      if File.file?(bc_flags_filename)
        previous_bc_flags = File.read(bc_flags_filename).strip
        bc_flags_changed = previous_bc_flags != current_bc_flags
      end
      File.write(bc_flags_filename, current_bc_flags)
      bc_flags_changed
    end

    private def codegen(program : Program, node, sources, output_filename)
      @link_flags = "#{@link_flags} -rdynamic"

      llvm_modules = Crystal.timing("Codegen (crystal)", @stats) do
        program.codegen node, debug: debug, single_module: @single_module || @release || @cross_compile || @emit, expose_crystal_main: false
      end

      if @cross_compile
        output_dir = "."
      else
        output_dir = CacheDir.instance.directory_for(sources)
      end

      bc_flags_changed = bc_flags_changed? output_dir

      units = llvm_modules.map do |type_name, llvm_mod|
        CompilationUnit.new(self, type_name, llvm_mod, output_dir, bc_flags_changed)
      end

      lib_flags = program.lib_flags

      if @cross_compile
        cross_compile program, units, lib_flags, output_filename
      else
        result = codegen program, units, lib_flags, output_filename, output_dir
      end

      CacheDir.instance.cleanup if @cleanup

      result
    end

    private def cross_compile(program, units, lib_flags, output_filename)
      llvm_mod = units.first.llvm_mod
      object_name = "#{output_filename}.o"

      optimize llvm_mod if @release
      llvm_mod.print_to_file object_name.gsub(/\.o/, ".ll") if dump_ll?

      target_machine.emit_obj_to_file llvm_mod, object_name

      stdout.puts "#{CC} #{object_name} -o #{output_filename} #{@link_flags} #{lib_flags}"
    end

    private def codegen(program, units : Array(CompilationUnit), lib_flags, output_filename, output_dir)
      object_names = units.map &.object_filename

      target_triple = target_machine.triple
      reused = [] of String

      Crystal.timing("Codegen (bc+obj)", @stats) do
        if units.size == 1
          first_unit = units.first

          codegen_single_unit(program, first_unit, target_triple)
          reused << first_unit.name if first_unit.reused_previous_compilation?

          if emit = @emit
            first_unit.emit(emit, emit_base_filename || output_filename)
          end
        else
          reused = codegen_many_units(program, units, target_triple)
        end
      end

      # We check again because maybe this directory was created in between (maybe with a macro run)
      if Dir.exists?(output_filename)
        error "can't use `#{output_filename}` as output filename because it's a directory"
      end

      output_filename = File.expand_path(output_filename)

      Crystal.timing("Codegen (linking)", @stats) do
        Dir.cd(output_dir) do
          system %(#{CC} -o "#{output_filename}" "${@}" #{@link_flags} #{lib_flags}), object_names
        end
      end

      {units, reused}
    end

    private def codegen_many_units(program, units, target_triple)
      jobs_count = 0
      reused = [] of String
      wait_channel = Channel(Nil).new(@n_threads)

      # For stats output we want to count how many previous
      # .o files were reused, mainly to detect performance regressions.
      # Because we fork, we must communicate using a pipe.
      if @stats
        pr, pw = IO.pipe
        spawn do
          pr.each_line do |line|
            reused << line
          end
        end
      end

      units.each_slice(Math.max(units.size / @n_threads, 1)) do |slice|
        jobs_count += 1
        spawn do
          codegen_process = fork do
            pipe_w = pw
            slice.each do |unit|
              codegen_single_unit(program, unit, target_triple)
              if pipe_w && unit.reused_previous_compilation?
                pipe_w.puts unit.name
              end
            end
          end
          codegen_process.wait
          wait_channel.send nil
        end
      end

      jobs_count.times { wait_channel.receive }
      if pipe_w = pw
        pipe_w.close
        Fiber.yield
      end

      reused
    end

    private def codegen_single_unit(program, unit, target_triple)
      unit.llvm_mod.target = target_triple
      unit.compile
    end

    private def print_macro_run_stats(program)
      return unless @stats && !program.compiled_macros_cache.empty?

      puts
      puts "Macro runs:"
      program.compiled_macros_cache.each do |filename, compiled_macro_run|
        print " - "
        print filename
        print ": "
        if compiled_macro_run.reused
          print "reused previous compilation (#{compiled_macro_run.elapsed})"
        else
          print compiled_macro_run.elapsed
        end
        puts
      end
    end

    private def print_codegen_stats(result)
      return unless @stats
      return unless result

      units, reused = result

      puts
      puts "Codegen (bc+obj):"
      if units.size == reused.size
        puts " - all previous .o files were reused"
      elsif reused.size == 0
        puts " - no previous .o files were reused"
      else
        puts " - #{reused.size}/#{units.size} .o files were reused"
        not_reused = units.reject { |u| reused.includes?(u.name) }
        puts
        puts "These modules were not reused:"
        not_reused.each do |unit|
          puts " - #{unit.original_name} (#{unit.name}.bc)"
        end
      end
    end

    protected def target_machine
      @target_machine ||= begin
        triple = @target_triple || LLVM.default_target_triple
        TargetMachine.create(triple, @mcpu || "", @mattr || "", @release)
      end
    rescue ex : ArgumentError
      stdout.print colorize("Error: ").red.bold
      stdout.print "llc: "
      stdout.puts ex.message
      exit 1
    end

    protected def optimize(llvm_mod)
      fun_pass_manager = llvm_mod.new_function_pass_manager
      {% if LibLLVM::IS_35 || LibLLVM::IS_36 %}
        fun_pass_manager.add_target_data target_machine.data_layout
      {% end %}
      pass_manager_builder.populate fun_pass_manager
      fun_pass_manager.run llvm_mod
      module_pass_manager.run llvm_mod
    end

    @module_pass_manager : LLVM::ModulePassManager?

    private def module_pass_manager
      @module_pass_manager ||= begin
        mod_pass_manager = LLVM::ModulePassManager.new
        {% if LibLLVM::IS_35 || LibLLVM::IS_36 %}
          mod_pass_manager.add_target_data target_machine.data_layout
        {% end %}
        pass_manager_builder.populate mod_pass_manager
        mod_pass_manager
      end
    end

    @pass_manager_builder : LLVM::PassManagerBuilder?

    private def pass_manager_builder
      @pass_manager_builder ||= begin
        registry = LLVM::PassRegistry.instance
        registry.initialize_all

        builder = LLVM::PassManagerBuilder.new
        builder.opt_level = 3
        builder.size_level = 0
        builder.use_inliner_with_threshold = 275
        builder
      end
    end

    private def system(command, args = nil)
      stdout.puts "#{command} #{args.join " "}" if verbose?

      ::system(command, args)
      unless $?.success?
        msg = $?.normal_exit? ? "code: #{$?.exit_code}" : "signal: #{$?.exit_signal} (#{$?.exit_signal.value})"
        code = $?.normal_exit? ? $?.exit_code : 1
        error "execution of command failed with #{msg}: `#{command}`", exit_code: code
      end
    end

    private def error(msg, exit_code = 1)
      Crystal.error msg, @color, exit_code, stderr: stderr
    end

    private def colorize(obj)
      obj.colorize.toggle(@color)
    end

    # An LLVM::Module with information to compile it.
    class CompilationUnit
      getter compiler
      getter name
      getter original_name
      getter llvm_mod
      getter? reused_previous_compilation = false

      def initialize(@compiler : Compiler, @name : String, @llvm_mod : LLVM::Module,
                     @output_dir : String, @bc_flags_changed : Bool)
        @name = "_main" if @name == ""
        @original_name = @name
        @name = String.build do |str|
          @name.each_char do |char|
            case char
            when 'a'..'z', '0'..'9', '_'
              str << char
            when 'A'..'Z'
              # Because OSX has case insensitive filenames, try to avoid
              # clash of 'a' and 'A' by using 'A-' for 'A'.
              str << char << '-'
            else
              str << char.ord
            end
          end
        end

        if @name.size > 50
          # 17 chars from name + 1 (dash) + 32 (md5) = 50
          @name = "#{@name[0..16]}-#{Crypto::MD5.hex_digest(@name)}"
        end
      end

      def compile
        bc_name = self.bc_name
        object_name = self.object_name

        # To compile a file we first generate a `.bc` file and then
        # create an object file from it. These `.bc` files are stored
        # in the cache directory.
        #
        # On a next compilation of the same project, and if the compile
        # flags didn't change (a combination of the target triple, mcpu,
        # release and link flags, amongst others), we check if the new
        # `.bc` file is exactly the same as the old one. In that case
        # the `.o` file will also be the same, so we simply reuse the
        # old one. Generating an `.o` file is what takes most time.

        must_compile = true
        can_reuse_previous_compilation =
          !compiler.emit && !@bc_flags_changed && File.exists?(bc_name) && File.exists?(object_name)

        {% if LibLLVM::IS_35 %}
          # In LLVM 3.5 we can't write a bitcode to memory,
          # so instead we write it to another file
          bc_name_new = self.bc_name_new
          llvm_mod.write_bitcode_to_file(bc_name_new)

          if can_reuse_previous_compilation
            if FileUtils.cmp(bc_name, bc_name_new)
              # If the user cancelled a previous compilation it might be that
              # the .o file is empty
              if File.size(object_name) > 0
                File.delete bc_name_new
                must_compile = false
              end
            end
          end

          if must_compile
            # Create/overwrite the .bc file (for next compilations)
            File.rename(bc_name_new, bc_name)
            compiler.optimize llvm_mod if compiler.release?
            compiler.target_machine.emit_obj_to_file llvm_mod, object_name
          end
        {% else %}
          memory_buffer = llvm_mod.write_bitcode_to_memory_buffer

          if can_reuse_previous_compilation
            memory_io = IO::Memory.new(memory_buffer.to_slice)
            changed = File.open(bc_name) { |bc_file| !FileUtils.cmp(bc_file, memory_io) }

            # If the user cancelled a previous compilation
            # it might be that the .o file is empty
            if !changed && File.size(object_name) > 0
              must_compile = false
              memory_buffer.dispose
              memory_buffer = nil
            else
              # We need to compile, so we'll write the memory buffer to file
            end
          end

          # If there's a memory buffer, it means we must create a .o from it
          if memory_buffer
            # Create the .bc file (for next compilations)
            File.write(bc_name, memory_buffer.to_slice)
            memory_buffer.dispose
          end
        {% end %}

        if must_compile
          compiler.optimize llvm_mod if compiler.release?
          compiler.target_machine.emit_obj_to_file llvm_mod, object_name
        else
          @reused_previous_compilation = true
        end

        llvm_mod.print_to_file ll_name if compiler.dump_ll?
      end

      def emit(values : Array, output_filename)
        values.each do |value|
          emit value, output_filename
        end
      end

      def emit(value : String, output_filename)
        case value
        when "asm"
          compiler.target_machine.emit_asm_to_file llvm_mod, "#{output_filename}.s"
        when "llvm-bc"
          FileUtils.cp(bc_name, "#{output_filename}.bc")
        when "llvm-ir"
          llvm_mod.print_to_file "#{output_filename}.ll"
        when "obj"
          FileUtils.cp(object_name, "#{output_filename}.o")
        end
      end

      def object_name
        Crystal.relative_filename("#{@output_dir}/#{object_filename}")
      end

      def object_filename
        "#{@name}.o"
      end

      def bc_name
        "#{@output_dir}/#{@name}.bc"
      end

      def bc_name_new
        "#{@output_dir}/#{@name}.new.bc"
      end

      def ll_name
        "#{@output_dir}/#{@name}.ll"
      end
    end
  end
end
