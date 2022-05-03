require_relative 'lib/ccrpc/version'

Gem::Specification.new do |spec|
  spec.name          = "ccrpc"
  spec.version       = Ccrpc::VERSION
  spec.authors       = ["Lars Kanis"]
  spec.email         = ["kanis@comcard.de"]

  spec.summary       = %q{Simple bidirectional RPC protocol}
  spec.description   = %q{Simple bidirectional and thread safe RPC protocol. Works on arbitrary Ruby IO objects.}
  spec.homepage      = "http://gitlab.comcard-nt.de/edv/ccrpc"
  spec.license       = "MIT"
  spec.required_ruby_version = Gem::Requirement.new(">= 2.5.0")

  spec.metadata["allowed_push_host"] = "http://ccgems"

  spec.metadata["homepage_uri"] = spec.homepage

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files         = Dir.chdir(File.expand_path('..', __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
end
