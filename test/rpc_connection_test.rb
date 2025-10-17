require_relative "test_helper"
require 'tempfile'
require 'rbconfig'
require 'socket'
require 'timeout'
require 'openssl'

# Thread.abort_on_exception = true

class TestRpcConnection < Minitest::Test
  def pipe_connection(testname, report_on_exception, proto)
    skip "No fork" unless Process.respond_to?(:fork)

    ar, aw = IO.pipe
    br, bw = IO.pipe
    fork do
      ar.close
      bw.close
      eval(server_code("br", "aw", proto))
    end
    br.close
    aw.close
    [ar, bw]
  end

  def socket_connection(testname, report_on_exception, proto)
    s = TCPServer.new 0
    a = TCPSocket.new "localhost", s.addr[1]
    _b = s.accept
    s.close

    Thread.new do
      eval(server_code("_b", "_b", proto))
    end

    [a, a]
  end

  def socket_openssl_connection(testname, report_on_exception, proto)
    context = OpenSSL::SSL::SSLContext.new
    context.cert, context.key = create_openssl_cert("localhost")
    s = TCPServer.new 0
    so = OpenSSL::SSL::SSLServer.new(s, context)
    a = TCPSocket.new "localhost", s.addr[1]
    ao = OpenSSL::SSL::SSLSocket.new(a, context)
    ao.sync_close = true
    Thread.new{ ao.connect }
    _b = so.accept
    so.close

    Thread.new do
      eval(server_code("_b", "_b", proto))
    end

    [ao, ao]
  end

  def popen_connection(testname, report_on_exception, proto)
    code = <<-EOT
      $: << #{File.expand_path("../../lib", __FILE__).inspect}
      require 'ccrpc'
      testname = #{testname.inspect}
      report_on_exception = #{report_on_exception.inspect}
      # Use a copy of STDOUT because...
      stdo = STDOUT.dup.binmode
      # .. STDOUT is now redirected to STDERR, so that pp prints to STDERR
      STDOUT.reopen(STDERR) unless RUBY_ENGINE=="jruby" && RbConfig::CONFIG['host_os']=~/mingw|mswin/i
      #{server_code("STDIN.binmode", "stdo", proto)}
    EOT
    tf = Tempfile.new('rpc')
    tf.write(code)
    tf.close
    @tempfile = tf # Save the file handle, so that the file not not deleted before opened by ruby (especially on Windows)

    io = IO.popen([RbConfig::CONFIG['ruby_install_name'], tf.path], "wb+")
    [io, io]
  end

  def server_code(r, w, proto)
    <<-EOT
      serv = Ccrpc::RpcConnection.new(#{r}, #{w}, protocol: :#{proto})
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
            th = Thread.new do
              Thread.current.report_on_exception = report_on_exception
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
            th.name = testname
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

  %w[pipe socket popen socket_openssl].each do |channel|
    %i[text binary prefer_binary].each do |proto|
      define_method("test_echo_#{channel}_#{proto}"){ test_echo(channel, proto) }
      define_method("test_echo_utf8_#{channel}_#{proto}"){ test_echo_utf8(channel, proto) }
      define_method("test_recursive_#{channel}_#{proto}"){ test_recursive(channel, proto) }
      define_method("test_threads_#{channel}_#{proto}"){ test_threads(channel, proto) }
      define_method("test_exit_#{channel}_#{proto}"){ test_exit(channel, proto) }
      define_method("test_transmission_buffer_overflow_#{channel}_#{proto}"){ test_transmission_buffer_overflow(channel, proto) }
      define_method("test_call_back_#{channel}_#{proto}"){ test_call_back(channel, proto) }
    end
    %i[text binary prefer_binary only_text].each do |proto|
      %i[text binary prefer_binary only_text].each do |proto2|
        next if proto == :binary && proto2 == :only_text || proto2 == :binary && proto == :only_text
        define_method("test_echo_#{channel}_from_#{proto}_to_#{proto2}"){ test_echo_from_text_to_binary(channel, proto, proto2) }
      end
    end
    define_method("test_legacy_call_#{channel}"){ test_legacy_call(channel) }
    define_method("test_detach_#{channel}"){ test_detach(channel) }
  end

  %i[text binary prefer_binary].each do |proto|
    define_method("test_kill_process_#{proto}"){ test_kill_process(proto) }
  end


  def test_call_already_returned
    with_connection(:pipe) do |c|
      assert_raises(Ccrpc::RpcConnection::CallAlreadyReturned) do
        c.call(:callbacko) do |callback|
          callback.answer = {}
          callback.call_back(:echo)
        end
      end
    end
  end

  def test_callback_without_block
    err = with_connection(:pipe, report_on_exception: false) do |c|
      assert_raises(Ccrpc::RpcConnection::NoCallbackDefined) do
        c.call(:callbacko)
      end
    end
    assert_match(/"callbackoo".*called without a block.*test_callback_without_block/, err.message)
  end

  def test_anonymous_callback_without_block
    called = false
    err = with_connection(:pipe, report_on_exception: false) do |c|
      assert_raises(Ccrpc::RpcConnection::NoCallbackDefined) do
        c.call(:callbacka) do |call|
          called = true
        end
      end
    end
    refute called, "a call-specific block shouldn't be called"
    assert_match(/"callbackaa".*no Ccrpc::RpcConnection#call running/, err.message)
  end

  def test_lazy_anonymous_callback
    recv_call = nil
    with_connection(:pipe, lazy_answers: true) do |c|
      recv = c.call do |call|
        recv_call = call
        [{}, true]
      end
      call = c.call(:callbacka, {a: 3})
      recv.itself # wait for the anonymous callback to receive and process the call
      call.itself # wait for the call to return
    end
    assert_equal :callbackaa, recv_call.func
    assert_equal({"a" => "3"}, recv_call.params)
  end

  private

  def test_echo_from_text_to_binary(channel, proto1, proto2)
    with_ios(channel, protocol: proto2) do |*ios|
      c = Ccrpc::RpcConnection.new(*ios, protocol: proto1)
      r = c.call('echo', bindata: @bindata)
      assert_equal({'bindata' => @bindata}, r)
      r = c.call('callbacko', bindata: @bindata, depth: 0, &method(:process_callback))
      assert_equal({ 'bindata_back' => @bindata.reverse }, r)
      c.detach
    end
  end

  def with_connection(channel, report_on_exception: true, lazy_answers: false, protocol: :text)
    ios = send("#{channel}_connection", caller[0], report_on_exception, protocol)
    c = Ccrpc::RpcConnection.new(*ios, lazy_answers: lazy_answers)
    res = yield(c)
    c.detach
    ios.each{|io| io.close unless io.closed? }
    res
  end

  def with_ios(channel, report_on_exception: true, protocol: :text)
    ios = send("#{channel}_connection", caller[0], report_on_exception, protocol)
    yield(*ios)
    ios.each{|io| io.close unless io.closed? }
  end


  def test_echo(channel, proto)
    with_connection(channel, protocol: proto) do |c|
      r = c.call('echo', bindata: @bindata, to_be_removed: nil)
      assert_equal({'bindata' => @bindata}, r)
    end
  end

  def test_echo_utf8(channel, proto)
    with_connection(channel, protocol: proto) do |c|
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

  def test_recursive(channel, proto)
    with_connection(channel, protocol: proto) do |c|
      r = c.call('callbacko', bindata: @bindata, depth: 0, &method(:process_callback))
      assert_equal({ 'bindata_back' => @bindata.reverse }, r)
    end
  end

  def test_threads(channel, proto)
    skip "concurrent use of OpenSSL isn't reliable on Truffleruby" if RUBY_ENGINE=="truffleruby"
    with_connection(channel, protocol: proto) do |c|
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

  def test_exit(channel, proto)
    with_connection(channel, protocol: proto) do |c|
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
    r, w = IO.pipe
    c = Ccrpc::RpcConnection.new(r, w, lazy_answers: true)
    res = c.call("exit")
    c.call do |call|
      [{shutdown: [call.func, call.params]}, true]
    end.itself  # Call .itself to wait for calls due to lazy_answers:true
    assert_equal({'shutdown' => '[:exit, {}]'}, res)
    r.close; w.close
  end

  def test_detach(channel)
    with_connection(channel) do |c|
      skip "close_write isn't supported on #{c.write_io.class}" unless c.write_io.respond_to?(:close_write)
      c.detach
      c.write_io.puts "echo_no_thread"
      c.write_io.close_write
      assert_equal "\n", c.read_io.gets.gsub("\r\n","\n")
      assert_nil c.read_io.gets
    end
  end

  def test_legacy_call(channel)
    with_ios(channel) do |read_io, write_io|
      skip "close_write isn't supported on #{write_io.class}" unless write_io.respond_to?(:close_write)
      write_io.puts "a\tb"
      write_io.puts "echo_no_thread"
      write_io.close_write
      assert_equal "a\tb\n", read_io.gets.gsub("\r\n","\n")
      assert_equal "\n", read_io.gets.gsub("\r\n","\n")
      assert_nil read_io.gets
    end
  end

  def test_transmission_buffer_overflow(channel, proto)
    with_connection(channel, protocol: proto) do |c|
      some_data = 'some data '*100
      results = 10000.times.map do |idx|
        c.call('echo_no_thread', idx: idx, data: some_data)
      end
      results.each_with_index do |res, idx|
        assert_equal({'idx' => idx.to_s, 'data' => some_data}, res)
      end
    end
  end

  def test_call_back(channel, proto)
    skip "concurrent use of OpenSSL isn't reliable on Truffleruby" if RUBY_ENGINE=="truffleruby"
    with_connection(channel, protocol: proto) do |c|
      ths = 100.times.map do |thx|
        Thread.new(thx) do |thy|
          c.call('callbacko') do |call|
            { thy: thy, th: Thread.current.object_id, func: call.func }
          end
        end
      end

      ths.each.with_index do |th, thx|
        r = th.value
        assert_equal thx, r['thy'].to_i
        assert_equal th.object_id, r['th'].to_i
        assert_equal 'callbackoo', r['func']
      end
    end
  end

  public def test_detach_error
    rd, wr = IO.pipe
    c = Ccrpc::RpcConnection.new(rd, wr)
    c.detach
    assert_raises(Ccrpc::RpcConnection::ConnectionDetached){ c.call(:dummy) }
  end

  def test_kill_process(proto)
    skip "not reliable on JRuby on Windows" if RUBY_ENGINE=="jruby" && RbConfig::CONFIG['host_os']=~/mingw|mswin/i
    ios = popen_connection(__method__, true, proto)
    c = Ccrpc::RpcConnection.new(*ios, lazy_answers: true, protocol: proto)
    res = c.call(:sleep, sleep: 20)
    sleep 0.1
    Process.kill(9, ios[0].pid)

#     assert_raises(Ccrpc::RpcConnection::ConnectionDetached) do
    assert_nil res
#     end
    c.detach
    ios.each{|io| io.close unless io.closed? }
  end
end
