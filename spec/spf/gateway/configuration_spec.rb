require 'spec/spec_helper'

require 'spf/gateway/configuration'

require_relative './reference_configuration'


describe SPF::Gateway::Configuration do

  it 'should correctly detect application priority' do
    with_reference_config do |conf|
      conf.applications[:participants][:priority].must_equal 50.0
    end
  end

end
