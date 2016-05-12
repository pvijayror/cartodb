# coding: utf-8
require_dependency 'helpers/avatar_helper'
require_dependency 'cartodb/central'

class Carto::Admin::MobileAppsController < Admin::AdminController
  include Carto::ControllerHelper
  include MobileAppsHelper
  include AvatarHelper

  APP_PLATFORMS = %w(android ios xamarin-android xamarin-ios windows-phone).freeze
  APP_TYPES = %w(dev open private).freeze

  ssl_required  :index, :show, :new, :create, :update, :destroy, :api_keys
  before_filter :invalidate_browser_cache
  before_filter :login_required
  before_filter :check_user_permissions
  before_filter :initialize_cartodb_central_client
  before_filter :validate_id, only: [:show, :update, :destroy, :api_keys]
  before_filter :load_mobile_app, only: [:show, :update, :api_keys]
  before_filter :setup_avatar_upload, only: [:new, :create, :show, :update]

  rescue_from Carto::LoadError, with: :render_404

  layout 'application'

  def index
    @mobile_apps = @cartodb_central_client.get_mobile_apps(current_user.username).map { |a| MobileApp.new(a) }

    get_open_monthly_users

  rescue CartoDB::CentralCommunicationFailure => e
    @mobile_apps = []
    CartoDB::Logger.error(message: 'Error loading mobile apps from Central', exception: e)
    flash[:error] = 'Unable to connect to license server. Try again in a moment.'
  end

  def show
  end

  def new
    @mobile_app = MobileApp.new
  end

  def create
    @mobile_app = MobileApp.new(params[:mobile_app])

    unless @mobile_app.valid?
      flash[:error] = @mobile_app.errors.full_messages.join(', ')
      render :new
      return
    end

    attributes = @mobile_app.as_json.symbolize_keys.slice(:name, :description, :icon_url, :platform, :app_id, :app_type)
    @cartodb_central_client.create_mobile_app(current_user.username, current_user.api_key, attributes)

    redirect_to CartoDB.url(self, 'mobile_apps'), flash: { success: 'Your app has been added succesfully!' }

  rescue CartoDB::CentralCommunicationFailure => e
    if e.response_code == 422
      # TODO: Descriptive errors?
      flash[:error] = e.errors
    else
      CartoDB::Logger.error(message: 'Error creating mobile_app in Central', exception: e)
      flash[:error] = 'Unable to connect to license server. Try again in a moment.'
    end
    render :new
  end

  def update
    updated_attributes = params[:mobile_app].symbolize_keys.slice(:name, :description, :icon_url)
    @mobile_app.name = updated_attributes[:name]
    @mobile_app.icon_url = updated_attributes[:icon_url]
    @mobile_app.description = updated_attributes[:description]

    unless @mobile_app.valid?
      flash[:error] = @mobile_app.errors.full_messages.join(', ')
      render :show
      return
    end

    @cartodb_central_client.update_mobile_app(current_user.username, @app_id, updated_attributes)

    redirect_to CartoDB.url(self, 'mobile_app', id: @app_id), flash: { success: 'Your app has been updated succesfully!' }

  rescue CartoDB::CentralCommunicationFailure => e
    if e.response_code == 422
      # TODO: Descriptive errors?
      flash[:error] = e.errors
    else
      CartoDB::Logger.error(message: 'Error updating mobile_app in Central', exception: e)
      flash[:error] = 'Unable to connect to license server. Try again in a moment.'
    end
    render :show
  end

  def destroy
    @cartodb_central_client.delete_mobile_app(current_user.username, @app_id)
    redirect_to CartoDB.url(self, 'mobile_apps'), flash: { success: 'Your app has been deleted succesfully!' }

  rescue CartoDB::CentralCommunicationFailure => e
    raise Carto::LoadError.new('Mobile app not found') if e.response_code == 404
    CartoDB::Logger.error(message: 'Error deleting mobile app from Central', exception: e, app_id: @app_id)
    redirect_to CartoDB.url(self, 'mobile_app', id: @app_id), flash: { error: 'Unable to connect to license server. Try again in a moment.' }
  end

  def api_keys
    respond_to do |format|
      format.html { render 'mobile_app_api_keys' }
    end
  end

  private

  def check_user_permissions
    raise Carto::LoadError.new('Mobile apps disabled') unless current_user.mobile_sdk_enabled?
  end

  def initialize_cartodb_central_client
    raise Carto::LoadError.new('Mobile apps disabled') unless Cartodb::Central.sync_data_with_cartodb_central?
    @cartodb_central_client ||= Cartodb::Central.new
  end

  def validate_id
    @app_id = uuid_parameter(:id)
  end

  def setup_avatar_upload
    @icon_valid_extensions = AVATAR_VALID_EXTENSIONS
  end

  def load_mobile_app
    @mobile_app = MobileApp.new(@cartodb_central_client.get_mobile_app(current_user.username, @app_id))

  rescue CartoDB::CentralCommunicationFailure => e
    raise Carto::LoadError.new('Mobile app not found') if e.response_code == 404
    CartoDB::Logger.error(message: 'Error loading mobile app from Central', exception: e, app_id: @app_id)
    redirect_to CartoDB.url(self, 'mobile_apps'), flash: { error: 'Unable to connect to license server. Try again in a moment.' }
  end

  def get_open_monthly_users
    @open_monthly_users = @mobile_apps.sum {|a| a.monthly_users if a.app_type == 'open'}
  end

  def get_private_monthly_users
    @private_monthly_users = @mobile_apps.sum {|a| a.monthly_users if a.app_type == 'private'}
  end
end
