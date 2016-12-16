require 'spf-common/logger'
require 'spf-common/validate'

module SPF
  module Controller

    class ApplicationConfiguration
      include SPF::Logging

      # Setup absolute path for app directory
      APP_DIR = File.join('etc', 'controller', 'app_configurations')

      attr_reader :conf

      private

        def initialize
          @conf = {}
        end

        def validate(opt)
          SPF::Common::Validate.conf?(opt)
        end

        def application(name, opt)
          if validate(opt)
            @conf[name.to_sym] ||= opt
          else
            logger.warn("Configuration \"#{name}\" is not valid")
          end
        end

      public

        def self.load_from_file

          # create configuration object
          conf = Configuration.new

          Dir.glob(File.join(APP_DIR, "*") do |conf_name|
            # take the file content and pass it to instance_eval
            File.file?(conf_name) ? conf.instance_eval (File.new(conf_name, 'r').read)
          end

          # return new object
          conf
        end

    end

  end
end