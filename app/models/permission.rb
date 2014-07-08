# encoding: utf-8

require_relative './permission/presenter'
require_relative './visualization/member'
require_relative 'shared_entity'

module CartoDB
  class Permission < Sequel::Model

    # @param id String (uuid)
    # @param owner_id String (uuid)
    # @param owner_username String
    # @param entity_id String (uuid)
    # @param entity_type String

    @old_acl = nil

    ACCESS_READONLY   = 'r'
    ACCESS_READWRITE  = 'rw'
    ACCESS_NONE       = 'n'

    TYPE_USER         = 'user'
    TYPE_ORGANIZATION = 'org'

    ENTITY_TYPE_VISUALIZATION = 'vis'

    DEFAULT_ACL_VALUE = '[]'

    # Format: requested_permission => [ allowed_permissions_list ]
    PERMISSIONS_MATRIX = {
        ACCESS_READONLY    => [ ACCESS_READONLY, ACCESS_READWRITE ],
        ACCESS_READWRITE   => [ ACCESS_READWRITE ],
        ACCESS_NONE        => []
    }

    ALLOWED_ENTITY_KEYS = [:id, :username, :name, :avatar_url]

    # @return Hash
    def acl
      ::JSON.parse((self.access_control_list.nil? ? DEFAULT_ACL_VALUE : self.access_control_list), symbolize_names: true)
    end

    # Format:
    # [
    #   {
    #     type:         string,
    #     entity:
    #     {
    #       id:         uuid,
    #       username:   string,
    #       avatar_url: string,   (optional)
    #     },
    #     access:       string
    #   }
    # ]
    #
    # type is from TYPE_xxxxx constants
    # access is from ACCESS_xxxxx constants
    #
    # @param value Array
    # @throws PermissionError
    def acl=(value)
      incoming_acl = value.nil? ? ::JSON.parse(DEFAULT_ACL_VALUE) : value
      raise PermissionError.new('ACL is not an array') unless incoming_acl.kind_of? Array
      incoming_acl.map { |item|
        unless item.kind_of?(Hash) && item[:entity].present? && item[:type].present? && item[:access].present? \
          && (item[:entity].keys - ALLOWED_ENTITY_KEYS == []) \
          && [ACCESS_READONLY, ACCESS_READWRITE, ACCESS_NONE].include?(item[:access])
          raise PermissionError.new('Wrong ACL entry format')
        end
      }

      cleaned_acl = incoming_acl.map { |item|
        {
          type:   item[:type],
          id:     item[:entity][:id],
          access: item[:access]
        }
      }

      if @old_acl.nil?
        @old_acl = acl
      end

      self.access_control_list = ::JSON.dump(cleaned_acl)
    end

    def set_user_permission(subject, access)
      set_subject_permission(subject.id, access, TYPE_USER)
    end

    def set_subject_permission(subject_id, access, type)
      new_acl = self.acl
      new_acl << {
          type:   type,
          entity: {
            id: subject_id,
            avatar_url: '',
            username: '',
            name: ''
          },
          access: access
      }
      self.acl = new_acl
    end

    # @return User|nil
    def owner
      User.where(id:self.owner_id).first
    end

    # @param value User
    def owner=(value)
      self.owner_id = value.id
      self.owner_username = value.username
    end

    # @return Mixed|nil
    def entity
      case self.entity_type
        when ENTITY_TYPE_VISUALIZATION
          CartoDB::Visualization::Member.new(id:self.entity_id).fetch
        else
          nil
      end
    end

    # @param value Mixed
    def entity=(value)
      if value.kind_of? CartoDB::Visualization::Member
        self.entity_type = ENTITY_TYPE_VISUALIZATION
        self.entity_id = value.id
      else
        raise PermissionError.new('Unsupported entity type')
      end
    end

    def validate
      super
      errors.add(:owner_id, 'cannot be nil') if (self.owner_id.nil? || self.owner_id.empty?)
      errors.add(:owner_username, 'cannot be nil') if (self.owner_username.nil? || self.owner_username.empty?)
      errors.add(:entity_id, 'cannot be nil') if (self.entity_id.nil? || self.entity_id.empty?)
      errors.add(:entity_type, 'cannot be nil') if (self.entity_type.nil? || self.entity_type.empty?)
      errors.add(:entity_type, 'invalid type') unless self.entity_type == ENTITY_TYPE_VISUALIZATION
      unless new?
        validates_presence [:id]
      end
    end #validate

    def before_save
      super
      self.updated_at = Time.now
    end

    def after_save
      update_shared_entities unless new?
    end

    def before_destroy
      destroy_shared_entities
    end

    # @param subject User
    # @return String Permission::ACCESS_xxx
    def permission_for_user(subject)
      permission = nil

      # Common scenario
      return ACCESS_READWRITE if is_owner?(subject)

      acl.map { |entry|
        if entry[:type] == TYPE_USER && entry[:id] == subject.id
          permission = entry[:access]
        end
        # Organization has lower precedence than user, if set leave as it is
        if entry[:type] == TYPE_ORGANIZATION && permission == nil
          if !subject.organization.nil? && subject.organization.id == entry[:id]
            permission = entry[:access]
          end
        end
      }
      permission = ACCESS_NONE if permission.nil?
      permission
    end

    def permission_for_org
      permission = nil
      acl.map { |entry|
        if entry[:type] == TYPE_ORGANIZATION
            permission = entry[:access]
        end
      }
      ACCESS_NONE if permission.nil?
    end

    # Note: Does not check ownership
    # @param subject User
    # @param access String Permission::ACCESS_xxx
    def is_permitted?(subject, access)
      permission = permission_for_user(subject)
      Permission::PERMISSIONS_MATRIX[access].include? permission
    end

    def is_owner?(subject)
      self.owner_id == subject.id
    end

    def to_poro
      CartoDB::PermissionPresenter.new(self).to_poro
    end

    def destroy_shared_entities
      CartoDB::SharedEntity.where(entity_id: self.entity_id).delete
    end

    def clear
      revoke_previous_permissions(entity)
      self.access_control_list = DEFAULT_ACL_VALUE
      save
    end

    def update_shared_entities
      e = entity
      # First clean previous sharings
      destroy_shared_entities
      revoke_previous_permissions(e)

      # Create user entities for the new ACL
      users = relevant_user_acl_entries(acl)
      users_entities = User.where(id: users.map { |u| u[:id] }).all
      users.each { |user|
        shared_entity = CartoDB::SharedEntity.new(
            recipient_id:   user[:id],
            recipient_type: CartoDB::SharedEntity::RECIPIENT_TYPE_USER,
            entity_id:      self.entity_id,
            entity_type:    type_for_shared_entity(self.entity_type)
        ).save

        # if the entity is a canonical visualizations give database permissions
        if (e.table)
          if self.owner_id != e.permission.owner_id
            raise PermissionError.new('Change permission without ownership')
          end
          priv = e.privacy
          if priv == CartoDB::Visualization::Member::PRIVACY_PRIVATE
            e.privacy = CartoDB::Visualization::Member::PRIVACY_ORGANIZATION
            e.store
          end
          grant_db_permission(e, user[:access], shared_entity)
        else
          # update acl for related tables using canonical visualization preserving the previous permissions
          e.related_tables.each { |t|
            # if the user is the owner of the table just give access
            if self.owner_id == e.permission.owner_id
              vis = t.table_visualization
              perm = vis.permission
              users_entities.each { |u|
                # check permission and give read perm
                if not vis.has_permission?(u, CartoDB::Visualization::Member::PERMISSION_READONLY)
                  perm.set_user_permission(u, CartoDB::Visualization::Member::PERMISSION_READONLY)
                end
              }
              perm.save
            end
          }
        end

      }

      org = relevant_org_acl_entry(acl)
      if org
        shared_entity = CartoDB::SharedEntity.new(
            recipient_id:   org[:id],
            recipient_type: CartoDB::SharedEntity::RECIPIENT_TYPE_ORGANIZATION,
            entity_id:      self.entity_id,
            entity_type:    type_for_shared_entity(self.entity_type)
        ).save
        # if the entity is a canonical visualizations give database permissions
        if (e.table)
          if self.owner_id != e.permission.owner_id
            raise PermissionError.new('Change permission without ownership')
          end
          priv = e.privacy
          if priv == CartoDB::Visualization::Member::PRIVACY_PRIVATE
            e.privacy = CartoDB::Visualization::Member::PRIVACY_ORGANIZATION
            e.store
          end
          grant_db_permission(e, org[:access], shared_entity)
        else
          # update acl for related tables using canonical visualization preserving the previous permissions
          e.related_tables.each { |t|
            # if the user is the owner of the table just give access
            if self.owner_id == e.permission.owner_id
              vis = t.table_visualization
              perm = vis.permission
              if vis.permission.permission_for_org == ACCESS_NONE
                perm.set_subject_permission(org[:id], CartoDB::Visualization::Member::PERMISSION_READONLY, TYPE_ORGANIZATION)
                perm.save
              end
            end
          }
        end

      end
    end

    def users_with_permissions(permission_type)
      user_ids = relevant_user_acl_entries(acl).select { |entry|
        permission_type.include?(entry[:access])
      }.map { |entry|
          entry[:id]
      }

      User.where(id: user_ids).all
    end

    private

    # @param permission_type ENTITY_TYPE_xxxx
    # @throws PermissionError
    def type_for_shared_entity(permission_type)
      if permission_type == ENTITY_TYPE_VISUALIZATION
        return CartoDB::SharedEntity::ENTITY_TYPE_VISUALIZATION
      end
      PermissionError.new('Invalid permission type for shared entity')
    end

    # when removing permission form a table related visualizations should
    # be checked. The policy is the following:
    #  - if the table is used in one layer of the visualization, it's removed
    #  - if the table is used in the only one visualization layer, the vis is removed
    # TODO: send a notification to the visualizations owner
    def check_related_visualizations(table)
      dependent_visualizations = table.dependent_visualizations.to_a
      non_dependent_visualizations = table.non_dependent_visualizations.to_a
      table_visualization = table.table_visualization
      non_dependent_visualizations.each do |visualization|
        # check permissions, if the owner does not have permissions
        # to see the table the layers using this table are removed
        perm = visualization.permission
        if not table_visualization.has_permission?(perm.owner, CartoDB::Visualization::Member::PERMISSION_READONLY)
          visualization.unlink_from(table)
        end
      end

      dependent_visualizations.each do |visualization| 
        # check permissions, if the owner does not have permissions
        # to see the table the visualization is removed
        perm = visualization.permission
        if not table_visualization.has_permission?(perm.owner, CartoDB::Visualization::Member::PERMISSION_READONLY)
          visualization.delete
        end
      end
    end

    def revoke_previous_permissions(entity)
      users = relevant_user_acl_entries(@old_acl.nil? ? [] : @old_acl)
      org = relevant_org_acl_entry(@old_acl.nil? ? [] : @old_acl)
      case entity.class.name
        when CartoDB::Visualization::Member.to_s
          if entity.table
            if org
              entity.table.remove_organization_access
            end
            users.each { |user|
              entity.table.remove_access(User.where(id: user[:id]).first)
            }
            check_related_visualizations(entity.table)
          end
        else
          raise PermissionError.new('Unsupported entity type trying to grant permission')
      end
    end

    def grant_db_permission(entity, access, shared_entity)
      if shared_entity.recipient_type == CartoDB::SharedEntity::RECIPIENT_TYPE_ORGANIZATION
        permission_strategy = OrganizationPermission.new
      else
        u = User.where(id: shared_entity[:recipient_id]).first
        permission_strategy = UserPermission.new(u)
      end

      case entity.class.name
        when CartoDB::Visualization::Member.to_s
          # assert database permissions for non canonical tables are assigned
          # its canonical vis
          if not entity.table
              raise PermissionError.new('Trying to change permissions to a table without ownership')
          end
          table = entity.table

          # check ownership 
          if not self.owner_id == entity.permission.owner_id
            raise PermissionError.new('Trying to change permissions to a table without ownership')
          end
          # give permission
          if access == ACCESS_READONLY
            permission_strategy.add_read_permission(table)
          elsif access == ACCESS_READWRITE
            permission_strategy.add_read_write_permission(table)
          end
        else
          raise PermissionError.new('Unsupported entity type trying to grant permission')
      end
    end

    # Only user entries, and those with forbids also skipped
    def relevant_user_acl_entries(acl_list)
      relevant_acl_entries(acl_list, TYPE_USER)
    end

    def relevant_org_acl_entry(acl_list)
      relevant_acl_entries(acl_list, TYPE_ORGANIZATION).first
    end

    def relevant_acl_entries(acl_list, type)
      acl_list.select { |entry|
        entry[:type] == type && entry[:access] != ACCESS_NONE
      }.map { |entry|
        {
            id:     entry[:id],
            access: entry[:access]
        }
      }
    end

  end

  class PermissionError < StandardError; end


  class OrganizationPermission
    def add_read_permission(table)
      table.add_organization_read_permission
    end

    def add_read_write_permission(table)
      table.add_organization_read_write_permission
    end

    def is_permitted(table, access)
      table.permission.permission_for_org == access
    end
  end


  class UserPermission

    def initialize(user)
      @user = user
    end

    def is_permitted(table, access)
      table.permission.is_permitted?(@user, access)
    end

    def add_read_permission(table)
      table.add_read_permission(@user)
    end

    def add_read_write_permission(table)
      table.add_read_write_permission(@user)
    end
  end

end
