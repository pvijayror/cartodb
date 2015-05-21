# encoding: UTF-8

module Carto
  module Api
    class LayerPresenter

      PUBLIC_VALUES = %W{ options kind infowindow tooltip id order parent_id }

      EMPTY_CSS = '#dummy{}'

      TORQUE_ATTRS = %w(
        table_name
        user_name
        property
        blendmode
        resolution
        countby
        torque-duration
        torque-steps
        torque-blend-mode
        query
        tile_style
        named_map
        visible
      )

      INFOWINDOW_KEYS = %w(
        fields template_name template alternative_names width maxHeight
      )

      #TODO: options part needs to be refactored
      #TODO: Many private methods need also refactoring

      def initialize(layer, options={}, configuration={}, decoration_data={})
        @layer            = layer
        @options          = options
        @configuration    = configuration
        @decoration_data  = decoration_data

        @viewer_user = options.fetch(:viewer_user, nil)
        @owner_user  = options.fetch(:user, nil)
      end

      def to_poro
        public_values(@layer).merge('options' => layer_options).merge(children_for(@layer))
      end

      def to_json
        public_values(layer).merge(children_for(layer)).to_json
      end

      # TODO: Pending refactor, right now just copied
      def to_vizjson_v2
        if base?(@layer)
          with_kind_as_type(public_values(@layer).merge('options' => layer_options).merge(children_for(@layer)))
        elsif torque?(@layer)
          as_torque
        else
          {
            id:         @layer.id,
            parent_id:  @layer.parent_id,
            children:   children_for(@layer, false),
            type:       'CartoDB',
            infowindow: infowindow_data_v2,
            tooltip:    tooltip_data_v2,
            legend:     @layer.legend,
            order:      @layer.order,
            visible:    public_values(@layer)[:options]['visible'],
            options:    options_data_v2
          }
        end
      end

      # TODO: Pending refactor, right now just copied
      def to_vizjson_v1
        return public_values(@layer).merge('options' => layer_options).merge(children_for(@layer)) if base?(@layer)
        {
          id:         @layer.id,
          parent_id:  @layer.parent_id,
          children:   children_for(@layer, false),
          kind:       'CartoDB',
          infowindow: infowindow_data_v1,
          order:      @layer.order,
          options:    options_data_v1
        }
      end

      private

      attr_reader :layer, :options, :configuration

      def public_values(layer)
        Hash[ PUBLIC_VALUES.map { |attribute| [attribute, layer.send(attribute)] } ]
      end

      def children_for(layer, as_hash=true)
        items = layer.children.nil? ? [] : layer.children.map { |child_layer| { id: child_layer.id } }
        as_hash ? { 'children' => items } : items
      end

      # Decorates the layer presentation with data if needed. nils on the decoration act as removing the field
      def decorate_with_data(source_hash, decoration_data=nil)
        if not decoration_data.nil?
          decoration_data.each { |key, value| 
            source_hash[key] = value
            source_hash.delete_if { |k, v| 
              v.nil? 
            }
          }
        end
        source_hash
      end

      def base?(layer)
        ['tiled', 'background', 'gmapsbase', 'wms'].include? layer.kind
      end

      def torque?(layer)
        layer.kind == 'torque'
      end

      def with_template(infowindow, path)
        # Careful with this logic:
        # - nil means absolutely no infowindow (e.g. a torque)
        # - path = nil or template filled: either pre-filled or custom infowindow, nothing to do here
        # - template and path not nil but template not filled: stay and fill
        return nil if infowindow.nil?
        template = infowindow['template']
        return infowindow if (!template.nil? && !template.empty?) || path.nil?

        infowindow.merge!(template: File.read(path))
        infowindow
      end

      def layer_options
        layer_options = @layer.options.nil? ? Hash.new : @layer.options

        # if the table_name already have a schema don't add another one.
        # This case happens when you share a layer already shared with you
        return layer_options if layer_options['table_name'] && layer_options['table_name'].include?('.')

        if @owner_user && @viewer_user && @owner_user.id != @viewer_user.id
          layer_options['table_name'] = @layer.qualified_table_name(@owner_user)
        # TODO: Legacy support: Remove 'user_name' and use always :viewer_user and :user
        elsif @viewer_user && layer_options['user_name'] && @viewer_user.username != layer_options['user_name'] && 
              layer_options['table_name']
            user_name = layer_options['user_name']
            if user_name.include?('-')
              table_name = "\"#{layer_options['user_name']}\".#{layer_options['table_name']}"
            else
              table_name = "#{layer_options['user_name']}.#{layer_options['table_name']}"
            end
            layer_options['table_name'] = table_name
        end

        layer_options
      end

      def options_data_v1
        return @layer.options if @options[:full]
        @layer.options.select { |key, value| public_options.include?(key.to_s) }
      end

      def options_data_v2
        if @options[:full]
          full_data = decorate_with_data(@layer.options, @decoration_data)
          full_data.options
        else
          sql = sql_from(@layer.options)
          data = {
            sql:                wrap(sql, @layer.options),
            layer_name:         name_for(@layer),
            cartocss:           css_from(@layer.options),
            cartocss_version:   @layer.options.fetch('style_version'),
            interactivity:      @layer.options.fetch('interactivity')
          }
          data = decorate_with_data(data, @decoration_data)

          # TODO: Check this works ok
          if @viewer_user
            unless data['user_name'] == @viewer_user.username
              data['table_name'] = "\"#{data['user_name']}\".#{data['table_name']}"
            end
            data['dynamic_cdn'] = @viewer_user.dynamic_cdn_enabled
          end
          data
        end
      end

      def with_kind_as_type(attributes)
        decorate_with_data(attributes.merge(type: attributes.delete('kind')), @decoration_data)
      end

      def as_torque
        api_templates_type = @options.fetch(:https_request, false) ? 'private' : 'public'
        layer_options = decorate_with_data(
            # Make torque always have a SQL query too (as vizjson v2)
            @layer.options.merge({ 'query' => wrap(sql_from(@layer.options), @layer.options) }), 
            @decoration_data
          )

        {
          id:         @layer.id,
          parent_id:  @layer.parent_id,
          children:   children_for(@layer, false),
          type:       'torque',
          order:      @layer.order,
          legend:     @layer.legend,
          options:    {
            stat_tag:           @options.fetch(:visualization_id),
            maps_api_template:  ApplicationHelper.maps_api_template(api_templates_type),
            sql_api_template:   ApplicationHelper.sql_api_template(api_templates_type),
            # tiler_* is kept for backwards compatibility
            tiler_protocol:     (@configuration[:tiler]["public"]["protocol"] rescue nil),
            tiler_domain:       (@configuration[:tiler]["public"]["domain"] rescue nil),
            tiler_port:         (@configuration[:tiler]["public"]["port"] rescue nil),
            # sql_api_* is kept for backwards compatibility
            sql_api_protocol:   (@configuration[:sql_api]["public"]["protocol"] rescue nil),
            sql_api_domain:     (@configuration[:sql_api]["public"]["domain"] rescue nil),
            sql_api_endpoint:   (@configuration[:sql_api]["public"]["endpoint"] rescue nil),
            sql_api_port:       (@configuration[:sql_api]["public"]["port"] rescue nil),
            cdn_url:            @configuration.fetch(:cdn_url, nil),
            layer_name:         name_for(@layer),
            dynamic_cdn:        @viewer_user ? @viewer_user.dynamic_cdn_enabled : false
          }.merge(
            layer_options.select { |k| TORQUE_ATTRS.include? k })
        }
      end

      def infowindow_data_v1
        with_template(@layer.infowindow, @layer.infowindow_template_path)
      rescue => e
        Rollbar.report_exception(e)
        throw e
      end

      def infowindow_data_v2
        whitelisted_infowindow(with_template(@layer.infowindow, @layer.infowindow_template_path))
      rescue => e
        Rollbar.report_exception(e)
        throw e
      end

      def tooltip_data_v2 
        whitelisted_infowindow(with_template(@layer.tooltip, @layer.tooltip_template_path))
      rescue => e
        Rollbar.report_exception(e)
        throw e
      end

      def name_for(layer)
        layer_alias = layer.options.fetch('table_name_alias', nil)
        table_name  = layer.options.fetch('table_name') 

        return table_name unless layer_alias && !layer_alias.empty?
        layer_alias
      end

      def sql_from(options)
        query = options.fetch('query', '')
        return default_query_for(options) if query.nil? || query.empty?
        query
      end

      def css_from(options)
        style = options.include?('tile_style') ? options['tile_style'] : nil
        (style.nil? || style.strip.empty?) ? EMPTY_CSS : options.fetch('tile_style')
      end

      def wrap(query, options)
        wrapper = @options.fetch('query_wrapper', nil)
        return query if wrapper.nil? || wrapper.empty?
        EJS.evaluate(wrapper, sql: query)
      end

      def default_query_for(layer_options)
        if @viewer_user
          unless layer_options['user_name'] == @viewer_user.username
            return "select * from \"#{layer_options['user_name']}\".#{layer_options['table_name']}"
          end
        end
        "select * from #{layer_options.fetch('table_name')}"
      end

      def public_options
        return @configuration if @configuration.empty?
        @configuration.fetch(:layer_opts).fetch('public_opts')
      end

      def whitelisted_infowindow(infowindow)
        infowindow.nil? ? nil : infowindow.select { |key, value| 
                                                    INFOWINDOW_KEYS.include?(key) || INFOWINDOW_KEYS.include?(key.to_s)
                                                  }
      end

    end
  end
end
