# encoding: utf-8

require_dependency 'carto/api/vizjson3_presenter'

module Carto
  module NamedMaps
    class Template
      NAMED_MAPS_VERSION = '0.0.1'.freeze
      CARTOCSS_VERSION = '2.0.1'.freeze
      NAME_PREFIX = 'tpl_'.freeze
      AUTH_TYPE_OPEN = 'open'.freeze
      AUTH_TYPE_SIGNED = 'token'.freeze
      EMPTY_CSS = '#dummy{}'.freeze

      TILER_WIDGET_TYPES = {
        'category': 'aggregation',
        'formula': 'formula',
        'histogram': 'histogram',
        'list': 'list',
        'time-series': 'histogram'
      }.freeze

      def initialize(visualization)
        raise 'Carto::NamedMaps::Template needs a Carto::Visualization' unless visualization.is_a?(Carto::Visualization)

        @visualization = visualization
        @vizjson = Carto::Api::VizJSON3Presenter.new(visualization).to_named_map_vizjson
      end

      def generate_template
        stats_aggregator.timing('named-map.template-data') do
          {
            name: name,
            auth: auth,
            version: NAMED_MAPS_VERSION,
            placeholders: placeholders,
            layergroup: {
              layers: layers,
              stat_tag: @visualization.id,
              dataviews: dataviews,
              analyses: analyses
            },
            view: view
          }
        end
      end

      private

      def placeholders
        placeholders = []

        @visualization.map.named_maps_layers.select(&:data_layer?).each_with_index do |layer, index|
          placeholders << {
            "layer#{index}": {
              type: 'number',
              default: layer.options[:visible] ? 1 : 0
            }
          }
        end

        placeholders
      end

      def layers
        layers = []
        map = @visualization.map

        map.named_maps_layers.select(&:basemap?).each do |layer|
          type, options = type_and_options_for_basemap_layers(layer)

          layers.push(type: type, options: options)
        end

        map.named_maps_layers.select(&:data_layer?).each_with_index do |layer, index|
          type, options = type_and_options_for_cartodb_layers(layer, index)

          layers.push(type: type, options: options)
        end

        layers
      end

      def type_and_options_for_cartodb_layers(layer, index)
        layer_options = layer.options

        options = {
          cartocss: layer_options.fetch('tile_style').strip.empty? ? EMPTY_CSS : layer_options.fetch('tile_style'),
          cartocss_version: '2.0.1',
          interactivity: layer_options[:interactivity]
        }

        layer_options_source = layer_options[:source]
        if layer_options_source
          options[:source] = { id: layer_options_source }
        else
          options[:sql] =
            "SELECT * FROM (#{layer_options[:query]}) AS wrapped_query WHERE <%= layer#{index} %>=1"
        end

        layer_infowindow = layer.infowindow
        if layer_infowindow && layer_infowindow.fetch('fields') && !layer_infowindow.fetch('fields').empty?
          options[:attributes] = {
            id:       'cartodb_id',
            columns:  layer_infowindow['fields'].map { |field| field.fetch('name') }
          }
        end

        ['cartodb', options]
      end

      def type_and_options_for_basemap_layers(layer)
        layer_options = layer.options

        if layer_options['type'] == 'Plain'
          type = 'plain'

          layer_options = if layer_options['image'].empty?
                            { color: layer_options['color'] }
                          else
                            { imageUrl: layer_options['image'] }
                          end
        else
          type = 'http'

          layer_options = if layer_options['urlTemplate'] && !layer_options['urlTemplate'].empty?
                            options = {
                              urlTemplate: layer_options['urlTemplate']
                            }

                            if layer_options.include?('subdomains')
                              options[:subdomains] = layer_options['subdomains']
                            end

                            options
                          end
        end

        [type, layer_options]
      end

      def options(layer)
        layer_options = layer.options
        {
          source: {
            id: layer_options[:source]
          },
          cartocss: layer_options.fetch('tile_style').strip.empty? ? EMPTY_CSS : layer_options.fetch('tile_style'),
          cartocss_version: CARTOCSS_VERSION
        }
      end

      def dataviews
        dataviews = []

        @visualization.widgets.each do |widget|
          dataviews << {
            "#{widget.id}": dataview_data(widget)
          }
        end

        dataviews
      end

      def analyses
        @visualization.analyses.map(&:analysis_definition)
      end

      def stats_aggregator
        @@stats_aggregator_instance ||= CartoDB::Stats::EditorAPIs.instance
      end

      def dataview_data(widget)
        options = widget.options
        options[:aggregationColumn] = options[:aggregation_column]
        options.delete(:aggregation_column)

        dataview_data = {
          type: TILER_WIDGET_TYPES[widget.type],
          options: options
        }

        dataview_data[:source] = { id: widget.source_id } if widget.source_id.present?

        dataview_data
      end

      def name
        (NAME_PREFIX + @visualization.id).gsub(/[^a-zA-Z0-9\-\_.]/, '').tr('-', '_')
      end

      def auth
        method, valid_tokens = if @visualization.password_protected?
                                 [AUTH_TYPE_SIGNED, @visualization.get_auth_tokens]
                               elsif @visualization.organization?
                                 auth_tokens = @visualization.all_users_with_read_permission
                                                             .map(&:get_auth_tokens)
                                                             .flatten
                                                             .uniq

                                 [AUTH_TYPE_SIGNED, auth_tokens]
                               else
                                 [AUTH_TYPE_OPEN, nil]
                               end

        auth = { method: method }
        auth[:valid_tokens] = valid_tokens if valid_tokens

        auth
      end

      def view
        map = @visualization.map
        center_data = map.center_data

        data = {
          zoom: map.zoom,
          center: {
            lng: center_data[1].to_f,
            lat: center_data[0].to_f
          }
        }

        bounds_data = map.view_bounds_data

        # INFO: Don't return 'bounds' if all points are 0 to avoid static map trying to go too small zoom level
        if bounds_data[:west] != 0 || bounds_data[:south] != 0 || bounds_data[:east] != 0 || bounds_data[:north] != 0
          data[:bounds] = bounds_data
        end

        data
      end
    end
  end
end
