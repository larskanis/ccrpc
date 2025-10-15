# -*- coding: utf-8 -*-
# -*- frozen_string_literal: true -*-
###########################################################################
#    Copyright (C) 2015 to 2024 by Lars Kanis
#    <lars@greiz-reinsdorf.de>
#
# Copyright: See COPYING file that comes with this distribution
###########################################################################
#
# RPC Connection
#

require 'thread'
require_relative 'escape'

module Ccrpc
class RpcConnection
  class InvalidResponse < RuntimeError
  end
  class NoCallbackDefined < RuntimeError
  end
  class CallAlreadyReturned < NoCallbackDefined
  end
  class DoubleResultError < RuntimeError
  end
  class ConnectionDetached < RuntimeError
  end
  class ReceiverAlreadyDefined < RuntimeError
  end

  # The context of a received call.
  class Call
    # @return [RpcConnection]  The used connection.
    attr_reader :conn
    # @return [String]  Called function
    attr_reader :func
    # @return [Hash{String => String}] List of parameters passed with the call.
    attr_reader :params
    attr_reader :id
    # @return [Hash{String => String}] List of parameters send back to the called.
    attr_reader :answer

    # @private
    def initialize(conn, func, params={}, id)
      @conn = conn
      @func = func
      @params = params
      @id = id
      @answer = nil
    end

    # Send the answer back to the caller.
    #
    # @param [Hash{String, Symbol => String, Symbol}] value  The answer parameters to be sent to the caller.
    def answer=(value)
      raise DoubleAnswerError, "More than one answer to #{self.inspect}" if @answer
      @answer = value
      conn.send(:send_answer, value, id)
    end

    # Send a dedicated callback to the caller's block.
    #
    # If {RpcConnection#call} is called with both function name and block, then it's possible to call back to this dedicated block through {#call_back} .
    # The library ensures, that the callback ends up in the corresponding call block and in the same thread as the caller, even if there are multiple simultaneous calls are running at the same time in different threads or by using +lazy_answers+ .
    #
    # @param func [String, Symbol]  The RPC function to be called on the other side.
    #   The other side must wait for calls through {#call} with function name and with a block.
    # @param params [Hash{Symbol, String => Symbol, String}]  Optional parameters passed with the RPC call.
    #   They can be retrieved through {Call#params} on the receiving side.
    #
    # Yielded parameters and returned objects are described in {RpcConnection#call}.
    def call_back(func, params={}, &block)
      raise CallAlreadyReturned, "Callback is no longer possible since the call already returned #{self.inspect}" if @answer
      conn.send(:call_intern, func, params, @id, &block)
    end
  end

  CallbackReceiver = Struct.new :meth, :callbacks
  ReceivedCallData = Struct.new :cbfunc, :id, :recv_id

  attr_accessor :read_io
  attr_accessor :write_io

  # Create a RPC connection
  #
  # @param [IO] read_io   readable IO object for reception of data
  # @param [IO] write_io   writable IO object for transmission of data
  # @param [Boolean] lazy_answers   Enable or disable lazy results.
  #    If enabled the return value of #call is always a Ccrpc::Promise object.
  #    It behaves like an ordinary +nil+ or Hash object, but the actual IO blocking operation is delayed to the first method call on the Promise object.
  #    See {#call} for more description.
  # @param [Symbol] protocol   Select the protocol which is used to send calls.
  #    * The +:text+ protocol is the classic default.
  #    * The +:binary+ protocol is faster, but not so readable for human.
  #    * The +:prefer_binary+ is the same as :binary, but with an initial round-trip to check that the other end is binary-capable (means ccrpc >= 0.5).
  #    The protocol used to receive calls is selected by the *protocol* option on the other end.
  #    A connection could use different protocols for both directions, although this has no advantage.
  def initialize(read_io, write_io, lazy_answers: false, protocol: :text)
    super()

    @read_io = read_io
    @write_io = write_io
    @read_binary = false
    @write_binary = case protocol
      when :binary
        true
      when :text, :only_text # only_text is to simulate ccrpc-0.4.0 peer
        false
      when :prefer_binary
        nil
      else
        raise ArgumentError, "invalid protocol: #{protocol.inspect}"
    end
    if lazy_answers
      require 'ccrpc/lazy'
      alias maybe_lazy do_lazy
    else
      alias maybe_lazy dont_lazy
    end

    if @write_io.respond_to?(:setsockopt)
      @write_io.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
    end

    @id_mutex = Mutex.new
    @read_mutex = Mutex.new
    @write_mutex = Mutex.new
    @answers = {}
    @receivers = {}
    @answers_mutex = Mutex.new
    @proto_ack_mutex = Mutex.new
    @new_answer = ConditionVariable.new

    @read_enum = Enumerator.new do |y|
      begin
        while @read_enum
          if @read_binary
            t = @read_io.read(1)&.getbyte(0)
            # p @read_io=>t
            case t
              when 1
                keysize, valsize = @read_io.read(8).unpack("NN")
                key = @read_io.read(keysize).force_encoding(Encoding::UTF_8)
                value = @read_io.read(valsize).force_encoding(Encoding::UTF_8)
                y << [key, value]
              when 2
                id, funcsize = @read_io.read(8).unpack("NN")
                func = @read_io.read(funcsize)
                y << ReceivedCallData.new(func.force_encoding(Encoding::UTF_8), id)
              when 3
                id, recv_id, funcsize = @read_io.read(12).unpack("NNN")
                func = @read_io.read(funcsize)
                y << ReceivedCallData.new(func.force_encoding(Encoding::UTF_8), id, recv_id)
              when 4
                id = @read_io.read(4).unpack1("N")
                y << id
              when 79 # "O"
                l = @read_io.read(6)
                unless l == "\tK\n\a1\n"
                  raise InvalidResponse, "invalid binary response #{l.inspect}"
                end
                y << ["O", "K"]
                y << 1

              when NilClass
                # connection closed
                break

              else
                raise InvalidResponse, "invalid binary response #{t.inspect}"
            end

          else

            l = @read_io.gets&.force_encoding(Encoding::BINARY)
            # p @read_io=>l
            case
              when l=="\r\0\a1\n" && protocol != :only_text
                @read_binary = true
              when l=="\r\1\a1\n" && protocol != :only_text
                @read_binary = true
                send_answer({O: :K}, 1)

              when l=~/\A([^\t\a\n]+)\t(.*?)\r?\n\z/mn
                # received key/value pair used for either callback parameters or return values
                y << [Escape.unescape($1).force_encoding(Encoding::UTF_8), Escape.unescape($2.force_encoding(Encoding::UTF_8))]

              when l=~/\A([^\t\a\n]+)(?:\a(\d+))?(?:\a(\d+))?\r?\n\z/mn
                # received callback
                y << ReceivedCallData.new(Escape.unescape($1.force_encoding(Encoding::UTF_8)), $2&.to_i, $3&.to_i)

              when l=~/\A\a(\d+)\r?\n\z/mn
                # received return event
                y << $1.to_i

              when l.nil?
                # connection closed
                break

              else
                raise InvalidResponse, "invalid text response #{l.inspect}"
            end
          end
        end
      rescue => err
        y << err
      end
    end

    if @write_binary == true # immediate binary mode
      # Use ID 1 for proto change request to have a fixed string over the wire
      register_call("\r", 1)
      @write_io.write "\r\0\a1\n"
      @write_io.flush
    end

    # A random number as start call ID is not technically required, but makes transferred data more readable.
    @id = rand(1000) + 1
  end

  private def do_lazy(&block)
    Promise.new(&block)
  end
  private def dont_lazy
    yield
  end

  # Disable reception of data from the read_io object.
  #
  # This function doesn't close the IO objects.
  # A waiting reception is not aborted by this call.
  # It can be aborted by calling IO#close on the underlying read_io and write_io objects.
  def detach
    @read_enum = nil
  end

  # Do a RPC call and/or wait for a RPC call from the other side.
  #
  # {#call} must be called with either a function name (and optional parameters) or with a block or with both.
  # If {#call} is called with a function name, the block on the other side of the RPC connection is called with that function name.
  # If {#call} is called with a block only, than it receives these kind of calls, which are called anonymous callbacks.
  # If {#call} is called with a function name and a block, then the RPC function on the other side is called and it is possible to call back to this dedicated block by invoking {Call#call_back} .
  #
  # @param func [String, Symbol]  The RPC function to be called on the other side.
  #   The other side must wait for calls through {#call} without arguments but with a block.
  # @param params [Hash{Symbol, String => Symbol, String}]  Optional parameters passed with the RPC call.
  #   They can be retrieved through {Call#params} on the receiving side.
  #
  # @yieldparam [Ccrpc::Call] block  The context of the received call.
  # @yieldreturn [Hash{String, Symbol => String, Symbol}] The answer parameters to be sent back to the caller.
  # @yieldreturn [Array<Hash>] Two element array with the answer parameters as the first element and +true+ as the second.
  #   By this answer type the answer is sent to other side but the reception of further calls or callbacks is stopped subsequently and the local corresponding {#call} method returns with +nil+.
  #
  # @return [Hash]  Received answer parameters.
  # @return [Promise] Received answer parameters enveloped by a Promise.
  #   This type of answers can be enabled by +RpcConnection#new(lazy_answers: true)+
  #   The Promise object is returned as soon as the RPC call is sent and a callback receiver is registered, but before waiting for the corresponding answer.
  #   This way several calls can be send in parallel without using threads.
  #   As soon as a method is called on the Promise object, this method is blocked until the RPC answer was received.
  #   The Promise object then behaves like a Hash or +nil+ object.
  #   It is recommended to use Promise#itself to trigger waiting for call answers or callbacks (although any other method triggers waiting as well).
  # @return [NilClass] Waiting for further answers was stopped gracefully by either returning +[hash, true]+ from the block or because the connection was closed.
  def call(func=nil, params={}, &block)
    call_intern(func, params, &block)
  end

  protected

  def register_call(func, id, &block)
    id ||= next_id if func

    @answers_mutex.synchronize do
      @receivers[id] = CallbackReceiver.new(block_given? ? nil : caller[4], [])
    end
    id
  end

  def wait_for_return(id, &block)
    maybe_lazy do
      @answers_mutex.synchronize do
        res = loop do
          # Is a callback pending for this thread?
          if cb=@receivers[id].callbacks.shift
            @answers_mutex.unlock
            begin
              # invoke the user block
              rets, exit = yield(cb)
              if rets
                cb.answer = rets
              end
              break if exit
            ensure
              @answers_mutex.lock
            end

          # Is a call return pending for this thread?
          elsif a=@answers.delete(id)
            break a

          # Unless some other thread is already reading from the read_io, do it now
          elsif @read_mutex.try_lock
            @answers_mutex.unlock
            begin
              break if receive_answers
            ensure
              @read_mutex.unlock
              @answers_mutex.lock
              # Send signal possibly again to prevent deadlock if another thread started waiting before we re-locked the @answers_mutex
              @new_answer.signal
            end

          # Wait for signal from other thread about a new call return or callback was received
          else
            @new_answer.wait(@answers_mutex)
          end
        end

        @receivers.delete(id)

        res
      end
    end
  end

  def call_intern(func, params={}, recv_id=nil, &block)
    id = register_call(func, nil, &block)
    send_call(func, params, id, recv_id) if func
    wait_for_return(id, &block)
  end

  def next_id
    @id_mutex.synchronize do
      @id = (@id + 1) & 0xffffffff
    end
  end

  def wait_for_proto_ack
    @proto_ack_mutex.synchronize do
      if @write_binary.nil? # acknowledge text/binary mode
        register_call("\r", 1)
        @write_mutex.synchronize do
          @write_io.write "\r\1\a1\n"
          @write_io.flush
        end
        # wait until protocol is acknowledged
        res = wait_for_return(1)
        if res == {"O" => "K"}
          @write_binary = true
        else
          @write_binary = false
        end
      end
    end
  end

  def send_call_or_answer(params)
    to_send = String.new
    @write_mutex.synchronize do
      params.compact.each do |key, value|
        if @write_binary
          k = key.to_s
          v = value.to_s
          to_send << [1, k.bytesize, v.bytesize, k, v].pack("CNNa*a*")
        else
          to_send << Escape.escape(key.to_s) << "\t" <<
              Escape.escape(value.to_s) << "\n"
        end
        if to_send.bytesize > 9999
          @write_io.write to_send
          to_send = String.new
        end
      end
      yield(to_send)
      @write_io.write(to_send)
      @write_io.flush
    end
    after_write
  end

  def send_call(func, params, id, recv_id)
    wait_for_proto_ack unless recv_id
    send_call_or_answer(params) do |to_send|
      if @write_binary
        f = func.to_s
        if recv_id
          to_send << [3, id, recv_id, f.bytesize, f].pack("CNNNa*")
        else
          to_send << [2, id, f.bytesize, f].pack("CNNa*")
        end
      else
        to_send << Escape.escape(func.to_s) << "\a#{id}"
        to_send << "\a#{recv_id}" if recv_id
        to_send << "\n"
      end
    end
  end

  def send_answer(answer, id)
    send_call_or_answer(answer) do |to_send|
      if @write_binary
        to_send << [4, id].pack("CN")
      else
        to_send << "\a#{id}" if id
        to_send << "\n"
      end
    end
  end

  def receive_answers
    rets = {}
    (@read_enum || raise(ConnectionDetached, "connection already detached")).each do |l|
      case l
        when Exception
          raise l

        when Array
          rets[l[0]] ||= l[1]

        when ReceivedCallData
          # received callback
          callback = Call.new(self, l.cbfunc.to_sym, rets, l.id)

          @answers_mutex.synchronize do
            receiver = @receivers[l.recv_id]

            if !receiver
              if l.recv_id
                raise NoCallbackDefined, "call_back to #{l.cbfunc.inspect} was received, but corresponding call returned already"
              else
                raise NoCallbackDefined, "call to #{l.cbfunc.inspect} was received, but there is no #{self.class}#call running"
              end
            elsif meth=receiver.meth
              raise NoCallbackDefined, "call_back to #{l.cbfunc.inspect} was received, but corresponding call was called without a block in #{meth}"
            end

            receiver.callbacks << callback
            @new_answer.broadcast
          end
          return

        when Integer
          # received return event
          id = l

          @answers_mutex.synchronize do
            @answers[id] = rets
            @new_answer.broadcast
          end
          return

        else
          raise InvalidResponse, "invalid response #{l.inspect}"
      end
    end
    detach
    return true
  end

  # Can be overwritten by subclasses to make use of idle time while waiting for answers.
  def after_write
  end
end
end
