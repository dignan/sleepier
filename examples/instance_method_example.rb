require './lib/sleepier'

class Example < Object
    def hw(name)
        puts("Hello world #{name}")
        sleep(10)
        puts("Goodbye world")
    end
end

example = Example.new

spec = Sleepier::ChildSpec.new('hello_goodbye', example.method(:hw), ['pat'], :transient, :brutal_kill)
supervisor = Sleepier::Supervisor.new([spec], :one_for_one)
supervisor.start

begin
    supervisor.monitor
rescue Interrupt
    puts("Caught interrupt, quitting")
end
