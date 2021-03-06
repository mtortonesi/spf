require 'timers'

require 'spf/common/utils'
require 'spf/common/logger'
require 'spf/common/extensions/fixnum'

require 'spf/gateway/service'
require 'spf/gateway/pipeline'
# require 'spf/gateway/processing-strategies/audio'
# require 'spf/gateway/processing-strategies/audio_recognition_processing_strategy'
# require 'spf/gateway/processing-strategies/face_detection_processing_strategy'
# require 'spf/gateway/processing-strategies/object_count_processing_strategy'
# require 'spf/gateway/processing-strategies/ocr_processing_strategy'
# require 'spf/gateway/service-strategies/audio_info_service_strategy'
# require 'spf/gateway/service-strategies/surveillance_service_strategy'
# require 'spf/gateway/service-strategies/find_text_service_strategy'


module SPF
  module Gateway
    class ServiceManager

      include SPF::Logging
      include SPF::Common::Utils

      # @@PROCESSING_STRATEGY_FACTORY = {
      #   :ocr => SPF::Gateway::OcrProcessingStrategy,
      #   :object_count => SPF::Gateway::ObjectCountProcessingStrategy,
      #   :audio_recognition => SPF::Gateway::AudioRecognitionProcessingStrategy,
      #   :face_detection => SPF::Gateway::FaceDetectionProcessingStrategy
      # }
      @@PROCESSING_STRATEGY_FACTORY = Hash.new

      # @@SERVICE_STRATEGY_FACTORY = {
      #   :surveillance => SPF::Gateway::SurveillanceServiceStrategy,
      #   :find_text => SPF::Gateway::FindTextServiceStrategy,
      #   :audio_info => SPF::Gateway::AudioInfoServiceStrategy
      # }
      @@SERVICE_STRATEGY_FACTORY = Hash.new

      # Initializes the service manager.
      def initialize
        @services = {}
        @services_lock = Concurrent::ReadWriteLock.new
        @active_pipelines = {}
        @active_pipelines_lock = Concurrent::ReadWriteLock.new
        @timers = Timers::Group.new
        @tau_test = nil

        load_service_strategies
        load_processing_strategies
      end

      # Instantiates (creates and activates) a service.
      #
      # @param service_name [Symbol] Name of the service to instantiate.
      # @param service_conf [Hash] Configuration of the service to instantiate.
      # @param application [SPF::Gateway::Application] The application the service to instantiate belongs to.
      def instantiate_service(service_name, service_conf, application)
        svc = nil
        @services_lock.with_write_lock do
          # retrieve service location in @services
          app_name = application.name.to_sym
          @services[app_name] ||= {}
          @services[app_name][service_name] ||= [nil, nil]
          svc = @services[app_name][service_name][0]

          # create service if it does not exist...
          unless svc
            svc_strategy = self.class.service_strategy_factory(service_name, service_conf,application)
            svc = Service.new(service_name, service_conf, application, svc_strategy)
            logger.info "*** #{self.class.name}: Created new service #{service_name.to_s} ***"
            # add service to the set of services of corresponing application
            # TODO: we operate under the assumption that the (application_name,
            # service_name) couple is unique for each service. Make sure the
            # assumption holds, so that the following statement does not overwrite
            # anything!!!
            @services[app_name][service_name] = [svc, nil]  # [service, timer]
          end
        end

        # ...and activate it!
        # TODO: or postopone activation until the first request arrives?
        activate_service(svc) if svc
      end

      # Instantiates a service if and only if it already exists.
      #
      # @param service_name [SPF::Gateway::Service] Instance of the service to reactivate.
      def restart_service(svc)
        # do nothing if the service was not configured before
        @services_lock.with_read_lock do
          return if @services[svc.application.name.to_sym].nil? ||
            @services[svc.application.name.to_sym][svc.name].nil?
        end

        # reactivate the service
        activate_service(svc)
      end

      # Atomically finds the service from the pair
      # application_name:service_name provided in the
      # parameters and resets any timer associated
      # to that service.
      #
      # @param application_name [Symbol] Name of the application.
      # @param service_name [Symbol] Name of the service to find.
      def get_service_by_name(application_name, service_name)
        # TODO: we operate under the assumption that the (application_name,
        # service_name) couple is unique for each service. Make sure the
        # assumption holds, so that the following statement returns just one service.
        @services_lock.with_read_lock do
          return if @services[application_name].nil? ||
            @services[application_name][service_name].nil?

          svc_timer_pair = @services[application_name][service_name]
          reset_timer(svc_timer_pair[1])
          svc_timer_pair[0]
        end
      end

      # Executes the block of code for each pipeline p
      # interested in the raw_data passed as a parameter
      #
      # @param raw_data [String] The string of bytes contained in the UDP
      #                          message received from the network.
      def with_pipelines_interested_in(raw_data)
        @active_pipelines_lock.with_read_lock do
          interested_pipelines = @active_pipelines.select { |pl_sym, pl| pl.interested_in?(raw_data) }
          interested_pipelines.each_value do |pl|
            yield pl
          end
        end
      end

      def set_tau_test(tau_test)
        @tau_test = tau_test
      end


      private

        # Instantiates the service_strategy based on the service_name.
        #
        # @param service_name [Symbol] Name of the service to instantiate.
        # @param service_conf [Hash] Configuration of the service to instantiate.
        def self.service_strategy_factory(service_name, service_conf, application)
          raise "#{self.class.name}: Unknown service" if @@SERVICE_STRATEGY_FACTORY[service_name].nil?
          svc = @@SERVICE_STRATEGY_FACTORY[service_name].new(application.priority,
            service_conf[:processing_pipelines], service_conf[:time_decay], service_conf[:distance_decay])
        end

        # Instantiates the processing_strategy based on the service_name.
        #
        # @param processing_strategy_name [String] Name of the processing_strategy to instantiate.
        def self.processing_strategy_factory(processing_strategy_name)
          raise "#{self.class.name}: Unknown processing pipeline" if
            @@PROCESSING_STRATEGY_FACTORY[processing_strategy_name].nil?
          @@PROCESSING_STRATEGY_FACTORY[processing_strategy_name].new
        end

        # Activates a service
        #
        # @param svc [SPF::Gateway::Service] the service to activate.
        def activate_service(svc)
          # do nothing if service is already active
          return if svc.active?

          # if a service has a maximum idle lifetime, schedule its deactivation
          @services_lock.with_write_lock do
            return if svc.active?
            active_timer = nil
            if svc.max_idle_time && svc.max_idle_time > 0
              active_timer = @timers.after(svc.max_idle_time) { deactivate_service(svc) }
              logger.info "*** #{self.class.name}: Added new timer for service #{svc.name.to_s} ***"
            end
            @services[svc.application.name.to_sym][svc.name][1] = active_timer

            pipeline = nil
            # instantiate pipeline if needed
            svc.pipeline_names.each do |pipeline_name|
              @active_pipelines_lock.with_read_lock do
                pipeline = @active_pipelines[pipeline_name]
              end
              unless pipeline
                @active_pipelines_lock.with_write_lock do
                  # check again in case another thread has acquired
                  # the write lock and changed @active_pipelines
                  pipeline = @active_pipelines[pipeline_name]
                  if pipeline.nil?
                    pipeline = Pipeline.new(
                      self.class.processing_strategy_factory(pipeline_name), @tau_test)
                    @active_pipelines[pipeline_name] = pipeline
                    logger.info "*** #{self.class.name}: Added new pipeline #{pipeline_name.to_s} ***"
                  end
                end
              end

              # register the new service with the pipeline and activate the service
              pipeline.register_service(svc)
              logger.info "*** #{self.class.name}: Registered service #{svc.name} with pipeline #{pipeline_name.to_s} ***"
            end
            svc.activate
          end
        end

        # Atomically deactivates a service and unregisters it from
        # all registered pipelines. Pipelines left with no services
        # are also deactivated.
        #
        # @param svc [SPF::Gateway::Service] The service to deactivate.
        def deactivate_service(svc)
          # deactivate the service if active
          return unless svc.active?

          @services_lock.with_write_lock do
            return unless svc.active?
            svc.deactivate

            # remove timer associated to service
            remove_timer(svc)

            @active_pipelines_lock.with_write_lock do
              # unregister pipelines registered with the service
              @active_pipelines.each_value do [pl]
                pl.unregister_service(svc)
              end

              # delete useless pipelines
              @active_pipelines.keep_if { |pl_sym, pl| pl.has_services? }
            end
          end
        end

        # Removes the timer associated to the service svc
        #
        # @param svc [SPF::Gateway::Service] The service whose timer needs to be removed.
        def remove_timer(svc)
          @services[svc.application.name.to_sym][svc.name][1] = nil
        end

        # Resets the timer associated to the service svc
        #
        # @param svc [SPF::Gateway::Service] The service whose timer needs to be reset.
        def reset_timer(timer)
          return if timer.nil?
          timer.reset() unless timer.paused?
        end

        def load_service_strategies
          service_strategies_dir = File.expand_path(File.join(File.dirname(__FILE__), 'service-strategies'))
          Dir["#{service_strategies_dir}/*_service_strategy.rb"].each do |service_strategy|
            ss_name = /(.+)_service_strategy.rb/.match(service_strategy.split("/")[-1])
            unless ss_name.nil?
              ss_name = ss_name[1]
              ss_name_camelize = camelize(ss_name)
              if ss_name != "basic"
                require service_strategy
                @@SERVICE_STRATEGY_FACTORY[ss_name.to_sym] = Module.const_get("SPF::Gateway::#{ss_name_camelize}ServiceStrategy")
              end
            end
          end
        end

        def load_processing_strategies
          processing_strategies_rb_dir = File.expand_path(File.join(File.dirname(__FILE__), 'processing-strategies'))
          Dir["#{processing_strategies_rb_dir}/*_processing_strategy.rb"].each do |processing_strategy|
            ps_name = /(.+)_processing_strategy.rb/.match(processing_strategy.split("/")[-1])
            unless ps_name.nil?
              ps_name = ps_name[1]
              ps_name_camelize = camelize(ps_name)
              if ps_name.downcase != "basic"
                require processing_strategy
                @@PROCESSING_STRATEGY_FACTORY[ps_name.to_sym] = Module.const_get("SPF::Gateway::#{ps_name_camelize}ProcessingStrategy")
              end
            end
          end

          # processing_strategies_java_dir = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', '..', 'java', 'spf', 'it', 'unife', 'spf', 'gateway', 'processingstrategies'))
          # Dir["#{processing_strategies_java_dir}/*ProcessingStrategy.class"].each do |processing_strategy|
          #   ps_name = /(.+)ProcessingStrategy.class/.match(processing_strategy.split("/")[-1])
          #   unless ps_name.nil?
          #     ps_name = ps_name[1]
          #     ps_name_underscore = underscore(ps_name)
          #     if ps_name_underscore.downcase != "basic"
          #       @@PROCESSING_STRATEGY_FACTORY[ps_name_underscore.to_sym] = Module.const_get("Java::ItUnifeSpfGatewayProcessingstrategies::#{ps_name}ProcessingStrategy")
          #     end
          #   end
          # end
        end

    end
  end
end
