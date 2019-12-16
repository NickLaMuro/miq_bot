require 'spec_helper'

RSpec.shared_context "with stub cross_repo_tests", :with_stub_cross_repo do
  require 'tmpdir'
  require 'fileutils'

  attr_reader :sandbox_dir, :cross_repo_remote, :cross_repo_clone

  let(:suite_sandbox_dir) { Rails.root.join("spec", "tmp", "sandbox").to_s }
  let(:travis_yml_path)   { File.join(cross_repo_clone, ".travis.yml") }

  before do |example|
    FileUtils.mkdir_p suite_sandbox_dir

    # Generate a directory for this particular test
    dir_name     = example.full_description.tr(':#', '-').tr(' ', '_')
    @sandbox_dir = Dir.mktmpdir(dir_name, suite_sandbox_dir)

    # Define the dir variables so they are accessible from the examples
    @cross_repo_source = File.join(@sandbox_dir, "cross_repo-tests-source")
    @cross_repo_remote = File.join(@sandbox_dir, "cross_repo-tests-remote")
    @cross_repo_clone  = File.join(@sandbox_dir, "cross_repo-tests-cloned")

    # Set the bot name
    allow(described_class).to receive(:bot_name).and_return("rspec_bot")
    # Set RunTest.test_repo_url to the tmp git dir we are creating
    allow(described_class).to receive(:test_repo_url).and_return(@cross_repo_remote)
    # Set RunTest.test_repo_name to the basename of @cross_repo_clone
    allow(described_class).to receive(:test_repo_name).and_return(File.basename(@cross_repo_clone))
    # Stub Repo::BASE_PATH so that RunTest.test_repo_clone_dir points to the
    # top level of our suite sandbox dir.  The cloned repo will be will be
    # placed into `@sandbox_dir` because of how the code parses the
    # test_repo_url stubbed above.
    stub_const("::Repo::BASE_PATH", suite_sandbox_dir)

    default_travis_yaml_content = <<~YAML
      dist: xenial
      language: ruby
      rvm:
      - 2.5.5
      cache:
        bundler: true
      addons:
        postgresql: '10'
        apt:
          packages:
          - libarchive-dev
      script: bundle exec manageiq-cross_repo
      matrix:
        fast_finish: true
      env:
        global:
        - REPOS=
        matrix:
        - TEST_REPO=manageiq
    YAML

    tmp_repo = GitRepoHelper::TmpRepo.generate @cross_repo_source do
      add_file ".travis.yml", default_travis_yaml_content
      commit "add .travis.yml"
      tag "v1.0"
    end

    tmp_repo.create_remote "origin", @cross_repo_remote
  end

  # delete tmp repos dir
  after do
    FileUtils.remove_entry sandbox_dir unless ENV["DEBUG"]
    described_class.instance_variable_set(:@test_repo_clone_dir, nil)
  end
end

RSpec.describe GithubService::Commands::RunTest do
  subject { described_class.new(issue) }

  let(:issue)            { GithubService.issue(fq_repo_name, issue_id) }
  let(:issue_id)         { 1234 }
  let(:issue_url)        { "/repos/#{fq_repo_name}/issues/#{issue_id}" }
  let(:issue_identifier) { "#{fq_repo_name}##{issue_id}" }
  let(:fq_repo_name)     { "ManageIQ/bar" }
  let(:command_issuer)   { "NickLaMuro" }
  let(:command_value)    { "manageiq-ui-classic" }
  let(:comment_url)      { "/repos/#{fq_repo_name}/issues/#{issue_id}/comments" }
  let(:member_check_url) { "/orgs/ManageIQ/members/#{command_issuer}" }
  let(:repo_check_url)   { "/orgs/ManageIQ/repos" }

  before do
    pr_fetch_response = single_pull_request_response(fq_repo_name, issue_id)
    github_service_add_stub :url           => issue_url,
                            :response_body => pr_fetch_response

    github_service_add_stub :url             => member_check_url,
                            :response_status => 204

    github_service_stub_org_repos "ManageIQ", ["manageiq-ui-classic", "bar"]
  end

  describe "#execute!" do
    def run_execute!(valid: true, add_stubs: true)
      if add_stubs
        # if we are stubbing, determine the number of expections based on validity
        #
        # Basically, if it isn't valid, we should never hit `run_tests`,
        # otherwise it is run only once.
        run_number = valid ? 1 : 0
        expect(subject).to receive(:run_tests).exactly(run_number).times
      end

      subject.execute!(:issuer => command_issuer, :value => command_value)
    end

    it "runs tests when valid" do
      run_execute!
    end

    context "with a non-member" do
      let(:command_issuer)       { "non_member" }
      let(:non_member_check_url) { "/orgs/ManageIQ/members/non_member" }

      before do
        clear_stubs_for!(:get, member_check_url)
        clear_stubs_for!(:get, repo_check_url) # never reached

        # unsuccessful membership check for command_issuer
        github_service_add_stub :url             => non_member_check_url,
                                :response_status => 404
      end

      it "rejects the use of the command to non-members" do
        comment_body = {
          "body" => "@non_member Only members of the ManageIQ organization may use this command."
        }.to_json
        github_service_add_stub :url           => comment_url,
                                :method        => :post,
                                :request_body  => comment_body,
                                :response_body => {"id" => 1234}.to_json

        run_execute!(:valid => false)

        github_service_stubs.verify_stubbed_calls
      end
    end

    context "with an issue (not a PR)" do
      before do
        clear_stubs_for!(:get, issue_url)
        clear_stubs_for!(:get, repo_check_url) # never reached

        issue_fetch_response = single_issue_request_response(fq_repo_name, issue_id)
        github_service_add_stub :url           => issue_url,
                                :response_body => issue_fetch_response
      end

      it "adds a comment informing the command is being ignored by the bot" do
        comment_body = {
          "body" => "@NickLaMuro 'run-test(s)' command is only valid on pull requests, ignoring..."
        }.to_json
        github_service_add_stub :url           => comment_url,
                                :method        => :post,
                                :request_body  => comment_body,
                                :response_body => {"id" => 1234}.to_json

        run_execute!(:valid => false)

        github_service_stubs.verify_stubbed_calls
      end
    end

    context "with an invalid command" do
      let(:command_value) { "fake-repo" }

      it "adds a comment informing the command is being ignored by the bot" do
        comment_body = {
          "body" => "@NickLaMuro 'fake-repo' is an invalid repo, ignoring..."
        }.to_json
        github_service_add_stub :url           => comment_url,
                                :method        => :post,
                                :request_body  => comment_body,
                                :response_body => {"id" => 1234}.to_json

        run_execute!(:valid => false)

        github_service_stubs.verify_stubbed_calls
      end
    end
  end

  describe "#run_tests", :with_stub_cross_repo do
    before do
      subject.instance_variable_set(:@issuer,     command_issuer)
      subject.instance_variable_set(:@repos,      %w[repo1 repo2])
      subject.instance_variable_set(:@test_repos, %w[foo bar])

      clear_previous_github_service_stubs!

      pull_request_data = {
        "base"  => "master",
        "head"  => subject.branch_name,
        "title" => "[BOT] Cross repo test run",
        "body"  => <<~PR_BODY
          From Pull Request:  ManageIQ/bar#1234
          For User:           @NickLaMuro
        PR_BODY
      }.to_json

      github_service_add_stub :url           => "/repos/ManageIQ/cross_repo-tests-remote/pulls",
                              :method        => :post,
                              :request_body  => pull_request_data,
                              :response_body => {"number" => 2345}.to_json

      subject.run_tests
    end

    it "clones the repo" do
      expect(Dir.exist?(cross_repo_clone)).to be_truthy
      expect(File.exist?(travis_yml_path)).to be_truthy
    end

    it "creates a new branch" do
      branch = subject.branch_name
      repo   = subject.rugged_repo

      expect(repo.head.name.sub(/^refs\/heads\//, '')).to eq branch
    end

    it "updates the .travis.yml" do
      content = YAML.load_file(travis_yml_path)

      expect(content["env"]["global"]).to eq ["REPOS=repo1,repo2"]
      expect(content["env"]["matrix"]).to eq ["TEST_REPO=foo", "TEST_REPO=bar"]
    end

    it "commits the changes" do
      repo           = subject.rugged_repo
      last_commit    = repo.last_commit
      commit_content = repo.lookup(last_commit.tree.get_entry(".travis.yml")[:oid]).content

      expect(last_commit.message).to eq <<~MSG
        Running tests for NickLaMuro

        From Pull Request:  ManageIQ/bar#1234
      MSG

      expect(commit_content).to include "- REPOS=repo1,repo2"
      expect(commit_content).to include "- TEST_REPO=foo"
      expect(commit_content).to include "- TEST_REPO=bar"
    end

    it "pushes the changes" do
      Dir.mktmpdir do |dir|
        # create a new clone to test the remote got the push
        repo = Rugged::Repository.clone_at cross_repo_remote, dir
        repo.remotes["origin"].fetch

        branch_name    = subject.branch_name # branch name from cloned repo
        branch         = repo.branches["origin/#{branch_name}"]
        commit_content = repo.lookup(branch.target.tree.get_entry(".travis.yml")[:oid]).content

        expect(branch).to_not be_nil
        expect(branch.target.message).to eq <<~MSG
          Running tests for NickLaMuro

          From Pull Request:  ManageIQ/bar#1234
        MSG

        expect(commit_content).to include "- REPOS=repo1,repo2"
        expect(commit_content).to include "- TEST_REPO=foo"
        expect(commit_content).to include "- TEST_REPO=bar"
      end
    end

    it "creates a pull request" do
      github_service_stubs.verify_stubbed_calls
    end
  end

  describe "#parse_value (private)" do
    before do
      subject.send(:parse_value, command_value)
    end

    it "sets @test_repos and @repos" do
      expect(subject.test_repos).to eq ["ManageIQ/manageiq-ui-classic"]
      expect(subject.repos).to      eq [issue_identifier]
    end

    context "with 'including' argument" do
      let(:command_value) { "manageiq-ui-classic including manageiq#1234" }

      it "sets @test_repos and @repos" do
        expect(subject.test_repos).to eq ["ManageIQ/manageiq-ui-classic"]
        expect(subject.repos).to      eq ["ManageIQ/manageiq#1234", issue_identifier]
      end
    end

    context "multiple repos and test repos" do
      let(:repos)         { %w[Fryguy/more_core_extensions@feature linux_admin#123] }
      let(:test_repos)    { %w[manageiq-api manageiq-ui-classic] }
      let(:command_value) { "#{test_repos.join(',')} including #{repos.join(',')}" }

      it "sets @test_repos and @repos" do
        expected_test_repos = %w[ManageIQ/manageiq-api ManageIQ/manageiq-ui-classic]
        expected_repos      = %W[
          Fryguy/more_core_extensions@feature
          ManageIQ/linux_admin#123
          #{issue_identifier}
        ]

        expect(subject.test_repos).to eq expected_test_repos
        expect(subject.repos).to      eq expected_repos
      end
    end
  end

  describe "#repos_valid? (private)" do
    it "returns true with all valid repos" do
      repos = %w[ManageIQ/bar manageiq-ui-classic]
      expect(subject.send(:repos_valid?, repos)).to be_truthy
    end

    it "returns false with an invalid repo" do
      repos = %W[#{issue_identifier} manageiq-ui-classic ManageIQ/faker]
      expect(subject.send(:repos_valid?, repos)).to be_falsey
    end

    it "supports parsing out the '@' and '#' identifiers" do
      repos = %W[#{issue_identifier} manageiq-ui-classic@fine]
      expect(subject.send(:repos_valid?, repos)).to be_truthy
    end
  end
end
