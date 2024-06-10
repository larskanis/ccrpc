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

  class Call
    attr_reader :conn
    attr_reader :func
    attr_reader :params
    attr_reader :id
    attr_reader :answer

    def initialize(conn, func, params={}, id)
      @conn = conn
      @func = func
      @params = params
      @id = id
      @answer = nil
    end

    def answer=(value)
      raise DoubleAnswerError, "More than one answer to #{self.inspect}" if @answer
      @answer = value
      conn.send(:send_answer, value, id)
    end

    def call_back(func, params={}, &block)
      raise CallAlreadyReturned, "Callback is no longer possible since the call already returned #{self.inspect}" if @answer
      conn.send(:call_intern, func, params, @id, &block)
    end
  end

  CallbackReceiver = Struct.new :meth, :callbacks

  attr_accessor :read_io
  attr_accessor :write_io

  def initialize(read_io, write_io)
    super()

    @read_io = read_io
    @write_io = write_io

    if @write_io.respond_to?(:setsockopt)
      @write_io.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
    end

    # A random number as call ID is not technically required, but makes transferred data more readable.
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

  def detach
    @read_enum = nil
  end

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

    @answers_mutex.synchronize do
      res = loop do
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

        elsif a=@answers.delete(id)
          break a

        elsif @read_mutex.try_lock
          @answers_mutex.unlock
          begin
            break if receive_answers
          ensure
            @read_mutex.unlock
            @answers_mutex.lock
            @new_answer.signal
          end

        else
          @new_answer.wait(@answers_mutex)
        end
      end

      @receivers.delete(id)

      res
    end
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

  def after_write
    # can be overwritten to make use of idle time
  end
end
end
