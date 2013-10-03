require 'minitest/autorun'
require_relative '../../lib/sleepier'

class TestChildSpec < MiniTest::Unit::TestCase
    def setup
        @permanent_child_spec = Sleepier::ChildSpec.new('test_1', puts, [], :permanent, :brutal_kill)
        @transient_child_spec = Sleepier::ChildSpec.new('test_2', puts, [], :transient, :brutal_kill)
        @temporary_child_spec = Sleepier::ChildSpec.new('test_3', puts, [], :temporary, :brutal_kill)
        @supervisor_child_spec = Sleepier::ChildSpec.new('test_4', puts, [], :temporary, :brutal_kill, is_supervisor=true)
    end

    def test_permanent_should_restart
        assert(@permanent_child_spec.should_restart?(0, 3, 5))
    end

    def test_transient_should_restart
        assert_equal(@transient_child_spec.should_restart?(0, 3, 5), false)
    end

    def test_transient_error_should_restart
        assert(@transient_child_spec.should_restart?(1, 3, 5))
    end

    def test_temporary_should_restart
        assert_equal(@temporary_child_spec.should_restart?(0, 3, 5), false)
    end

    def test_child_child_spec_is_child
        assert(@temporary_child_spec.child?)
        assert_equal(@temporary_child_spec.supervisor?, false)
    end

    def test_supervisor_child_spec_is_supervisor
        assert(@supervisor_child_spec.supervisor?)
        assert_equal(@supervisor_child_spec.child?, false)
    end

    def test_too_many_restarts
        # Make it think it was restarted 3 times in a row
        @supervisor_child_spec.restarted
        @supervisor_child_spec.restarted
        @supervisor_child_spec.restarted
        assert_equal(@supervisor_child_spec.should_restart?(0, 3, 5) , false)
    end
end
