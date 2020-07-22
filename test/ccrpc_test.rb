require "test_helper"

class CcrpcTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Ccrpc::VERSION
  end
end
