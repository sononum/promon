require 'rubygems'
require 'net/https'
require 'prowl'
require 'ruby-growl'
require 'timeout'
require 'uri'
require 'logger'
require 'mail'

module Promon
  
  # Some silly constants
  App_Name = 'promon'
  Error_BadHostname = "Couldn't find hostname"
  Error_BadURL = "Bad URL"
  Error_SiteIsDown = 'Site is down'
  Error_Timeout = 'Timed out'
  Error_TooManyRedirects = 'Too many redirects'
  Error_ConnectionRefused = 'Connection refused'
  Error_WrongResponseCode = 'Wrong response code'
  Error_NoRouteToHost = "No route to host"
  Error_Resolved = 'Error resolved'
  Error_Application = 'internal error'
  Notify_Startup = 'started'
  Notify_Shutdown = 'terminated'
  Timeout_In_Seconds = 5
  VERSION = "0.1.0"

  NoErr = 0
  Err = -1

  Config = YAML::load(IO.read('config.yaml'))
  logfile = Config['logfile'] || File.expand_path('promon.log', File.dirname(__FILE__))
  puts "Logging to #{logfile}"
  Logger = Logger.new(logfile, 10, 98304)

  class Notifier
    attr_reader :app_name
    
    def initialize(options)
      @app_name = options[:app_name]
    end # initialize
    
    def notify(subject, body, options=nil)
    end
  end # class Notifier
  

  class ProwlNotifier < Notifier
    def initialize(options)
      super(options)
      @prowl = Prowl.new(:application => @app_name, :apikey => options['apikey'])
      unless @prowl
        Logger.fatal "failed to initialize prowl-notifier with options #{options}" 
      else
        Logger.info "initialized prowl-notifier"
      end
    end # initialize
    
    def notify(subject, body, options=nil)
      url = options[:url] if options
      begin
         @prowl.add(:event => subject, :description => body, :url => url) if @prowl
      rescue Exception => e
        Logger.error "Failed to notify with prowl: #{subject}, reason: #{e.message}"
      end
      
    end # notify
  end # class ProwlNotifier
  

  class GrowlNotifier < Notifier
    def initialize(options)
      super(options)
      nots = [Error_BadHostname, 
        Error_BadURL, 
        Error_SiteIsDown, 
        Error_Timeout, 
        Error_TooManyRedirects, 
        Error_ConnectionRefused, 
        Error_WrongResponseCode, 
        Error_NoRouteToHost, 
        Error_Resolved, 
        Error_Application,
        Notify_Startup,
        Notify_Shutdown]
      @growl = Growl.new(options['host'], @app_name, nots, nots, options['password'])
      unless @growl
        Logger.fatal "failed to initialize growl-notifier with options #{options}" 
      else
        Logger.info "initialized growl-notifier"
      end
    end #initialize
    

    def notify(subject, body, options=nil)
      priority = options ? options['priority'] || 1 : 1
      sticky = options ? options['sticky'] || true : true
      begin
        @growl.notify(subject, "#{@app_name} #{subject}", body, priority, sticky)
      rescue Exception => e
        Logger.error "Failed to notify with growl: #{subject}, reason: #{e.message}"
      end
    end # notify
  end # class GrowlNotifier


  class MailNotifier < Notifier
    def initialize(options)
      super(options)
      Mail.defaults do
        delivery_method :smtp, {
          :address        => options['smtp_server'],
          :user_name      => options['smtp_username'],
          :password       => options['smtp_password'],
          :port           => options['port'] || 25,
          :authentication => :plain,
          :openssl_verify_mode  => OpenSSL::SSL::VERIFY_NONE
        }
      end # Mail defaults
      @to = options['to']
      @cc = options['cc']
      @from = options['from'] || "#{@app_name}@#{`hostname`.strip}"
      Logger.info "initialized mail-logger, to #{@to}"
    end # initialize


    def notify(subject, body, options=nil)
      mail = Mail.new
      mail.from = @from
      mail.to = @to
      mail.cc = @cc
      mail.subject = "#{@app_name} - #{subject}"
      mail.body = body
      begin
        mail.deliver
      rescue Exception => e
        Logger.error "Failed to notify with mail: #{subject}, reason: #{e.message}"
      end
    end # notify
  end # class MailNotifier
  
  
  class Promon
    attr_accessor :run
    attr_reader :notifiers

    def initialize
      @notifiers = []      
      Logger.debug "This is promon #{VERSION}"
      
      @run = true
      @yaml = Config
      @sleep = @yaml['sleep'] ||  60
  
      @redirects = 0;
      @errors = {}
    
      @app_name = @yaml['app_name'] || App_Name
      @user_agent = @app_name + ': Site Monitor'
      
      @yaml['notifiers'].each do |notifier_options|
        notifier_options[:app_name] = @app_name
        @notifiers << ProwlNotifier.new(notifier_options) if notifier_options["method"] == "prowl"
        @notifiers << GrowlNotifier.new(notifier_options) if notifier_options["method"] == "growl"
        @notifiers << MailNotifier.new(notifier_options) if notifier_options["method"] == "mail"
      end
      @notifiers.each do |n|
        n.notify(Notify_Startup, "running with PID: #{Process.pid}")
      end
    end
    
    
    def check
      @yaml['http'].each do |check|
        check_http(check["url"], check["response"], check["code"] || 200)
      end # http.each
    end #check
    
    
    def run
      loop do
        begin
          check
        rescue Exception => e
          application_error e
        end
        sleep @sleep
      end
    end
    
    private
    

    def check_http(url, response, code)
      Logger.info "checking #{url}"
      uri = URI.parse(url)
      # Build up our little HTTP request
      http = Net::HTTP.new(uri.host, uri.port)
      http.read_timeout = Timeout_In_Seconds
      http.use_ssl = (url.index('https://') == 0) ? true : false;
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE

      # Try to GET the URL. If we can't, let's say the site is down
      begin
        response = Timeout::timeout(Timeout_In_Seconds) {
          http.get(uri.request_uri, {'User-Agent' => @user_agent})
        }
      rescue Errno::ECONNREFUSED
        return error(Error_ConnectionRefused, url)
      rescue Errno::ETIMEDOUT
        return error(Error_Timeout, url)
      rescue Errno::EHOSTUNREACH
        return error(Error_NoRouteToHost, url)
      rescue Timeout::Error
        return error(Error_Timeout, url)
      rescue SocketError
        return error(Error_BadHostname, url)
      rescue NoMethodError
        return error(Error_BadURL, url)
      end
      
      if response.code.to_i == code.to_i
        error_resolved(url) if @errors[url]
      else
        error(Error_WrongResponseCode, url, "responded with #{response.code} instead of #{code}")
      end
        
    end # check_http
    
    def error(error, url, info = nil)
      infostring = url
      infostring += " #{info}" if info
      
      if @errors[url]
        Logger.warn "#{error}: #{infostring} - no notification"
        return 
      end
      Logger.warn "#{error}: #{infostring}"
      
      @notifiers.each do |n|
        n.notify(error, infostring, {:url => url})
      end
      @errors[url] = true
    end #error
    
    def error_resolved(url)
      Logger.info "error resolved for #{url}"
      @notifiers.each do |n|
        n.notify(Error_Resolved, url, {:url => url})
      end      
      @errors[url] = nil
    end
    
    def application_error(e)
      Logger.fatal "An uncaught Exception occurred in promon: #{e.message}"
      puts e.backtrace
      @errors = {}
      @notifiers.each do |n|
        n.notify(Error_Application, e.message)
      end
    end
    
  end # class promon
end # module promon

pmon = Promon::Promon.new()

pmon.run
pmon.notifiers.each do |n|
  n.notify(Promon::Notify_Shutdown, "terminated, PID: #{Process.pid}")
end
