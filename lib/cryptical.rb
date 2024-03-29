require 'base64'
require 'openssl'

class Cryptical
  def self.encrypt(string, key)
    Base64.encode64(aes(key, string)).gsub /\s/, ''
  end

  def self.decrypt(string, key)
    aes_decrypt(key, Base64.decode64(string))
  end

  def self.aes(key,string)
    cipher = OpenSSL::Cipher::Cipher.new("aes-256-cbc")
    cipher.encrypt
    cipher.key = Digest::SHA256.digest(key)
    cipher.iv = initialization_vector = cipher.random_iv
    cipher_text = cipher.update(string)
    cipher_text << cipher.final
    return initialization_vector + cipher_text
  end

  def self.aes_decrypt(key, encrypted)
    cipher = OpenSSL::Cipher::Cipher.new("aes-256-cbc")
    cipher.decrypt
    cipher.key = Digest::SHA256.digest(key)    
    cipher.iv = encrypted.slice!(0,16)
    d = cipher.update(encrypted)
    d << cipher.final
  end
end
