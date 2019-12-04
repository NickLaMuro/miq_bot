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
    # Lists of repos should be comma delimited.
    #
    # == Examples
    #
    # === In ManageIQ/manageiq PR #1234:
    #
    # The following command:
    #
    #   @miq-bot run-tests manageiq-ui-classic
    #
    # will create a commit with the .travis.yml changes:
    #
    #
    #   @@ -14,6 +14,6 @@ matrix:
    #      fast_finish: true
    #    env:
    #      global:
    #   -  - REPOS=
    #   +  - REPOS=ManageIQ/manageiq#12345
    #      matrix:
    #   -  - TEST_REPO=
    #   +  - TEST_REPO=ManageIQ/manageiq-ui-classic
    #
    #
    # === In ManageIQ/manageiq PR #1234
    #
    # The following command:
    #
    #   @miq-bot run-tests manageiq-api,manageiq-ui-classic \
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
    #   +  - TEST_REPO=ManageIQ/manageiq-ui-classic
    #
    # TODO:  Handle the "self" case, where `manageiq` is also a TEST_REPO
    #
    # (maybe include a "self" helper as well?)
    #
    # === In ManageIQ/manageiq-ui-classic PR #1234:
    #
    # The following command:
    #
    #   @miq-bot run-tests manageiq#5678
    #
    # will create a commit with the .travis.yml changes:
    #
    #   @@ -14,6 +14,6 @@ matrix:
    #      fast_finish: true
    #    env:
    #      global:
    #   -  - REPOS=
    #   +  - REPOS=manageiq#5678
    #      matrix:
    #   -  - TEST_REPO=
    #   +  - TEST_REPO=manageiq-ui-classic#1234
    #
    class RunTest < Base
      # The user calling the command
      attr_reader :issuer

      # The (extra) repo(s) being targeted to be included in the test run
      attr_reader :repos

      # The repo(s) that will have the test suite run
      attr_reader :test_repos

      # The arguments for the `run-test` command being called
      attr_reader :value

      restrict_to :organization

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

      def run_tests
        create_cross_repo_test_branch
        commit_yaml_changes
        push_push_commit_to_remote
        create_cross_repo_test_pull_request
      end

      def create_cross_repo_test_branch
        # TODO
      end

      def commit_yaml_changes
        # TODO
      end

      def push_push_commit_to_remote
        # TODO
      end

      def create_cross_repo_test_pull_request
        # TODO
      end
    end
  end
end
