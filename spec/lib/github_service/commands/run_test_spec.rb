require 'spec_helper'

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
