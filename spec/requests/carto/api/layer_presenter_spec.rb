# encoding: utf-8

require_relative '../../../spec_helper'
require_relative '../../../../app/controllers/carto/api/layer_presenter'
require_relative '../../api/json/layer_presenter_shared_examples'

describe "Carto::Api::LayersController - Layer Model" do
  it_behaves_like 'layer presenters', Carto::Api::LayerPresenter, ::Layer
end

describe "Carto::Api::LayersController - Carto::Layer" do
  it_behaves_like 'layer presenters', Carto::Api::LayerPresenter, Carto::Layer
end

describe Carto::Api::LayerPresenter do
  describe 'wizard_properties' do
    let(:wizard_properties) do
      {
        "type" => "polygon"
      }
    end

    it "autogenerates `style_properties` based on `wizard_properties` if it isn't present" do
      layer = FactoryGirl.build(:carto_layer, options: { 'wizard_properties' => wizard_properties })
      poro_options = Carto::Api::LayerPresenter.new(layer).to_poro['options']
      poro_options['wizard_properties'].should_not be_nil
      style_properties = poro_options['style_properties']
      style_properties.should_not be_nil
      style_properties['autogenerated'].should be_true
    end

    it "doesn't autogenerate `style_properties` if `wizard_properties` is not present or is empty" do
      layer = FactoryGirl.build(:carto_layer, options: { 'wizard_properties' => nil })
      poro_options = Carto::Api::LayerPresenter.new(layer).to_poro['options']
      poro_options['wizard_properties'].should be_nil
      style_properties = poro_options['style_properties']
      style_properties.should be_nil

      layer = FactoryGirl.build(:carto_layer, options: { 'wizard_properties' => {} })
      poro_options = Carto::Api::LayerPresenter.new(layer).to_poro['options']
      poro_options['wizard_properties'].should_not be_nil
      style_properties = poro_options['style_properties']
      style_properties.should be_nil
    end
  end
end
