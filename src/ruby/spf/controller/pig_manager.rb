require 'socket'
require 'concurrent'
require 'json'

require 'spf/common/tcpserver_strategy'
require 'spf/common/logger'
require 'spf/common/validate'

require_relative './pig_ds'


module SPF
  module Controller
    class PigManager < SPF::Common::TCPServerStrategy

    include SPF::Logging

      @@DEFAULT_HOST = "localhost"
      @@DEFAULT_PORT = 52160

      def initialize(pigs, pigs_tree, host=@@DEFAULT_HOST, port=@@DEFAULT_PORT)
        super(host, port, self.class.name)

        @pigs = pigs
        @pigs_lock = Concurrent::ReadWriteLock.new
        @pigs_tree = pigs_tree
        @pig_tree_lock = Concurrent::ReadWriteLock.new
      end

      private

        def handle_connection(socket)
          _, port, host = socket.peeraddr
          logger.info "*** PigManager: Received connection from #{host}:#{port} ***"

          header, body = receive_request(socket, host, port)
          if header.nil? or body.nil?
            logger.warn "*** PigManager: Received wrong message from #{host}:#{port} ***"
            return
          end

          pig = validate_request(header, body, host, port)
          if pig.nil?
            socket.puts "REFUSED"
            logger.warn "*** PigManager: Refused connection from #{host}:#{port} ***"
            return
          end

          socket.puts "OK!"

          pig.socket = socket
          pig.ip = host
          pig.port = port

          @pigs_lock.with_write_lock do
            if @pigs.key?(pig.alias_name)
              @pigs[pig.alias_name].socket = pig.socket
              @pigs[pig.alias_name].ip = pig.ip
              @pigs[pig.alias_name].port = pig.port
              logger.info "*** PigManager: Successfully updated registration info of PIG #{pig.alias_name} ***"
            else
              @pigs[pig.alias_name] = pig
              logger.info "*** PigManager: Successfully registered PIG #{pig.alias_name} ***"
            end
          end

          @pig_tree_lock.with_write_lock do
            @pigs_tree.add(pig)
          end
        end

        def validate_request(header, body, host, port)
          request = header.split(' ')
          bytesize = request[2].to_i
          unless request[0].eql? "REGISTER" and request[1].eql? "PIG"
            logger.warn "*** PigManager: Received wrong header from #{host}:#{port} ***"
            return
          end
          unless bytesize > 0
            logger.warn "*** PigManager: Received wrong bytesize from #{host}:#{port} ***"
            return
          end
          unless body.bytesize == (bytesize+1)
            logger.warn "*** PigManager: Error PIG bytesize from #{host}:#{port} ***"
            return
          end

          tmp_pig = JSON.parse(body)    # parsed PIGs have keys as strings, not Symbols

          unless SPF::Common::Validate.latitude?(tmp_pig['gps_lat']) && SPF::Common::Validate.longitude?(tmp_pig['gps_lon'])
            logger.warn "*** PigManager: Error PIG GPS coordinates from #{host}:#{port} ***"
            return
          end

          PigDS.new(tmp_pig["alias_name"], 0, 0, nil, tmp_pig["gps_lat"], tmp_pig["gps_lon"])
        end

        def receive_request(socket, host, port)
          header = nil
          body = nil
          begin
            header = socket.gets
            body = socket.gets
          rescue => e
            logger.warn  "*** PigManager: Receive request error #{e.message} from #{host}:#{port} ***"
          end
          [header, body]
        end

    end
  end
end
