class CommitMonitorHandlers::Commit::GemfileChecker
  include Sidekiq::Worker

  def self.handled_branch_modes
    [:pr]
  end

  def self.options
    @options ||= YAML.load_file(Rails.root.join('config/gemfile_checker.yml'))
  end

  def self.pr_contacts
    options["pr_contacts"]
  end

  delegate :options, :pr_contacts, :to => :class

  attr_reader :branch, :commit

  def perform(branch_id, commit, commit_details)
    @branch = CommitMonitorBranch.find(branch_id)

    if @branch.nil?
      logger.info("Branch #{branch_id} no longer exists.  Skipping.")
      return
    end

    return unless commit_details["files"].any? { |f| File.basename(f) == "Gemfile" }

    @commit = commit
    process_branch
  end

  private

  def process_branch
    send("process_#{branch.pull_request? ? "pr" : "regular"}_branch")
  end

  def process_pr_branch
    logger.info("#{self.class.name}##{__method__} Updating pull request #{branch.pr_number} with Gemfile comment.")

    GithubService.call(:repo => branch.repo) do |github|
      github.issues.comments.create(
        :issue_id => branch.pr_number,
        :body     => "#{pr_contacts.join(" ")} Gemfile changes dectected in commit #{branch.commit_uri_to(commit)}.  Please review."
      )
    end
  end

  def process_regular_branch
    # TODO: Support regular branches with EmailService once we can send email.
  end
end
