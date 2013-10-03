require './lib/sleepier'

fn = Proc.new do |name|
  puts("Hello world #{name}")
  sleep(10)
  puts("Goodbye world")
end

spec = Sleepier::ChildSpec.new('brootle', fn, ['pat'], :transient, :brutal_kill)
supervisor = Sleepier::Supervisor.new([spec], :one_for_one)
supervisor.start

begin
    sup = Thread.new do
      supervisor.monitor
    end
    
    supervisor.terminate_child('brootle')
    sup.join
rescue Interrupt
    puts("Caught interrupt, quitting")
end
