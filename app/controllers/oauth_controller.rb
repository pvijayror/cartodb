# coding: UTF-8

require 'oauth/controllers/provider_controller'

class OauthController < ApplicationController
  include OAuth::Controllers::ProviderController
  
  ssl_required :authorize, :request_token, :access_token, :token, :test_request
  
  skip_before_filter :login_required, :only => :authorize
  after_filter :store_token_in_redis, :only => :access_token

  def authorize
    unless params[:oauth_token]
      render :nothing => true, :status => 404 and return
    end
    unless @token = ::RequestToken.find_by_token(params[:oauth_token])
      render :action => "authorize_failure" and return
    end
    if @token.invalidated?
      render :action => "authorize_failure" and return
    end
    if logged_in?
      @token.authorize!(current_user)
    else
      @token.authorize!(@token.client_application.user)
    end
    @redirect_url = URI.parse(@token.oob? ? @token.client_application.callback_url || CartoDB.hostname : @token.callback_url)

    unless @redirect_url.to_s.blank?
      @redirect_url.query = @redirect_url.query.blank? ?
                            "oauth_token=#{@token.token}&oauth_verifier=#{@token.verifier}" :
                            @redirect_url.query + "&oauth_token=#{@token.token}&oauth_verifier=#{@token.verifier}"
      redirect_to @redirect_url.to_s
    else
      render :action => "authorize_success"
    end
  end
  
  protected
  
  def store_token_in_redis
    $api_credentials.hset "rails:oauth_tokens:#{@token.token}", "user_id", @token.user_id
    $api_credentials.hset "rails:oauth_tokens:#{@token.token}", "time", Time.now
  end

end
