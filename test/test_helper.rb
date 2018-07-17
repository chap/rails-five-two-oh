ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
require 'rails/test_help'


# Selenium::WebDriver::Chrome.driver_path = ENV['GOOGLE_CHROME_BIN']
chrome_bin = ENV.fetch('GOOGLE_CHROME_SHIM', nil)

chrome_opts = chrome_bin ? { "chromeOptions" => { "binary" => chrome_bin } } : {}

Capybara.register_driver :chrome_shim do |app|
  Capybara::Selenium::Driver.new(
     app,
     browser: :chrome,
     desired_capabilities: Selenium::WebDriver::Remote::Capabilities.chrome(chrome_opts)
  )
end

Capybara.javascript_driver = :chrome_shim

# options = Selenium::WebDriver::Firefox::Options.new
# options.binary = "/path/to/firefox" 
# driver = Selenium::WebDriver.for :firefox, options: options


class ActiveSupport::TestCase
  # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
  fixtures :all

  # Add more helper methods to be used by all tests here...
end
