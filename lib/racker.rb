require "socket"
require "stringio"
require "tempfile"
require "rack"
require "rack/builder"
require "rack/utils"
require "prax/logger"

class Racker
  attr_accessor :server, :threads, :queue

  def self.run(*args)
    new(*args).run
  end

  def self.logger
    @logger ||= begin
      $stdout.sync = true
      ::Logger.new($stdout)
    end
  end

  def self.logger=(logger)
    @logger = logger
  end

  def initialize(options = {})
    Signal.trap("INT")  { exit }
    Signal.trap("TERM") { exit }
    Signal.trap("QUIT") { exit }
    Signal.trap("EXIT") { finalize }

    if options[:pid]
      @pid_path = options[:pid]
      File.open(@pid_path, "w") { |f| f.write(Process.pid) }
    end
    Racker.logger = ::Logger.new(options[:log]) if options[:log]

    @mutex = Mutex.new
    @queue = Queue.new

    spawn_server(options)
    spawn_threads
  rescue
    finalize
    raise
  end

  def spawn_threads
    @threads = 4.times.map do
      Thread.new do
        loop { handle_connection(queue.pop) }
      end
    end
  end

  def spawn_server(options)
    Racker.logger.debug("Starting server on #{options[:server]}")
    if options[:server] =~ %r{^/}
      @socket_path = options[:server]
      self.server = UNIXServer.new(@socket_path)
    else
      host, port = options[:server].split(':', 2)
      self.server = TCPServer.new(host, port || 9292)
    end
  end

  def finalize
    server.close if server
    File.unlink(@pid_path)    if @pid_path    and File.exists?(@pid_path)
    File.unlink(@socket_path) if @socket_path and File.exists?(@socket_path)
  end

  def app
    @mutex.synchronize do
      @app ||= begin
        config_path = Dir.getwd + "/config.ru"
        Racker.logger.debug("Building Rack app at #{config_path}")
        app, _ = Rack::Builder.parse_file(config_path)
        app
      end
    end
  end

  def run
    Racker.logger.info("Server ready to receive connections")
    loop { queue << server.accept }
  end

  def handle_connection(socket)
    env = parse_env_from_socket(socket)
    code = headers = body = nil

    begin
      code, headers, body = app.call(env)
    rescue => exception
      render_exception(socket, env, exception)
      raise
    end
    Racker.logger.info("#{code} - #{env['REQUEST_URI']}")

    socket.flush
    socket.write("#{env["HTTP_VERSION"]} #{code} #{http_status(code)}\r\n")
    headers["Connection"] = "close"
    headers.each { |key, value| socket.write("#{key}: #{value}\r\n") }
    socket.write("\r\n")

    body.each { |b| socket.write(b) }
  rescue Errno::EPIPE, Errno::EIO, Errno::ECONNRESET
  ensure
    unless socket.closed?
      socket.flush
      socket.close
    end
    body.close if body.respond_to?(:close)
    env["rack.input"].close if env and env["rack.input"]
  end

  def parse_env_from_socket(socket)
    env = {
      "rack.version"      => [ 1, 1 ],
      "rack.multithread"  => true,
      "rack.multiprocess" => false,
      "rack.run_once"     => false,
      "SERVER_SOFTWARE"   => "racker 0.0.1",
    }
    env["rack.errors"] = STDERR
    env["rack.logger"] = Racker.logger

    _, _, host = socket.peeraddr
    env["REMOTE_ADDR"] = host

    line = socket.gets
    line.strip =~ %r{^([A-Z]+) (.*) (HTTP/1\.\d)$}
    env["REQUEST_METHOD"]  = $1
    env["REQUEST_URI"]     = $2
    env["HTTP_VERSION"]    = $3
    env["SERVER_PROTOCOL"] = $3

    idx = env["REQUEST_URI"].rindex('?')
    if idx
      env["PATH_INFO"] = env["REQUEST_PATH"] = env["REQUEST_URI"][0...idx]
      env["QUERY_STRING"] = env["REQUEST_URI"][(idx + 1)..-1]
    else
      env["PATH_INFO"] = env["REQUEST_PATH"] = env["REQUEST_URI"]
      env["QUERY_STRING"] = ""
    end
    env["SCRIPT_NAME"] = ""

    while line = socket.gets
      if line.strip =~ /^([^:]*):\s*(.*)$/
        value, key = $2, $1.upcase.gsub("-", "_")
        case key
        when "CONTENT_TYPE"   then env["CONTENT_TYPE"]   = value
        when "CONTENT_LENGTH" then env["CONTENT_LENGTH"] = value.to_i
        else env["HTTP_#{key}"] = value
        end
      end
      break if line.strip.empty?
    end

    server_name, server_port = env["HTTP_HOST"].split(":", 2)
    env["SERVER_NAME"] = server_name
    env["SERVER_PORT"] = server_port

    env["rack.url_scheme"] = "http"
    env["rack.input"] = read_body_as_rewindable_input(socket, env["CONTENT_LENGTH"] || 0)

    env
  end

  def read_body_as_rewindable_input(socket, content_length)
    if content_length > (1024 * (80 + 32))
      tempfile = Tempfile.new("RackerInputBody")
      tempfile.chmod(000)
      tempfile.set_encoding("ASCII-8BIT") if tempfile.respond_to?(:set_encoding)
      tempfile.binmode
      ::File.unlink(tempfile.path)
#      IO.copy_stream(socket, tempfile, content_length)
      tempfile.write(socket.read(content_length))
      tempfile.rewind
      tempfile
    elsif content_length > 0
      StringIO.new(socket.read(content_length))
    else
      StringIO.new("")
    end
  end

  private
    def http_status(code)
      Rack::Utils::HTTP_STATUS_CODES[code]
    end

    def render_exception(socket, env, exception)
      socket.flush
      socket.write([
        "#{env["HTTP_VERSION"]} 500 #{http_status(500)}",
        "Connection: close",
        "Content-Type: text/plain",
        "X-Racker-Exception: 1"
      ].join("\r\n"))
      socket.write("\r\n\r\n")
      socket.write(exception.class.name + ": " + exception.message + "\n\n")
      exception.backtrace.each { |line| socket.write(line + "\n") }
    end
end
