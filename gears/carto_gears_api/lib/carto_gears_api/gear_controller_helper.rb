# This should be included in every controller using the following CARTO layouts:
# - application
module CartoGearsApi
  module GearControllerHelper
    include SafeJsObject
    include CartoDB::ConfigUtils
    include TrackjsHelper
    include GoogleAnalyticsHelper
    include HubspotHelper
    include FrontendConfigHelper
    include AppAssetsHelper
    include MapsApiHelper
    include SqlApiHelper
    include CartoGearsApi::UrlHelper

    def logged_user
      @logged_user ||= CartoGearsApi::UsersService.new.logged_user(request)
    end
  end
end
