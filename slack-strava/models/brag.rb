module Brag
  def with_strava_error_handler(&_block)
    yield
  rescue Strava::Api::V3::ClientError => e
    case e.message
    when '{"message":"Rate Limit Exceeded","errors":[{"resource":"Application","field":"rate limit","code":"exceeded"}]} [HTTP 429]' then
      logger.warn 'Strava API rate limit exceeded.'
      raise e
    else
      backtrace = e.backtrace.join("\n")
      logger.warn "Error in team #{team}, #{self}, #{e.message}, #{backtrace}."
    end
  rescue StandardError => e
    backtrace = e.backtrace.join("\n")
    logger.warn "Error in team #{team}, #{self}, #{e.message}, #{backtrace}."
  end

  def sync_and_brag!
    with_strava_error_handler do
      sync_new_strava_activities!
      brag!
    end
  end
end
