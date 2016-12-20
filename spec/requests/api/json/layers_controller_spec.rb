# encoding: utf-8

require_relative '../../../spec_helper'
require_relative '../../../../app/controllers/api/json/layers_controller'
require_relative 'layers_controller_shared_examples'

describe Api::Json::LayersController do
  include Carto::Factories::Visualizations

  it_behaves_like 'layers controllers' do
  end
end
