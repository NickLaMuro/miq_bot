class WebhookProcessor
  include Sidekiq::Worker
  sidekiq_options :queue => :miq_bot

  def perform(id, action, data)
    puts "got a webhook!"
    puts "id:     #{id}"
    puts "action: #{action}"
    puts "data:   #{data.inspect}"
  end

end
