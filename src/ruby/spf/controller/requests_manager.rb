require 'timeout'
require 'concurrent'

require 'spf/common/tcpserver_strategy'
require 'spf/common/logger'
require 'spf/common/validate'
require 'spf/common/exceptions'
require 'spf/common/extensions/fixnum'

require_relative './application_configuration'


module SPF
  module Controller
    class RequestsManager < SPF::Common::TCPServerStrategy

    include SPF::Logging

      @@APPLICATION_CONFIG_DIR = File.expand_path(File.join(File.dirname(__FILE__), '..', '..', '..', '..', 'etc', 'controller', 'app_configurations'))
      @@ALLOWED_COMMANDS = %q(service_policies dissemination_policy)

      @@DEFAULT_HOST = "localhost"
      @@DEFAULT_PORT = 52161

      # Timeouts
      @@DEFAULT_OPTIONS = {
        send_data_timeout: 5.seconds,
        receive_request_timeout: 5.seconds
      }

      def initialize(pig_sockets, pigs_tree, host=@@DEFAULT_HOST, port=@@DEFAULT_PORT)
        super(host, port, self.class.name)

        @pig_sockets = pig_sockets
        @pig_sockets_lock = Concurrent::ReadWriteLock.new
        @pigs_tree = pigs_tree
        @pig_tree_lock = Concurrent::ReadWriteLock.new

        @app_conf = {}
        Dir.foreach(File.join(@@APPLICATION_CONFIG_DIR)) do |app_name|
          app_config_pwd = File.join(@@APPLICATION_CONFIG_DIR, app_name)
          next if File.directory? app_config_pwd
          @app_conf[app_name.to_sym] = ApplicationConfiguration::load_from_file(app_config_pwd)[app_name.to_sym]
        end
      end

      def change_application_configuration(app_name, command)
        commands.each do |k,v|
          case k
          when /add_(.+)/
            break unless @@ALLOWED_COMMANDS.include? $1
            to_send=<<-END
            REPROGRAM #{app_name}
              add_#{$1}: #{v}
            END

          when /change_(.+)/
            break unless @@ALLOWED_COMMANDS.include? $1
            to_send=<<-END
            REPROGRAM #{app_name}
              change_#{$1}: #{v}
            END
          end
        end
      end

      private

        # REQUEST participants/find_text
        # User 3;44.838124,11.619786;find "water"
        def handle_connection(user_socket)
          _, port, host = user_socket.peeraddr
          logger.info "*** RequestManager: Received connection from #{host}:#{port} ***"

          header, body = receive_request(user_socket)
          if header.nil? or body.nil?
            logger.info "*** RequestManager: Received wrong message from #{host}:#{port} ***"
            return
          end

          request, app_name, serv = parse_request_header(header)
          raise SPF::Common::Exceptions::WrongHeaderFormatException unless request.eql? "REQUEST"

          unless @app_conf.has_key? app_name.to_sym
            logger.error "*** RequestManager: Received request for inexistent configuration ***"
            return
          end

          _, lat, lon, _ = parse_request_body(body)
          unless SPF::Common::Validate.latitude?(lat) && SPF::Common::Validate.longitude?(lon)
            logger.error "*** RequestManager: Error in client GPS coordinates ***"
            return
          end

          @pigs_tree_lock.with_read_lock do
            result = @pigs_tree.nearest([lat.to_f, lon.to_f])
          end

          if result.nil?
            logger.fatal "*** RequestManager: Could not find the nearest PIG (empty data structure?) ***"
            return
          end

          pig = result.data
          puts "NEAREST PIG: #{pig}"

          @pigs_sockets_lock.with_read_lock do
            pig_socket = @pig_sockets["#{pig[:ip]}:#{pig[:port]}".to_sym]
          end
          # TODO
          # ? If the nearest pig is down, send the request to another pig
          if pig_socket.nil?
            @pigs_sockets_lock.with_write_lock do
              @pig_sockets.delete("#{pig[:ip]}:#{pig[:port]}".to_sym)
            end
            @pigs_tree_lock.with_write_lock do
              # TODO delete node
              @pig_tree.delete("#{pig[:ip]}:#{pig[:port]}".to_sym)
            end
          end

          if pig[:applications][app_name.to_sym].nil?
            # Configuration never sent to the pig before --> doing that now
            send_app_configuration(app_name.to_sym, pig_socket, pig)
          end

          send_data(pig_socket, header, body)
          # rescue Errno::ECONNRESET, Errno::EPIPE, Errno::EHOSTUNREACH, Errno::ECONNREFUSED

        rescue Timeout::Error
          logger.warn  "*** RequestManager: Timeout connect to PIG #{host}:#{port}! ***"
        rescue SPF::Common::Exceptions::WrongHeaderFormatException
          logger.warn "*** RequestManager: Received header with wrong format from #{host}:#{port}! ***"
        rescue SPF::Common::Exceptions::UnreachablePig
          logger.warn "*** RequestManager: Impossible connect to PIG #{pig[:ip]}:#{pig[:port]}! ***"
        rescue Errno::EHOSTUNREACH
          logger.warn "*** RequestManager: PIG #{pig[:ip]}:#{pig[:port]} unreachable! ***"
        rescue Errno::ECONNREFUSED
          logger.warn  "*** RequestManager: Connection refused by PIG #{pig[:ip]}:#{pig[:port]}! ***"
        rescue Errno::ECONNRESET
          logger.warn "*** RequestManager: Connection reset by PIG #{pig[:ip]}:#{pig[:port]}! ***"
        rescue Errno::ECONNABORTED
          logger.warn "*** RequestManager: Connection aborted by PIG #{pig[:ip]}:#{pig[:port]}! ***"
        rescue Errno::ETIMEDOUT
          logger.warn "*** RequestManager: Connection to PIG #{pig[:ip]}:#{pig[:port]} closed for timeout! ***"
        rescue EOFError
          logger.warn "*** RequestManager: PIG #{pig[:ip]}:#{pig[:port]} disconnected! ***"
        rescue ArgumentError => e
          logger.warn e.message
        end

        def receive_request(user_socket)
          header = nil
          body = nil
          begin
            status = Timeout::timeout(@@DEFAULT_OPTIONS[:receive_request_timeout]) do
              _, port, host = user_socket.peeraddr
              header = user_socket.gets
              body = user_socket.gets
            end
          rescue SPF::Common::Exceptions::ReceiveRequestTimeout
            logger.warn  "*** RequestManager: Receive request timeout to PIG #{host}:#{port}! ***"
          end
          [header, body]
        end

        def read_reconf_template(template_filename)
          @reconf_template = File.new(template_filename, 'r').read
        end

        # REQUEST participants/find_text
        def parse_request_header(header)
          tmp = header.split(' ')
          app_name, serv = tmp[1].split('/')
          [tmp[0], app_name, serv]
        end

        # User 3;44.838124,11.619786;find "water"
        def parse_request_body(body)
          tmp = body.split(';')
          lat, lon = tmp[1].split(',')
          [tmp[0], lat, lon, tmp[2]]
        end

        def send_app_configuration(app_name, socket, pig)
          if @app_conf[app_name].nil?
            logger.error "*** RequestManager: Could not find the configuration for application '#{app_name.to_s}' ***"
            raise ArgumentError, "*** RequestManager: Application '#{app_name.to_s}' not found! ***"
          end

          config = @app_conf[app_name].to_s.force_encoding(Encoding::UTF_8)
          reprogram_body = "application \"#{app_name.to_s}\", #{config}"
          reprogram_header = "REPROGRAM #{reprogram_body.bytesize}"

          send_data(socket, reprogram_header, reprogram_body)

          pig[:applications][app_name] = @app_conf[app_name]
        end

        def send_data(socket, header, body)
          attempts = 3
          begin
            status = Timeout::timeout(@@DEFAULT_OPTIONS[:send_data_timeout]) do
              socket.puts(reprogram_header)
              socket.puts(reprogram_body)
              socket.flush
              logger.info "*** RequestManager: Sent data to PIG #{pig[:ip]}:#{pig[:port]} ***"
            end
          rescue
            attempts -= 1
            attempts > 0 ? retry : (fail SPF::Common::Exceptions::UnreachablePig)
          end
        end

    end
  end
end
