class User
  include Mongoid::Document
  include Mongoid::Timestamps

  field :user_id, type: String
  field :user_name, type: String
  field :access_token, type: String
  field :token_type, type: String
  field :activities_at, type: DateTime

  embeds_one :athlete

  belongs_to :team, index: true
  validates_presence_of :team

  index({ user_id: 1, team_id: 1 }, unique: true)
  index(user_name: 1, team_id: 1)

  def slack_mention
    "<@#{user_id}>"
  end

  def self.find_by_slack_mention!(team, user_name)
    query = user_name =~ /^<@(.*)>$/ ? { user_id: Regexp.last_match[1] } : { user_name: Regexp.new("^#{user_name}$", 'i') }
    user = User.where(query.merge(team: team)).first
    raise SlackStrava::Error, "I don't know who #{user_name} is!" unless user
    user
  end

  # Find an existing record, update the username if necessary, otherwise create a user record.
  def self.find_create_or_update_by_slack_id!(client, slack_id)
    instance = User.where(team: client.owner, user_id: slack_id).first
    instance_info = Hashie::Mash.new(client.web_client.users_info(user: slack_id)).user
    instance.update_attributes!(user_name: instance_info.name) if instance && instance.user_name != instance_info.name
    instance ||= User.create!(team: client.owner, user_id: slack_id, user_name: instance_info.name)
    instance
  end

  def to_s
    "user_id=#{user_id}, user_name=#{user_name}"
  end

  def connect!(code)
    response = Strava::Api::V3::Auth.retrieve_access(ENV['STRAVA_CLIENT_ID'], ENV['STRAVA_CLIENT_SECRET'], code)
    if response.success?
      create_athlete(athlete_id: response['athlete']['id'])
      update_attributes!(token_type: response['token_type'], access_token: response['access_token'])
      Api::Middleware.logger.info "Connected team=#{team_id}, user=#{user_name}, user_id=#{id}, athlete_id=#{athlete.athlete_id}"
      dm!(text: 'Your Strava account has been successfully connected.')
    else
      raise "Strava returned #{response.code}: #{response.body}"
    end
  end

  def dm!(message)
    client = Slack::Web::Client.new(token: team.token)
    im = client.im_open(user: user_id)
    client.chat_postMessage(message.merge(channel: im['channel']['id'], as_user: true))
  end

  # brag about one activity
  def brag!
    activity = new_strava_activities.first
    return unless activity
    Api::Middleware.logger.info "Bragging about #{self}, #{activity}"
    team.brag!(attachments: [
                 fallback: "#{activity.name} via #{slack_mention}, #{activity.distance_in_miles_s} #{activity.time_in_hours_s} #{activity.pace_per_mile_s}",
                 title: activity.name,
                 author_name: user_name,
                 image_url: activity.image_url,
                 fields: [
                   { title: 'Distance', value: activity.distance_in_miles_s, short: true },
                   { title: 'Time', value: activity.time_in_hours_s, short: true },
                   { title: 'Pace', value: activity.pace_per_mile_s, short: true },
                   { title: 'Start', value: activity.start_date_local_s, short: true }
                 ]
               ])
    update_attributes!(activities_at: activity.start_date)
  end

  def new_strava_activities
    raise 'Missing access_token' unless access_token
    client = Strava::Api::V3::Client.new(access_token: access_token)
    since = activities_at || created_at
    page = 1
    page_size = 10
    result = []
    loop do
      activities = client.list_athlete_activities(page: page, per_page: page_size, after: since.to_i)
      result.concat(activities.map { |activity| Activity.new(activity) })
      break if activities.size < page_size
      page += 1
    end
    result
  end
end
