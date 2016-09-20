# encoding: UTF-8

require 'carto/connector'

class Carto::ConnectorConfiguration < ActiveRecord::Base
  belongs_to :connector_provider, class_name: Carto::ConnectorProvider
  belongs_to :user, class_name: Carto::User
  belongs_to :organization, class_name: Carto::Organization

  # A ConnectorConfiguration can belong to either user or an organization, but not both;
  # it may also be a default configuration (no user or organization).
  # Only one configuration may exist for any valid combination of user, organization and provider.
  # So we have 3 kinds of configuration records:
  # * default configuration for provider: user.nil? && organization.nil? FIXME: remove this? (only app_config defaults)
  # * organization configuration: user.nil? && organization.present?
  # * user configuration: organization.nil? && user.present?
  validates :connector_provider_id, presence: true
  validates :user_id, uniqueness: { scope: [:connector_provider_id, :organization_id] }, if: 'organization_id.nil?'
  validates :organization_id, uniqueness: { scope: [:connector_provider_id, :user_id] }, if: 'user_id.nil?'
  validate :not_user_and_organization_simultaneously

  def not_user_and_organization_simultaneously
    if user_id.present? && organization_id.present?
      errors.add(:user_id, "can't assign to an organization simultaneously with a user")
    end
  end

  # columns:
  # enabled boolean
  # max_rows integer

  def self.default(provider)
    # Look for default provider configration
    config = where(user_id: nil, organization_id: nil, connector_provider_id: provider.id).first
    if !config
      # Create in memory record using app_config defaults
      config = new(
        connector_provider: provider,
        enabled:  Cartodb.get_config(:connectors, provider.name, 'enabled') || false,
        max_rows: Cartodb.get_config(:connectors, provider.name, 'max_rows')
      )
    end
    config
  end

  def self.for_user(user, provider)
    if provider
      config = where(user_id: user.id, connector_provider_id: provider.id).first
      if config.blank? && user.organization_id.present?
        config = where(organization_id: user.organization_id, connector_provider_id: provider.id).first
      end
      if config.blank?
        config = default(provider)
      end
      config
    end
  end
end
