  task :log_timing => :environment do
    STDOUT.sync = true
    10.times do |i|
      puts "PUTS: #{Time.now} - #{i}"
      Rails.logger.info "Logger.info: #{Time.now} - #{i}"
      sleep 5
    end
  end
