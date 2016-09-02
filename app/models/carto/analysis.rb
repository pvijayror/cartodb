# encoding: UTF-8

require 'json'
require_relative './carto_json_serializer'

require_dependency 'carto/table_utils'

class Carto::Analysis < ActiveRecord::Base
  extend Carto::TableUtils

  serialize :analysis_definition, ::Carto::CartoJsonSymbolizerSerializer
  validates :analysis_definition, carto_json_symbolizer: true
  validate :validate_user_not_viewer

  before_destroy :validate_user_not_viewer

  belongs_to :visualization, class_name: Carto::Visualization
  belongs_to :user, class_name: Carto::User

  after_save :update_map_dataset_dependencies
  after_save :notify_map_change
  after_destroy :notify_map_change

  def self.find_by_natural_id(visualization_id, natural_id)
    analysis = find_by_sql(
      [
        "select id from analyses where visualization_id = :visualization_id and analysis_definition ->> 'id' = :natural_id",
        { visualization_id: visualization_id, natural_id: natural_id }
      ]
    ).first
    # Load all data
    analysis.reload if analysis
    analysis
  end

  def self.source_analysis_for_layer(layer, index)
    map = layer.map
    visualization = map.visualization
    user = visualization.user

    visualization_id = visualization.id
    user_id = user.id

    layer_options = layer.options
    username = layer_options[:user_name]
    table_name = layer_options[:table_name]

    qualified_table_name = if username && username != user.username
                             safe_schema_and_table_quoting(username, table_name)
                           else
                             table_name
                           end

    analysis_definition = {
      id: 'abcdefghijklmnopqrstuvwxyz'[index] + '0',
      type: 'source',
      params: { query: layer.default_query(user) },
      options: { table_name: qualified_table_name }
    }

    new(visualization_id: visualization_id, user_id: user_id, analysis_definition: analysis_definition)
  end

  def update_table_name!(old_name, new_name)
    rename_in_definition!(analysis_definition, old_name, new_name)

    update_attributes(analysis_definition: analysis_definition)
  end

  def analysis_definition_for_api
    filter_valid_properties(analysis_node)
  end

  def natural_id
    pj = analysis_definition
    return nil unless pj
    pj[:id]
  end

  def map
    return nil unless visualization
    visualization.map
  end

  def analysis_node
    Carto::AnalysisNode.new(analysis_definition)
  end

  private

  RENAMABLE_ATTRIBUTES = ['query', 'table_name'].freeze

  def rename_in_definition!(hash, target, substitution)
    hash.each do |key, value|
      if value.is_a?(Hash)
        rename_in_definition!(value, target, substitution)
      elsif value.is_a?(Array)
        rename_in_array!(value, target, substitution)
      elsif RENAMABLE_ATTRIBUTES.include?(key.to_s) && value.include?(target)
        value.gsub!(target, substitution)
      end
    end

    hash
  end

  def rename_in_array!(array, target, substitution)
    array.each do |value|
      if value.is_a?(Hash)
        rename_in_definition!(value, target, substitution)
      elsif value.is_a?(Array)
        rename_in_array!(value, target, substitution)
      elsif RENAMABLE_ATTRIBUTES.include?(key.to_s) && value.include?(target)
        value.gsub!(target, substitution)
      end
    end

    array
  end

  # Analysis definition contains attributes not needed by Analysis API (see #7128).
  # This methods extract the needed ones.
  VALID_ANALYSIS_PROPERTIES = [:id, :type, :params].freeze

  def filter_valid_properties(node)
    valid = node.definition.select { |property, _| VALID_ANALYSIS_PROPERTIES.include?(property) }
    node.children_and_location.each do |location, child|
      child_in_hash = location.reduce(valid, :[])
      child_in_hash.replace(filter_valid_properties(child))
    end
    valid
  end

  def update_map_dataset_dependencies
    map.update_dataset_dependencies
  end

  def notify_map_change
    map.notify_map_change if map
  end

  def validate_user_not_viewer
    if user.viewer
      errors.add(:user, "Viewer users can't edit analyses")
      return false
    end
  end
end
