God.watch do |w|
  w.name = "promon"
  w.dir = File.dirname(__FILE__)
  w.start = "ruby #{File.expand_path('promon.rb', File.dirname(__FILE__))}"
  w.keepalive(:memory_max => 50.megabytes, :cpu_max => 10.percent)
end