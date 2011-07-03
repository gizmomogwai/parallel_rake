$:.unshift File.join(File.dirname(__FILE__), '..', 'lib')

require 'rake'
require 'prake/task_parallel'

describe Rake::Task do
  it 'should notify listener' do
    t = task :testtask do
      puts '1'
    end
    l = mock
    l.should_receive(:execution_state_changed).with(t, Rake::ExecutionState.invoked)
    l.should_receive(:execution_state_changed).with(t, Rake::ExecutionState.enqueued)
    l.should_receive(:execution_state_changed).with(t, Rake::ExecutionState.ok)
    t.add_execution_state_listener(l)
    t.invoke
  end
end
