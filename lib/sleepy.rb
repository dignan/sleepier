#!/usr/bin/env ruby
require 'logger'

module Sleepy
    class Supervisor < Object
        def initialize(sub_processes)
            @sub_processes = sub_processes
            @pids = []
            @log = Logger.new(STDOUT)
        end

        def monitor
            while true
                begin
                    pid, status = Process.wait2
                rescue Errno::ECHILD
                    @log.error("No children, exiting")
                    break
                end

                if status != 0
                    @log.info("Process #{pid} failed somehow")
                    @pids.delete(pid)
                    self.start_process
                end
            end
        end

        def start_process
            @pids << Process.fork do
                yield if block_given?
            end
        end

        def start
            @sub_processes.times do
                self.start_process do
                    pid = Process.pid
                    log = Logger.new("supervisor_#{pid}.log")

                    begin
                        log.info("Starting process #{pid}")
                        sleep(300)
                    rescue Interrupt
                        log.info("Caught interrupt in #{pid}, quitting")
                    end
                end
            end
        end
    end
end
