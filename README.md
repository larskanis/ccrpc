# Ccrpc - A minimalistic RPC library for Ruby

Features:
* Simple human readable wire protocol
* Works on arbitrary ruby IO objects (Pipes, Sockets, STDIN, STDOUT) even Windows CR/LF converting IOs
* No object definitions - only plain string transfers (so no issues with undefined classes or garbage collection like in DRb)
* Each call transfers a function name and a list of parameters in form of a Hash<String=>String>
* Each response equally transfers a list of parameters
* Similar to closures, it's possible to respond to a particular call as a call_back
* Fully asynchronous, either by use of multiple threads or by using lazy_answers, so that arbitrary calls in both directions can be mixed simultaneously without blocking each other
* Fully thread safe, but doesn't use additional internal threads
* Each call_back arrives in the thread of the caller
* Only dedicated functions can be called (not arbitrary as in DRb)
* No dependencies


## Installation

Add this line to your application's Gemfile:

```ruby
gem 'ccrpc'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install ccrpc

## Usage

Fork a subprocess and communicate with it through pipes
```ruby
  require 'ccrpc'

  ar, aw = IO.pipe # pipe to send data to the forking process
  br, bw = IO.pipe # pipe to send data to the forked process
  fork do
    ar.close; bw.close
    # Create the receiver side of the connection
    rpc = Ccrpc::RpcConnection.new(br, aw)
    # Wait for calls
    rpc.call do |call|
      # Print the received call data
      pp func: call.func, params: call.params  # =>  {:func=>:hello, :params=>{"who"=>"world"}}
      # The answer of the subprocess
      {my_answer: 'hello back'}
    end
  end
  br.close; aw.close

  # Create the caller side of the connection
  rpc = Ccrpc::RpcConnection.new(ar, bw)
  # Call function "hello" with param {"who" => "world"}
  pp rpc.call(:hello, who: 'world')  # => {"my_answer"=>"hello back"}
```

Communicate with a subprocess through STDIN and STDOUT.
Since STDIN and STDOUT are used for the RPC connection, it's best zu redirect STDOUT to STDERR after the RPC object is created.
This avoids clashes between "p" calls and the RPC protocol.

The following example invokes the call in the opposite direction, from the subprocess to the main process.

```ruby
  require 'ccrpc'

  # The code of the subprocess:
  code = <<-EOT
    require 'ccrpc'
    # Create the receiver side of the connection
    # Use a copy of STDOUT because...
    rpc = Ccrpc::RpcConnection.new(STDIN, STDOUT.dup)
    # .. STDOUT is now redirected to STDERR, so that pp prints to STDERR
    STDOUT.reopen(STDERR)
    # Call function "hello" with param {"who" => "world"}
    pp rpc.call(:hello, who: 'world')  # => {"my_answer"=>"hello back"}
  EOT

  # Write the code to a temp file
  tf = Tempfile.new('rpc')
  tf.write(code)
  tf.flush
  # Execute the temp file in a subprocess
  io = IO.popen(['ruby', tf.path], "w+")

  # Create the caller side of the connection
  rpc = Ccrpc::RpcConnection.new(io, io)
  # Wait for calls
  rpc.call do |call|
    # Print the received call data to STDERR
    pp func: call.func, params: call.params  # =>  {:func=>:hello, :params=>{"who"=>"world"}}
    # The answer of the subprocess
    {my_answer: 'hello back'}
  end
  # call returns when the IO is closed by the subprocess
```


## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/larskanis/ccrpc.


## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
