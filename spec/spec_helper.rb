# $LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)

require 'minitest/spec'
require 'minitest-spec-context'

require 'minitest/autorun'

require 'minitest/reporters'
Minitest::Reporters.use!
# Minitest::Reporters.use! Minitest::Reporters::DefaultReporter.new(color: true)
