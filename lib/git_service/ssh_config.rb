# Port from `net/ssh/config.rb` to be able to parse the identity file for a
# given host from a ssh_config file.
#
# net-ssh LICENSE
#
# Copyright © 2008 Jamis Buck
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the ‘Software’), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED ‘AS IS’, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
module GitService
  class SshConfig
    DEFAULT_FILES = %w[~/.ssh/config /etc/ssh_config /etc/ssh/ssh_config].freeze

    class << self
      # Returns an array of locations of OpenSSH configuration files to parse by
      # default.
      def default_files
        DEFAULT_FILES.dup
      end

      # Parses the configuration data for the given +host+ from all of the given
      # +files+ (defaulting to the list of files returned by #default_files),
      # translates the resulting hash into the options recognized by Net::SSH,
      # and returns them.
      def for(host, files=expandable_default_files)
        translate(files.inject({}) { |settings, file|
          parse_file(file, host, settings)
        })
      end

      # Parses the OpenSSH configuration settings in the given +file+ for the
      # given +host+. If +settings+ is given, the options are merged into that
      # hash, with existing values taking precedence over newly parsed ones.
      # Returns a hash containing the OpenSSH options. (See #translate for how to
      # convert the OpenSSH options into Net::SSH options.)
      def parse_file(path, host, settings={}, base_dir = nil)
        file = File.expand_path(path)
        base_dir ||= File.dirname(file)
        return settings unless File.readable?(file)

        globals = {}
        block_matched = false
        block_seen = false
        IO.foreach(file) do |line|
          next if line =~ /^\s*(?:#.*)?$/

          if line =~ /^\s*(\S+)\s*=(.*)$/
            key, value = $1, $2
          else
            key, value = line.strip.split(/\s+/, 2)
          end

          # silently ignore malformed entries
          next if value.nil?

          key.downcase!
          value = unquote(value)

          value = case value.strip
                  when /^\d+$/ then value.to_i
                  when /^no$/i then false
                  when /^yes$/i then true
                  else value
                  end

          if key == 'host'
            # Support "Host host1 host2 hostN".
            # See http://github.com/net-ssh/net-ssh/issues#issue/6
            negative_hosts, positive_hosts = value.to_s.split(/\s+/).partition { |h| h.start_with?('!') }

            # Check for negative patterns first. If the host matches, that overrules any other positive match.
            # The host substring code is used to strip out the starting "!" so the regexp will be correct.
            negative_matched = negative_hosts.any? { |h| host =~ pattern2regex(h[1..-1]) }

            if negative_matched
              block_matched = false
            else
              block_matched = positive_hosts.any? { |h| host =~ pattern2regex(h) }
            end

            block_seen = true
            settings[key] = host
          elsif key == 'match'
            block_matched = eval_match_conditions(value, host, settings)
            block_seen = true
          elsif !block_seen
            case key
            when 'identityfile', 'certificatefile'
              (globals[key] ||= []) << value
            when 'include'
              included_file_paths(base_dir, value).each do |file_path|
                globals = parse_file(file_path, host, globals, base_dir)
              end
            else
              globals[key] = value unless settings.key?(key)
            end
          elsif block_matched
            case key
            when 'identityfile', 'certificatefile'
              (settings[key] ||= []) << value
            when 'include'
              included_file_paths(base_dir, value).each do |file_path|
                settings = parse_file(file_path, host, settings, base_dir)
              end
            else
              settings[key] = value unless settings.key?(key)
            end
          end

          # ProxyCommand and ProxyJump override each other so they need to be tracked togeather
          %w[proxyjump proxycommand].each do |proxy_key|
            if (proxy_value = settings.delete(proxy_key))
              settings['proxy'] ||= [proxy_key, proxy_value]
            end
          end
        end

        globals.merge(settings) do |key, oldval, newval|
          case key
          when 'identityfile', 'certificatefile'
            oldval + newval
          else
            newval
          end
        end
      end

      # Given a hash of OpenSSH configuration options, converts them into
      # a hash of Net::SSH options. Unrecognized options are ignored. The
      # +settings+ hash must have Strings for keys, all downcased, and
      # the returned hash will have Symbols for keys.
      def translate(settings)
        settings.each_with_object({}) do |(key, value), hash|
          translate_config_key(hash, key.to_sym, value, settings)
        end
      end

      # Filters default_files down to the files that are expandable.
      def expandable_default_files
        default_files.keep_if do |path|
          begin
            File.expand_path(path)
            true
          rescue ArgumentError
            false
          end
        end
      end

      private

      TRANSLATE_CONFIG_KEY_RENAME_MAP = {
        :identityfile => :privatekey,
        :user         => :username,
      }.freeze
      def translate_config_key(hash, key, value, settings)
        case key
        when *TRANSLATE_CONFIG_KEY_RENAME_MAP.keys
          hash[TRANSLATE_CONFIG_KEY_RENAME_MAP[key]] = value
        end
      end

      # Converts an ssh_config pattern into a regex for matching against
      # host names.
      def pattern2regex(pattern)
        tail = pattern
        prefix = ""
        while !tail.empty? do
          head,sep,tail = tail.partition(/[\*\?]/)
          prefix = prefix + Regexp.quote(head)
          case sep
          when '*'
            prefix += '.*'
          when '?'
            prefix += '.'
          when ''
          else
            fail "Unpexpcted sep:#{sep}"
          end
        end
        Regexp.new("^" + prefix + "$", true)
      end

      def included_file_paths(base_dir, config_paths)
        tokenize_config_value(config_paths).flat_map do |path|
          Dir.glob(File.expand_path(path, base_dir)).select { |f| File.file?(f) }
        end
      end

      # Tokenize string into tokens.
      # A token is a word or a quoted sequence of words, separated by whitespaces.
      def tokenize_config_value(str)
        str.scan(/([^"\s]+)?(?:"([^"]+)")?\s*/).map(&:join)
      end

      def eval_match_conditions(condition, host, settings)
        # Not using `\s` for whitespace matching as canonical
        # ssh_config parser implementation (OpenSSH) has specific character set.
        # Ref: https://github.com/openssh/openssh-portable/blob/2581333d564d8697837729b3d07d45738eaf5a54/misc.c#L237-L239
        conditions = condition.split(/[ \t\r\n]+|(?<!=)=(?!=)/).reject(&:empty?)
        return true if conditions == ["all"]

        conditions = conditions.each_slice(2)
        condition_matches = []
        conditions.each do |(kind,exprs)|
          exprs = unquote(exprs)

          case kind.downcase
          when "all"
            raise "all cannot be mixed with other conditions"
          when "host"
            if exprs.start_with?('!')
              negated = true
              exprs = exprs[1..-1]
            else
              negated = false
            end
            condition_met = false
            exprs.split(",").each do |expr|
              condition_met = condition_met || host =~ pattern2regex(expr)
            end
            condition_matches << (true && negated ^ condition_met)
            # else
            # warn "net-ssh: Unsupported expr in Match block: #{kind}"
          end
        end

        !condition_matches.empty? && condition_matches.all?
      end

      def unquote(string)
        string =~ /^"(.*)"$/ ? Regexp.last_match(1) : string
      end
    end
  end
end
