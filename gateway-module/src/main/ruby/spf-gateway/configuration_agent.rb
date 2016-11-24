require 'timeout'

require 'spf-common/controller'


module SPF
  module Exceptions
    # New exception types
    class HeaderReadTimeout < Exception; end
    class ProgramReadTimeout < Exception; end
    class WrongHeaderFormatException < Exception; end
  end

  module Gateway

    class ConfigurationAgent < SPF::Common::Controller
      # Timeouts
      DEFAULT_OPTIONS = {
        header_read_timeout:  10,     # 10 seconds
        program_read_timeout: 2 * 60, # 2 minutes
      }

      # Get ASCII/UTF-8 code for newline character
      # Note: the following code is uglier but should be more portable and
      # robust than a simple '\n'.ord
      NEWLINE = '\n'.unpack('C').first

      def initialize(host, port, opts = {})
        super(host, port)
        @conf = DEFAULT_OPTIONS.merge(opts)
      end

      
      private

        def handle_connection(socket)
          # get client address
          _, port, host = socket.peeraddr
          logger.info "*** Received connection from #{host}:#{port} ***"

          # try to read first line
          first_line = ""
          status = Timeout::timeout(@conf[:header_read_timeout],
                                    SPF::Exceptions::HeaderReadTimeout) do
            first_line = socket.gets
          end

          # parse (tokenize, actually) the header line
          header = first_line.split(" ")

          case header[0]
          when "PROGRAM"
            # check header format, which should be "PROGRAM size_in_bytes"
            unless header.size == 2
              raise SPF::Exceptions::WrongHeaderFormatException
            end

            # obtain number of bytes to read
            to_read = Integer(header[1]) # might raise ArgumentError

            reprogram(to_read, socket)

          when "REQUEST"
            # REQUEST application_name;service_name\n
            application_name, service_name = header[1].split(";")
            new_service_request(application_name.to_sym, service_name.to_sym, socket)

          else
            raise SPF::Exceptions::WrongHeaderFormatException
          end

        rescue SPF::Exceptions::HeaderReadTimeout => e
          logger.warn  "*** Timeout reading header from #{host}:#{port}! ***"
          raise e
        rescue SPF::Exceptions::ProgramReadTimeout => e
          logger.warn  "*** Timeout reading program from #{host}:#{port}! ***"
          raise e
        rescue SPF::Exceptions::WrongHeaderFormatException => e
          logger.error "*** Received header with wrong format from #{host}:#{port}! ***"
          raise e
        rescue ArgumentError => e
          logger.error "*** #{host}:#{port} sent wrong program size format! ***"
          raise e
        rescue EOFError => e
          logger.error "*** #{host}:#{port} disconnected! ***"
          raise e
        ensure
          socket.close
        end

        def reprogram(to_read, socket)
          # read the actual program
          program = ""
          status = Timeout::timeout(@conf[:program_read_timeout],
                                    SPF::Exceptions::ProgramReadTimeout) do
            loop do
              program += socket.gets
              break if program.length >= to_read
            end
          end

          # reset configuration
          # TODO: this is just a placeholder
          Configuration.reset(program)
        end

        def new_service_request(application_name, service_name, socket)
          # find service
          svc = @service_manager.get_service_by_name(application_name, service_name)
          return if svc.nil?
          
          # bring service up again if down
          @service_manager.restart_service(svc) unless svc.active?

          # update service
          svc.register_request(socket)
        end
    end
  end
end