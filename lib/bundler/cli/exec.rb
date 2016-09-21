# frozen_string_literal: true
require "bundler/current_ruby"

module Bundler
  class CLI::Exec
    attr_reader :options, :args, :cmd

    RESERVED_SIGNALS = %w(SEGV BUS ILL FPE VTALRM KILL STOP).freeze

    def initialize(options, args)
      @options = options
      @cmd = args.shift
      @args = args

      if Bundler.current_ruby.ruby_2? && !Bundler.current_ruby.jruby?
        @args << { :close_others => !options.keep_file_descriptors? }
      elsif options.keep_file_descriptors?
        Bundler.ui.warn "Ruby version #{RUBY_VERSION} defaults to keeping non-standard file descriptors on Kernel#exec."
      end
    end

    def run
      validate_cmd!
      SharedHelpers.set_bundle_environment
      if bin_path = Bundler.which(cmd)
        if !Bundler.settings[:disable_exec_load] && ruby_shebang?(bin_path)
          return kernel_load(bin_path, *args)
        end
        # First, try to exec directly to something in PATH
        if Bundler.current_ruby.jruby_18?
          kernel_exec(bin_path, *args)
        else
          kernel_exec([bin_path, cmd], *args)
        end
      else
        # exec using the given command
        kernel_exec(cmd, *args)
      end
    end

  private

    def validate_cmd!
      return unless cmd.nil?
      Bundler.ui.error "bundler: exec needs a command to run"
      exit 128
    end

    def kernel_exec(*args)
      ui = Bundler.ui
      Bundler.ui = nil
      Kernel.exec(*args)
    rescue Errno::EACCES, Errno::ENOEXEC
      Bundler.ui = ui
      Bundler.ui.error "bundler: not executable: #{cmd}"
      exit 126
    rescue Errno::ENOENT
      Bundler.ui = ui
      Bundler.ui.error "bundler: command not found: #{cmd}"
      Bundler.ui.warn "Install missing gem executables with `bundle install`"
      exit 127
    end

    def kernel_load(file, *args)
      args.pop if args.last.is_a?(Hash)
      ARGV.replace(args)
      $0 = file
      Process.setproctitle(process_title(file, args)) if Process.respond_to?(:setproctitle)
      ui = Bundler.ui
      Bundler.ui = nil
      configure_gem_path_override
      require "bundler/setup"
      signals = Signal.list.keys - RESERVED_SIGNALS
      signals.each {|s| trap(s, "DEFAULT") }
      Kernel.load(file)
    rescue SystemExit
      raise
    rescue Exception => e # rubocop:disable Lint/RescueException
      Bundler.ui = ui
      Bundler.ui.error "bundler: failed to load command: #{cmd} (#{file})"
      backtrace = e.backtrace.take_while {|bt| !bt.start_with?(__FILE__) }
      abort "#{e.class}: #{e.message}\n  #{backtrace.join("\n  ")}"
    end

    # This is a bit esoteric. There's two separate pieces to understand first.
    #
    # (1) When `:disable_shared_gems` is true, the `GEM_PATH` gets initialized
    # to an empty string. This is done to make sure it's expanded to ONLY the
    # Bundler --path setting, otherwise it expands to include the system path.
    #
    # (2) Prior to 1.12, the code here in bundle exec didn't use Kernel.load
    # and didn't `require "bundler/setup"`, which meant the path to gems was
    # never involved.
    #
    # In 1.12, bundle exec was overhauled for various reasons to use
    # Kernel.load, and `require "bundler/setup"` is now invoked, which created
    # a bug. In cases like `--deployment` where `disable_shared_gems` is true,
    # Bundler couldn't find itself, because Bundler never lives in the
    # `--path` but only in system gems.
    #
    # We fixed this (the bundle exec bug) in 1.13.0 by changing GEM_PATH to be
    # initialized to nil instead of empty string in all cases. But it created
    # another bug. We've reverted the change so that GEM_PATH is now back to
    # being initialized, but still need to override how the GEM_PATH is set
    # in this special case so that the bundler executable can be found.
    def configure_gem_path_override
      Bundler.settings.temporary(:disable_shared_gems => false)
    end

    def process_title(file, args)
      "#{file} #{args.join(" ")}".strip
    end

    def ruby_shebang?(file)
      possibilities = [
        "#!/usr/bin/env ruby\n",
        "#!/usr/bin/env jruby\n",
        "#!#{Gem.ruby}\n",
      ]
      first_line = File.open(file, "rb") {|f| f.read(possibilities.map(&:size).max) }
      possibilities.any? {|shebang| first_line.start_with?(shebang) }
    end
  end
end
