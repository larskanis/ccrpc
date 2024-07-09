# -*- coding: utf-8 -*-
# -*- frozen_string_literal: true -*-
###########################################################################
#    Copyright (C) 2015 by Lars Kanis
#    <kanis@comcard.de>
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

  attr_accessor :read_io
  attr_accessor :write_io

  # Create a RPC connection
  #
  # @param [IO] read_io   readable IO object for reception of data
  # @param [IO] write_io   writable IO object for transmission of data
  # @param [Boolean] lazy_answers   Enable or disable lazy results. See {#call} for more description.
  def initialize(read_io, write_io, lazy_answers: false)
    super()

    @read_io = read_io
    @write_io = write_io
    if lazy_answers
      require 'ccrpc/lazy'
      alias maybe_lazy do_lazy
    else
      alias maybe_lazy dont_lazy
    end

    if @write_io.respond_to?(:setsockopt)
      @write_io.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
    end

    # A random number as start call ID is not technically required, but makes transferred data more readable.
    @id = rand(1000)
    @id_mutex = Mutex.new
    @read_mutex = Mutex.new
    @write_mutex = Mutex.new
    @answers = {}
    @receivers = {}
    @answers_mutex = Mutex.new
    @new_answer = ConditionVariable.new

    @read_enum = Enumerator.new do |y|
      begin
        while @read_enum
          l = @read_io.gets&.force_encoding(Encoding::BINARY)
          break if l.nil?
          y << l
        end
      rescue => err
        y << err
      end
    end
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
  #   The Promise object is returned as soon as the RPC call is sent, but before waiting for the corresponding answer.
  #   This way several calls can be send in parallel without using threads.
  #   As soon as a method is called on the Promise object, this method is blocked until the RPC answer was received.
  #   The Promise object then behaves like a Hash object.
  # @return [NilClass] Waiting for further answers was stopped gracefully by either returning +[hash, true]+ from the block or because the connection was closed.
  def call(func=nil, params={}, &block)
    call_intern(func, params, &block)
  end

  protected

  def call_intern(func, params={}, recv_id=nil, &block)
    id = next_id if func

    @answers_mutex.synchronize do
      @receivers[id] = CallbackReceiver.new(block_given? ? nil : caller[3], [])
    end

    send_call(func, params, id, recv_id) if func

    pr = proc do
      @answers_mutex.synchronize do
        res = loop do
          # Is a callback pending for this thread?
          if cb=@receivers[id].callbacks.shift
            @answers_mutex.unlock
            begin
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
    func ? maybe_lazy(&pr) : pr.call
  end

  def next_id
    @id_mutex.synchronize do
      @id = (@id + 1) & 0xffffffff
    end
  end

  def send_call(func, params, id, recv_id=nil)
    to_send = String.new
    @write_mutex.synchronize do
      params.reject{|k,v| v.nil? }.each do |key, value|
        to_send << Escape.escape(key.to_s) << "\t" <<
            Escape.escape(value.to_s) << "\n"
        if to_send.bytesize > 9999
          @write_io.write to_send
          to_send = String.new
        end
      end
      to_send << Escape.escape(func.to_s) << "\a#{id}"
      to_send << "\a#{recv_id}" if recv_id
      @write_io.write(to_send << "\n")
    end
    @write_io.flush
    after_write
  end

  def send_answer(answer, id)
    to_send = String.new
    @write_mutex.synchronize do
      answer.reject{|k,v| v.nil? }.each do |key, value|
        to_send << Escape.escape(key.to_s) << "\t" <<
            Escape.escape(value.to_s) << "\n"
        if to_send.bytesize > 9999
          @write_io.write to_send
          to_send = String.new
        end
      end
      to_send << "\a#{id}" if id
      @write_io.write(to_send << "\n")
    end
    @write_io.flush
    after_write
  end

  def receive_answers
    rets = {}
    (@read_enum || raise(ConnectionDetached, "connection already detached")).each do |l|
      case l
        when Exception
          raise l
        when /\A([^\t\a\n]+)\t(.*)\n\z/mn
          # received key/value pair used for either callback parameters or return values
          rets[Escape.unescape($1).force_encoding(Encoding::UTF_8)] ||= Escape.unescape($2.force_encoding(Encoding::UTF_8))

        when /\A([^\t\a\n]+)(?:\a(\d+))?(?:\a(\d+))?\n\z/mn
          # received callback
          cbfunc, id, recv_id = $1, $2&.to_i, $3&.to_i

          callback = Call.new(self, Escape.unescape(cbfunc.force_encoding(Encoding::UTF_8)).to_sym, rets, id)

          @answers_mutex.synchronize do
            receiver = @receivers[recv_id]

            if !receiver
              if recv_id
                raise NoCallbackDefined, "call_back to #{cbfunc.inspect} was received, but corresponding call returned already"
              else
                raise NoCallbackDefined, "call to #{cbfunc.inspect} was received, but there is no #{self.class}#call running"
              end
            elsif meth=receiver.meth
              raise NoCallbackDefined, "call_back to #{cbfunc.inspect} was received, but corresponding call was called without a block in #{meth}"
            end

            receiver.callbacks << callback
            @new_answer.broadcast
          end
          return

        when /\A\a(\d+)\n\z/mn
          # received return event
          id = $1.to_i
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
