require 'hipchat'

# HipChat has rate limits (500 API request per 5 minutes), so make sure we don't make too many requests here, especially
# as we may use the same API token across multiple branches that could deploy at once
SLEEP_TIME = 10

namespace :hipchat do

  task :notify_deploy_started do
    if give_opportunity_to_cancel?
      wait_for_hipchat_cancellation
    else
      send_message("#{human} is deploying #{deployment_name} to #{environment_string}#{fetch(:hipchat_with_migrations, '')}.", send_options)
    end
  end

  task :notify_deploy_finished do
    send_options.merge!(:color => success_message_color)
    send_message("#{human} finished deploying #{deployment_name} to #{environment_string}.", send_options)
  end

  task :notify_deploy_reverted do
    send_options.merge!(:color => failed_message_color)
    send_message("#{human} cancelled deployment of #{deployment_name} to #{environment_string}.", send_options)
  end

  def send_options
    return @send_options if defined?(@send_options)
    @send_options = message_format ? {:message_format => message_format } : {}
    @send_options.merge!(:notify => message_notification)
    @send_options.merge!(:color => message_color)
    @send_options
  end

  def send_message(message, options)
    return unless enabled?

    rooms.each { |room|
      begin
        hipchat_client[room].send(deploy_user, message, options)
      rescue => e
        puts e.message
        puts e.backtrace
      end
    }
  end

  def hipchat_client
    hipchat_token = fetch(:hipchat_token)
    hipchat_options = fetch(:hipchat_options, {})

    @hipchat_client ||= fetch(:hipchat_client, HipChat::Client.new(hipchat_token, hipchat_options))
  end

  def enabled?
    fetch(:hipchat_enabled, true)
  end

  def environment_string
    if fetch(:stage)
      "#{fetch(:stage)} (#{environment_name})"
    else
      environment_name
    end
  end

  def deployment_name
    if fetch(:branch, nil)
      branch = fetch(:branch)
      real_revision = fetch(:real_revision)

      name = "#{application_name}/#{branch}"
      name += " #{formatted_revision(real_revision[0..7])}" if real_revision
      name
    else
      application_name
    end
  end

  def formatted_revision(revision)
    fetch(:hipchat_revision_format, '(revision %{revision})') % {revision: revision}
  end

  def application_name
    alt_application_name.nil? ? fetch(:application) : alt_application_name
  end

  def message_color
    fetch(:hipchat_color, 'yellow')
  end

  def success_message_color
    fetch(:hipchat_success_color, 'green')
  end

  def failed_message_color
    fetch(:hipchat_failed_color, 'red')
  end

  def message_notification
    fetch(:hipchat_announce, false)
  end

  def message_format
    fetch(:hipchat_message_format, 'html')
  end

  def deploy_user
    fetch(:hipchat_deploy_user, 'Deploy')
  end

  def alt_application_name
    fetch(:hipchat_app_name, nil)
  end

  def human
    user = ENV['HIPCHAT_USER'] || fetch(:hipchat_human)
    user = user || if (u = %x{git config user.name}.strip) != ''
                     u
                   elsif (u = ENV['USER']) != ''
                     u
                   else
                     'Someone'
                   end
    user
  end

  def environment_name
    fetch(:hipchat_env, fetch(:rack_env, fetch(:rails_env, fetch(:stage))))
  end

  before 'deploy:starting', 'hipchat:notify_deploy_started'
  after 'deploy:finished', 'hipchat:notify_deploy_finished'
  if Rake::Task.task_defined? 'deploy:failed'
    after 'deploy:failed', 'hipchat:notify_deploy_reverted'
  end

  def rooms
    hipchat_room_name = fetch(:hipchat_room_name)

    return [hipchat_room_name] if hipchat_room_name.is_a?(String)
    return [hipchat_room_name.to_s] if hipchat_room_name.is_a?(Symbol)

    hipchat_room_name
  end

  def history(room)
    JSON.parse(hipchat_client[room].history())
  end

  def cancellation_message
    branch = deployment_name.split('/').last
    "cancel #{branch} deploy"
  end

  def is_deploy_message?(m)
    m['from'].include?('Deploy')
  end

  def found_cancellation_message?(room)
    messages_with_recent_first = history(room)['items'].reverse

    messages_with_recent_first.each do |m|
      return false if is_deploy_message?(m) # don't go back any further
      return true if m['message'].include?(cancellation_message)
    end

    false
  end

  def wait_for_hipchat_cancellation
    send_message("@here #{human} is deploying #{deployment_name} to #{environment_string}#{fetch(:hipchat_with_migrations, '')}. Reply with a message containing '#{cancellation_message}'' to cancel.  Otherwise, the deploy will proceed in #{cancellation_window} seconds.", send_options.merge(notify: true))
    puts "Allowing #{cancellation_window} seconds for users to cancel deploy via HipChat message."

    (cancellation_window / SLEEP_TIME).times do
      sleep(SLEEP_TIME)
      if rooms.any? { |room| found_cancellation_message?(room) }
        send_message("Cancelling deploy.", send_options)
        raise 'Cancelling deploy based on HipChat message'
      end
    end

    send_message("Proceeding with deploy of #{deployment_name}.", send_options)
    puts 'No HipChat message - proceeding with deploy.'
  end

  def give_opportunity_to_cancel?
    fetch(:hipchat_give_opportunity_to_cancel, false)
  end

  def cancellation_window
    fetch(:hipchat_cancellation_window, 180)
  end

end
