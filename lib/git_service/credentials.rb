module GitService
  class Credentials
    # provide a nested set of hashes, each with a hash that can be passed to
    # Rugged::Credentials::SshKey.
    #
    # Example:
    #
    #   GitService::Credentials.host_config = {
    #     '*' => {
    #       :username    => 'git',
    #       :private_key => '~/.ssh/id_rsa'
    #     },
    #     'github.com' => {
    #       :username    => 'git',
    #       :private_key => '~/.ssh/id_rsa'
    #     }
    #   }
    #
    def self.host_config=(host_config = {})
      @host_config = host_config.to_h
    end

    # Generic method for finding hosts using what is available
    #
    # If @host_config is set, use that, otherwise use ssh-agent config
    #
    def self.find_for_user_and_host(username, hostname)
      from_hash_config_for_host(hostname) || from_ssh_config(username, hostname) || from_ssh_agent(username)
    end

    def self.from_ssh_config(username, hostname)
      ssh_config = GitService::SshConfig.for(hostname)

      return if ssh_config.empty?

      ssh_config[:username]   = username if username                            # favor URL username if present
      ssh_config[:privatekey] = File.expand_path(ssh_config[:privatekey].first) # only use first key

      Rugged::Credentials::SshKey.new(ssh_config)
    end

    def self.from_ssh_agent(username)
      Rugged::Credentials::SshKeyFromAgent.new(:username => username)
    end

    def self.from_hash_config_for_host(host)
      return nil unless defined?(@host_config)

      ssh_key_config   = @host_config[host]
      ssh_key_config ||= @host_config['*'] || @host_config[:*]

      if ssh_key_config
        Rugged::Credentials::SshKey.new(ssh_key_config)
      end
    end
  end
end
