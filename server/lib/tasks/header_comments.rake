# lib/tasks/header_comments.rake

#
# Add or refresh top-of-file header comments for:
#   - Ruby (.rb)
#   - Rake (.rake)
#   - YAML (.yml)
#   - JavaScript (.js)
#
# Usage:
#   bundle exec rake app:header_comments
#   bundle exec rake "app:header_comments[file1.rb file2.yml]"

require 'shellwords'

module HeaderComments
  SUPPORTED_EXTS = %w[.rb .rake .yml .js].freeze unless const_defined?(:SUPPORTED_EXTS)
  EXCLUDED_DIRS = %w[tmp node_modules vendor _data].freeze unless const_defined?(:EXCLUDED_DIRS)

  class << self
    def add_header_comments(file_list: [])
      $stderr.print 'Autocorrect: header comments …'
      list = file_list || []
      files = if list.empty?
          $stderr.print ' processing all files …'
          Dir.glob('**/*', File::FNM_DOTMATCH).select { |path| processable_file?(path) }
      else
          list.select { |path| processable_file?(path) }
      end

      files.each { |f| rewrite_header_for(f) }
      $stderr.puts ' ✅'
    end

    def processable_file?(path)
      ext = File.extname(path)
      return false unless SUPPORTED_EXTS.include?(ext)
      return false unless File.file?(path)
      return false if EXCLUDED_DIRS.any? { |dir| path.start_with?("#{dir}/") }

      true
    end

    private :processable_file?

    def rewrite_header_for(file)
      return unless File.exist?(file)

      content = File.read(file)
      ext = File.extname(file)

      # Skip shebang scripts for Ruby — header would push the shebang off the first line.
      return if ext != '.yml' && content.match?(/\A#!\s*/)

      updated = prepend_comment(file, content, file)
      return if updated == content

      File.write(file, updated)
      puts " #{file}"
    end

    def prepend_comment(file, original_content, comment)
      case File.extname(file)
      when '.rb', '.rake' then prepend_ruby_comment(original_content, comment)
      when '.yml' then prepend_yml_comment(original_content, comment)
      when '.js' then prepend_js_comment(original_content, comment)
      else original_content
      end
    end

    def prepend_ruby_comment(content, comment)
      content = content.sub(/\A# .*\.(rb|rake)\n+/, '')
      header = "# #{comment}\n\n"
      content.start_with?(header) ? content : header + content
    end

    def prepend_yml_comment(content, comment)
      content = content.sub(/\A# .*\.yml\n+\s*/, '')
      header_line = "# #{comment}\n\n"
      return content if content.start_with?(header_line)

      if content.start_with?('---')
        first_line, rest = content.split("\n", 2)
        [first_line, header_line, rest].compact.join("\n")
      else
        header_line + content
      end
    end

    def prepend_js_comment(content, comment)
      content = content.sub(%r{\A// .*\.js\n+}, '')
      header = "// #{comment}\n\n"
      content.start_with?(header) ? content : header + content
    end
  end
end

namespace :app do
  desc 'Add / refresh header comments (optional space-separated file list)'
  task :header_comments, [:file_list] do |_, args|
    files = Shellwords.split(args[:file_list].to_s)
    HeaderComments.add_header_comments(file_list: files)
  end
end
