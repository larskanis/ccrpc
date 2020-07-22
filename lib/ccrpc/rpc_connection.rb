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
      conn.send_answer(value, id)
      @answer = value
    end
  end

  attr_accessor :read_io
  attr_accessor :write_io

  def initialize(read_io, write_io)
    super()
    @read_io = read_io
    @write_io = write_io
    @id = 0
    @id_mutex = Mutex.new
    @read_mutex = Mutex.new
    @write_mutex = Mutex.new
    @close_mutex = Mutex.new
    @answers = {}
    @answers_mutex = Mutex.new
    @new_answer = ConditionVariable.new
    @read_queue = Queue.new
    stop_thread_rd, @stop_thread_wr = IO.pipe
    @read_thread = Thread.new do
      begin
        while IO.select([@read_io, stop_thread_rd])[0].include?(@read_io)
          l = @read_io.gets&.force_encoding(Encoding::UTF_8)
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
      id = next_id
      send_call(func, params, id)

      @answers_mutex.synchronize do
        loop do
          if a=@answers.delete(id)
            break a
          elsif @read_mutex.try_lock
            @answers_mutex.unlock
            begin
              break if receive_answers(&block)
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
    else
      @read_mutex.synchronize do
        until receive_answers(&block)
        end
      end
    end
  end

  def next_id
    @id_mutex.synchronize do
      @id = (@id + 1) & 0xffffffff
    end
  end

  def send_call(func, params, id)
    to_send = String.new
    params.reject{|k,v| v.nil? }.each do |key, value|
      to_send << Escape.escape(key.to_s) << "\t" << Escape.escape(value.to_s) << "\n"
    end
    to_send << Escape.escape(func.to_s)
    to_send << "\a#{id}\n"

    @write_mutex.synchronize do
      @write_io.write to_send
      @write_io.flush
    end
    after_write
  end

  def send_answer(answer, id)
    to_send = String.new
    answer.reject{|k,v| v.nil? }.each do |key, value|
      to_send << Escape.escape(key.to_s) << "\t" << Escape.escape(value.to_s) << "\n"
    end
    to_send << (id ? "\a#{id}\n" : "\n")

    @write_mutex.synchronize do
      @write_io.write to_send
      @write_io.flush
    end
    after_write
  end

  protected
  def receive_answers
    rets = {}
    while l=@read_queue.pop
      case l
        when Exception
          raise l
        when /\A([^\t\a\n]+)\t(.*)\n\z/m
          # received key/value pair used for either callback parameters or return values
          rets[Escape.unescape($1)] ||= Escape.unescape($2)

        when /\A([^\t\a\n]+)(?:\a(\d+))?\n\z/m
          # received callback
          cbfunc, id = $1, $2
          @read_mutex.unlock

          begin
            unless block_given?
              raise NoCallbackDefined, "A callback was received, but #{self.class}#call was called without a block"
            end

            callback = Call.new(self, Escape.unescape(cbfunc).to_sym, rets, id)

            rets, exit = yield(callback)
            if rets
              callback.answer = rets
            end

            rets = {}
            return true if exit
          ensure
            @read_mutex.lock
          end

        when /\A\a(\d+)\n\z/m
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
