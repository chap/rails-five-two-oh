require "test_helper"


  
  
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

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
# options = Selenium::WebDriver::Firefox::Options.new
# options.binary = "/path/to/firefox" 
# driver = Selenium::WebDriver.for :firefox, options: options

  driven_by :chrome_shim
end
