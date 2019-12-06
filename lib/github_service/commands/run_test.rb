module GithubService
  module Commands
    # = GithubService::Commands::RunTest
    #
    # Triggers a build given the configured test repo:
    #
    #   Settings.github.run_tests_repo.*
    #
    # Which doing so will:
    #
    #    - validate the command
    #    - create a branch
    #    - create a commit with the travis.yml changes
    #    - push said branch to the origin
    #    - create a pull request for that branch
    #
    # More info can be found here on how the whole process works:
    #
    #   https://github.com/ManageIQ/manageiq-cross_repo-tests
    #
    # == Command structure
    #
    # @miq-bot run-tests [<repos-to-test>] [including <extra-repos>]
    #
    # where:
    #
    #   - a `repo` is of the form [org/]repo[@ref|#pr]
    #   - `repos-to-test` is a list of repos to have tested
    #   - `extra-repos` is a list of repos (gems) to override in the bundle
    #
    # each "lists of repos" should be comma delimited.
    #
    # == Example
    #
    # In ManageIQ/manageiq PR #1234
    #
    #   @miq-bot run-tests manageiq-api,manageiq-ui-classic#5678 \
    #     including Fryguy/more_core_extensions@feature,Fryguy/linux_admin@feature
    #
    # will create a commit with the .travis.yml changes:
    #
    #   @@ -14,6 +14,6 @@ matrix:
    #      fast_finish: true
    #    env:
    #      global:
    #   -  - REPOS=
    #   +  - REPOS=Fryguy/more_core_extensions@feature,Fryguy/linux_admin@feature,ManageIQ/manageiq#1234
    #      matrix:
    #   -  - TEST_REPO=
    #   +  - TEST_REPO=ManageIQ/manageiq-api
    #   +  - TEST_REPO=ManageIQ/manageiq-ui-classic#5678
    #
    # TODO:  Handle the "self" case, where `manageiq` is also a TEST_REPO
    #
    # (maybe include a "self" helper as well?)
    #
    class RunTest < Base
      # The user calling the command
      attr_reader :issuer

      # The (extra) repo(s) being targeted to be included in the test run
      attr_reader :repos

      # The repo(s) that will have the test suite run
      attr_reader :test_repos

      # The *-cross_repo-tests rugged instance
      attr_reader :rugged_repo

      # The arguments for the `run-test` command being called
      attr_reader :value

      restrict_to :organization

      def self.test_repo_url
        Settings.github.run_tests_repo.url
      end

      def self.test_repo_name
        Settings.github.run_tests_repo.name
      end

      def self.test_repo_clone_dir
        @test_repo_clone_dir ||= begin
                                   url_parts = test_repo_url.split("/")[-2, 2]
                                   repo_org  = url_parts.first
                                   repo_dir  = test_repo_name
                                   File.join(::Repo::BASE_PATH, repo_org, repo_dir)
                                 end
      end

      # Name of the bot
      def self.bot_name
        Settings.github_credentials.username
      end

      # The new branch name for this particular run of the command (uniq)
      def branch_name
        @branch_name ||= "#{self.class.bot_name}-run-tests-#{issue.number}-#{SecureRandom.uuid}"
      end

      def run_tests
        clone_repo_if_necessary
        create_cross_repo_test_branch
        update_travis_yaml_content
        commit_travis_yaml_changes
        push_commit_to_remote
        create_cross_repo_test_pull_request
      end

      private

      def _execute(issuer:, value:)
        @issuer = issuer
        parse_value(value)
        return unless valid?

        run_tests
      end

      def parse_value(value)
        @value = value

        @test_repos, @repos = value.split(/\s+including\s+/)
                                   .map { |repo_list| repo_list.split(",") }

        # Add the identifier for the PR for this comment to @repos here
        @repos ||= []
        @repos  << "#{issue.repo_name}##{issue.number}"

        @test_repos.map! { |repo_name| normalize_repo_name(repo_name) }
        @repos.map!      { |repo_name| normalize_repo_name(repo_name) }
      end

      def normalize_repo_name(repo)
        repo.include?("/") ? repo : "#{issue.organization_name}/#{repo}"
      end

      def valid?
        unless issue.pull_request?
          issue.add_comment("@#{issuer} 'run-test(s)' command is only valid on pull requests, ignoring...")
          return false
        end

        unless repos_valid?(@test_repos + @repos)
          issue.add_comment("@#{issuer} '#{value}' is an invalid repo, ignoring...")

          return false
        end

        true
      end

      REPO_ONLY_REGEXP = /(?:[^\/]+\/)?(?<REPO_NAME_ONLY>[^@#]+)/.freeze
      def repos_valid?(repos)
        repos.all? do |repo|
          name_only = repo.match(REPO_ONLY_REGEXP)[:REPO_NAME_ONLY]
          GithubService.org_repos(issue.organization_name).include?(name_only)
        end
      end

      ##### run_tests steps #####

      # Clone repo (if needed) and initialize @rugged_repo
      def clone_repo_if_necessary
        repo_path = self.class.test_repo_clone_dir
        if Dir.exist?(self.class.test_repo_clone_dir)
          @rugged_repo = Rugged::Repository.new(repo_path)
        else
          url = self.class.test_repo_url
          @rugged_repo = Rugged::Repository.clone_at(url, repo_path)
        end
        git_fetch
      end

      def create_cross_repo_test_branch
        rugged_repo.create_branch(branch_name, "origin/master")
        rugged_repo.checkout(branch_name)
      end

      def update_travis_yaml_content
        Dir.chdir(@rugged_repo.workdir) do
          content = YAML.load_file(".travis.yml")

          content["env"] = {} unless content["env"]
          content["env"]["global"] = ["REPOS=#{repos.join(',')}"]
          content["env"]["matrix"] = test_repos.map { |repo| "TEST_REPO=#{repo}" }

          File.write('.travis.yml', content.to_yaml)
        end
      end

      def commit_travis_yaml_changes
        index = rugged_repo.index
        index.add('.travis.yml')
        index.write

        # rubocop:disable: Rails/TimeZone
        bot       = self.class.bot_name
        author    = { :name => issuer, :email => "no-name@example.com", :time => Time.now }
        committer = { :name => bot,    :email => "#{bot}@manageiq.org", :time => Time.now }
        # rubocop:enable: Rails/TimeZone

        Rugged::Commit.create(
          rugged_repo,
          :author     => author,
          :committer  => committer,
          :parents    => [rugged_repo.last_commit].compact,
          :tree       => index.write_tree(rugged_repo),
          :update_ref => "HEAD",
          :message    => <<~COMMIT_MSG
            Running tests for #{issuer}

            From Pull Request:  #{issue.fq_repo_name}##{issue.number}
          COMMIT_MSG
        )
      end

      def push_commit_to_remote
        push_options = {}

        if Settings.github_credentials.username && Settings.github_credentials.password
          rugged_creds = Rugged::Credentials::UserPassword.new(
            :username => Settings.github_credentials.username,
            :password => Settings.github_credentials.password
          )
          push_options[:credentials] = rugged_creds
        end

        remote = @rugged_repo.remotes['origin']
        remote.push(["refs/heads/#{branch_name}"], push_options)
      end

      def create_cross_repo_test_pull_request
        fq_repo_name = "#{issue.organization_name}/#{File.basename(self.class.test_repo_url, '.*')}"
        pr_desc      = <<~PULL_REQUEST_MSG
          From Pull Request:  #{issue.fq_repo_name}##{issue.number}
          For User:           @#{issuer}
        PULL_REQUEST_MSG

        GithubService.create_pull_request(fq_repo_name,
                                          "master", branch_name,
                                          "[BOT] Cross repo test run", pr_desc)
      end

      ##### Duplicate Git stuffs #####

      # Code that probably should be refactored to be shared elsewhere, but for
      # now just shoving it here to get a working prototype together.

      # Mostly a dupulicate from Repo.git_fetch (app/models/repo.rb)
      #
      # Don't need the credentials stuff since we are assuming https for this repo
      def git_fetch
        rugged_repo.remotes.each { |remote| rugged_repo.fetch(remote.name) }
      end
    end
  end
end
