$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "ccrpc"

require "minitest/autorun"

def create_openssl_cert(name)
  require "openssl"
  key = OpenSSL::PKey::RSA.new 2048

  cert = OpenSSL::X509::Certificate.new
  cert.serial = 0
  cert.version = 2
  cert.not_before = Time.now
  cert.not_after = Time.now + 86400
  cert.public_key = key.public_key

  cert_name = OpenSSL::X509::Name.parse "CN=#{name}/DC=example"
  cert.subject = cert_name

  extension_factory = OpenSSL::X509::ExtensionFactory.new nil, cert
  cert.issuer = cert_name
  extension_factory.issuer_certificate = cert
  # build a CA cert
  # This extension indicates the CA’s key may be used as a CA.
  cert.add_extension    extension_factory.create_extension('basicConstraints', 'CA:TRUE', true)
  # This extension indicates the CA’s key may be used to verify signatures on both certificates and certificate revocations.
  cert.add_extension    extension_factory.create_extension('keyUsage', 'cRLSign,keyCertSign', true)
  cert.add_extension    extension_factory.create_extension('subjectKeyIdentifier', 'hash')

  # Root CA certificates are self-signed.
  cert.sign(key, OpenSSL::Digest::SHA256.new)

  [cert, key]
end
