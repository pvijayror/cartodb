# encoding utf-8

require 'factories/carto_visualizations'
require 'spec_helper_min'

module Carto
  module Tracking
    module Events
      describe 'Events' do
        include Carto::Factories::Visualizations

        before(:all) do
          @user = FactoryGirl.create(:carto_user)
          @intruder = FactoryGirl.create(:carto_user)
          @map, @table, @table_visualization, @visualization = create_full_visualization(@user)
          @visualization.privacy = 'private'
          @visualization.save
          @visualization.reload
        end

        after(:all) do
          destroy_full_visualization(@map, @table, @table_visualization, @visualization)
          @user.destroy
          @intruder.destroy
        end

        def days_with_decimals(time_object)
          time_object.to_f / 60 / 60 / 24
        end

        def check_hash_has_keys(hash, keys)
          keys.each do |key|
            puts "checking #{key} is not nil"
            hash[key].should_not be_nil
          end
        end

        describe ExportedMap do
          before (:all) { @event_class = self.class.description.constantize }
          after  (:all) { @event_class = nil }

          describe '#properties validation' do
            after(:each) do
              expect { @event.report! }.to raise_error(Carto::UnprocesableEntityError)
            end

            after(:all) do
              @event = nil
            end

            it 'requires a user_id' do
              @event = @event_class.new(@user.id, visualization_id: @visualization.id)
            end

            it 'requires a visualization_id' do
              @event = @event_class.new(@user.id, user_id: @user.id)
            end
          end

          describe '#security validation' do
            after(:each) do
              expect { @event.report! }.to raise_error(Carto::UnauthorizedError)
            end

            after(:all) do
              @event = nil
            end

            it 'must have access read access to visualization' do
              @event = @event_class.new(@intruder.id,
                                        visualization_id: @visualization.id,
                                        user_id: @intruder.id)

              expect { @event.report! }.to raise_error(Carto::UnauthorizedError)
            end

            it 'must be reported by user' do
              @event = @event_class.new(@intruder.id,
                                        visualization_id: @visualization.id,
                                        user_id: @user.id)

              expect { @event.report! }.to raise_error(Carto::UnauthorizedError)
            end
          end

          it 'reports' do
            event = @event_class.new(@user.id,
                                     visualization_id: @visualization.id,
                                     user_id: @user.id)

            expect { event.report! }.to_not raise_error
          end

          it 'reports by user with access' do
            event = @event_class.new(@intruder.id,
                                     visualization_id: @visualization.id,
                                     user_id: @intruder.id)

            Carto::Visualization.any_instance.stubs(:is_accesible_by_user?).with(@intruder).returns(true)

            expect { event.report! }.to_not raise_error
          end

          it 'matches current prod properites' do
            current_prod_properties = [:vis_id,
                                       :privacy,
                                       :type,
                                       :object_created_at,
                                       :lifetime,
                                       :username,
                                       :email,
                                       :plan,
                                       :user_active_for,
                                       :user_created_at,
                                       :event_origin,
                                       :creation_time]

            format = @event_class.new(@user.id,
                                      visualization_id: @visualization.id,
                                      user_id: @user.id)
                                 .instance_eval { @format }

            check_hash_has_keys(format.to_segment, current_prod_properties)
          end
        end

        describe CreatedMap do
          before (:all) { @event_class = self.class.description.constantize }
          after  (:all) { @event_class = nil }

          describe '#properties validation' do
            after(:each) do
              expect { @event.report! }.to raise_error(Carto::UnprocesableEntityError)
            end

            after(:all) do
              @event = nil
            end

            it 'requires a user_id' do
              @event = @event_class.new(@user.id, visualization_id: @visualization.id)
            end

            it 'requires a visualization_id' do
              @event = @event_class.new(@user.id, user_id: @user.id)
            end
          end

          describe '#security validation' do
            after(:each) do
              expect { @event.report! }.to raise_error(Carto::UnauthorizedError)
            end

            after(:all) do
              @event = nil
            end

            it 'must have access write access to visualization' do
              @event = @event_class.new(@intruder.id,
                                        visualization_id: @visualization.id,
                                        user_id: @intruder.id)

              expect { @event.report! }.to raise_error(Carto::UnauthorizedError)
            end

            it 'must be reported by user' do
              @event = @event_class.new(@intruder.id,
                                        visualization_id: @visualization.id,
                                        user_id: @user.id)

              expect { @event.report! }.to raise_error(Carto::UnauthorizedError)
            end
          end

          it 'reports' do
            event = @event_class.new(@user.id,
                                     visualization_id: @visualization.id,
                                     user_id: @user.id)

            expect { event.report! }.to_not raise_error
          end

          it 'reports by user with access' do
            event = @event_class.new(@intruder.id,
                                     visualization_id: @visualization.id,
                                     user_id: @intruder.id)

            Carto::Visualization.any_instance.stubs(:writable_by?).with(@intruder).returns(true)

            expect { event.report! }.to_not raise_error
          end

          it 'matches current prod properites' do
            current_prod_properties = [:vis_id,
                                       :privacy,
                                       :type,
                                       :object_created_at,
                                       :lifetime,
                                       :origin,
                                       :username,
                                       :email,
                                       :plan,
                                       :user_active_for,
                                       :user_created_at,
                                       :event_origin,
                                       :creation_time]

            format = @event_class.new(@user.id,
                                      visualization_id: @visualization.id,
                                      user_id: @user.id,
                                      origin: 'bananas')
                                 .instance_eval { @format }

            check_hash_has_keys(format.to_segment, current_prod_properties)
          end
        end

        describe DeletedMap do
          before (:all) { @event_class = self.class.description.constantize }
          after  (:all) { @event_class = nil }

          describe '#properties validation' do
            after(:each) do
              expect { @event.report! }.to raise_error(Carto::UnprocesableEntityError)
            end

            after(:all) do
              @event = nil
            end

            it 'requires a user_id' do
              @event = @event_class.new(@user.id, visualization_id: @visualization.id)
            end

            it 'requires a visualization_id' do
              @event = @event_class.new(@user.id, user_id: @user.id)
            end
          end

          describe '#security validation' do
            after(:each) do
              expect { @event.report! }.to raise_error(Carto::UnauthorizedError)
            end

            after(:all) do
              @event = nil
            end

            it 'must have access write access to visualization' do
              @event = @event_class.new(@intruder.id,
                                        visualization_id: @visualization.id,
                                        user_id: @intruder.id)

              expect { @event.report! }.to raise_error(Carto::UnauthorizedError)
            end

            it 'must be reported by user' do
              @event = @event_class.new(@intruder.id,
                                        visualization_id: @visualization.id,
                                        user_id: @user.id)

              expect { @event.report! }.to raise_error(Carto::UnauthorizedError)
            end
          end

          it 'reports' do
            event = @event_class.new(@user.id,
                                     visualization_id: @visualization.id,
                                     user_id: @user.id)

            expect { event.report! }.to_not raise_error
          end

          it 'reports by user with access' do
            event = @event_class.new(@intruder.id,
                                     visualization_id: @visualization.id,
                                     user_id: @intruder.id)

            Carto::Visualization.any_instance.stubs(:writable_by?).with(@intruder).returns(true)

            expect { event.report! }.to_not raise_error
          end

          it 'matches current prod properites' do
            current_prod_properties = [:vis_id,
                                       :privacy,
                                       :type,
                                       :object_created_at,
                                       :lifetime,
                                       :username,
                                       :email,
                                       :plan,
                                       :user_active_for,
                                       :user_created_at,
                                       :event_origin,
                                       :creation_time]

            format = @event_class.new(@user.id,
                                      visualization_id: @visualization.id,
                                      user_id: @user.id)
                                 .instance_eval { @format }

            check_hash_has_keys(format.to_segment, current_prod_properties)
          end
        end

        describe PublishedMap do

        end

        describe CompletedConnection do
          before (:all) { @event_class = self.class.description.constantize }
          after  (:all) { @event_class = nil }

          let(:connection) do
            {
              data_from: 'Manolo',
              imported_from: 'Escobar',
              sync: true,
              file_type: '.manolo'
            }
          end

          describe '#properties validation' do
            after(:each) do
              expect { @event.report! }.to raise_error(Carto::UnprocesableEntityError)
            end

            after(:all) do
              @event = nil
            end

            it 'requires a user_id' do
              @event = @event_class.new(@user.id,
                                        visualization_id: @visualization.id,
                                        connection: connection)
            end

            it 'requires a visualization_id' do
              @event = @event_class.new(@user.id,
                                        connection: connection,
                                        user_id: @user.id)
            end

            it 'requires a connection' do
              @event = @event_class.new(@user.id,
                                        visualization_id: @visualization.id,
                                        user_id: @user.id)
            end
          end

          describe '#security validation' do
            after(:each) do
              expect { @event.report! }.to raise_error(Carto::UnauthorizedError)
            end

            after(:all) do
              @event = nil
            end

            it 'must have access write access to visualization' do
              @event = @event_class.new(@intruder.id,
                                        visualization_id: @visualization.id,
                                        user_id: @intruder.id,
                                        connection: connection)

              expect { @event.report! }.to raise_error(Carto::UnauthorizedError)
            end

            it 'must be reported by user' do
              @event = @event_class.new(@intruder.id,
                                        visualization_id: @visualization.id,
                                        user_id: @intruder.id,
                                        connection: connection)

              expect { @event.report! }.to raise_error(Carto::UnauthorizedError)
            end
          end

          it 'reports' do
            event = @event_class.new(@user.id,
                                     visualization_id: @visualization.id,
                                     user_id: @user.id,
                                     connection: connection)

            expect { event.report! }.to_not raise_error
          end

          it 'reports by user with access' do
            event = @event_class.new(@intruder.id,
                                     visualization_id: @visualization.id,
                                     user_id: @intruder.id,
                                     connection: connection)

            Carto::Visualization.any_instance.stubs(:writable_by?).with(@intruder).returns(true)

            expect { event.report! }.to_not raise_error
          end

          it 'matches current prod properites' do
            current_prod_properties = [:data_from,
                                       :imported_from,
                                       :sync,
                                       :file_type,
                                       :username,
                                       :email,
                                       :plan,
                                       :user_active_for,
                                       :user_created_at,
                                       :event_origin,
                                       :creation_time]

            format = @event_class.new(@user.id,
                                      visualization_id: @visualization.id,
                                      user_id: @user.id,
                                      connection: connection)
                                 .instance_eval { @format }

            check_hash_has_keys(format.to_segment, current_prod_properties)
          end
        end

        describe FailedConnection do
          before (:all) { @event_class = self.class.description.constantize }
          after  (:all) { @event_class = nil }

          let(:connection) do
            {
              data_from: 'Manolo',
              imported_from: 'Escobar',
              sync: true,
              file_type: '.manolo'
            }
          end

          describe '#properties validation' do
            after(:each) do
              expect { @event.report! }.to raise_error(Carto::UnprocesableEntityError)
            end

            after(:all) do
              @event = nil
            end

            it 'requires a user_id' do
              @event = @event_class.new(@user.id,
                                        visualization_id: @visualization.id,
                                        connection: connection)
            end

            it 'requires a visualization_id' do
              @event = @event_class.new(@user.id,
                                        connection: connection,
                                        user_id: @user.id)
            end

            it 'requires a connection' do
              @event = @event_class.new(@user.id,
                                        visualization_id: @visualization.id,
                                        user_id: @user.id)
            end
          end

          describe '#security validation' do
            after(:each) do
              expect { @event.report! }.to raise_error(Carto::UnauthorizedError)
            end

            after(:all) do
              @event = nil
            end

            it 'must have access write access to visualization' do
              @event = @event_class.new(@intruder.id,
                                        visualization_id: @visualization.id,
                                        user_id: @intruder.id,
                                        connection: connection)

              expect { @event.report! }.to raise_error(Carto::UnauthorizedError)
            end

            it 'must be reported by user' do
              @event = @event_class.new(@intruder.id,
                                        visualization_id: @visualization.id,
                                        user_id: @intruder.id,
                                        connection: connection)

              expect { @event.report! }.to raise_error(Carto::UnauthorizedError)
            end
          end

          it 'reports' do
            event = @event_class.new(@user.id,
                                     visualization_id: @visualization.id,
                                     user_id: @user.id,
                                     connection: connection)

            expect { event.report! }.to_not raise_error
          end

          it 'reports by user with access' do
            event = @event_class.new(@intruder.id,
                                     visualization_id: @visualization.id,
                                     user_id: @intruder.id,
                                     connection: connection)

            Carto::Visualization.any_instance.stubs(:writable_by?).with(@intruder).returns(true)

            expect { event.report! }.to_not raise_error
          end

          it 'matches current prod properites' do
            current_prod_properties = [:data_from,
                                       :imported_from,
                                       :sync,
                                       :file_type,
                                       :username,
                                       :email,
                                       :plan,
                                       :user_active_for,
                                       :user_created_at,
                                       :event_origin,
                                       :creation_time]

            format = @event_class.new(@user.id,
                                      visualization_id: @visualization.id,
                                      user_id: @user.id,
                                      connection: connection)
                                 .instance_eval { @format }

            check_hash_has_keys(format.to_segment, current_prod_properties)
          end
        end

        describe ExceededQuota do

        end

        describe ScoredTrendingMap do

        end

        describe VisitedPrivatePage do

        end

        describe CreatedDataset do

        end

        describe DeletedDataset do

        end

        describe LikedMap do

        end
      end
    end
  end
end
