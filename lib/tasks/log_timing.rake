  task :log_timing => :environment do
    10.times do |i|
      puts "#{Time.now} - #{i}"
      sleep 5
    end
  end
