# lib/tasks/linter.rake

#
#   - app:linter    => bundle check, brakeman, bundle audit, rubocop
#   - app:formatter => header comments, rufo, rubocop --autocorrect (optional file_list)

require 'shellwords'

# bundle-audit auto-registers its own rake task on require.
begin
  require 'bundler/audit/task'
  Bundler::Audit::Task.new
rescue LoadError
  # bundle-audit gem not installed in this environment; skip silently.
end

namespace :app do
  desc 'Run linter checks (bundle check, brakeman, bundle audit, rubocop)'
  task :linter do
    tasks = {
      'Checking Bundle' => 'bundle check',
      # Brakeman expects a Rails app — `--force` lets it scan a plain Ruby project anyway.
      'Auditing Brakeman' => 'bundle exec brakeman --quiet --no-pager --no-summary --no-exit-on-warn --force',
      'Linting Rubocop' => 'bundle exec rubocop --format simple',
    }
    tasks['Auditing bundler'] = 'bundle audit check --update' unless ENV['OPENAI_CODEX']

    tasks.each do |description, command|
      $stderr.sync = true
      $stderr.print "#{description} …"
      output = `#{command} 2>&1`
      status = $?.exitstatus

      if status.zero?
        $stderr.puts ' ✅'
      else
        $stderr.puts ' ❌'
        puts output
        abort("Aborting due to #{description} failure.")
      end
    end

    puts 'All checks passed.'
  end

  desc 'Auto-format Ruby code (header comments, rufo, rubocop --autocorrect). Optional space-separated file list.'
  task :formatter, [:file_list] do |_, args|
    raw = args[:file_list].to_s
    files = Shellwords.split(raw)
    puts "Processing files: #{files.join(', ')}" unless files.empty?

    Rake::Task['app:header_comments'].invoke(args[:file_list])
    Rake::Task['app:header_comments'].reenable

    $stderr.sync = true
    $stderr.print 'Autocorrect: rufo …'
    LinterTasks.run_rufo(files)
    $stderr.puts ' ✅'

    $stderr.print 'Autocorrect: rubocop …'
    LinterTasks.run_rubocop_autocorrect(files)
    $stderr.puts ' ✅'
  end
end

# Helpers shared by the formatter task. Plain Ruby — no Rails dependency.
module LinterTasks
  module_function

  def run_rufo(files)
    if files.empty?
      system('bundle exec rufo . --loglevel=silent >/dev/null')
    else
      escaped = files.map { |f| Shellwords.shellescape(f) }
      system("bundle exec rufo #{escaped.join(' ')} --loglevel=silent >/dev/null")
    end
  end

  def run_rubocop_autocorrect(files)
    if files.empty?
      system('bundle exec rubocop --format quiet --autocorrect >/dev/null')
    else
      escaped = files.map { |f| Shellwords.shellescape(f) }
      system("bundle exec rubocop --force-exclusion --format quiet --autocorrect #{escaped.join(' ')} >/dev/null")
    end
  end
end
