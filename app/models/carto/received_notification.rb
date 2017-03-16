# encoding: UTF-8

module Carto
  class ReceivedNotification < ActiveRecord::Base
    belongs_to :user, inverse_of: :received_notifications
    belongs_to :notification, inverse_of: :received_notifications

    delegate :icon, :body, to: :notification
  end
end
