#!/usr/bin/env ruby
require 'logger'
require 'date'

# Sleepier is a Process Management tool in the style of a supervisor.  It most similar to the Erlang supervisor behaviour.
#
# The basic usage of Sleepier is:
#
# 1. Create an `Array` of `Sleepier::ChildSpec` objects
# 2. Initialize a `Sleepier::Supervisor` object with the array of `Sleepier::ChildSpec` objects
# 3. Create a new `Thread` and call `monitor` on the supervisor object within the thread
# 4. Call `start` on the supervisor
#
# Note that `start` will return as soon as the processes are started, and does not wait for them to finish.
#
# Features:
#
# - Starting and stopping processes
# - Rapid termination handling
# - Several process shutdown strategies
# - Different process lifecycles
# - Pluggable logging
module Sleepier
    # The different styles which can be used to manage restarts
    #
    # - :permanent - Always restart the process, except when it has been restarted more than `max_restart_count` times in `max_restart_window` seconds
    # - :temporary - Never restart the process
    # - :transient - Only restart the process if it failed and hasn't been restarted more than `max_restart_count` times in `max_restart_window` seconds
    VALID_RESTART_OPTIONS = [:permanent, :temporary, :transient]

    # How to shutdown the process
    #
    # - :brutal_kill - Terminate immediately, without giving it a chance to terminate gracefully.  Equivalent to a kill -9 on Linux
    # - :timeout - Attempt to terminate gracefully, but after `shutdown_timeout` seconds, brutally kill
    # - :infinity - Terminate gracefully, even if it takes forever. USE WITH CAUTION!  THIS CAN RESULT IN NEVER-ENDING PROCESSES
    VALID_SHUTDOWN_OPTIONS = [:brutal_kill, :timeout, :infinity]

    @@logger = Logger.new(STDOUT)

    # Logger used by sleepier functionality
    def self.logger
      @@logger
    end

    # Configure the sleepier logger to another Ruby Logger-style logger
    #
    # @param logger [Logger] The new logger to use
    def self.logger=(logger)
      @@logger = logger
    end

    # Specifies the properties of the child process to be launched
    class ChildSpec < Object

        attr_accessor :child_id, :start_func, :args, :restart, :shutdown, :pid, :terminating, :shutdown_timeout

        # Create a new `ChildSpec`
        #
        # @param child_id Unique id associated with this specification.  This can be used to terminate the process
        # @param start_func The function run by the process
        # @param args [Array] The list of arguments passed to the function.  If there are none, pass it an empty `Array`
        # @param restart [VALID_RESTART_OPTIONS] One of the `VALID_RESTART_OPTIONS` that determines how to handle restarts
        # @param shutdown [VALID_SHUTDOWN_OPTIONS] One of the `VALID_SHUTDOWN_OPTIONS` that determines how to shutdown the process
        # @param is_supervisor [true, false] Is the child a supervisor itself?!  Potentially useful for trees of supervisors
        # @param shutdown_timeout [int] If `shutdown` is `:timeout`, this is how long to wait before brutally killing the process
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

        # Called by the supervisor to check whether the process should be restarted.  Checks whether the process has been restarted
        # more than `max_restart_count` times in `max_restart_window` seconds, and whether the `shutdown` type even
        # allows restarts
        #
        # @return [true, false]
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

        # Used to notify the child spec that it has been restarted, and when.  This allows tracking of
        # how many recent restarts the child spec has had.
        def restarted
            @failures << Time.now.to_i
        end

        def too_many_restarts?(max_restart_count, max_restart_window)
            max_restart_count <= self.restarts_within_window(max_restart_window)
        end

        # Counts how many restarts have happened within the last `max_restart_window` seconds, and
        # clears out old failures.
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

    # `Sleepier::Supervisor` manages a set of `Sleepier::ChildSpec` objects according to the guidance passed to it via the constructor.
    class Supervisor < Object
        # @todo implement strategies other than :one_for_one
        #
        # Determines how to handle restarts for all processes supervised
        #
        # - :one_for_one - Only restart the process that failed if one process terminates
        # - :one_for_all - Restart all processes if one process terminates
        # - :rest_for_one - Restart all processes after the process, in the order they started, that terminates as well as the process that terminated
        VALID_RESTART_STRATEGIES = [:one_for_one, :one_for_all, :rest_for_one, :simple_one_for_one]

        # Create the supervisor.  Does *not* start it.
        #
        # @param child_specs [Sleepier::ChildSpec] What processes to start and monitor
        # @param restart_strategy [VALID_RESTART_STRATEGIES] Managing how restarts are handled for the group of processes
        # @param max_restart_count [int] How many times within `max_restart_window` a process can restart.
        # @param max_restart_window [int] A moving window in seconds during which a process may terminate `max_restart_count` times before the supervisor gives up.
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

        # Watches for processes to terminate.  Sends the pid and status returned by the process to `handle_finished_process`
        #
        # @note This may be called before calling start to minimize chances of a process terminating before monitoring starts
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

        # Start all the child processes
        def start
            @child_specs.each do |child_id, child_spec|
                self.start_process(child_id)
            end
            @started = true
        end

        # Add a new child process and start it
        #
        # @param child_spec [Sleepier::ChildSpec] spec to use and start
        def start_new_child(child_spec)
            @child_specs[child_spec.child_id] = child_spec
            self.start_process(child_spec.child_id)
        end

        # Starts termination of a process.  This does *not* wait for the process to finish.
        #
        # @param child_id Which child to terminate
        #
        # @todo Add a callback for when the process finishes here
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

        # Internal function that handles a process finishing
        #
        # @param pid [int] The pid of the finished process, used to find the right child process
        # @param status [int] Status code.  0 is normal, anything else is abnormal termination
        #
        # @return [true,false] Returns true if the process should have been restarted and was, false otherwise
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

        # Internal function used by `start_new_child` and `start`
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
