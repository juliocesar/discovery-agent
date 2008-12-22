require 'rubygems'
require 'socket'
require 'ipaddr'
require 'yaml'
require 'net/dns'

HOST_MAX_LIFE = 60
LOOKUP_INTERVAL = 3

Host = Struct.new('Host', :ip_address, :port, :alive_on)

Thread.abort_on_exception = true
Socket.do_not_reverse_lookup = true
STDOUT.sync = false

module Discovery

  class HostList < Array
    class NotHostError < Exception; end

    def add_host(host)
      raise NotHostError, "Entry is not a Host struct" unless host.is_a? Struct::Host
      self << host
    end

    def delete_host(host)
      self.delete host
    end

    def has_host?(host)
      return true if self.find { |h|
        h.ip_address == host.ip_address and h.port == host.port
      }
      false
    end

    def update_host_ttl(host, ttl)
      self.select { |h|
        h.ip_address == host.ip_address and h.port == host.port
      }.first.alive_on = ttl
    end
  end

  class MulticastSocket < UDPSocket
    def add_membership(multicast_range)
      hostname = Net::DNS::Name.create(Socket.gethostname)
      host_address = Socket.getaddrinfo(hostname.to_s, 0, Socket::AF_INET, Socket::SOCK_STREAM)[0][3]
      host_address = IPAddr.new(host_address).hton
      multicast_range = IPAddr.new(multicast_range).hton
      multicast_address = multicast_range + host_address

      setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
      setsockopt(Socket::IPPROTO_IP, Socket::IP_ADD_MEMBERSHIP, multicast_address)
      setsockopt(Socket::IPPROTO_IP, Socket::IP_MULTICAST_IF, host_address)
    end

    def drop_membership(multicast_address)
      ip_address = IPAddr.new(multicast_address).hton + IPAddr.new('0.0.0.0').hton
      setsockopt(Socket::IPPROTO_IP, Socket::IP_DROP_MEMBERSHIP, ip_address)
    end
  end


  class Agent
    MULTICAST_RANGE = '239.0.0.1'
    DYSCOVERY_PORT = 9090

    attr_accessor :peer_list

    def initialize(*args)
      @registered_services = {}

      @broadcaster = UDPSocket.new
      @events_callbacks = {}
      @peer_list = {}
      @lookup_list = args or []

      @server_worker = Thread.start do
        # This thread sleeps until a service gets registered
        sleep
        @socket = Discovery::MulticastSocket.new
        @socket.add_membership(MULTICAST_RANGE)
        @socket.bind(Socket::INADDR_ANY, DYSCOVERY_PORT)
        loop {
          io = select( [@socket], nil, nil )
          if io
            raw_message, from = io[0][0].recvfrom(300, 0)
            reply = parse_reply(raw_message)
            # We'll want to raise an error here
            if not reply
              puts "Invalid Reply: #{raw_message}"
            else
              handle_reply(reply, from)
            end
          end
        }
      end

      @broadcaster_handler = Thread.start do
        loop {
          io = select( [@broadcaster], nil, nil )
          if io
            raw_message, from = io[0][0].recvfrom(300, 0)
            reply = parse_reply(raw_message)
            # We'll want to raise an error here
            if not reply
              puts "Invalid Reply: #{raw_message}"
            else
              handle_reply(reply, from)
            end
          end
        }
      end

      @broadcaster_worker = Thread.start do
        loop {
          remove_dead_hosts
          @lookup_list.each { |service|
            puts "casting"
            whos_there?(service)
          }
          sleep(LOOKUP_INTERVAL)
        }
      end

      Kernel.at_exit { terminate }
    end

    def multicast(message)
      @broadcaster.send(message, 0, MULTICAST_RANGE, DYSCOVERY_PORT)
    end; private :multicast

    def unicast(message, ip_address, port)
      @broadcaster.send(message, 0, ip_address, port)
    end; private :unicast

    def im_off(service, host)
      multicast(message(service, 'im_off', host))
    end

    def whos_there?(service)
      multicast(message(service, 'whos_there'))
    end

    def im_here_reply(service, from)
      host = @registered_services[service]
      unicast( message(service, 'im_here', host), from[2], from[1] )
    end
    
    def im_here_notify(service, host)
      host = @registered_services[service]
      multicast(message(service, 'im_here', host))
    end


    def parse_reply(reply)
      msg = YAML.load(reply) rescue nil
      msg["service"] ? msg : nil
    end

    def handle_reply(reply, from = nil)
      case reply["message"]
      when "whos_there"
        if @registered_services.has_key?(reply["service"])
          host = @registered_services[reply["service"]]
          im_here_reply(reply["service"], from)
        end
      when "im_here"
        return nil if not @lookup_list.include? reply['service']
        ip_address, port = reply["reply"].split(/:/)
        host = Host.new(ip_address, port.to_i, Time.now.to_i)
        @peer_list[reply["service"]] ||= HostList.new
        if @peer_list[reply['service']].has_host? host
          @peer_list[reply['service']].update_host_ttl(host, Time.now.to_i)
        else
          add_peer(reply['service'], host) 
        end
      when "im_off"
        # puts "RECEIVED I'm off: #{reply.inspect}"
        if @peer_list.has_key?(reply["service"])
          host = get_host(reply["reply"])
          remove_peer(reply["service"], host)
        end
      end
    end

    def remove_dead_hosts
      @peer_list.each_key { |service|
        @peer_list[service].find_all { |h| 
          (h.alive_on + HOST_MAX_LIFE) < Time.now.to_i
        }.each { |host|
          remove_peer(service, host)
        }
      }
    end

    # packs service, message, and reply (if any)
    # in the DiscoveryAgent message format
    def message(service, message, host = nil)
      msg = {
        'service' => service,
        'message' => message,
      }
      msg['reply'] = "#{host.ip_address}:#{host.port}" if host
      msg = YAML.dump(msg)
      return msg
    end; private :message

    def get_host(host_and_port)
      host = Host.new
      ip_address, port = host_and_port.split(/:/)
      host.ip_address = ip_address
      host.port = port.to_i
      return host
    end; private :get_host

    def remove_peer(service, host)
      @peer_list[service].delete_host host
      @events_callbacks[:host_gone].call(host) if @events_callbacks[:host_gone]
      @peer_list.delete service if @peer_list[service].empty?
    end

    def add_peer(service, host)
      @peer_list[service].add_host host
      @events_callbacks[:host_found].call(host) if @events_callbacks[:host_found]
    end

    def register_service(name, ip_address, port)
      @server_worker.wakeup
      host = Host.new
      host.ip_address = ip_address
      host.port = port.to_i
      @registered_services[name] = host
      sleep 1
      im_here_notify(name, host)
    end

    def register_callback(event, &block)
      @events_callbacks[event] = block
    end

    def terminate
      @registered_services.each { |service, host|
        im_off(service, host)
      }
    end
  end

end
