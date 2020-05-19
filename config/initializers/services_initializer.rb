unless Rails.env.test?
  BugzillaService.credentials = Settings.bugzilla_credentials
  BugzillaService.product     = Settings.bugzilla.product
  PivotalService.credentials  = Settings.pivotal_credentials

  if Settings.git_service_hostname_ssh_config
    GitService::Credentials.host_config = Settings.git_service_hostname_ssh_config
  end
end
