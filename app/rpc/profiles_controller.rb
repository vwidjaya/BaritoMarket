class ProfilesController < Api::V2::BaseController
  include Wisper::Publisher
  bind ::Rpc::ProfileService::Service

  def get_profile_by_app_secret(profile_req, _call)
    profile_response_json = REDIS_CACHE.get(
      "#{APP_PROFILE_CACHE_PREFIX}:#{profile_req.app_secret}")
    if profile_response_json.present?
      return Rpc::Profile.decode_json(profile_response_json)
    end

    # Try to fetch it from database if cache is missing
    app = BaritoApp.find_by(secret_key: profile_req.app_secret)

    if app.blank? || !app.available?
      raise grpc_error(:NOT_FOUND, "App not found or inactive") and return
    end

    profile_response = generate_profile_response(app)
    broadcast(:profile_response_updated,
      profile_req.app_secret, profile_response)

    profile_response
  end

  def get_profile_by_app_group_secret(profile_req, _call)
    profile_response_json = REDIS_CACHE.get(
      "#{APP_GROUP_PROFILE_CACHE_PREFIX}:#{profile_req.app_group_secret}:#{profile_req.app_name}")
    if profile_response_json.present?
      return Rpc::Profile.decode_json(profile_response_json)
    end

    # Fetch App Group
    app_group = AppGroup.find_by(secret_key: profile_req.app_group_secret)

    if app_group.blank? || !app_group.available?
      raise grpc_error(:NOT_FOUND, "AppGroup not found or inactive") and return
    end

    # Fetch App
    app = BaritoApp.find_by(
      name: profile_req.app_name,
      app_group_id: app_group.id
    )

    if app.blank?
      app = BaritoApp.setup({
        app_group_id: app_group.id,
        name: profile_req.app_name,
        topic_name: profile_req.app_name,
        max_tps: Figaro.env.default_app_max_tps
      })
    elsif !app.available?
      raise grpc_error(:UNAVAILABLE, "App is inactive") and return
    end

    profile_response = generate_profile_response(app)
    broadcast(:app_group_profile_response_updated,
      profile_req.app_group_secret, profile_req.app_name, profile_response)

    profile_response
  end

  def generate_profile_response(app)
    infrastructure = app.app_group.infrastructure

    Rpc::Profile.new(
      id: app.id,
      name: app.name,
      app_secret: app.secret_key,
      app_group_name: app.app_group_name,
      max_tps: app.max_tps,
      cluster_name: app.cluster_name,
      consul_host: app.consul_host,
      status: app.status,
      meta: Rpc::ProfileMeta.new(
        service_names: {
          'producer' => 'barito-flow-producer',
          'zookeeper' => 'zookeeper',
          'kafka' => 'kafka',
          'consumer' => 'barito-flow-consumer',
          'elasticsearch' => 'elasticsearch',
          'kibana' => 'kibana',
        },
        kafka: Rpc::KafkaMeta.new(
          topic_name: app.topic_name,
          partition: infrastructure.options['kafka_partition'],
          replication_factor: infrastructure.options['kafka_replication_factor'],
          consumer_group: 'barito',
        ),
        elasticsearch: Rpc::ElasticsearchMeta.new(
          index_prefix: app.topic_name,
          document_type: 'barito',
        ),
      ),
  end

  def grpc_error(code, err)
    GRPC::BadStatus.new(GRPC::Core::StatusCodes::code, err)
  end
end
