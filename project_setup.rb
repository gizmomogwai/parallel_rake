class Listener
  def execution_state_changed(task, state)
#    puts "Execution state for #{task.name} changed to #{state}"
  end
end

DELAY=1
FAILING = [2, 4].map{|i|"task#{i}"}
l = Listener.new
4.times do |i|
  t = task "task#{i+1}" do |t|
    puts  "running #{t.name}"
    sleep(DELAY)
    if FAILING.include?(t.name)
      raise "problem in task #{t.name}"
    end
  end
  t.add_execution_state_listener(l)
end

task :tasks =>[:task1, :task2, :task3, :task4] do
  #  sh 'gibts nicht'
end


file "project/base.o" => ['project/base/base.h', 'project/base/base.cpp'] do |t|
  sh "g++ -c project/base/base.cpp -o #{t.name}"
end

file "project/lib.o" => ['project/lib/lib.h', 'project/lib/lib.cpp'] do |t|
  sh "g++ -c project/lib/lib.cpp -o #{t.name}"
end

file "project/main.o" => ['project/main/main.cpp', 'project/base/base.h', 'project/lib/lib.h'] do |t|
  sh "g++ -c project/main/main.cpp -o #{t.name}"
end

file "project/main.exe" => ['project/main.o', 'project/lib.o', 'project/base.o'] do |t|
  sh "g++ -o #{t.name} #{t.prerequisites.join(' ')}"
end
