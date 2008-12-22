#Discovery Agent

This is a funny one. I was still learning Ruby when I got started on it. You can think of this class as a 
poor man's Bonjour. It was a Ruby and networking experiment.

Who knows, one day I may decide to take it further. I'll leave it here for historical purposes, should I
become a millionaire Hollywood star.

#Usage

    >> a = Discovery::Agent.new
    => #<Discovery::Agent:0x12cc6d4 @broadcaster_handler=#<Thread:0x12cc5d0 sleep>, @events_callbacks={}, 
    @server_worker=#<Thread:0x12cc634 sleep>, @broadcaster=#<UDPSocket:0x12cc684>, @lookup_list=[], @registered_services={}, 
    @broadcaster_worker=#<Thread:0x12cc544 sleep>, @peer_list={}>
    >> a.register_service 'myservice', 'localhost', 9090
    => 63
    >> b = Discovery::Agent.new 'myservice'
    => #<Discovery::Agent:0x12c5a78 @broadcaster_handler=#<Thread:0x12c5974 sleep>, @events_callbacks={}, 
    @server_worker=#<Thread:0x12c59d8 sleep>, @broadcaster=#<UDPSocket:0x12c5a28>, @lookup_list=["myserver"], 
    @registered_services={}, @broadcaster_worker=#<Thread:0x12c58e8 sleep>, @peer_list={}>
    ... wait 3-5 seconds
    >> b.peer_list
    => {"myserver"=>[#<struct Struct::Host ip_address="localhost", port=9090, alive_on=1229904158>]}

Capisce? "a" gets instanced, and we tell the network "a" has "myservice" running on "localhost", port 9090. "b" gets instanced as looking for "myservice" services on the network. It soon enough finds what "a" advertised earlier on.

#But I can't get it to work...

This software is WorksForMe&trade; certified.

#License

MIT licensed (google it). 