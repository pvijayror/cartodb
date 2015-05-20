# encoding: utf-8

shared_examples_for "layer presenters" do |tested_klass|

  describe '#show legacy tests' do

    before(:all) do
      set_tested_class(tested_klass)

      @user = create_user(
        username: 'test',
        email:    'client@example.com',
        password: 'clientex'
      )

      host! 'test.localhost.lan'
    end

    before(:each) do
      CartoDB::NamedMapsWrapper::NamedMaps.any_instance.stubs(:get).returns(nil)
      delete_user_data @user
    end

    after(:all) do
      @user.destroy
    end

    def set_tested_class(klass)
      @klass = klass
    end

    def instance_of_tested_class(args)
      @klass.new(args)
    end

    it "Tests to_json()" do
      layer = Layer.create kind: 'carto'

      presenter = instance_of_tested_class(layer)
    end

  end

end
