  task :log_timing => :environment do
    $stdout.sync = true
    10.times do |i|
      puts "#{Time.now} - #{i}"
      sleep 5
    end
  end
