require "test_helper"
require 'tempfile'
require 'rbconfig'
require 'socket'
require 'timeout'

class TestRpcConnection < Minitest::Test
  def pipe_connection
    omit "No fork" if RUBY_PLATFORM=~/mingw|mswin/
    ar, aw = IO.pipe
    br, bw = IO.pipe
    fork do
      ar.close
      bw.close
      eval(server_code("br", "aw"))
    end
    br.close
    aw.close
    [ar, bw]
  end

  def socket_connection
    s = TCPServer.new 0
    a = TCPSocket.new 'localhost', s.addr[1]
    _b = s.accept
    s.close

    Thread.abort_on_exception = true
    Thread.new do
      eval(server_code("_b", "_b"))
    end

    [a, a]
  end

  def popen_connection
    code = <<-EOT
      $: << #{File.expand_path("../../lib", __FILE__).inspect}
      require 'ccrpc'
      #{server_code("STDIN", "STDOUT")}
    EOT
    tf = Tempfile.new('rpc')
    tf.write(code)
    tf.close
    @tempfile = tf # Speichern des Dateihandles, damit Datei nicht eher gelöscht wird als von ruby geöffnet (speziell unter Windows)

    io = IO.popen([RbConfig::CONFIG['ruby_install_name'], tf.path], "w+")
    [io, io]
  end

  def server_code(r,w)
    <<-EOT
      serv = Ccrpc::RpcConnection.new(#{r}, #{w})
      pr = proc do |call|
        case call.func
          when :exit
            [{shutdown: 'now'}, true]
          when :echo_no_thread
            call.params
          when :sleep
            sleep(call.params["sleep"].to_i)
            call.params
          else
            Thread.new do
              call.answer = case call.func
                when :echo
                  call.params
                when :callbacka
                  call.conn.call('callbackaa', call.params, &pr)
                when :callbacko
                  call.call_back('callbackoo', call.params, &pr)
                else
                  { 'Error' => "Unexpected function received: \#{call.func.inspect}" }
              end
            end
            nil
        end
      end
      serv.call(&pr)
      serv.detach
      serv.read_io.close
      serv.write_io.close unless serv.write_io.closed?
    EOT
  end

  def setup
    @bindata = (0..255).inject(String.new){|s,a| s << [a].pack("C") }.force_encoding(Encoding::UTF_8)
  end

  %w[pipe socket popen].each do |channel|
    define_method("test_echo_#{channel}"){ test_echo(channel) }
    define_method("test_echo_utf8_#{channel}"){ test_echo_utf8(channel) }
    define_method("test_recursive_#{channel}"){ test_recursive(channel) }
    define_method("test_threads_#{channel}"){ test_threads(channel) }
    define_method("test_exit_#{channel}"){ test_exit(channel) }
    define_method("test_legacy_call_#{channel}"){ test_legacy_call(channel) }
    define_method("test_detach_#{channel}"){ test_detach(channel) }
    define_method("test_transmission_buffer_overflow_#{channel}"){ test_transmission_buffer_overflow(channel) }
    define_method("test_call_back_#{channel}"){ test_call_back(channel) }
  end

  def test_call_already_returned
    assert_raises(Ccrpc::RpcConnection::CallAlreadyReturned) do
      with_connection(:pipe) do |c|
        c.call(:callbacko) do |callback|
          callback.answer = {}
          callback.call_back(:echo)
        end
      end
    end
  end

  def test_callback_without_block
    err = assert_raises(Ccrpc::RpcConnection::NoCallbackDefined) do
      with_connection(:pipe) do |c|
        c.call(:callbacko)
      end
    end
    assert_match(/"callbackoo".*called without a block.*test_callback_without_block/, err.message)
  end

  def test_anonymous_callback_without_block
    called = false
    err = assert_raises(Ccrpc::RpcConnection::NoCallbackDefined) do
      with_connection(:pipe) do |c|
        c.call(:callbacka) do |call|
          called = true
        end
      end
    end
    refute called, "a call-specific block shouldn't be called"
    assert_match(/"callbackaa".*no Ccrpc::RpcConnection#call running/, err.message)
  end

  def test_anonymous_callback
    recv_call = nil
    with_connection(:pipe) do |c|
      Thread.new do
        c.call do |call|
          recv_call = call
          [{}, true]
        end
      end
      c.call(:callbacka, {a: 3})
    end
    assert_equal :callbackaa, recv_call.func
    assert_equal({"a" => "3"}, recv_call.params)
  end

  private

  def with_connection(channel)
    ios = send("#{channel}_connection")
    c = Ccrpc::RpcConnection.new(*ios)
    yield(c)
    c.detach
    ios.each{|io| io.close unless io.closed? }
  end

  def with_ios(channel)
    ios = send("#{channel}_connection")
    yield(*ios)
    ios.each{|io| io.close unless io.closed? }
  end


  def test_echo(channel)
    with_connection(channel) do |c|
      r = c.call('echo', bindata: @bindata, to_be_removed: nil)
      assert_equal({'bindata' => @bindata}, r)
    end
  end

  def test_echo_utf8(channel)
    with_connection(channel) do |c|
      r = c.call('echo', "AbCäöü\x8F\x0E\\\\\t\n\a€" => "aBc\n\a\t\\äÖüß€")
      assert_equal({"AbCäöü\x8F\x0E\\\\\t\n\a€" => "aBc\n\a\t\\äÖüß€"}, r)
    end
  end

  def process_callback(call)
    case call.func
      when :callbackoo
        depth = call.params['depth'].to_i
        if depth < 1
          call.call_back('callbacko', call.params.merge('depth' => depth+1), &method(:process_callback))
        else
          { bindata_back: call.params['bindata'].reverse, thx: call.params['thx'] }
        end
      else
        { 'Error' => "Unexpected function received: \#{func.inspect}" }
    end
  end

  def test_recursive(channel)
    with_connection(channel) do |c|
      r = c.call('callbacko', bindata: @bindata, depth: 0, &method(:process_callback))
      assert_equal({ 'bindata_back' => @bindata.reverse }, r)
    end
  end

  def test_threads(channel)
    with_connection(channel) do |c|
      ths = 100.times.map do |thx|
        Thread.new do
          c.call('callbacko', depth: 0, thx: thx, bindata: @bindata, &method(:process_callback))
        end
      end

      ths.each.with_index do |th, thx|
        r = th.value
        assert_equal thx, r['thx'].to_i
        assert_equal @bindata.reverse, r['bindata_back']
      end
    end
  end

  def test_exit(channel)
    with_connection(channel) do |c|
      r = c.call(:exit)
      assert_equal({'shutdown' => 'now'}, r)
      sleep 0.1
      assert_raises do
        r = c.call(:exit)
        raise unless {'shutdown' => 'now'} == r
      end
    end
  end

  public def test_call_self_async
    skip "this doesn't work since result to RpcConnection#call is no longer Lazy"
    r, w = IO.pipe
    c = Ccrpc::RpcConnection.new(r, w)
    res = c.call("exit")
    c.call do |call|
      [{shutdown: [call.func, call.params]}, true]
    end
    assert_equal({'shutdown' => '[:exit, {}]'}, res)
  end

  def test_detach(channel)
    with_connection(channel) do |c|
      c.detach
      c.write_io.puts "echo_no_thread"
      c.write_io.close_write
      assert_equal "\n", c.read_io.gets
      assert_nil c.read_io.gets
    end
  end

  def test_legacy_call(channel)
    with_ios(channel) do |read_io, write_io|
      write_io.puts "a\tb"
      write_io.puts "echo_no_thread"
      write_io.close_write
      assert_equal "a\tb\n", read_io.gets
      assert_equal "\n", read_io.gets
      assert_nil read_io.gets
    end
  end

  def test_transmission_buffer_overflow(channel)
    with_connection(channel) do |c|
      some_data = 'some data '*100
      results = 10000.times.map do |idx|
        c.call('echo_no_thread', idx: idx, data: some_data)
      end
      results.each_with_index do |res, idx|
        assert_equal({'idx' => idx.to_s, 'data' => some_data}, res)
      end
    end
  end

  def test_call_back(channel)
    with_connection(channel) do |c|
      ths = 100.times.map do |thx|
        Thread.new(thx) do |thy|
          c.call('callbacko') do |call|
            { thy: thy, th: Thread.current.object_id }
          end
        end
      end

      ths.each.with_index do |th, thx|
        r = th.value
        assert_equal thx, r['thy'].to_i
        assert_equal th.object_id, r['th'].to_i
      end
    end
  end

  public def test_kill_process
    ios = popen_connection
    c = Ccrpc::RpcConnection.new(*ios)
    th = Thread.new do
      c.call(:sleep, sleep: 20)
    end
    sleep 0.1
    Process.kill(9, ios[0].pid)

#     assert_raises(Ccrpc::RpcConnection::ConnectionDetached) do
    assert_nil th.value
#     end
    c.detach
    ios.each{|io| io.close unless io.closed? }
  end
end
