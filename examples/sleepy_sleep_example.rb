require 'sleepy'

supervisor = Sleepy::Supervisor.new(3)
supervisor.start
begin
    supervisor.monitor
rescue Interrupt
    puts("Caught interrupt, quitting")
end
