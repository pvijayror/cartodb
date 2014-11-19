# coding: UTF-8
require_relative './user/user_decorator'
require_relative './user/oauths'
require_relative './synchronization/synchronization_oauth'
require_relative './visualization/member'
require_relative './visualization/collection'
require_relative './user/user_organization'
require_relative './synchronization/collection.rb'

class User < Sequel::Model
  include CartoDB::MiniSequel
  include CartoDB::UserDecorator
  include Concerns::CartodbCentralSynchronizable

  self.strict_param_setting = false

  # @param name             String
  # @param avatar_url       String
  # @param database_schema  String

  one_to_one  :client_application
  one_to_many :synchronization_oauths
  one_to_many :tokens, :class => :OauthToken
  one_to_many :maps
  one_to_many :assets
  one_to_many :data_imports
  one_to_many :geocodings, order: :created_at.desc
  one_to_many :search_tweets, order: :created_at.desc
  many_to_one :organization

  many_to_many :layers, :order => :order, :after_add => proc { |user, layer|
    layer.set_default_order(user)
  }

  # Sequel setup & plugins
  plugin :association_dependencies, :client_application => :destroy, :synchronization_oauths => :destroy
  plugin :validation_helpers
  plugin :json_serializer
  plugin :dirty

  # Restrict to_json attributes
  @json_serializer_opts = {
    :except => [ :crypted_password,
                 :salt,
                 :invite_token,
                 :invite_token_date,
                 :admin,
                 :enabled,
                 :map_enabled],
    :naked => true # avoid adding json_class to result
  }

  SYSTEM_TABLE_NAMES = %w( spatial_ref_sys geography_columns geometry_columns raster_columns raster_overviews cdb_tablemetadata )
  GEOCODING_BLOCK_SIZE = 1000

  self.raise_on_typecast_failure = false
  self.raise_on_save_failure = false

  ## Validations
  def validate
    super
    validates_presence :username
    validates_unique   :username
    validates_format /^[a-z0-9\-]+$/, :username, :message => "must only contain lowercase letters, numbers and the dash (-) symbol"
    validates_format /^[a-z0-9]{1}/, :username, :message => "must start with alfanumeric chars"
    validates_format /[a-z0-9]{1}$/, :username, :message => "must end with alfanumeric chars"
    errors.add(:name, 'is taken') if name_exists_in_organizations?

    validates_presence :email
    validates_unique   :email, :message => 'is already taken'
    validates_format EmailAddressValidator::Regexp::ADDR_SPEC, :email, :message => 'is not a valid address'

    validates_presence :password if new? && (crypted_password.blank? || salt.blank?)
    if new? || password.present?
      errors.add(:password, "is not confirmed") unless password == password_confirmation
    end
    if organization.present?
      if new?
        errors.add(:organization, "not enough seats") if organization.users.count >= organization.seats
        errors.add(:quota_in_bytes, "not enough disk quota") if quota_in_bytes.to_i + organization.assigned_quota > organization.quota_in_bytes
      else
        # Organization#assigned_quota includes the OLD quota for this user,
        # so we have to ammend that in the calculation:
        errors.add(:quota_in_bytes, "not enough disk quota") if quota_in_bytes.to_i + organization.assigned_quota - initial_value(:quota_in_bytes) > organization.quota_in_bytes
      end
    end
  end

  def public_user_roles
    self.organization_user? ? [CartoDB::PUBLIC_DB_USER, database_public_username] : [CartoDB::PUBLIC_DB_USER]
  end

  ## Callbacks
  def before_create
    super
    self.database_host ||= ::Rails::Sequel.configuration.environment_for(Rails.env)['host']
    self.api_key ||= self.class.make_token
  end

  def before_save
    super
    self.updated_at = Time.now
    # Set account_type and default values for organization users
    # TODO: Abstract this
    self.account_type = "ORGANIZATION USER" if self.organization_user? && !self.organization_owner?
    if self.organization_user?
      if new? || column_changed?(:organization_id)
        self.twitter_datasource_enabled = self.organization.twitter_datasource_enabled
        self.here_maps_enabled          = self.organization.here_maps_enabled
        self.stamen_maps_enabled        = self.organization.stamen_maps_enabled
        self.rainbow_maps_enabled       = self.organization.rainbow_maps_enabled
      end
      self.max_layers ||= 6
      self.private_tables_enabled ||= true
      self.sync_tables_enabled ||= true
    end
  end #before_save

  def after_create
    super
    setup_user
    save_metadata
    self.load_avatar
    monitor_user_notification
    sleep 3
    set_statement_timeouts
    if self.has_organization_enabled?
      ::Resque.enqueue(::Resque::UserJobs::Mail::NewOrganizationUser, self.id)
    end
  end

  def after_save
    super
    save_metadata
    changes = (self.previous_changes.present? ? self.previous_changes.keys : [])
    set_statement_timeouts   if changes.include?(:user_timeout) || changes.include?(:database_timeout)
    rebuild_quota_trigger    if changes.include?(:quota_in_bytes)
    if changes.include?(:account_type) || changes.include?(:available_for_hire) || changes.include?(:disqus_shortname) || changes.include?(:email) || \
       changes.include?(:website) || changes.include?(:name) || changes.include?(:description) || \
       changes.include?(:twitter_username) || changes.include?(:dynamic_cdn_enabled)
      invalidate_varnish_cache(regex: '.*:vizjson')
    end
    if changes.include?(:database_host)
      User.terminate_database_connections(database_name, previous_changes[:database_host][0])
    elsif changes.include?(:database_schema)
      User.terminate_database_connections(database_name, database_host)
    end

  end

  def before_destroy
    org_id = nil
    @org_id_for_org_wipe = nil
    error_happened = false
    has_organization = false
    unless self.organization.nil?
      self.organization.reload  # Avoid ORM caching
      if self.organization.owner.id == self.id
        @org_id_for_org_wipe = self.organization.id  # after_destroy will wipe the organization too
        if self.organization.users.count > 1
          msg = 'Attempted to delete owner from organization with other users'
          CartoDB::Logger.info msg
          raise CartoDB::BaseCartoDBError.new(msg)
        end
      end

      # Right now, cannot delete users with entities shared with other users or the org.
      can_delete = true
      CartoDB::Permission.where(owner_id: self.id).each { |permission|
        can_delete = can_delete && permission.acl.empty?
      }
      unless can_delete
        raise CartoDB::BaseCartoDBError.new('Cannot delete user, has shared entities')
      end

      has_organization = true
    end

    begin
      org_id = self.organization_id
      self.organization_id = nil

      # Remove user tables
      self.tables.all.each { |t| t.destroy }

      # Remove user data imports, maps, layers and assets
      self.data_imports.each { |d| d.destroy }
      self.maps.each { |m| m.destroy }
      self.layers.each { |l| remove_layer l }
      self.geocodings.each { |g| g.destroy }
      self.assets.each { |a| a.destroy }
      CartoDB::Synchronization::Collection.new.fetch(user_id: self.id).destroy
    rescue StandardError => exception
      error_happened = true
      CartoDB::Logger.info "Error destroying user #{username}. #{exception.message}\n#{exception.backtrace}"
    end

    # Remove metadata from redis
    $users_metadata.DEL(self.key) unless error_happened

    # Invalidate user cache
    invalidate_varnish_cache

    # Delete the DB or the schema
    if has_organization
      drop_organization_user(org_id, is_owner = !@org_id_for_org_wipe.nil?) unless error_happened
    else
      if User.where(:database_name => self.database_name).count > 1
        raise CartoDB::BaseCartoDBError.new('The user is not supposed to be in a organization but another user has the same database_name. Not dropping it')
      else
        drop_database_and_user unless error_happened
      end
    end
  end

  def after_destroy
    unless @org_id_for_org_wipe.nil?
      organization = Organization.where(id: @org_id_for_org_wipe).first
      organization.destroy
    end
  end

  # Org users share the same db, so must only delete the schema
  def drop_organization_user(org_id, is_owner=false)
    raise CartoDB::BaseCartoDBError.new('Tried to delete an organization user without org id') if org_id.nil?

    Thread.new do
      in_database(as: :superuser) do |database|
        # Drop this user privileges in every schema of the DB
        schemas = ['cdb', 'cdb_importer', 'cartodb', 'public', self.database_schema] +
          User.select(:database_schema).where(:organization_id => org_id).all.collect(&:database_schema)
        schemas.uniq.each do |s|
          if is_owner
            drop_user_privileges_in_schema(s, [CartoDB::PUBLIC_DB_USER])
          else
            drop_user_privileges_in_schema(s)
          end
        end

        # Only remove publicuser from current user schema (and if owner, already done above)
        unless is_owner
          drop_user_privileges_in_schema(self.database_schema, [CartoDB::PUBLIC_DB_USER])
        end

        # Drop user quota function
        database.run(%Q{ DROP FUNCTION IF EXISTS "#{self.database_schema}"._CDB_UserQuotaInBytes()})
        # If user is in an organization should never have public schema, so to be safe check
        drop_all_functions_from_schema(self.database_schema)
        unless self.database_schema == 'public'
          # Must drop all functions before or it will fail
          database.run(%Q{ DROP SCHEMA IF EXISTS "#{self.database_schema}" })
        end
      end

      conn = self.in_database(as: :cluster_admin)
      User.terminate_database_connections(database_name, database_host)
      conn.run("REVOKE ALL ON DATABASE \"#{database_name}\" FROM \"#{database_username}\"")
      conn.run("REVOKE ALL ON DATABASE \"#{database_name}\" FROM \"#{database_public_username}\"")
      conn.run("DROP USER \"#{database_public_username}\"")
      conn.run("DROP USER \"#{database_username}\"")
    end.join

    monitor_user_notification
  end

  def drop_database_and_user
    Thread.new do
      conn = self.in_database(as: :cluster_admin)
      conn.run("UPDATE pg_database SET datallowconn = 'false' WHERE datname = '#{database_name}'")
      User.terminate_database_connections(database_name, database_host)
      conn.run("DROP DATABASE \"#{database_name}\"")
      conn.run("DROP USER \"#{database_username}\"")
    end.join
    monitor_user_notification
  end

  def self.terminate_database_connections(database_name, database_host)
    connection_params = ::Rails::Sequel.configuration.environment_for(Rails.env).merge(
      'host' => database_host,
      'database' => 'postgres'
    ) {|key, o, n| n.nil? ? o : n}
    conn = ::Sequel.connect(connection_params)
    conn.run("
      DO language plpgsql $$
      DECLARE
          ver INT[];
          sql TEXT;
      BEGIN
          SELECT INTO ver regexp_split_to_array(
            regexp_replace(version(), '^PostgreSQL ([^ ]*) .*', '\\1'),
            '\\.'
          );
          sql := 'SELECT pg_terminate_backend(';
          IF ver[1] > 9 OR ( ver[1] = 9 AND ver[2] > 1 ) THEN
            sql := sql || 'pid';
          ELSE
            sql := sql || 'procpid';
          END IF;

          sql := sql || ') FROM pg_stat_activity WHERE datname = '
            || quote_literal('#{database_name}');

          RAISE NOTICE '%', sql;

          EXECUTE sql;
      END
      $$
    ")
    conn.disconnect
  end

  def invalidate_varnish_cache(options = {})
    options[:regex] ||= '.*'
    CartoDB::Varnish.new.purge("#{database_name}#{options[:regex]}")
  end

  ## Authentication
  AUTH_DIGEST = '47f940ec20a0993b5e9e4310461cc8a6a7fb84e3'

  # allow extra vars for auth
  attr_reader :password
  attr_accessor :password_confirmation

  ##
  # SLOW! Checks map views for every user
  # delta: get users who are also this percentage below their limit.
  #        example: 0.20 will get all users at 80% of their map view limit
  #
  def self.overquota(delta = 0)
    User.where(enabled: true).all.reject{ |u| u.organization_id.present? }.select do |u|
        limit = u.map_view_quota.to_i - (u.map_view_quota.to_i * delta)
        over_map_views = u.get_api_calls(from: u.last_billing_cycle, to: Date.today).sum > limit

        limit = u.geocoding_quota.to_i - (u.geocoding_quota.to_i * delta)
        over_geocodings = u.get_geocoding_calls > limit

        limit =  u.twitter_datasource_quota.to_i - (u.twitter_datasource_quota.to_i * delta)
        over_twitter_imports = u.get_twitter_imports_count > limit

        over_map_views || over_geocodings || over_twitter_imports
    end
  end

  def self.password_digest(password, salt)
    digest = AUTH_DIGEST
    10.times do
      digest = secure_digest(digest, salt, password, AUTH_DIGEST)
    end
    digest
  end

  def self.secure_digest(*args)
    Digest::SHA1.hexdigest(args.flatten.join('--'))
  end

  def self.make_token
    secure_digest(Time.now, (1..10).map{ rand.to_s })
  end

  def password=(value)
    @password = value
    self.salt = new?? self.class.make_token : User.filter(:id => self.id).select(:salt).first.salt
    self.crypted_password = self.class.password_digest(value, salt)
  end

  def self.authenticate(email, password)
    if candidate = User.filter("email ILIKE ? OR username ILIKE ?", email, email).first
      candidate.crypted_password == password_digest(password, candidate.salt) ? candidate : nil
    else
      nil
    end
  end

  # Database configuration setup

  def database_username
    if Rails.env.production?
      "cartodb_user_#{id}"
    elsif Rails.env.staging?
      "cartodb_staging_user_#{self.id}"
    else
      "#{Rails.env}_cartodb_user_#{id}"
    end
  end

  def database_public_username
    has_organization_enabled? ? "cartodb_publicuser_#{id}" : 'publicuser'
  end

  def database_password
    crypted_password + database_username
  end

  def user_database_host
    self.database_host
  end

  def reset_pooled_connections
    # Only close connections to this users' database
    $pool.close_connections!(self.database_name)
  end

  def in_database(options = {}, &block)
    configuration = get_db_configuration_for(options[:as])

    connection = $pool.fetch(configuration) do
      db = get_database(options, configuration)
      db.extension(:connection_validator)
      db.pool.connection_validation_timeout = configuration.fetch('conn_validator_timeout', -1)
      db
    end

    if block_given?
      yield(connection)
    else
      connection
    end
  end

  def connection(options = {})
    configuration = get_db_configuration_for(options[:as])

    $pool.fetch(configuration) do
      get_database(options, configuration)
    end
  end

  def get_database(options, configuration)
      ::Sequel.connect(configuration.merge(:after_connect=>(proc do |conn|
        conn.execute(%Q{ SET search_path TO "#{self.database_schema}", cartodb, public }) unless options[:as] == :cluster_admin
      end)))
  end

  def get_db_configuration_for(user = nil)
    logger = (Rails.env.development? || Rails.env.test? ? ::Rails.logger : nil)
    if user == :superuser
      ::Rails::Sequel.configuration.environment_for(Rails.env).merge(
        'database' => self.database_name,
        :logger => logger,
        'host' => self.database_host
      ) {|key, o, n| n.nil? ? o : n}
    elsif user == :cluster_admin
      ::Rails::Sequel.configuration.environment_for(Rails.env).merge(
        'database' => 'postgres',
        :logger => logger,
        'host' => self.database_host
      ) {|key, o, n| n.nil? ? o : n}
    elsif user == :public_user
      ::Rails::Sequel.configuration.environment_for(Rails.env).merge(
        'database' => self.database_name,
        :logger => logger,
        'username' => CartoDB::PUBLIC_DB_USER, 'password' => CartoDB::PUBLIC_DB_USER_PASSWORD,
        'host' => self.database_host
      ) {|key, o, n| n.nil? ? o : n}
    elsif user == :public_db_user
      ::Rails::Sequel.configuration.environment_for(Rails.env).merge(
        'database' => self.database_name,
        :logger => logger,
        'username' => database_public_username, 'password' => CartoDB::PUBLIC_DB_USER_PASSWORD,
        'host' => self.database_host
      ) {|key, o, n| n.nil? ? o : n}
    else
      ::Rails::Sequel.configuration.environment_for(Rails.env).merge(
        'database' => self.database_name,
        :logger => logger,
        'username' => database_username,
        'password' => database_password,
        'host' => self.database_host
      ) {|key, o, n| n.nil? ? o : n}
    end
  end


  def run_pg_query(query)
    time = nil
    res  = nil
    translation_proc = nil
    in_database do |user_database|
      time = Benchmark.measure {
        user_database.synchronize do |conn|
          res = conn.exec query
        end
        translation_proc = user_database.conversion_procs
      }
    end
    {
      :time          => time.real,
      :total_rows    => res.ntuples,
      :rows          => pg_to_hash(res, translation_proc),
      :results       => pg_results?(res),
      :modified      => pg_modified?(res),
      :affected_rows => pg_size(res)
    }
    rescue => e
    if e.is_a? PGError
      if e.message.include?("does not exist")
        if e.message.include?("column")
          raise CartoDB::ColumnNotExists, e.message
        else
          raise CartoDB::TableNotExists, e.message
        end
      else
        raise CartoDB::ErrorRunningQuery, e.message
      end
    else
      raise e
    end
  end

  # List all public visualization tags of the user
  def tags(exclude_shared=false, type=CartoDB::Visualization::Member::DERIVED_TYPE)
    require_relative './visualization/tags'
    options = {}
    options[:exclude_shared] = true if exclude_shared
    CartoDB::Visualization::Tags.new(self, options).names({
      type: type,
      privacy: CartoDB::Visualization::Member::PRIVACY_PUBLIC
    })
  end #tags

  # List all public map tags of the user
  def map_tags
    require_relative './visualization/tags'
    CartoDB::Visualization::Tags.new(self).names({
       type: CartoDB::Visualization::Member::CANONICAL_TYPE,
       privacy: CartoDB::Visualization::Member::PRIVACY_PUBLIC
    })
  end #map_tags

  def tables
    ::Table.filter(:user_id => self.id).order(:id).reverse
  end

  def tables_including_shared
    CartoDB::Visualization::Collection.new.fetch(
        user_id: self.id,
        type: CartoDB::Visualization::Member::CANONICAL_TYPE
    ).map { |item|
      item.table
    }
  end

  def load_avatar
    if self.avatar_url.nil?
      self.reload_avatar
    end
  end

  def reload_avatar
    request = Typhoeus::Request.new(
      self.gravatar(protocol = 'http://', 128, default_image = '404'),
      method: :get
    )
    response = request.run
    if response.code == 200
      # First try to update the url with the user gravatar
      self.avatar_url = "//#{gravatar_user_url(128)}"
      self.this.update avatar_url: self.avatar_url
    else
      # If the user doesn't have gravatar try to get a cartodb avatar
      if self.avatar_url.nil? || self.avatar_url == "//#{default_avatar}"
        # Only update the avatar if the user avatar is nil or the default image
        self.avatar_url = "//#{cartodb_avatar}"
        self.this.update avatar_url: self.avatar_url
      end
    end
  end

  def cartodb_avatar
    if !Cartodb.config[:avatars].nil? &&
       !Cartodb.config[:avatars]['base_url'].nil? && !Cartodb.config[:avatars]['base_url'].empty? &&
       !Cartodb.config[:avatars]['kinds'].nil? && !Cartodb.config[:avatars]['kinds'].empty? &&
       !Cartodb.config[:avatars]['colors'].nil? && !Cartodb.config[:avatars]['colors'].empty?
      avatar_base_url = Cartodb.config[:avatars]['base_url']
      avatar_kind = Cartodb.config[:avatars]['kinds'][Random.new.rand(0..Cartodb.config[:avatars]['kinds'].length - 1)]
      avatar_color = Cartodb.config[:avatars]['colors'][Random.new.rand(0..Cartodb.config[:avatars]['colors'].length - 1)]
      return "#{avatar_base_url}/avatar_#{avatar_kind}_#{avatar_color}.png"
    else
      CartoDB::Logger.info "Attribute avatars_base_url not found in config. Using default avatar"
      return default_avatar
    end
  end

  def avatar
    self.avatar_url.nil? ? "//#{self.default_avatar}" : self.avatar_url
  end

  def default_avatar
    return "cartodb.s3.amazonaws.com/static/public_dashboard_default_avatar.png"
  end

  def gravatar(protocol = "http://", size = 128, default_image = default_avatar)
    "#{protocol}#{self.gravatar_user_url(size)}&d=#{protocol}#{URI.encode(default_image)}"
  end #gravatar

  def gravatar_user_url(size = 128)
    digest = Digest::MD5.hexdigest(email.downcase)
    return "gravatar.com/avatar/#{digest}?s=#{size}"
  end

  # Retrive list of user tables from database catalogue
  #
  # You can use this to check for dangling records in the
  # admin db "user_tables" table.
  #
  # NOTE: this currently returns all public tables, can be
  #       improved to skip "service" tables
  #
  def tables_effective
    in_database do |user_database|
      user_database.synchronize do |conn|
        query = "select table_name::text from information_schema.tables where table_schema = 'public'"
        tables = user_database[query].all.map { |i| i[:table_name] }
        return tables
      end
    end
  end

  # Gets the list of OAuth accounts the user has (currently only used for synchronization)
  # @return CartoDB::OAuths
  def oauths
    @oauths ||= CartoDB::OAuths.new(self)
  end

  def trial_ends_at
    if account_type.to_s.downcase == 'magellan' && upgraded_at && upgraded_at + 15.days > Date.today
      upgraded_at + 15.days
    else
      nil
    end
  end

  def dedicated_support?
    /(FREE|MAGELLAN|JOHN SNOW|ACADEMY|ACADEMIC|ON HOLD)/i.match(self.account_type) ? false : true
  end

  def remove_logo?
    /(FREE|MAGELLAN|JOHN SNOW|ACADEMY|ACADEMIC|ON HOLD)/i.match(self.account_type) ? false : true
  end

  def soft_geocoding_limit?
    if self[:soft_geocoding_limit].nil?
      plan_list = "ACADEMIC|Academy|Academic|INTERNAL|FREE|AMBASSADOR|ACADEMIC MAGELLAN|PARTNER|FREE|Magellan|Academy|ACADEMIC|AMBASSADOR"
      (self.account_type =~ /(#{plan_list})/ ? false : true)
    else
      self[:soft_geocoding_limit]
    end
  end
  alias_method :soft_geocoding_limit, :soft_geocoding_limit?

  def hard_geocoding_limit?
    !self.soft_geocoding_limit?
  end
  alias_method :hard_geocoding_limit, :hard_geocoding_limit?

  def hard_geocoding_limit=(val)
    self[:soft_geocoding_limit] = !val
  end

  def arcgis_datasource_enabled?
    self.arcgis_datasource_enabled == true
  end

  def soft_twitter_datasource_limit?
    self.soft_twitter_datasource_limit  == true
  end

  def hard_twitter_datasource_limit?
    !self.soft_twitter_datasource_limit?
  end
  alias_method :hard_twitter_datasource_limit, :hard_twitter_datasource_limit?

  def hard_twitter_datasource_limit=(val)
    self[:soft_twitter_datasource_limit] = !val
  end

  def private_maps_enabled
    /(FREE|MAGELLAN|JOHN SNOW|ACADEMY|ACADEMIC|ON HOLD)/i.match(self.account_type) ? false : true
  end

  def import_quota
    self.account_type.downcase == 'free' ? 1 : 3
  end

  def view_dashboard
    self.this.update dashboard_viewed_at: Time.now
    set dashboard_viewed_at: Time.now
  end

  def dashboard_viewed?
    !!dashboard_viewed_at
  end

  # create the core user_metadata key that is used in redis
  def key
    "rails:users:#{username}"
  end

  # save users basic metadata to redis for node sql api to use
  def save_metadata
    $users_metadata.HMSET key,
      'id', id,
      'database_name', database_name,
      'database_password', database_password,
      'database_host', database_host,
      'database_publicuser', database_public_username,
      'map_key', api_key
  end

  def get_auth_tokens
    tokens = [get_auth_token]
    if has_organization?
      tokens << organization.get_auth_token
    end
    tokens
  end

  def get_auth_token
    if self.auth_token.nil?
      self.auth_token = make_auth_token
      self.save
    end
    self.auth_token
  end

  # Should return the number of tweets imported by this user for the specified period of time, as an integer
  def get_twitter_imports_count(options = {})
    date_to = (options[:to] ? options[:to].to_date : Date.today)
    date_from = (options[:from] ? options[:from].to_date : self.last_billing_cycle)
    self.search_tweets_dataset
        .where(state: ::SearchTweet::STATE_COMPLETE)
        .where('created_at >= ? AND created_at <= ?', date_from, date_to + 1.days)
        .sum("retrieved_items".lit).to_i
  end

  # Returns an array representing the last 30 days, populated with api_calls
  # from three different sources
  def get_api_calls(options = {})
    date_to = (options[:to] ? options[:to].to_date : Date.today)
    date_from = (options[:from] ? options[:from].to_date : Date.today - 29.days)
    calls = $users_metadata.pipelined do
      date_to.downto(date_from) do |date|
        $users_metadata.ZSCORE "user:#{username}:mapviews:global", date.strftime("%Y%m%d")
      end
    end.map &:to_i

    # Add old api calls
    old_calls = get_old_api_calls["per_day"].to_a.reverse rescue []
    calls = calls.zip(old_calls).map { |pair|
      pair[0].to_i + pair[1].to_i
    } unless old_calls.blank?

    # Add ES api calls
    es_calls = get_es_api_calls_from_redis(options) rescue []
    calls = calls.zip(es_calls).map { |pair|
      pair[0].to_i + pair[1].to_i
    } unless es_calls.blank?

    return calls
  end

  def get_geocoding_calls(options = {})
    date_to = (options[:to] ? options[:to].to_date : Date.today)
    date_from = (options[:from] ? options[:from].to_date : self.last_billing_cycle)
    self.geocodings_dataset.where(kind: 'high-resolution').where('created_at >= ? and created_at <= ?', date_from, date_to + 1.days)
      .sum("processed_rows + cache_hits".lit).to_i
  end # get_geocoding_calls

  # Get ES api calls from redis
  def get_es_api_calls_from_redis(options = {})
    date_to = (options[:to] ? options[:to].to_date : Date.today)
    date_from = (options[:from] ? options[:from].to_date : Date.today - 29.days)
    es_calls = $users_metadata.pipelined do
      date_to.downto(date_from) do |date|
        $users_metadata.ZSCORE "user:#{self.username}:mapviews_es:global", date.strftime("%Y%m%d")
      end
    end.map &:to_i
    return es_calls
  end

  def effective_twitter_block_price
    organization.present? ? organization.twitter_datasource_block_price : self.twitter_datasource_block_price
  end

  def effective_twitter_datasource_block_size
    organization.present? ? organization.twitter_datasource_block_size : self.twitter_datasource_block_size
  end

  def effective_twitter_total_quota
    organization.present? ? organization.twitter_datasource_quota : self.twitter_datasource_quota
  end

  def effective_get_twitter_imports_count
    organization.present? ? organization.get_twitter_imports_count : self.get_twitter_imports_count
  end

  def remaining_geocoding_quota
    if organization.present?
      remaining = organization.geocoding_quota - organization.get_geocoding_calls
    else
      remaining = geocoding_quota - get_geocoding_calls
    end
    (remaining > 0 ? remaining : 0)
  end

  def remaining_twitter_quota
    if organization.present?
      remaining = organization.twitter_datasource_quota - organization.get_twitter_imports_count
    else
      remaining = self.twitter_datasource_quota - get_twitter_imports_count
    end
    (remaining > 0 ? remaining : 0)
  end

  # Get the api calls from ES and sum them to the stored ones in redis
  # Returns the final sum of them
  def get_api_calls_from_es
    require 'date'
    yesterday = Date.today - 1
    from_date = DateTime.new(yesterday.year, yesterday.month, yesterday.day, 0, 0, 0).strftime("%Q")
    to_date = DateTime.now.strftime("%Q")
    request_body = Cartodb.config[:api_requests_es_service]['body'].dup
    request_url = Cartodb.config[:api_requests_es_service]['url'].dup
    request_body.gsub!("$CDB_SUBDOMAIN$", self.username)
    request_body.gsub!("\"$FROM$\"", from_date)
    request_body.gsub!("\"$TO$\"", to_date)
    request = Typhoeus::Request.new(
      request_url,
      method: :post,
      headers: { "Content-Type" => "application/json" },
      body: request_body
    )
    response = request.run
    if response.code != 200
      raise(response.body)
    end
    values = {}
    JSON.parse(response.body)["aggregations"]["0"]["buckets"].each {|i| values[i['key']] = i['doc_count']}
    return values
  end

  # Get the final api calls from ES and write them to redis
  def set_api_calls_from_es(options = {})
    if options[:force_update]
      es_api_calls = get_api_calls_from_es
      es_api_calls.each do |d,v|
        $users_metadata.ZADD "user:#{self.username}:mapviews_es:global", v, DateTime.strptime(d.to_s, "%Q").strftime("%Y%m%d")
      end
    end
  end

  # Legacy stats fetching

    def get_old_api_calls
      JSON.parse($users_metadata.HMGET(key, 'api_calls').first) rescue {}
    end

    def set_old_api_calls(options = {})
      # Ensure we update only once every 3 hours
      if options[:force_update] || get_old_api_calls["updated_at"].to_i < 3.hours.ago.to_i
        api_calls = JSON.parse(
          open("#{Cartodb.config[:api_requests_service_url]}?username=#{self.username}").read
        ) rescue {}

        # Manually set updated_at
        api_calls["updated_at"] = Time.now.to_i
        $users_metadata.HMSET key, 'api_calls', api_calls.to_json
      end
    end

  def last_billing_cycle
    day = period_end_date.day rescue 29.days.ago.day
    date = (day > Date.today.day ? Date.today<<1 : Date.today)
    begin
      Date.parse("#{date.year}-#{date.month}-#{day}")
    rescue ArgumentError
      day = day - 1
      retry
    end
  end

  def set_last_active_time
    $users_metadata.HMSET key, 'last_active_time',  Time.now
  end

  def get_last_active_time
    $users_metadata.HMGET(key, 'last_active_time').first
  end

  def set_last_ip_address(ip_address)
    $users_metadata.HMSET key, 'last_ip_address',  ip_address
  end

  def get_last_ip_address
    $users_metadata.HMGET(key, 'last_ip_address').first
  end

  def reset_client_application!
    if client_application
      client_application.destroy
    end
    ClientApplication.create(:user_id => self.id)
  end

  def self.find_with_custom_fields(user_id)
    User.filter(:id => user_id).select(:id,:email,:username,:tables_count,:crypted_password,:database_name,:admin).first
  end


  def enabled?
    self.enabled
  end

  def disabled?
    !self.enabled
  end

  def database_exists?
    return false if database_name.blank?
    conn = self.in_database(as: :cluster_admin)
    conn[:pg_database].filter(:datname => database_name).all.any?
  end

  private :database_exists?

  # This method is innaccurate and understates point based tables (the /2 is to account for the_geom_webmercator)
  # TODO: Without a full table scan, ignoring the_geom_webmercator, we cannot accuratly asses table size
  # Needs to go on a background job.
  def db_size_in_bytes(use_total = false)
    attempts = 0
    begin
      # Hack to support users without the new MU functiones loaded
      user_data_size_function = self.cartodb_extension_version_pre_mu? ? "CDB_UserDataSize()" : "CDB_UserDataSize('#{self.database_schema}')"
      result = in_database(:as => :superuser).fetch("SELECT cartodb.#{user_data_size_function}").first[:cdb_userdatasize]
      update_gauge("db_size", result)
      result
    rescue
      attempts += 1
      in_database(:as => :superuser).fetch("ANALYZE")
      retry unless attempts > 1
    end
  end

  def real_tables
    self.in_database(:as => :superuser)
    .select(:pg_class__oid, :pg_class__relname)
    .from(:pg_class)
    .join_table(:inner, :pg_namespace, :oid => :relnamespace)
    .where(:relkind => 'r', :nspname => self.database_schema)
    .exclude(:relname => SYSTEM_TABLE_NAMES)
    .all
  end

  def ghost_tables_work(job)
    job && job['payload'] && job['payload']['class'] === 'Resque::UserJobs::SyncTables::LinkGhostTables' && !job['args'].nil? && job['args'].length == 1 && job['args'][0] === self.id
  end

  def link_ghost_tables_working
    # search in the first 100. This is random number
    enqeued = Resque.peek(:users, 0, 100).select { |job| 
      job && job['class'] === 'Resque::UserJobs::SyncTables::LinkGhostTables' && !job['args'].nil? && job['args'].length == 1 && job['args'][0] === self.id
    }.length
    workers = Resque::Worker.all
    working = workers.select { |w| ghost_tables_work(w.job) }.length
    return (workers.length > 0 && working > 0) || enqeued > 0
  end

  # Looks for tables created on the user database with
  # the columns needed
  def link_ghost_tables
    no_tables = self.real_tables.blank?
    link_renamed_tables unless no_tables
    link_deleted_tables
    link_created_tables(search_for_cartodbfied_tables) unless no_tables
  end

  # this method search for tables with all the columns needed in a cartodb table.
  # it does not check column types or triggers attached
  # returns the list of tables in the database with those columns but not in metadata database
  def search_for_cartodbfied_tables
    metadata_table_names = self.tables.select(:name).map(&:name).map { |t| "'" + t + "'" }.join(',')
    db = self.in_database(:as => :superuser)
    reserved_columns = Table::CARTODB_COLUMNS + [Table::THE_GEOM_WEBMERCATOR]
    cartodb_columns = (reserved_columns).map { |t| "'" + t.to_s + "'" }.join(',')
    sql = %Q{
      WITH a as (
        SELECT table_name, count(column_name::text) cdb_columns_count
        FROM information_schema.columns c, pg_tables t
        WHERE
        t.tablename = c.table_name AND
        t.tableowner = '#{database_username}' AND
    }

    if metadata_table_names.length != 0
      sql += "c.table_name not in (#{metadata_table_names}) AND"
    end

    sql += %Q{
          column_name in (#{cartodb_columns})
          group by 1
      )
      select table_name from a where cdb_columns_count = #{reserved_columns.length}
    }
    db[sql].all.map { |t| t[:table_name] }
  end

  # search in the user database for tables that are not in the metadata database
  def search_for_modified_table_names
    metadata_table_names = self.tables.select(:name).map(&:name)
    #TODO: filter real tables by ownership
    real_names = real_tables.map { |t| t[:relname] }
    return metadata_table_names.to_set != real_names.to_set
  end


  def link_renamed_tables
    metadata_tables_ids = self.tables.select(:table_id).map(&:table_id)
    metadata_table_names = self.tables.select(:name).map(&:name)
    renamed_tables       = real_tables.reject{|t| metadata_table_names.include?(t[:relname])}.select{|t| metadata_tables_ids.include?(t[:oid])}
    renamed_tables.each do |t|
      table = ::Table.find(:table_id => t[:oid])
      begin
        Rollbar.report_message('ghost tables', 'debug', {
          :action => 'rename',
          :new_table => t[:relname]
        })
        vis = table.table_visualization
        vis.register_table_only = true
        vis.name = t[:relname]
        vis.store
      rescue Sequel::DatabaseError => e
        raise unless e.message =~ /must be owner of relation/
      end
    end
  end

  def link_created_tables(table_names)
    created_tables = real_tables.select {|t| table_names.include?(t[:relname]) }
    created_tables.each do |t|
      begin
        Rollbar.report_message('ghost tables', 'debug', {
          :action => 'registering table',
          :new_table => t[:relname]
        })
        table = Table.new
        table.user_id  = self.id
        table.name     = t[:relname]
        table.table_id = t[:oid]
        table.register_table_only = true
        table.keep_user_database_table = true
        table.save
      rescue => e
        puts e
      end
    end
  end

  def link_deleted_tables
    metadata_tables_ids = self.tables.select(:table_id).map(&:table_id)
    dropped_tables = metadata_tables_ids - real_tables.map{|t| t[:oid]}

    # Remove tables with oids that don't exist on the db
    self.tables.where(table_id: dropped_tables).all.each do |table|
      Rollbar.report_message('ghost tables', 'debug', {
        :action => 'dropping table',
        :new_table => table.name
      })
      table.keep_user_database_table = true
      table.destroy
    end if dropped_tables.present?

    # Remove tables with null oids unless the table name exists on the db
    self.tables.filter(table_id: nil).all.each do |t|
      t.keep_user_database_table = true
      t.destroy unless self.real_tables.map { |t| t[:relname] }.include?(t.name)
    end if dropped_tables.present? && dropped_tables.include?(nil)
  end

  def exceeded_quota?
    self.over_disk_quota? || self.over_table_quota?
  end

  def remaining_quota(use_total = false)
    self.quota_in_bytes - self.db_size_in_bytes(use_total)
  end

  def disk_quota_overspend
    self.over_disk_quota? ? self.remaining_quota.abs : 0
  end

  def over_disk_quota?
    self.remaining_quota <= 0
  end

  def over_table_quota?
    (remaining_table_quota && remaining_table_quota <= 0) ? true : false
  end

  def account_type_name
    self.account_type.gsub(' ', '_').downcase
    rescue
    ''
  end

  #can be nil table quotas
  def remaining_table_quota
    if self.table_quota.present?
      remaining = self.table_quota - self.table_count
      (remaining < 0) ? 0 : remaining
    end
  end

  def public_table_count
    table_count({
      privacy: CartoDB::Visualization::Member::PRIVACY_PUBLIC,
      exclude_raster: true
    })
  end

  # Only returns owned tables (not shared ones)
  def table_count(filters={})
    filters.merge!(
      type: CartoDB::Visualization::Member::CANONICAL_TYPE,
      exclude_shared: true
    )

    visualization_count(filters)
  end

  def failed_import_count
    DataImport.where(user_id: self.id, state: 'failure').count
  end

  def success_import_count
    DataImport.where(user_id: self.id, state: 'complete').count
  end

  def import_count
    DataImport.where(user_id: self.id).count
  end

  # Get the count of public visualizations
  def public_visualization_count
    visualization_count({
      type: CartoDB::Visualization::Member::DERIVED_TYPE,
      privacy: CartoDB::Visualization::Member::PRIVACY_PUBLIC,
      exclude_shared: true,
      exclude_raster: true
    })
  end

  # Get a count of visualizations with some optional filters
  def visualization_count(filters = {})
    type_filter           = filters.fetch(:type, nil)
    privacy_filter        = filters.fetch(:privacy, nil)
    exclude_shared_filter = filters.fetch(:exclude_shared, false)
    exclude_raster_filter = filters.fetch(:exclude_raster, false)

    parameters = {
      user_id:        self.id,
      per_page:       CartoDB::Visualization::Collection::ALL_RECORDS,
      exclude_shared: exclude_shared_filter
    }

    parameters.merge!(type: type_filter)      unless type_filter.nil?
    parameters.merge!(privacy: privacy_filter)   unless privacy_filter.nil?
    parameters.merge!(exclude_raster: exclude_raster_filter) if exclude_raster_filter
    CartoDB::Visualization::Collection.new.fetch(parameters).count
  end

  def last_visualization_created_at
    Rails::Sequel.connection.fetch("SELECT created_at FROM visualizations WHERE " +
      "map_id IN (select id FROM maps WHERE user_id=?) ORDER BY created_at DESC " +
      "LIMIT 1;", id)
      .to_a.fetch(0, {}).fetch(:created_at, nil)
  end

  def metric_key
    "cartodb.#{Rails.env.production? ? "user" : Rails.env + "-user"}.#{self.username}"
  end

  def update_gauge(gauge, value)
    Statsd.gauge("#{metric_key}.#{gauge}", value)
  rescue
  end

  def update_visualization_metrics
    update_gauge("visualizations.total", maps.count)
    update_gauge("visualizations.table", table_count)

    update_gauge("visualizations.derived", visualization_count({ exclude_shared: true, exclude_raster: true }))
  end

  def rebuild_quota_trigger
    puts "Setting user quota in db '#{database_name}' (#{username})"
    in_database(:as => :superuser) do |db|

      if !cartodb_extension_version_pre_mu? && has_organization?
        db.run("DROP FUNCTION IF EXISTS public._CDB_UserQuotaInBytes();")
      end

      db.transaction do
        # NOTE: this has been written to work for both
        #       databases that switched to "cartodb" extension
        #       and those before the switch.
        #       In the future we should guarantee that exntension
        #       lives in cartodb schema so we don't need to set
        #       a search_path before
        search_path = db.fetch("SHOW search_path;").first[:search_path]
        db.run("SET search_path TO cartodb, public;")
        if cartodb_extension_version_pre_mu?
          db.run("SELECT CDB_SetUserQuotaInBytes(#{self.quota_in_bytes});")
        else
          db.run("SELECT CDB_SetUserQuotaInBytes('#{self.database_schema}', #{self.quota_in_bytes});")
        end
        db.run("SET search_path TO #{search_path};")
      end
    end
  end

  def importing_jobs
    imports = DataImport.where(state: ['complete', 'failure']).invert
      .where(user_id: self.id)
      .where { created_at > Time.now - 24.hours }.all
    running_import_ids = Resque::Worker.all.map { |worker| worker.job["payload"]["args"].first["job_id"] rescue nil }.compact
    imports.map do |import|
      if import.created_at < Time.now - 5.minutes && !running_import_ids.include?(import.id)
        import.handle_failure
        nil
      else
        import
      end
    end.compact
  end

  def job_tracking_identifier
    "account#{self.username}"
  end

  def partial_db_name
    if self.has_organization_enabled?
      self.organization.owner_id
    else
      self.id
    end
  end

  def has_organization_enabled?
    if self.has_organization? && self.organization.owner.present?
      true
    else
      false
    end
  end

  def has_organization?
    !!self.organization
  end

  def organization_owner?
    self.organization.present? && self.organization.owner == self
  end

  def organization_user?
    self.organization.present?
  end

  def belongs_to_organization?(organization)
    organization_user? and self.organization.eql? organization
  end

  def create_client_application
    ClientApplication.create(:user_id => self.id)
  end

  def create_db_user
    conn = self.in_database(as: :cluster_admin)
    begin
      conn.run("CREATE USER \"#{database_username}\" PASSWORD '#{database_password}'")
    rescue => e
      puts "#{Time.now} USER SETUP ERROR (#{database_username}): #{$!}"
      raise e
    end
  end

  def create_public_db_user
    in_database(as: :superuser) do |database|
      database.run(%Q{ CREATE USER "#{database_public_username}" LOGIN INHERIT })
      database.run(%Q{ GRANT publicuser TO "#{database_public_username}" })
      database.run(%Q{ ALTER USER "#{database_public_username}" SET search_path = "#{database_schema}", public, cartodb })
    end
  end

  def create_user_db
    conn = self.in_database(as: :cluster_admin)
    begin
      conn.run("CREATE DATABASE \"#{self.database_name}\"
      WITH TEMPLATE = template_postgis
      OWNER = #{::Rails::Sequel.configuration.environment_for(Rails.env)['username']}
      ENCODING = 'UTF8'
      CONNECTION LIMIT=-1")
    rescue => e
      puts "#{Time.now} USER SETUP ERROR WHEN CREATING DATABASE #{self.database_name}: #{$!}"
      raise e
    end
  end

  def set_database_name
    # Assign database_name
    self.database_name = case Rails.env
      when 'development'
        "cartodb_dev_user_#{self.partial_db_name}_db"
      when 'staging'
        "cartodb_staging_user_#{self.partial_db_name}_db"
      when 'test'
        "cartodb_test_user_#{self.partial_db_name}_db"
      else
        "cartodb_user_#{self.partial_db_name}_db"
    end
    if self.has_organization_enabled?
      if !database_exists?
        raise "Organization database #{database_name} doesn't exist"
      end
    else
      if database_exists?
        raise "Database #{database_name} already exists"
      end
    end
    self.this.update database_name: self.database_name
  end

  def setup_new_user
    self.create_client_application
    Thread.new do
      self.create_db_user
      self.create_user_db
      self.grant_owner_in_database
    end.join
    self.create_importer_schema
    self.create_geocoding_schema
    self.load_cartodb_functions
    self.set_database_search_path
    self.reset_database_permissions # Reset privileges
    self.grant_publicuser_in_database
    self.set_user_privileges # Set privileges
    self.set_user_as_organization_member
    self.rebuild_quota_trigger
    self.create_function_invalidate_varnish
  end

  def setup_organization_user
    self.create_client_application
    Thread.new do
      self.create_db_user
      self.grant_user_in_database
    end.join
    self.load_cartodb_functions
    self.database_schema = self.username
    self.this.update database_schema: self.database_schema
    self.create_user_schema
    self.set_database_search_path
    self.create_public_db_user
    self.setup_schema
  end

  def setup_schema
    #This method is used both when creating a new user
    #and by the relocator when user is relocated to an org database.
    self.reset_user_schema_permissions # Reset privileges
    self.reset_schema_owner # Set user as his schema owner
    self.set_user_privileges # Set privileges
    self.set_user_as_organization_member
    self.rebuild_quota_trigger
  end

  def reset_schema_owner
    in_database(as: :superuser) do |database|
      database.run(%Q{ALTER SCHEMA \"#{self.database_schema}\" OWNER TO "#{self.database_username}"})
    end
  end

  def grant_owner_in_database
    self.run_queries_in_transaction(
      self.grant_all_on_database_queries,
      true
    )
  end

  def grant_user_in_database
    self.run_queries_in_transaction(
      self.grant_connect_on_database_queries,
      true
    )
  end

  def grant_publicuser_in_database
    self.run_queries_in_transaction(
      self.grant_connect_on_database_queries(CartoDB::PUBLIC_DB_USER),
      true
    )
    self.run_queries_in_transaction(
      self.grant_read_on_schema_queries('cartodb', CartoDB::PUBLIC_DB_USER),
      true
    )
    self.run_queries_in_transaction(
      [
        "GRANT USAGE ON SCHEMA public TO #{CartoDB::PUBLIC_DB_USER}",
        "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO #{CartoDB::PUBLIC_DB_USER}",
        "GRANT SELECT ON spatial_ref_sys TO #{CartoDB::PUBLIC_DB_USER}"
      ],
      true
    )
  end

  def set_user_privileges_in_cartodb_schema # MU
    # Privileges in cartodb schema
    self.run_queries_in_transaction(
      (
        self.grant_read_on_schema_queries('cartodb') +
        self.grant_write_on_cdb_tablemetadata_queries
      ),
      true
    )
  end

  def set_user_privileges_in_public_schema # MU
    # Privileges in public schema
    self.run_queries_in_transaction(
      self.grant_read_on_schema_queries('public'),
      true
    )
  end

  def set_user_privileges_in_own_schema # MU
    # Privileges in its own schema
    self.run_queries_in_transaction(
      self.grant_all_on_user_schema_queries,
      true
    )
  end

  def set_user_privileges_in_importer_schema # MU
    # Privileges in cdb_importer_schema
    self.run_queries_in_transaction(
      self.grant_all_on_schema_queries('cdb_importer'),
      true
    )
  end

  def set_user_privileges_in_geocoding_schema
    self.run_queries_in_transaction(
        self.grant_all_on_schema_queries('cdb'),
        true
    )
  end

  def set_privileges_to_publicuser_in_own_schema # MU
    # Privileges in user schema for publicuser
    self.run_queries_in_transaction(
      self.grant_usage_on_user_schema_to_other(CartoDB::PUBLIC_DB_USER),
      true
    )
  end

  def set_raster_privileges
    queries = [
      "GRANT SELECT ON TABLE \"#{database_schema}\".\"raster_overviews\" TO \"#{CartoDB::PUBLIC_DB_USER}\"",
      "GRANT SELECT ON TABLE \"#{database_schema}\".\"raster_columns\" TO \"#{CartoDB::PUBLIC_DB_USER}\"",
    ]
    unless self.organization.nil?
      queries << "GRANT SELECT ON TABLE \"#{database_schema}\".\"raster_overviews\" TO \"#{database_public_username}\""
      queries << "GRANT SELECT ON TABLE \"#{database_schema}\".\"raster_columns\" TO \"#{database_public_username}\""
    end
    self.run_queries_in_transaction(queries,true)
  end

  def set_user_privileges # MU
    self.set_user_privileges_in_cartodb_schema
    self.set_user_privileges_in_public_schema
    self.set_user_privileges_in_own_schema
    self.set_user_privileges_in_importer_schema
    self.set_user_privileges_in_geocoding_schema
    self.set_privileges_to_publicuser_in_own_schema
    self.set_raster_privileges
  end



  ## User's databases setup methods
  def setup_user
    return if disabled?
    self.set_database_name

    if self.has_organization_enabled?
      self.setup_organization_user
    else
      if self.has_organization?
        raise "It's not possible to create a user within a inactive organization"
      else
        self.setup_new_user
      end
    end
    #set_user_as_organization_owner_if_needed
  end

  def set_database_search_path
    in_database(as: :superuser) do |database|
      database.run(%Q{ ALTER USER "#{database_username}" SET search_path = "#{database_schema}", public, cartodb })
    end
  end

  def create_importer_schema
    create_schema('cdb_importer')
  end

  def create_geocoding_schema
    create_schema('cdb')
  end

  def create_user_schema
    create_schema(self.database_schema, self.database_username)
  end

  # Attempts to create a new database schema
  # Does not raise exception if the schema already exists
  def create_schema(schema, role = nil)
    in_database(as: :superuser) do |database|
      if role
        database.run(%Q{CREATE SCHEMA "#{schema}" AUTHORIZATION "#{role}"})
      else
        database.run(%Q{CREATE SCHEMA "#{schema}"})
      end
    end
  rescue Sequel::DatabaseError => e
    raise unless e.message =~ /schema .* already exists/
  end #create_schema

  # Add plpythonu pl handler
  def add_python
    in_database(
      :as => :superuser,
      no_cartodb_in_schema: true
    ).run(<<-SQL
      CREATE OR REPLACE PROCEDURAL LANGUAGE 'plpythonu' HANDLER plpython_call_handler;
    SQL
    )
  end

  # Create a "public.cdb_invalidate_varnish()" function to invalidate Varnish
  #
  # The function can only be used by the superuser, we expect
  # security-definer triggers OR triggers on superuser-owned tables
  # to call it with controlled set of parameters.
  #
  # The function is written in python because it needs to reach out
  # to a Varnish server.
  #
  # Being unable to communicate with Varnish may or may not be critical
  # depending on CartoDB configuration at time of function definition.
  #

  def create_function_invalidate_varnish
    if Cartodb.config[:varnish_management].fetch('http_port', false)
      create_function_invalidate_varnish_http
    else
      create_function_invalidate_varnish_telnet
    end
  end

  # Telnet invalidation works only for Varnish 2.x.
  def create_function_invalidate_varnish_telnet

    add_python

    varnish_host = Cartodb.config[:varnish_management].try(:[],'host') || '127.0.0.1'
    varnish_port = Cartodb.config[:varnish_management].try(:[],'port') || 6082
    varnish_timeout = Cartodb.config[:varnish_management].try(:[],'timeout') || 5
    varnish_critical = Cartodb.config[:varnish_management].try(:[],'critical') == true ? 1 : 0
    varnish_retry = Cartodb.config[:varnish_management].try(:[],'retry') || 5
    purge_command = Cartodb::config[:varnish_management]["purge_command"]



    in_database(:as => :superuser).run(<<-TRIGGER
    BEGIN;
    CREATE OR REPLACE FUNCTION public.cdb_invalidate_varnish(table_name text) RETURNS void AS
    $$
        critical = #{varnish_critical}
        timeout = #{varnish_timeout}
        retry = #{varnish_retry}

        client = GD.get('varnish', None)

        while True:

          if not client:
              try:
                import varnish
                client = GD['varnish'] = varnish.VarnishHandler(('#{varnish_host}', #{varnish_port}, timeout))
              except Exception as err:
                # NOTE: we won't retry on connection error
                if critical:
                  plpy.error('Varnish connection error: ' +  str(err))
                break

          try:
            # NOTE: every table change also changed CDB_TableMetadata, so
            #       we purge those entries too
            #
            # TODO: do not invalidate responses with surrogate key
            #       "not_this_one" when table "this" changes :/
            #       --strk-20131203;
            #
            client.fetch('#{purge_command} obj.http.X-Cache-Channel ~ "^#{self.database_name}:(.*%s.*)|(cdb_tablemetadata)|(table)$"' % table_name.replace('"',''))
            break
          except Exception as err:
            plpy.warning('Varnish fetch error: ' + str(err))
            client = GD['varnish'] = None # force reconnect
            if not retry:
              if critical:
                plpy.error('Varnish fetch error: ' +  str(err))
              break
            retry -= 1 # try reconnecting
    $$
    LANGUAGE 'plpythonu' VOLATILE;
    REVOKE ALL ON FUNCTION public.cdb_invalidate_varnish(TEXT) FROM PUBLIC;
    COMMIT;
TRIGGER
    )
  end

  def create_function_invalidate_varnish_http

    add_python

    varnish_host = Cartodb.config[:varnish_management].try(:[],'host') || '127.0.0.1'
    varnish_port = Cartodb.config[:varnish_management].try(:[],'http_port') || 6081
    varnish_timeout = Cartodb.config[:varnish_management].try(:[],'timeout') || 5
    varnish_critical = Cartodb.config[:varnish_management].try(:[],'critical') == true ? 1 : 0
    varnish_retry = Cartodb.config[:varnish_management].try(:[],'retry') || 5
    purge_command = Cartodb::config[:varnish_management]["purge_command"]



    in_database(:as => :superuser).run(<<-TRIGGER
    BEGIN;
    CREATE OR REPLACE FUNCTION public.cdb_invalidate_varnish(table_name text) RETURNS void AS
    $$
        critical = #{varnish_critical}
        timeout = #{varnish_timeout}
        retry = #{varnish_retry}

        import httplib

        while True:

          try:
            # NOTE: every table change also changed CDB_TableMetadata, so
            #       we purge those entries too
            #
            # TODO: do not invalidate responses with surrogate key
            #       "not_this_one" when table "this" changes :/
            #       --strk-20131203;
            #
            client = httplib.HTTPConnection('#{varnish_host}', #{varnish_port}, False, timeout)
            client.request('PURGE', '/batch', '', {"Invalidation-Match": ('^#{self.database_name}:(.*%s.*)|(cdb_tablemetadata)|(table)$' % table_name.replace('"',''))  })
            response = client.getresponse()
            assert response.status == 204
            break
          except Exception as err:
            plpy.warning('Varnish purge error: ' + str(err))
            if not retry:
              if critical:
                plpy.error('Varnish purge error: ' +  str(err))
              break
            retry -= 1 # try reconnecting
    $$
    LANGUAGE 'plpythonu' VOLATILE;
    REVOKE ALL ON FUNCTION public.cdb_invalidate_varnish(TEXT) FROM PUBLIC;
    COMMIT;
TRIGGER
    )
  end

  # Returns a tree elements array with [major, minor, patch] as in http://semver.org/
  def cartodb_extension_semver(extension_version)
    extension_version.split('.').take(3).map(&:to_i)
  end

  def cartodb_extension_version
    self.in_database(:as => :superuser).fetch('select cartodb.cdb_version() as v').first[:v]
  end

  def cartodb_extension_version_pre_mu?
    current_version = self.cartodb_extension_semver(self.cartodb_extension_version)
    if current_version.size == 3
      major, minor, _ = current_version
      major == 0 and minor < 3
    else
      raise 'Current cartodb extension version does not match standard x.y.z format'
    end
  end

  # Cartodb functions
  def load_cartodb_functions(statement_timeout = nil, cdb_extension_target_version = nil)
    if cdb_extension_target_version.nil?
      cdb_extension_target_version = '0.5.0'
    end

    add_python

    in_database({
                    as: :superuser,
                    no_cartodb_in_schema: true
                }) do |db|
      db.transaction do

        unless statement_timeout.nil?
          old_timeout = db.fetch("SHOW statement_timeout;").first[:statement_timeout]
          db.run("SET statement_timeout TO '#{statement_timeout}';")
        end

        db.run('CREATE EXTENSION plpythonu FROM unpackaged') unless db.fetch(%Q{
            SELECT count(*) FROM pg_extension WHERE extname='plpythonu'
          }).first[:count] > 0
        db.run('CREATE EXTENSION schema_triggers') unless db.fetch(%Q{
            SELECT count(*) FROM pg_extension WHERE extname='schema_triggers'
          }).first[:count] > 0
        db.run('CREATE EXTENSION postgis FROM unpackaged') unless db.fetch(%Q{
            SELECT count(*) FROM pg_extension WHERE extname='postgis'
          }).first[:count] > 0

        db.run(%Q{
          DO LANGUAGE 'plpgsql' $$
          DECLARE
            ver TEXT;
          BEGIN
            BEGIN
              SELECT cartodb.cdb_version() INTO ver;
            EXCEPTION WHEN undefined_function OR invalid_schema_name THEN
              RAISE NOTICE 'Got % (%)', SQLERRM, SQLSTATE;
              BEGIN
                CREATE EXTENSION cartodb VERSION '#{cdb_extension_target_version}' FROM unpackaged;
              EXCEPTION WHEN undefined_table THEN
                RAISE NOTICE 'Got % (%)', SQLERRM, SQLSTATE;
                CREATE EXTENSION cartodb VERSION '#{cdb_extension_target_version}';
                RETURN;
              END;
              RETURN;
            END;
            ver := '#{cdb_extension_target_version}';
            IF position('dev' in ver) > 0 THEN
              EXECUTE 'ALTER EXTENSION cartodb UPDATE TO ''' || ver || 'next''';
              EXECUTE 'ALTER EXTENSION cartodb UPDATE TO ''' || ver || '''';
            ELSE
              EXECUTE 'ALTER EXTENSION cartodb UPDATE TO ''' || ver || '''';
            END IF;
          END;
          $$;
        })

        unless statement_timeout.nil?
          db.run("SET statement_timeout TO '#{old_timeout}';")
        end

        obtained = db.fetch('SELECT cartodb.cdb_version() as v').first[:v]

        unless cartodb_extension_semver(cdb_extension_target_version) == cartodb_extension_semver(obtained)
          raise("Expected cartodb extension '#{cdb_extension_target_version}' obtained '#{obtained}'")
        end

#       db.run('SELECT cartodb.cdb_enable_ddl_hooks();')
      end
    end

    # We reset the connections to this database to be sure the change in default search_path is effective
    self.reset_pooled_connections

    self.rebuild_quota_trigger
  end

  def set_statement_timeouts
    in_database(as: :superuser) do |user_database|
      user_database["ALTER ROLE \"?\" SET statement_timeout to ?", database_username.lit, user_timeout].all
      user_database["ALTER DATABASE \"?\" SET statement_timeout to ?", database_name.lit, database_timeout].all
    end
    in_database.disconnect
    in_database.connect(get_db_configuration_for)
    in_database(as: :public_user).disconnect
    in_database(as: :public_user).connect(get_db_configuration_for(:public_user))
  rescue Sequel::DatabaseConnectionError => e
  end

  def run_queries_in_transaction(queries, superuser = false)
    conn_params = {}
    if superuser
      conn_params[:as] = :superuser
    end
    in_database(conn_params) do |user_database|
      user_database.transaction do
        queries.each do |q|
          user_database.run(q)
        end
        yield(user_database) if block_given?
      end
    end
  end

  def set_user_as_organization_member
    in_database(:as => :superuser) do |user_database|
      user_database.transaction do
        user_database.run("SELECT cartodb.CDB_Organization_Create_Member('#{database_username}');")
      end
    end
  end

  def set_user_as_organization_owner_if_needed
    if self.organization && self.organization.reload && self.organization.owner.nil? && self.organization.users.count == 1
      self.organization.owner = self
      self.organization.save
    end
  end

  def grant_connect_on_database_queries(db_user = nil)
    granted_user = db_user.nil? ? self.database_username : db_user
    [
      "GRANT CONNECT ON DATABASE \"#{self.database_name}\" TO \"#{granted_user}\""
    ]
  end

  def grant_all_on_database_queries
    [
      "GRANT ALL ON DATABASE \"#{self.database_name}\" TO \"#{self.database_username}\""
    ]
  end

  def grant_read_on_schema_queries(schema, db_user = nil)
    granted_user = db_user.nil? ? self.database_username : db_user
    [
      "GRANT USAGE ON SCHEMA \"#{schema}\" TO \"#{granted_user}\"",
      "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA \"#{schema}\" TO \"#{granted_user}\"",
      "GRANT SELECT ON ALL TABLES IN SCHEMA \"#{schema}\" TO \"#{granted_user}\""
    ]
  end

  def grant_write_on_cdb_tablemetadata_queries
    [
      "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE cartodb.cdb_tablemetadata TO \"#{database_username}\""
    ]
  end

  def grant_all_on_user_schema_queries
    [
      "GRANT ALL ON SCHEMA \"#{self.database_schema}\" TO \"#{database_username}\"",
      "GRANT ALL ON ALL SEQUENCES IN SCHEMA  \"#{self.database_schema}\" TO \"#{database_username}\"",
      "GRANT ALL ON ALL FUNCTIONS IN SCHEMA  \"#{self.database_schema}\" TO \"#{database_username}\"",
      "GRANT ALL ON ALL TABLES IN SCHEMA  \"#{self.database_schema}\" TO \"#{database_username}\""
    ]
  end

  def grant_usage_on_user_schema_to_other(granted_user)
    [
      "GRANT USAGE ON SCHEMA \"#{self.database_schema}\" TO \"#{granted_user}\""
    ]
  end

  def grant_all_on_schema_queries(schema)
    [
      "GRANT ALL ON SCHEMA \"#{schema}\" TO \"#{database_username}\""
    ]
  end

  def drop_user_privileges_in_schema(schema, additional_accounts=[])
    in_database(:as => :superuser) do |user_database|
      user_database.transaction do
        ([self.database_username, self.database_public_username] + additional_accounts).each do |u|
          user_database.run("REVOKE ALL ON SCHEMA \"#{schema}\" FROM \"#{u}\"")
          user_database.run("REVOKE ALL ON ALL SEQUENCES IN SCHEMA \"#{schema}\" FROM \"#{u}\"")
          user_database.run("REVOKE ALL ON ALL FUNCTIONS IN SCHEMA \"#{schema}\" FROM \"#{u}\"")
          user_database.run("REVOKE ALL ON ALL TABLES IN SCHEMA \"#{schema}\" FROM \"#{u}\"")
        end
      end
    end
  end

  def reset_user_schema_permissions
    in_database(:as => :superuser) do |user_database|
      user_database.transaction do
        schemas = [self.database_schema].uniq
        schemas.each do |schema|
          user_database.run("REVOKE ALL ON SCHEMA \"#{schema}\" FROM PUBLIC")
          user_database.run("REVOKE ALL ON ALL SEQUENCES IN SCHEMA \"#{schema}\" FROM PUBLIC")
          user_database.run("REVOKE ALL ON ALL FUNCTIONS IN SCHEMA \"#{schema}\" FROM PUBLIC")
          user_database.run("REVOKE ALL ON ALL TABLES IN SCHEMA \"#{schema}\" FROM PUBLIC")
        end
        yield(user_database) if block_given?
      end
    end
  end

  def reset_database_permissions
    in_database(:as => :superuser) do |user_database|
      user_database.transaction do
        schemas = %w(public cdb_importer cdb cartodb)

        ['PUBLIC', CartoDB::PUBLIC_DB_USER].each do |u|
          user_database.run("REVOKE ALL ON DATABASE \"#{database_name}\" FROM #{u}")
          schemas.each do |schema|
            user_database.run("REVOKE ALL ON SCHEMA \"#{schema}\" FROM #{u}")
            user_database.run("REVOKE ALL ON ALL SEQUENCES IN SCHEMA \"#{schema}\" FROM #{u}")
            user_database.run("REVOKE ALL ON ALL FUNCTIONS IN SCHEMA \"#{schema}\" FROM #{u}")
            user_database.run("REVOKE ALL ON ALL TABLES IN SCHEMA \"#{schema}\" FROM #{u}")
          end
        end
        yield(user_database) if block_given?
      end
    end
  end

  # Drops grants and functions in a given schema, avoiding by all means a CASCADE
  # to not affect extensions or other users
  def drop_all_functions_from_schema(schema_name)
    recursivity_max_depth = 3

    return if schema_name == 'public'

    in_database(as: :superuser) do |database|
      # Non-aggregate functions
      drop_function_sqls = database.fetch(%Q{
        SELECT 'DROP FUNCTION ' || ns.nspname || '.' || proname || '(' || oidvectortypes(proargtypes) || ');' AS sql
        FROM pg_proc INNER JOIN pg_namespace ns ON (pg_proc.pronamespace = ns.oid AND pg_proc.proisagg = FALSE)
        WHERE ns.nspname = '#{schema_name}'
      })

      # Simulate a controlled environment drop cascade contained to only functions
      failed_sqls = []
      recursivity_level = 0
      begin
        failed_sqls = []
        drop_function_sqls.each { |sql_sentence|
          begin
            database.run(sql_sentence[:sql])
          rescue Sequel::DatabaseError => e
            if e.message =~ /depends on function /i
              failed_sqls.push(sql_sentence)
            else
              raise
            end
          end
        }
        drop_function_sqls = failed_sqls
        recursivity_level += 1
      end while failed_sqls.count > 0 && recursivity_level < recursivity_max_depth

      # If something remains, reattempt later after dropping aggregates
      if drop_function_sqls.count > 0
        aggregate_dependant_function_sqls = drop_function_sqls
      else
        aggregate_dependant_function_sqls = []
      end

      # And now aggregate functions
      failed_sqls = []
      drop_function_sqls = database.fetch(%Q{
        SELECT 'DROP AGGREGATE ' || ns.nspname || '.' || proname || '(' || oidvectortypes(proargtypes) || ');' AS sql
        FROM pg_proc INNER JOIN pg_namespace ns ON (pg_proc.pronamespace = ns.oid AND pg_proc.proisagg = TRUE)
        WHERE ns.nspname = '#{schema_name}'
      })
      drop_function_sqls.each { |sql_sentence|
        begin
          database.run(sql_sentence[:sql])
        rescue Sequel::DatabaseError => e
          failed_sqls.push(sql_sentence)
        end
      }

      if failed_sqls.count > 0
        raise CartoDB::BaseCartoDBError.new('Cannot drop schema aggregate functions, dependencies remain')
      end

      # One final pass of normal functions, if left
      if aggregate_dependant_function_sqls.count > 0
        aggregate_dependant_function_sqls.each { |sql_sentence|
          begin
            database.run(sql_sentence[:sql])
          rescue Sequel::DatabaseError => e
            failed_sqls.push(sql_sentence)
          end
        }
      end

      if failed_sqls.count > 0
        raise CartoDB::BaseCartoDBError.new('Cannot drop schema functions, dependencies remain')
      end

    end
  end

  def fix_table_permissions
    tables_queries = []
    tables.each do |table|
      if table.public? || table.public_with_link_only?
        tables_queries << "GRANT SELECT ON \"#{self.database_schema}\".#{table.name} TO #{CartoDB::PUBLIC_DB_USER}"
      end
      tables_queries << "ALTER TABLE \"#{self.database_schema}\".#{table.name} OWNER TO \"#{database_username}\""
    end
    self.run_queries_in_transaction(
      tables_queries,
      true
    )
  end

  # Utility methods
  def fix_permissions
    # /!\ WARNING
    # This will delete all database permissions, and try to recreate them from scratch.
    # Use only if you know what you're doing. (or, better, don't use it)
    self.reset_database_permissions
    self.reset_user_schema_permissions
    self.grant_publicuser_in_database
    self.set_user_privileges
    self.fix_table_permissions
  end

  def monitor_user_notification
    FileUtils.touch(Rails.root.join('log', 'users_modifications'))
    if !Cartodb.config[:signups].nil? && !Cartodb.config[:signups]["service"].nil? && !Cartodb.config[:signups]["service"]["port"].nil?
      enable_remote_db_user
    end
  end

  def enable_remote_db_user
    request = Typhoeus::Request.new(
      "#{self.database_host}:#{Cartodb.config[:signups]["service"]["port"]}/scripts/activate_db_user",
      method: :post,
      headers: { "Content-Type" => "application/json" }
    )
    response = request.run
    if response.code != 200
      raise(response.body)
    else
      comm_response = JSON.parse(response.body)
      if comm_response['retcode'].to_i != 0
        raise(response['stderr'])
      end
    end
  end

  # return quoated database_schema when needed
  def sql_safe_database_schema
    if self.database_schema.include?('-')
      return "\"#{self.database_schema}\""
    end
    self.database_schema
  end

  # return public user url -> string
  def public_url
    subdomain = organization.nil? ? username : organization.name
    user_name = organization.nil? ? nil : username

    CartoDB.base_url(subdomain, user_name)
  end

  private

  def name_exists_in_organizations?
    !Organization.where(name: self.username).first.nil?
  end

  def make_auth_token
    digest = secure_digest(Time.now, (1..10).map{ rand.to_s })
    10.times do
      digest = secure_digest(digest, CartoDB::Visualization::Member::TOKEN_DIGEST)
    end
    digest
  end

  def secure_digest(*args)
    Digest::SHA256.hexdigest(args.flatten.join)
  end

end
