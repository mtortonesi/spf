require 'spf-common/controller'
require 'spf-common/logger'
require 'spf-common/validate'
require 'geokdtree'


module SPF
  
  include SPF::Logging
  
  class Controller < SPF::Common::Controller
    
    def initialize(host, port)
      config = PIGConfiguration::load_from_file(conf_filename)
      @pigs_list = config.pigs
      
      @pigs_tree = Geokdtree::Tree.new(2)
      @pigs_list.each do |pig|
        @pigs_tree.insert([pig['gps_lat'], pig['gps_lon']], pig)
      end
      
      @pig_connections = {}
      connect_to_pigs
      
      @reconf_template = read_reconf_template(template_filename)
      
      super(host, port)
    end

    private
    
    #def run(opts = {})
      #send requests to the PIG
#      first_req = ""
#      second_req = ""
#      third_req = ""
#      
#      sleep 3
#      Thread.new { SPF::Request.new(@iot_address, @iot_port, first_req).run }
#      sleep 10
#      Thread.new { SPF::Request.new(@iot_address, @iot_port, second_req).run }
#      sleep 10
#      Thread.new { SPF::Request.new(@iot_address, @iot_port, third_req).run }
      
    #end

    
    # REQUEST participants/find
    # User 3;44.838124,11.619786;find "water"
    
      def handle_connection(user_socket)
        _, port, host = user_socket.peeraddr
        puts "*** Received connection from #{host}:#{port}"
        
        header = user_socket.gets
        body = user_socket.gets
        
        user_socket.close
        
        # get gps coords
        _, lat, lon, _ = parse_request_body(body)
        unless SPF::Validate.latitude?(lat) && SPF::Validate.longitude?(lon)
          logger.error "Error in client GPS coordinates"
          return
        end
        
        result = @pigs_tree.nearest([lat.to_f, lon.to_f])
        if result.nil?
          logger.fatal "Could not find the nearest PIG (empty data structure?)"
          return
        end
        
        pig = result.data.inspect
        pig_socket = @pig_connections[(pig.ip + ":" + pig.port).to_sym]      # check
        if pig_socket.nil? or pig_socket.closed?
          pig_socket = TCPSocket.new(pig.ip, pig.port)
          @pig_connections[(pig.ip + ":" + pig.port).to_sym] = pig_socket
        end
        
        pig_socket.puts(header)
        pig_socket.puts(body)
        
      rescue EOFError
        puts "*** #{host}:#{port} disconnected"
        socket.close
      end

      # Open socket to all pigs in the @pigs list
      def connect_to_pigs
        @pigs_list.each do |pig|
          pig_socket = TCPSocket.new(pig.ip, pig.port)
          @pig_connections[(pig.ip + ":" + pig.port).to_sym] = pig_socket
        end
      end
      
      def read_reconf_template(template_filename)
        @reconf_template = File.new(template_filename, 'r').read
      end
      
      def parse_request_body(body)
        tmp = body.split(';')
        [tmp[0]] + tmp[1].split(',') + [tmp[2]]
      end
      
  end
end
