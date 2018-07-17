require "test_helper"

# Selenium::WebDriver::Chrome.driver_path = ENV['GOOGLE_CHROME_BIN']
# chrome_bin = ENV.fetch('GOOGLE_CHROME_SHIM', nil)
# chrome_opts = chrome_bin ? { "chromeOptions" => { "binary" => chrome_bin } } : {}
# Capybara.register_driver :chrome do |app|
#   Capybara::Selenium::Driver.new(
#      app,
#      browser: :chrome,
#      desired_capabilities: Selenium::WebDriver::Remote::Capabilities.chrome(chrome_opts)
#   )
# end

# options = Selenium::WebDriver::Firefox::Options.new
# options.binary = "/path/to/firefox" 
# driver = Selenium::WebDriver.for :firefox, options: options

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [1400, 1400]
end
