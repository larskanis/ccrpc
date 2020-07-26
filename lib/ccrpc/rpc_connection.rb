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
      conn.send(:send_answer, value, id)
      @answer = value
    end

    def call_back(func, params={}, &block)
      conn.send(:send_and_wait, func, params, @id, &block)
    end
  end

  attr_accessor :read_io
  attr_accessor :write_io

  def initialize(read_io, write_io)
    super()

    @read_io = read_io
    @write_io = write_io
    @id = rand(1000)
    @id_mutex = Mutex.new
    @read_mutex = Mutex.new
    @write_mutex = Mutex.new
    @close_mutex = Mutex.new
    @answers = {}
    @receivers = {}
    @answers_mutex = Mutex.new
    @receivers_mutex = Mutex.new
    @new_answer = ConditionVariable.new
    @read_queue = Queue.new
    stop_thread_rd, @stop_thread_wr = IO.pipe
    @read_thread = Thread.new do
      begin
        while IO.select([@read_io, stop_thread_rd])[0].include?(@read_io)
          l = @read_io.gets&.force_encoding(Encoding::BINARY)
          @read_queue << l
          break if l.nil?
        end
        @read_queue << ConnectionDetached.new("connection already detached")
      rescue => err
        @read_queue << err
      end
    end
  end

  def detach
    @close_mutex.synchronize do
      if @read_thread
        @stop_thread_wr.write "x"
        @stop_thread_wr.close
        @read_thread.join
        @read_thread = nil
        @stop_thread_wr = nil
      end
    end
  end

  def call(func=nil, params={}, &block)
    if func
      send_and_wait(func, params, &block)
    else
      register_receiver(nil, block || caller[0..1])
      @read_mutex.synchronize do
        until receive_answers
        end
      end
      deregister_receiver(nil)
    end
  end

  protected
  def register_receiver(id, block)
    @receivers_mutex.synchronize do
      raise ReceiverAlreadyDefined, "Receiver block already defined in #{block.inspect}" if @receivers[id]
      @receivers[id] = block
    end
  end

  def deregister_receiver(id)
    @receivers_mutex.synchronize do
      @receivers.delete(id)
    end
  end

  def send_and_wait(func, params, recv_id=nil, &block)
    id = next_id
    register_receiver(id, block || caller[1..2])
    send_call(func, params, id, recv_id)

    res = @answers_mutex.synchronize do
      loop do
        if a=@answers.delete(id)
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
    end

    deregister_receiver(id)
    res
  end

  def next_id
    @id_mutex.synchronize do
      @id = (@id + 1) & 0xffffffff
    end
  end

  def send_call(func, params, id, recv_id=nil)
    @write_mutex.synchronize do
      params.reject{|k,v| v.nil? }.each do |key, value|
        @write_io.write Escape.escape(key.to_s) << "\t" <<
            Escape.escape(value.to_s) << "\n"
      end
      to_send = Escape.escape(func.to_s) << "\a#{id}"
      to_send << "\a#{recv_id}" if recv_id
      @write_io.write to_send << "\n"
    end
    @write_io.flush
    after_write
  end

  def send_answer(answer, id)
    @write_mutex.synchronize do
      answer.reject{|k,v| v.nil? }.each do |key, value|
        @write_io.write Escape.escape(key.to_s) << "\t" <<
            Escape.escape(value.to_s) << "\n"
      end
      @write_io.write id ? "\a#{id}\n" : "\n"
    end
    @write_io.flush
    after_write
  end

  def receive_answers
    rets = {}
    while l=@read_queue.pop
      case l
        when Exception
          raise l
        when /\A([^\t\a\n]+)\t(.*)\n\z/mn
          # received key/value pair used for either callback parameters or return values
          rets[Escape.unescape($1).force_encoding(Encoding::UTF_8)] ||= Escape.unescape($2.force_encoding(Encoding::UTF_8))

        when /\A([^\t\a\n]+)(?:\a(\d+))?(?:\a(\d+))?\n\z/mn
          # received callback
          cbfunc, id, recv_id = $1, $2&.to_i, $3&.to_i
          @read_mutex.unlock

          begin
            block_or_meth = @receivers_mutex.synchronize do
              @receivers[recv_id]
            end
            if !block_or_meth
              raise NoCallbackDefined, "A callback was received, but #{self.class}#call was called without a block"
            elsif block_or_meth.is_a?(Array)
              raise NoCallbackDefined, "A callback was received, but #{block_or_meth[0]} was called without a block in #{block_or_meth[1]}"
            end

            callback = Call.new(self, Escape.unescape(cbfunc.force_encoding(Encoding::UTF_8)).to_sym, rets, id)

            rets, exit = block_or_meth.call(callback)
            if rets
              callback.answer = rets
            end

            rets = {}
            return true if exit
          ensure
            @read_mutex.lock
          end

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
