require './lib/sleepier'

fn = Proc.new do |name|
  puts("Hello world #{name}")
  sleep(10)
  puts("Goodbye world")
end

spec = Sleepier::ChildSpec.new('hello_goodbye', fn, ['pat'], :transient, :brutal_kill)
supervisor = Sleepier::Supervisor.new([spec], :one_for_one)
supervisor.start

begin
    supervisor.monitor
rescue Interrupt
    puts("Caught interrupt, quitting")
end
