require "bunny"

# Ruby script requiring bunny library 

STDOUT.sync = true

conn = Bunny.new("amqp://guest:guest@localhost:5672/")
conn.start
ch = conn.create_channel
x = ch.topic("lager_amqp_backend")


ch.queue("#",   :auto_delete => false).bind(x, :routing_key => "#").subscribe do |delivery_info, metadata, payload|
	puts "** #{payload} #{delivery_info.routing_key}"
end
x.publish("Ruby test", :routing_key => "test.ruby")
sleep 60
conn.close
