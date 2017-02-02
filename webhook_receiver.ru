#\ -p 8765

require "json"
require "sidekiq"
require ::File.expand_path("../app/workers/webhook_processor",  __FILE__)

File.write("tmp/webhook_processor.pid", $$)

class MiqBotHearbeat
  def call(env)
    request = Rack::Request.new(env)
    if request.path == "/" && request.request_method == "GET"
      [ 200, {'Content-Type' => 'text/plain'}, ["Webhook Processor: OK!"] ]
    else
      [ 404, {'Content-Type' => 'text/plain'}, ["Not Found"] ]
    end
  end
end

class MiqBotWebhookReceiver
  def call(env)
    request = Rack::Request.new(env)
    process_webhook request
  end

  def process_webhook(request)
    if valid request
      WebhookProcessor.perform_async(
        request.env["HTTP_X_GITHUB_DELIVERY"],
        request.env["HTTP_X_GITHUB_EVENT"],
        JSON.parse(request.body.read)
      )
      [ 200, {'Content-Type' => 'text/plain'}, ["Webhook Processed!"] ]
    else
      raise "Invalid Github Webhook"
    end
  rescue => e
    [ 500, {'Content-Type' => 'text/plain'}, ["Error:  #{e.message}"] ]
  end

  def valid request
    !!(
        request.env["HTTP_X_GITHUB_EVENT"] &&
        request.env["HTTP_X_GITHUB_DELIVERY"] &&
        request.body.length > 0
      )
  end
end

use Rack::Auth::Basic, "MiqBot" do |username, password|
  Rack::Utils.secure_compare("admin", username) &&
  Rack::Utils.secure_compare("smartvm", password)
end

map '/' do
  run MiqBotHearbeat.new
end

map '/payload' do
  run MiqBotWebhookReceiver.new
end
