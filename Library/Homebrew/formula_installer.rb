# encoding: UTF-8

require 'cxxstdlib'
require 'exceptions'
require 'formula'
require 'keg'
require 'tab'
require 'bottles'
require 'caveats'
require 'cleaner'
require 'formula_cellar_checks'
require 'install_renamed'
require 'cmd/tap'
require 'hooks/bottles'
require 'debrew'

class FormulaInstaller
  include FormulaCellarChecks

  def self.mode_attr_accessor(*names)
    attr_accessor(*names)
    names.each { |name| define_method("#{name}?") { !!send(name) }}
  end

  attr_reader :f
  attr_accessor :options
  mode_attr_accessor :show_summary_heading, :show_header
  mode_attr_accessor :build_from_source, :build_bottle, :force_bottle
  mode_attr_accessor :ignore_deps, :only_deps, :interactive
  mode_attr_accessor :verbose, :debug

  def initialize ff
    @f = ff
    @show_header = false
    @ignore_deps = false
    @only_deps = false
    @build_from_source = false
    @build_bottle = false
    @force_bottle = false
    @interactive = false
    @verbose = false
    @debug = false
    @options = Options.new

    @@attempted ||= Set.new

    @poured_bottle = false
    @pour_failed   = false
  end

  def pour_bottle? install_bottle_options={:warn=>false}
    return true if Homebrew::Hooks::Bottles.formula_has_bottle?(f)

    return false if @pour_failed
    return true  if force_bottle? && f.bottle
    return false if build_from_source? || build_bottle? || interactive?
    return false unless options.empty?

    if OS.linux?
      return true if f.name == "linux-headers"
      return true if f.name == "patchelf" && Formula["glibc"].installed?
      return false unless Formula["glibc"].installed? && Formula["patchelf"].installed?
    end

    return true if f.local_bottle_path
    return false unless f.bottle && f.pour_bottle?

    unless f.bottle.compatible_cellar?
      if install_bottle_options[:warn]
        opoo "Building source; cellar of #{f.name}'s bottle is #{f.bottle.cellar}"
      end
      return false
    end

    true
  end

  def install_bottle_for_dep?(dep, build)
    return false if build_from_source?
    return false unless dep.bottle && dep.pour_bottle?
    return false unless build.used_options.empty?
    return false unless dep.bottle.compatible_cellar?
    return true
  end

  def prelude
    verify_deps_exist unless ignore_deps?
    lock
    check_install_sanity
  end

  def verify_deps_exist
    begin
      f.recursive_dependencies.map(&:to_formula)
    rescue TapFormulaUnavailableError => e
      if Homebrew.install_tap(e.user, e.repo)
        retry
      else
        raise
      end
    end
  rescue FormulaUnavailableError => e
    e.dependent = f.name
    raise
  end

  def check_install_sanity
    raise FormulaInstallationAlreadyAttemptedError, f if @@attempted.include? f

    if f.installed?
      msg = "#{f.name}-#{f.installed_version} already installed"
      msg << ", it's just not linked" unless f.linked_keg.symlink? or f.keg_only?
      raise FormulaAlreadyInstalledError, msg
    end

    unless ignore_deps?
      unlinked_deps = f.recursive_dependencies.map(&:to_formula).select do |dep|
        dep.installed? and not dep.keg_only? and not dep.linked_keg.directory?
      end
      raise CannotInstallFormulaError,
        "You must `brew link #{unlinked_deps*' '}' before #{f.name} can be installed" unless unlinked_deps.empty?
    end
  end

  def build_bottle_preinstall
    @etc_var_glob ||= "#{HOMEBREW_PREFIX}/{etc,var}/**/*"
    @etc_var_preinstall = Dir[@etc_var_glob]
  end

  def build_bottle_postinstall
    @etc_var_postinstall = Dir[@etc_var_glob]
    (@etc_var_postinstall - @etc_var_preinstall).each do |file|
      Pathname.new(file).cp_path_sub(HOMEBREW_PREFIX, f.bottle_prefix)
    end
  end

  def install
    # not in initialize so upgrade can unlink the active keg before calling this
    # function but after instantiating this class so that it can avoid having to
    # relink the active keg if possible (because it is slow).
    if f.linked_keg.directory?
      # some other version is already installed *and* linked
      raise CannotInstallFormulaError, <<-EOS.undent
        #{f.name}-#{f.linked_keg.resolved_path.basename} already installed
        To install this version, first `brew unlink #{f.name}'
      EOS
    end

    check_conflicts

    compute_and_install_dependencies unless ignore_deps?

    return if only_deps?

    if build_bottle? && (arch = ARGV.bottle_arch) && !Hardware::CPU.optimization_flags.include?(arch)
      raise "Unrecognized architecture for --bottle-arch: #{arch}"
    end

    f.active_spec.deprecated_flags.each do |deprecated_option|
      old_flag = deprecated_option.old_flag
      new_flag = deprecated_option.current_flag
      opoo "#{f.name}: #{old_flag} was deprecated; using #{new_flag} instead!"
    end

    oh1 "Installing #{Tty.green}#{f.name}#{Tty.reset}" if show_header?

    @@attempted << f

    if pour_bottle?(:warn => true)
      begin
        pour
      rescue => e
        raise if ARGV.homebrew_developer?
        @pour_failed = true
        onoe e.message
        opoo "Bottle installation failed: building from source."
      else
        @poured_bottle = true
      end
    end

    build_bottle_preinstall if build_bottle?

    unless @poured_bottle
      compute_and_install_dependencies if @pour_failed and not ignore_deps?
      build
      clean
    end

    build_bottle_postinstall if build_bottle?

    opoo "Nothing was installed to #{f.prefix}" unless f.installed?
  end

  # HACK: If readline is present in the dependency tree, it will clash
  # with the stdlib's Readline module when the debugger is loaded
  def perform_readline_hack
    if (f.recursive_dependencies.any? { |d| d.name == "readline" } || f.name == "readline") && debug?
      ENV['HOMEBREW_NO_READLINE'] = '1'
    end
  end

  def check_conflicts
    return if ARGV.force?

    conflicts = f.conflicts.reject do |c|
      keg = Formulary.factory(c.name).prefix
      not keg.directory? && Keg.new(keg).linked?
    end

    raise FormulaConflictError.new(f, conflicts) unless conflicts.empty?
  end

  def compute_and_install_dependencies
    perform_readline_hack

    req_map, req_deps = expand_requirements

    check_requirements(req_map)

    deps = expand_dependencies(req_deps + f.deps)

    if deps.empty? and only_deps?
      puts "All dependencies for #{f.name} are satisfied."
    else
      install_dependencies(deps)
    end
  end

  def check_requirements(req_map)
    fatals = []

    req_map.each_pair do |dependent, reqs|
      reqs.each do |req|
        puts "#{dependent}: #{req.message}"
        fatals << req if req.fatal?
      end
    end

    raise UnsatisfiedRequirements.new(fatals) unless fatals.empty?
  end

  def install_requirement_default_formula?(req, build)
    return false unless req.default_formula?
    return false if build.without?(req) && (req.recommended? || req.optional?)
    return true unless req.satisfied?
    pour_bottle? || build_bottle?
  end

  def expand_requirements
    unsatisfied_reqs = Hash.new { |h, k| h[k] = [] }
    deps = []
    formulae = [f]

    while f = formulae.pop

      f.recursive_requirements do |dependent, req|
        build = effective_build_options_for(dependent)

        if (req.optional? || req.recommended?) && build.without?(req)
          Requirement.prune
        elsif req.build? && dependent == self.f && pour_bottle?
          Requirement.prune
        elsif req.build? && dependent != self.f && install_bottle_for_dep?(dependent, build)
          Requirement.prune
        elsif install_requirement_default_formula?(req, build)
          dep = req.to_dependency
          deps.unshift(dep)
          formulae.unshift(dep.to_formula)
          Requirement.prune
        elsif req.satisfied?
          Requirement.prune
        else
          unsatisfied_reqs[dependent] << req
        end
      end
    end

    return unsatisfied_reqs, deps
  end

  def expand_dependencies(deps)
    inherited_options = {}

    expanded_deps = Dependency.expand(f, deps) do |dependent, dep|
      options = inherited_options[dep.name] = inherited_options_for(dep)
      build = effective_build_options_for(
        dependent,
        inherited_options.fetch(dependent.name, [])
      )

      if (dep.optional? || dep.recommended?) && build.without?(dep)
        Dependency.prune
      elsif dep.build? && dependent == f && pour_bottle?
        Dependency.prune
      elsif dep.build? && dependent != f && install_bottle_for_dep?(dependent, build)
        Dependency.prune
      elsif dep.satisfied?(options)
        Dependency.skip
      end
    end

    expanded_deps.map { |dep| [dep, inherited_options[dep.name]] }
  end

  def effective_build_options_for(dependent, inherited_options=[])
    args  = dependent.build.used_options
    args |= dependent == f ? options : inherited_options
    args |= Tab.for_formula(dependent).used_options
    BuildOptions.new(args, dependent.options)
  end

  def inherited_options_for(dep)
    inherited_options = Options.new
    u = Option.new("universal")
    if (options.include?(u) || f.require_universal_deps?) && !dep.build? && dep.to_formula.option_defined?(u)
      inherited_options << u
    end
    inherited_options
  end

  def install_dependencies(deps)
    if deps.length > 1
      oh1 "Installing dependencies for #{f.name}: #{Tty.green}#{deps.map(&:first)*", "}#{Tty.reset}"
    end

    deps.each { |dep, options| install_dependency(dep, options) }

    @show_header = true unless deps.empty?
  end

  class DependencyInstaller < FormulaInstaller
    def initialize ff
      super
      @ignore_deps = true
    end

    def sanitized_ARGV_options
      args = super
      args.delete "--ignore-dependencies"
      args
    end
  end

  def install_dependency(dep, inherited_options)
    df = dep.to_formula
    tab = Tab.for_formula(df)

    if df.linked_keg.directory?
      linked_keg = Keg.new(df.linked_keg.resolved_path)
      linked_keg.unlink
    end

    if df.installed?
      installed_keg = Keg.new(df.prefix)
      tmp_keg = Pathname.new("#{installed_keg}.tmp")
      installed_keg.rename(tmp_keg)
    end

    fi = DependencyInstaller.new(df)
    fi.options           |= tab.used_options
    fi.options           |= dep.options
    fi.options           |= inherited_options
    fi.build_from_source  = build_from_source?
    fi.verbose            = verbose? unless verbose == :quieter
    fi.debug              = debug?
    fi.prelude
    oh1 "Installing #{f.name} dependency: #{Tty.green}#{dep.name}#{Tty.reset}"
    fi.install
    fi.caveats
    fi.finish
  rescue Exception
    ignore_interrupts do
      tmp_keg.rename(installed_keg) if tmp_keg && !installed_keg.directory?
      linked_keg.link if linked_keg
    end
    raise
  else
    ignore_interrupts { tmp_keg.rmtree if tmp_keg && tmp_keg.directory? }
  end

  def caveats
    return if only_deps?

    audit_installed if ARGV.homebrew_developer? and not f.keg_only?

    c = Caveats.new(f)

    unless c.empty?
      @show_summary_heading = true
      ohai 'Caveats', c.caveats
    end
  end

  def finish
    return if only_deps?

    ohai 'Finishing up' if verbose?

    install_plist

    keg = Keg.new(f.prefix)
    link(keg)
    fix_install_names(keg)

    post_install

    ohai "Summary" if verbose? or show_summary_heading?
    puts summary
  ensure
    unlock if hold_locks?
  end

  def emoji
    ENV['HOMEBREW_INSTALL_BADGE'] || "\xf0\x9f\x8d\xba"
  end

  def summary
    s = ""
    s << "#{emoji}  " if MacOS.version >= :lion and not ENV['HOMEBREW_NO_EMOJI']
    s << "#{f.prefix}: #{f.prefix.abv}"
    s << ", built in #{pretty_duration build_time}" if build_time
    s
  end

  def build_time
    @build_time ||= Time.now - @start_time if @start_time && !interactive?
  end

  def sanitized_ARGV_options
    args = []
    args << "--ignore-dependencies" if ignore_deps?

    if build_bottle?
      args << "--build-bottle"
      args << "--bottle-arch=#{ARGV.bottle_arch}" if ARGV.bottle_arch
    end

    if interactive?
      args << "--interactive"
      args << "--git" if interactive == :git
    end

    args << "--verbose" if verbose?
    args << "--debug" if debug?
    args << "--cc=#{ARGV.cc}" if ARGV.cc
    args << "--env=#{ARGV.env}" if ARGV.env

    case f.active_spec
    when f.head  then args << "--HEAD"
    when f.devel then args << "--devel"
    end

    f.options.each do |opt|
      name  = opt.name[/\A(.+)=\z$/, 1]
      value = ARGV.value(name)
      args << "--#{name}=#{value}" if name && value
    end

    args
  end

  def build_argv
    sanitized_ARGV_options + options.as_flags
  end

  def build
    FileUtils.rm Dir["#{HOMEBREW_LOGS}/#{f.name}/*"]

    @start_time = Time.now

    # 1. formulae can modify ENV, so we must ensure that each
    #    installation has a pristine ENV when it starts, forking now is
    #    the easiest way to do this
    read, write = IO.pipe
    # I'm guessing this is not a good way to do this, but I'm no UNIX guru
    ENV['HOMEBREW_ERROR_PIPE'] = write.to_i.to_s

    args = %W[
      nice #{RUBY_PATH}
      -W0
      -I #{HOMEBREW_LIBRARY_PATH}
      --
      #{HOMEBREW_LIBRARY_PATH}/build.rb
      #{f.path}
    ].concat(build_argv)

    # Ruby 2.0+ sets close-on-exec on all file descriptors except for
    # 0, 1, and 2 by default, so we have to specify that we want the pipe
    # to remain open in the child process.
    args << { write => write } if RUBY_VERSION >= "2.0"

    pid = fork do
      begin
        read.close
        exec(*args)
      rescue Exception => e
        Marshal.dump(e, write)
        write.close
        exit! 1
      end
    end

    ignore_interrupts(:quietly) do # the child will receive the interrupt and marshal it back
      write.close
      data = read.read
      read.close
      Process.wait(pid)
      raise Marshal.load(data) unless data.nil? or data.empty?
      raise Interrupt if $?.exitstatus == 130
      raise "Suspicious installation failure" unless $?.success?
    end

    raise "Empty installation" if Dir["#{f.prefix}/*"].empty?

  rescue Exception
    ignore_interrupts do
      # any exceptions must leave us with nothing installed
      f.prefix.rmtree if f.prefix.directory?
      f.rack.rmdir_if_possible
    end
    raise
  end

  def link(keg)
    if f.keg_only?
      begin
        keg.optlink
      rescue Keg::LinkError => e
        onoe "Failed to create #{f.opt_prefix}"
        puts "Things that depend on #{f.name} will probably not build."
        puts e
        Homebrew.failed = true
      end
      return
    end

    if keg.linked?
      opoo "This keg was marked linked already, continuing anyway"
      keg.remove_linked_keg_record
    end

    begin
      keg.link
    rescue Keg::ConflictError => e
      onoe "The `brew link` step did not complete successfully"
      puts "The formula built, but is not symlinked into #{HOMEBREW_PREFIX}"
      puts e
      puts
      puts "Possible conflicting files are:"
      mode = OpenStruct.new(:dry_run => true, :overwrite => true)
      keg.link(mode)
      @show_summary_heading = true
      Homebrew.failed = true
    rescue Keg::LinkError => e
      onoe "The `brew link` step did not complete successfully"
      puts "The formula built, but is not symlinked into #{HOMEBREW_PREFIX}"
      puts e
      puts
      puts "You can try again using:"
      puts "  brew link #{f.name}"
      @show_summary_heading = true
      Homebrew.failed = true
    rescue Exception => e
      onoe "An unexpected error occurred during the `brew link` step"
      puts "The formula built, but is not symlinked into #{HOMEBREW_PREFIX}"
      puts e
      puts e.backtrace if debug?
      @show_summary_heading = true
      ignore_interrupts { keg.unlink }
      Homebrew.failed = true
      raise
    end
  end

  def install_plist
    return unless f.plist
    f.plist_path.atomic_write(f.plist)
    f.plist_path.chmod 0644
  rescue Exception => e
    onoe "Failed to install plist file"
    ohai e, e.backtrace if debug?
    Homebrew.failed = true
  end

  def fix_install_names(keg)
    keg.fix_install_names(:keg_only => f.keg_only?)

    if @poured_bottle
      keg.relocate_install_names Keg::PREFIX_PLACEHOLDER, HOMEBREW_PREFIX.to_s,
        Keg::CELLAR_PLACEHOLDER, HOMEBREW_CELLAR.to_s, :keg_only => f.keg_only?
    end
  rescue Exception => e
    onoe "Failed to fix install names"
    puts "The formula built, but you may encounter issues using it or linking other"
    puts "formula against it."
    ohai e, e.backtrace if debug?
    Homebrew.failed = true
    @show_summary_heading = true
  end

  def clean
    ohai "Cleaning" if verbose?
    Cleaner.new(f).clean
  rescue Exception => e
    opoo "The cleaning step did not complete successfully"
    puts "Still, the installation was successful, so we will link it into your prefix"
    ohai e, e.backtrace if debug?
    Homebrew.failed = true
    @show_summary_heading = true
  end

  def post_install
    f.post_install
  rescue Exception => e
    opoo "The post-install step did not complete successfully"
    puts "You can try again using `brew postinstall #{f.name}`"
    ohai e, e.backtrace if debug?
    Homebrew.failed = true
    @show_summary_heading = true
  end

  def pour
    if Homebrew::Hooks::Bottles.formula_has_bottle?(f)
      return if Homebrew::Hooks::Bottles.pour_formula_bottle(f)
    end

    if f.local_bottle_path
      downloader = LocalBottleDownloadStrategy.new(f)
    else
      downloader = f.bottle
      downloader.verify_download_integrity(downloader.fetch)
    end
    HOMEBREW_CELLAR.cd do
      downloader.stage
    end

    Pathname.glob("#{f.bottle_prefix}/{etc,var}/**/*") do |path|
      path.extend(InstallRenamed)
      path.cp_path_sub(f.bottle_prefix, HOMEBREW_PREFIX)
    end
    FileUtils.rm_rf f.bottle_prefix

    CxxStdlib.check_compatibility(
      f, f.recursive_dependencies,
      Keg.new(f.prefix), MacOS.default_compiler
    )

    tab = Tab.for_keg(f.prefix)
    tab.poured_from_bottle = true
    tab.write
  end

  def audit_check_output(output)
    if output
      opoo output
      @show_summary_heading = true
    end
  end

  def audit_installed
    audit_check_output(check_PATH(f.bin))
    audit_check_output(check_PATH(f.sbin))
    super
  end

  private

  def hold_locks?
    @hold_locks || false
  end

  def lock
    if (@@locked ||= []).empty?
      f.recursive_dependencies.each do |dep|
        @@locked << dep.to_formula
      end unless ignore_deps?
      @@locked.unshift(f)
      @@locked.uniq!
      @@locked.each(&:lock)
      @hold_locks = true
    end
  end

  def unlock
    if hold_locks?
      @@locked.each(&:unlock)
      @@locked.clear
      @hold_locks = false
    end
  end
end


class Formula
  def keg_only_text
    s = "This formula is keg-only, which means it was not symlinked into #{HOMEBREW_PREFIX}."
    s << "\n\n#{keg_only_reason.to_s}"
    if lib.directory? or include.directory?
      s <<
        <<-EOS.undent_________________________________________________________72


        Generally there are no consequences of this for you. If you build your
        own software and it requires this formula, you'll need to add to your
        build variables:

        EOS
      s << "    LDFLAGS:  -L#{opt_lib}\n" if lib.directory?
      s << "    CPPFLAGS: -I#{opt_include}\n" if include.directory?
    end
    s << "\n"
  end
end
