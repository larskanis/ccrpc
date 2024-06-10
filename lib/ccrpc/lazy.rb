# = lazy.rb -- Lazy evaluation in Ruby
#
# Author:: MenTaLguY
#
# Copyright 2005-2006  MenTaLguY <mental@rydia.net>
#
# You may redistribute it and/or modify it under the same terms as Ruby.
#

require 'thread'

module Ccrpc
  # Raised when a forced computation diverges (e.g. if it tries to directly
  # use its own result)
  #
  class DivergenceError < RuntimeError
    def initialize( message="Computation diverges" )
      super( message )
    end
  end

  # Wraps an exception raised by a lazy computation.
  #
  # The reason we wrap such exceptions in LazyException is that they need to
  # be distinguishable from similar exceptions which might normally be raised
  # by whatever strict code we happen to be in at the time.
  #
  class LazyException < DivergenceError
    # the original exception
    attr_reader :reason

    def initialize( reason )
      @reason = reason
      super( "#{ reason } (#{ reason.class })" )
      set_backtrace( reason.backtrace.dup ) if reason
    end
  end

  # A promise is just a magic object that springs to life when it is actually
  # used for the first time, running the provided block and assuming the
  # identity of the resulting object.
  #
  # This impersonation isn't perfect -- a promise wrapping nil or false will
  # still be considered true by Ruby -- but it's good enough for most purposes.
  # If you do need to unwrap the result object for some reason (e.g. for truth
  # testing or for simple efficiency), you may do so via Kernel.demand.
  #
  # Formally, a promise is a placeholder for the result of a deferred computation.
  #
  class Promise
    alias __class__ class #:nodoc:
    instance_methods.each { |m| undef_method m unless m =~ /^__|^object_id$|^instance_variable|^frozen\?$/ }

    def initialize( &computation ) #:nodoc:
      @mutex = Mutex.new
      @computation = computation
      @exception = nil
    end

    # create this once here, rather than creating a proc object for
    # every evaluation
    DIVERGES = lambda {|promise| raise DivergenceError.new } #:nodoc:
    def DIVERGES.inspect #:nodoc:
      "DIVERGES"
    end

    def __result__ #:nodoc:
      @mutex.synchronize do
        if @computation
          raise @exception if @exception

          computation = @computation
          @computation = DIVERGES # trap divergence due to over-eager recursion

          begin
            @result = Promise.demand( computation.call( self ) )
            @computation = nil
          rescue DivergenceError => exception
            @exception = exception
            raise
          rescue Exception => exception
            # handle exceptions
            @exception = LazyException.new( exception )
            raise @exception
          end
        end

        @result
      end
    end

    def inspect #:nodoc:
      @mutex.synchronize do
        if @computation
          "#<#{ __class__ } computation=#{ @computation.inspect }>"
        else
          @result.inspect
        end
      end
    end

    def marshal_dump
      __result__
      Marshal.dump( [ @exception, @result ] )
    end

    def marshal_load( str )
      @mutex = Mutex.new
      ( @exception, @result ) = Marshal.load( str )
      @computation = DIVERGES if @exception
    end

    def respond_to?( message, include_all=false ) #:nodoc:
      message = message.to_sym
      message == :__result__ or
      message == :inspect or
      message == :marshal_dump or
      message == :marshal_load or
      __result__.respond_to?(message, include_all)
    end

    ruby2_keywords def method_missing( *args, &block ) #:nodoc:
      __result__.__send__( *args, &block )
    end

    def self.demand( promise )
      if promise.respond_to? :__result__
        promise.__result__
      else # not really a promise
        promise
      end
    end
  end
end
