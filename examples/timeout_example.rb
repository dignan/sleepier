require './lib/sleepier'

fn = Proc.new do |name|
    Signal.trap("TERM") do
        puts "Got the TERM signal.  I'll be on my merry way"
    end

    puts("Hello world #{name}")
    sleep(10)
    puts("Goodbye world")
end

spec = Sleepier::ChildSpec.new('timeout_example', fn, ['pat'], :transient, :timeout, false, 5)
supervisor = Sleepier::Supervisor.new([spec], :one_for_one)
supervisor.start

begin
    sup = Thread.new do
      supervisor.monitor
    end
    
    supervisor.terminate_child('timeout_example')
    sup.join
rescue Interrupt
    puts("Caught interrupt, quitting")
end
