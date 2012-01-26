require 'awesome_print'
require 'date'
require 'etc'
require 'English'
require 'fileutils'
require 'fog'
require 'pathname'

# TODO: Make this regex less naive; ideally, we shouldn't rewrite any lines where the value is correct,
# even if there's a comment present.
# http://stackoverflow.com/questions/8658722/challenge-regex-only-tokenizer-for-shell-assignment-like-config-lines

CONFIG_LINE = %r{
  (?<export> export ){0}
  (?<key> [\w-]+ ){0}
  (?<value> .* ){0}
  (?<comment> \#.*$ ){0}

  ^\s*(\g<export>\s+)?\g<key>\s*=\s*\g<value>\s*(\g<comment>)?$
 }x

IMPLIED_DIR_ENTRIES = /(^|\/)\.\.?$/

DATE   = Date.today.strftime('%Y-%m-%d')
BOLD   = `tput bold`
NORMAL = `tput sgr0`

if `which colordiff` == ''
  DIFF = "diff"
else
  DIFF = "colordiff"
end

# MakeItSo is a DSLish library of methods with the following guarantees[1]:
# - They are idempotent
# - They abort if there are errors
# - They set changed? when they change anything (global state)
# - They return true if they change anything, false if they don't (local state)
#
#   make = MakeItSo.new
#   make.dns_entry("ns.example.com", "1.2.3.4", "A")
    #=> true
#   make.changed?
    #=> true
#   make.dns_entry("ns.example.com", "1.2.3.4", "A")
    #=> false
#   make.reset
#   make.dns_entry("ns.example.com", "1.2.3.4", "A")
    #=> false
#   make.changed?
    #=> false
#
# [1] Yu're right - I can't really call it a guarantee without unit tests. Since you
# brought this up, you should be the one to write them. RSpec preferred.

class MakeItSo

  attr_accessor :apt_updated

  def initialize
    @changed     = false
    @apt_updated = false
  end

  def changed?
    @changed
  end

  def reset
    @changed = false
  end

  def sure_im_root
    unless `whoami`.chomp == 'root'
      puts "You must run this with rvmsudo."
      abort
    end
  end

  # TODO: Support alias records once https://github.com/fog/fog/pull/642 lands

  def dns_entry(name, value, type = 'A')
    # FIXME: don't hardcode aws or tiptap.com

    conflict_types = {'A' => 'CNAME', 'CNAME' => 'A'}

    name    = canonicalize(name)
    value   = canonicalize(value) if type == 'CNAME'
    zone    = Fog::DNS[:aws].zones.all(:domain => 'tiptap.com.').first
    records = Fog::DNS[:aws].records(:zone => zone).all
    record  = records.find{|r| r.name == name and r.type == type}

    if record and record.value != [value]
      puts "Deleting old #{type} record (#{name} -> #{record.value})"
      record.destroy
      record = nil
      @changed = true
    end

    # Automatically delete CNAME when creating an A record or vice versa - any other types, you're on your own
    if conflict_types[type]
      conflict_record = records.find{|r| r.name == name and r.type == conflict_types[type]}
      if conflict_record
        puts "Deleting old, conflicting #{conflict_record.type} record (#{name} -> # conflict_record.value})"
        conflict_record.destroy
        conflict_record = nil
        @changed = true
      end
    end

    unless record
      puts "Creating #{type} record (#{name} -> #{value})"
      Fog::DNS[:aws].records(:zone => zone).create(:name => name, :value => value, :type => type, :ttl => 300)
      @changed = true
    end

    @changed
  end

  # TODO: We probably don't want to set both files and dirs to the same exact mode; let's see what the use case is.

  def chmod(path, mode, options = {})
    paths   = glob(path, options).reject{|f| f.include?(".git")} # We can probably generalize this later
    changed = false

    paths.each do |f|
      old_mode = File.stat(f).mode & 07777
      unless old_mode == mode
        puts "Changing mode of #{f} from #{old_mode.to_s(8)} to #{mode.to_s(8)}"
        FileUtils.chmod(mode, f)
        changed = true
      end
    end

    @changed ||= changed
    changed
  end

  # changes owner AND group
  def chown(path, owner, options = {})
    paths   = glob(path, options)
    owner   = Etc.getpwnam(owner)
    changed = false

    paths.each do |f|
      stat = File.stat(f)
      unless stat.uid == owner.uid && stat.gid == owner.gid
        old_owner = "#{Etc.getpwuid(stat.uid).name}:#{Etc.getgrgid(stat.gid).name}"
        puts "Changing owner of #{f} from #{old_owner} to #{owner.name}:#{owner.name}"
        File.chown(owner.uid, owner.gid, f)
        changed = true
      end
    end

    @changed ||= changed
    changed
  end

  def dir(path)
    path = File.expand_path(path)
    return false if File.directory?(path)

    puts "Creating directory: #{path}"
    FileUtils.mkdir_p(path)
    chown(path, 'ubuntu') # TODO: make configurable
    @changed = true
  end

  def symlink(target, link)
    target  = File.expand_path(target)
    link    = File.expand_path(link)

    # File.realpath chases multiple links to their source, but will raise an error if
    # target doesn't currently exist.  File.readlink only goes one level deep, but works
    # with a non-existent target.

    if File.symlink?(link)
      if File.exist?(link)
        old_target = File.realpath(link)
      else
        old_target = File.readlink(link)
      end
    end

    return false if File.symlink?(link) && old_target == target

    if File.symlink?(link)
      puts "Unlinking #{link} from #{old_target}"
      File.unlink(link)
    elsif File.exist?(link)
      puts "Deleting old #{link}"
      backup_file(link)
      File.unlink(link)
    end

    puts "Linking #{link} to #{target}"
    File.symlink(target, link)
  end

  def file_not_present(*files)
    files.delete_if{|f| File.exist?(f) == false }
    return false if files.empty?

    FileUtils.rm(files)
    @changed = true
  end

  alias files_not_present :file_not_present

  # file_exactly takes "contents" as either a string or an array of strings, and makes that file
  # contain exactly and only those contents.

  def file_exactly(path, contents, *extra_args)
    path = File.expand_path(path)
    changed = (File.exist?(path) == false)

    if contents.kind_of?(Array)
      changed ||= (File.open(path).readlines.map(&:chomp) != contents)
    else
      changed ||= (File.open(path).read.chomp != contents)
    end

    if changed
      backup_file(path)
      puts "Updating #{path}:\n  #{BOLD}#{contents}#{NORMAL}"
      File.open(path, 'w', *extra_args) do |f|
        f.puts(contents)
      end
    elsif extra_args.count == 1 && extra_args[0].is_a?(Integer)
      chmod(path, extra_args[0])
    end

    @changed ||= changed
    changed
  end

  def file_exactly_iff(path, contents, condition)
    if condition
      file_exactly(path, contents)
    else
      file_not_present(path)
    end
  end

  def line_present(path, line)
    path  = File.expand_path(path)
    lines = File.readlines(path)
    return false if lines.any? {|l| l.match(line) }

    puts "In #{path}, adding line:\n  #{BOLD}#{line}#{NORMAL}"
    backup_file(path)
    File.open(path, "a") do |f|
      f.puts(line)
    end
    @changed = true
  end

  def line_not_present(path, pattern)
    path  = File.expand_path(path)
    lines = File.readlines(path)
    matches = lines.select {|l| l.match(pattern) }
    return false if matches.empty?

    matches.each do |m|
      puts "In #{path}, deleting line:\n  #{BOLD}#{m}#{NORMAL}"
    end

    lines.delete_if {|l| l.match(pattern) }

    backup_file(path)
    File.open(path, "w") do |f|
      f.puts(lines)
    end
    @changed = true
  end

  def line_present_iff(path, line, condition)
    if condition
      line_present(path, line)
    else
      line_not_present(path, line)
    end
  end

  # make.config("/etc/apache2/envvars", { 'PATH' => "/usr/local/rvm", 'RAILS_ENV' => "production"})
  def config(path, settings, shell_style = nil)
    path        = File.expand_path(path)
    lines       = File.readlines(path).map(&:chomp)
    orig_lines  = deep_clone(lines)
    shell_style = detect_shell_style_config(path, lines) if shell_style.nil?

    # remaining_settings starts as a copy, and then we delete each pair as we replace them
    # in the file. Any we haven't replaced will be added at the end.  We need a separate
    # copy of the hash, because we can't delete while we're iterating.
    remaining_settings = settings.dup

    lines.each do |l|
      settings = remaining_settings.dup
      settings.each do |key, value|
        m = l.match(CONFIG_LINE)
        if m && m[:key] == key
          l.replace(set_key_value(key, value, shell_style))
          remaining_settings.delete(key)
        end
      end
    end

    remaining_settings.each do |key, value|
      lines << set_key_value(key, value, shell_style)
    end

    return false if orig_lines == lines

    backup_path = backup_file(path)
    File.open(path, 'w') do |f|
      f.puts(lines)
    end

    puts "Updating #{path}:"
    puts `#{DIFF} --unified=0 #{backup_path} #{path}`
    puts
    @changed = true
  end

  def service_disabled(name)
    puts `update-rc.d #{name} disable` if Dir.glob("/etc/rc2.d/S*#{name}").any? {|f| File.symlink?(f) }
    puts `service #{name} stop`
    @changed = true
    # TODO: use sysv-init-tools and be smarter about @changed
  end

  def service_restarted(name)
    # On Ubuntu, apache2ctl doesn't reread envvars on a simple restart
    if name == 'apache2'
      puts `service #{name} stop`
      puts `service #{name} start` if $CHILD_STATUS.success?
    else
      puts `service #{name} restart`
    end

    unless $CHILD_STATUS.success?
      puts "Failed to restart #{name}"
      abort
    end
    @changed = true
  end

  def apt_installed(packages)
    packages = packages.join(' ') if packages.is_a?(Array)

    changes = `apt-get install --dry-run #{packages} 2>&1 | grep "newly installed"`.chomp
    m = changes.match(/(\d+) upgraded, (\d+) newly installed/)
    return false if m && m[1] == '0' && m[2] == '0'

    unless @apt_updated
      puts "Updating apt-get metadata"
      sh("apt-get update")
      @apt_updated = true
    end
    puts "Installing #{packages}"
    apt_env = "env DEBCONF_TERSE='yes' DEBIAN_PRIORITY='critical' DEBIAN_FRONTEND=noninteractive"
    sh("#{apt_env} apt-get --force-yes -qyu install #{packages}")
    @changed = true
  end

  def file_installed(source_root_dir, target_path, options = {})
    unless target_path.start_with?("/")
      puts "Must provide an absolute path for target in MakeItSo#file_install!"
      abort
    end

    changed         = false
    source_root_dir = File.expand_path(source_root_dir)
    source_path     = File.expand_path("#{source_root_dir}#{target_path}")
    source_files    = glob(source_path)

    source_files.each do |source|
      target  = source.partition(source_root_dir)[2]
      existed = File.exist?(target)

      if File.directory?(source)
        Dir.mkdir(target) unless existed
      elsif File.file?(source)
        unless existed && FileUtils.identical?(source, target)
          target_dir = Pathname(target).dirname
          unless target_dir.exist?
            puts "Creating parent(s) #{target_dir} for #{target}"
            target_dir.mkpath
          end

          verb = existed ? "Updating" : "Creating"
          puts "#{verb} #{target}"
          backup_file(target) unless options[:no_backup]

          target += ".tmp" if options[:temporary]
          FileUtils.cp(source, target)
          changed = true
        end
      else
        puts "I only know how to install files and directories: #{source}"
        abort
      end
    end

    @changed ||= changed
    changed
  end

  alias files_installed :file_installed

  def file_installed_iff(source_root_dir, target_path, condition, options = {})
    if File.directory?(target_path)
      puts "I haven't tested file_installed_iff with a directory yet: #{target_path}"
      abort
    end

    if condition
      file_installed(source_root_dir, target_path, options)
    else
      file_not_present(target_path)
    end
  end

  # TODO: Consider https://github.com/vajrapani666/executor
  # TODO: Use a Logger instead of redirecting
  def sh(command, set_changed = true)
    if command.include?('>')
      puts "You can't redirect output in MakeItSo#sh! I'd have to learn to redirect in Ruby!"
      abort
    end

    # TODO: Use Logger
    log_path = File.expand_path('~ubuntu/log/provision.log')
    File.open(log_path, 'a') do |f|
      f.puts command
    end

    `#{command} >> #{log_path} 2>&1`
    @changed ||= set_changed
    return set_changed if $CHILD_STATUS.success?

    puts "Error: #{SystemCallError.new($CHILD_STATUS.exitstatus)}"
    puts "executing: #{command}"
    puts "Check log/provision.log for details."
    exit $CHILD_STATUS.exitstatus
  end

  def host_known(hostname, local_user=nil)
    # TODO: Teach sh to ignore errors
    # TODO: Figure out how to use ssh-keyscan to see if this host is already in our known_hosts.. even if it's in a hashed format
    if local_user
      puts "Making host #{hostname} known to #{local_user}"
    else
      puts "Making host #{hostname} known"
    end

    command = "ssh -A -T -o StrictHostKeyChecking=no #{hostname} echo"
    command = "sudo -i -u #{local_user} #{command}" if local_user
    log_path = File.expand_path('~ubuntu/log/provision.log')

    File.open(log_path, 'a') do |f|
      f.puts command
    end

    `#{command} >> #{log_path} 2>&1`
    @changed = true
  end


  def a2_module_enabled(mod)
    do_apache_command(:enable, :module, mod)
  end

  def a2_module_disabled(mod)
    do_apache_command(:disable, :module, mod)
  end

  def a2_site_enabled(site)
    do_apache_command(:enable, :site, site)
  end

  def a2_site_disabled(site)
    do_apache_command(:disable, :site, site)
  end

  def user_in_group(user, group)
    return false if `groups #{user}`.match(group)

    sh("usermod #{user} --append --groups #{group}")
    @changed = true
  end

  private

  def do_apache_command(verb, thing, target)
    case thing
    when :module
      result_thing = 'Module'
      cmd_thing    = 'mod'
    when :site
      result_thing = 'Site'
      cmd_thing    = 'site'
    else
      abort "I don't know how to deal with apache #{thing}s."
    end

    case verb
    when :enable
      cmd_verb = 'en'
      gerund   = 'Enabling'
      success  = /Enabling #{result_thing} #{target}/i
      noop     = /#{result_thing} #{target} already enabled/i
    when :disable
      cmd_verb = 'dis'
      gerund   = 'Disabling'
      success  = /#{result_thing} #{target} disabled/i
      noop     = /#{result_thing} #{target} already disabled/i
    else
      abort "I know how to enable and disable apache modules, but not #{verb}.to_s"
    end

    result = `a2#{cmd_verb}#{cmd_thing} #{target}`
    if $CHILD_STATUS.success? && result =~ success
      puts "#{gerund} the #{target} #{thing}"
      changed = true
    elsif result =~ noop
      changed = false
    else
      puts "Error #{gerund.downcase} apache #{thing} #{target}: #{SystemCallError.new($CHILD_STATUS.exitstatus)}"
      exit $CHILD_STATUS.exitstatus
    end

    @changed ||= changed
    changed
  end

  def deep_clone(o)
    Marshal.load(Marshal.dump(o))
  end

  def detect_shell_style_config(path, lines)
    lines = deep_clone(lines)

    # Use the shebang if it's there

    if lines.first =~ /^#!/
      return lines.first =~ /\b(bash|zsh|sh|dash|csh|ash)\b/
    end

    # The hacky way
    special_cases = {
      "/etc/sysctl.conf" => false,
    }
    return special_cases[path] if special_cases.has_key?(path)

    lines.delete_if {|l| l.match(CONFIG_LINE).nil? }

    # The clever way
    shell     = lines.count {|l| l =~ /\S=\S/ && l.match(CONFIG_LINE)[:export] == 'export' }
    not_shell = lines.count {|l| l =~ /\s=\s/ }

    if shell > 0 && not_shell == 0
      true
    elsif shell == 0 && not_shell > 0
      false
    else
      puts "I'm confused! #{path} has #{shell} shell-style assignments, #{not_shell} non-shell assignments and no shebang."
      abort
    end
  end

  def set_key_value(key, value, shell_style)
    if shell_style
      %Q|export #{key}=#{value}|
    else
      %Q|#{key} = #{value}|
    end
  end

  def backup_file(path)
    return nil unless File.exist?(path)
    backup_path = "#{path}.#{DATE}"
    return backup_path if File.exist?(backup_path) # don't overwrite; earlier backup is fine

    puts "Backed up #{path} to *.#{DATE}"
    FileUtils.copy(path, backup_path)
    backup_path
  end

  def canonicalize(domain)
    if domain.end_with?('.')
      domain
    else
      "#{domain}."
    end
  end

  # Dir.glob isn't quite enough; we want to match all hidden files, but then reject the
  # pseudo-files like "." and "..", the way ls --almost-all does.
  def glob(path, options = {})
    path = File.expand_path(path)
    if File.file?(path) || options[:no_recurse] == true
      [path]
    else
      [path] + Dir.glob("#{path}/**/*", File::FNM_DOTMATCH).reject{|f| IMPLIED_DIR_ENTRIES =~ f }
    end
  end
end
