#!/usr/bin/env ruby
require 'logger'
require 'date'

module Sleepier
    VALID_RESTART_OPTIONS = [:permanent, :temporary, :transient]
    VALID_SHUTDOWN_OPTIONS = [:brutal_kill, :timeout, :infinity]

    @@logger = Logger.new(STDOUT)

    def self.logger
      @@logger
    end

    def self.logger=(logger)
      @@logger = logger
    end

    class ChildSpec < Object

        attr_accessor :child_id, :start_func, :args, :restart, :shutdown, :pid, :terminating, :shutdown_timeout

        def initialize(child_id, start_func, args, restart, shutdown, is_supervisor=false, shutdown_timeout=0)
            @child_id = child_id
            @start_func = start_func
            @args = args
            @restart = restart
            @shutdown = shutdown
            @is_supervisor = is_supervisor
            @shutdown_timeout = shutdown_timeout
            @pid = nil

            # Array of timestamps of restarts.  Used for checking restarts
            @failures = Array.new

            # Used for
            @terminating = false
        end

        def supervisor?
            @is_supervisor
        end

        def child?
            !@is_supervisor
        end

        def should_restart?(status_code, max_restart_count, max_restart_window)
            if self.too_many_restarts?(max_restart_count, max_restart_window)
                false
            elsif self.allows_restart?(status_code) && !@terminating
                true
            else
                false
            end
        end

        def allows_restart?(status_code)
            case self.restart
            when :permanent
                true
            when :temporary
                false
            when :transient
                if status_code == 0
                    false
                else
                    true
                end
            end
        end

        def restarted
            @failures << Time.now.to_i
        end

        def too_many_restarts?(max_restart_count, max_restart_window)
            max_restart_count <= self.restarts_within_window(max_restart_window)
        end

        def restarts_within_window(max_restart_window)
            failures_within_window = 0
            now = Time.now.to_i
            new_failures = Array.new

            @failures.each do |f|
                if now - f < max_restart_window
                    failures_within_window += 1
                    new_failures << f
                end
            end

            # Update the failures array to only include things currently within the window
            @failures = new_failures

            # Return the current number of failures within the window
            failures_within_window
        end
    end

    class Supervisor < Object
        VALID_RESTART_STRATEGIES = [:one_for_one, :one_for_all, :rest_for_one, :simple_one_for_one]

        def initialize(child_specs, restart_strategy, max_restart_count=3, max_restart_window=5)
            @child_specs = Hash.new
            child_specs.each {|child_spec| @child_specs[child_spec.child_id] = child_spec}

            @max_restart_count = max_restart_count
            @max_restart_window = max_restart_window

            if VALID_RESTART_STRATEGIES.include?(restart_strategy)
                @restart_strategy = restart_strategy
            else
                raise Exception.new('Invalid restart strategy')
            end

            @started = false
        end

        def monitor
            while true
                begin
                    pid, status = Process.wait2
                rescue Errno::ECHILD
                    if @started
                        Sleepier.logger.warn("No children, exiting")
                        break
                    end
                end

                self.handle_finished_process(pid, status)
            end
        end

        def start
            @child_specs.each do |child_id, child_spec|
                self.start_process(child_id)
            end
            @started = true
        end

        def start_new_child(child_spec)
            @child_specs[child_spec.child_id] = child_spec
            self.start_process(child_spec.child_id)
        end

        def terminate_child(child_id)
            child_spec = @child_specs[child_id]
            child_spec.terminating = true

            case child_spec.shutdown
            when :brutal_kill
                Process.kill("KILL", child_spec.pid)
            when :timeout
                Process.kill("TERM", child_spec.pid)

                Thread.new do
                    sleep(child_spec.shutdown_timeout)
                    Process.kill("KILL", child_spec.pid)
                end
            when :infinity
               Process.kill("TERM", child_spec.pid)
            end
        end

        def handle_finished_process(pid, status)
            @child_specs.each do |child_id, child_spec|
                if child_spec.pid == pid
                    if child_spec.should_restart?(status, @max_restart_count, @max_restart_window)
                        child_spec.restarted
                        self.start_process(child_id)
                        return true
                    else
                        Sleepier.logger.info("#{child_spec.restart.to_s.capitalize} child #{child_spec.child_id} finished.  Will not be restarted")
                        return false
                    end
                end
            end
        end

        def start_process(child_id)
            child_spec = @child_specs[child_id]
            pid = Process.fork do
                child_spec.start_func.call(*(child_spec.args))
            end

            child_spec.pid = pid
            Sleepier.logger.info("Started #{child_spec.child_id} with pid #{pid}")
        end
    end
end
