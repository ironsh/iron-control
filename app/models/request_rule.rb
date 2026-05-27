require "ipaddr"

class RequestRule < ApplicationRecord
  oid_prefix "rqr"

  HTTP_METHODS = %w[GET HEAD POST PUT PATCH DELETE OPTIONS CONNECT].freeze
  METHOD_WILDCARD = "*".freeze

  belongs_to :static_secret_ref, optional: true

  default_scope { order(:position) }

  validates :position, presence: true, numericality: { only_integer: true }
  validate :host_xor_cidr
  validate :cidr_is_valid
  validate :http_methods_are_valid
  validate :paths_are_valid

  private

  def host_xor_cidr
    if host.present? && cidr.present?
      errors.add(:base, "host and cidr are mutually exclusive")
    elsif host.blank? && cidr.blank?
      errors.add(:base, "either host or cidr must be present")
    end
  end

  def cidr_is_valid
    return if cidr.blank?
    IPAddr.new(cidr)
  rescue IPAddr::Error
    errors.add(:cidr, "is not a valid CIDR")
  end

  def http_methods_are_valid
    unless http_methods.is_a?(Array)
      errors.add(:http_methods, "must be an array")
      return
    end
    http_methods.each do |m|
      next if m == METHOD_WILDCARD || HTTP_METHODS.include?(m)
      errors.add(:http_methods, "#{m.inspect} is not a supported HTTP method")
    end
  end

  def paths_are_valid
    unless paths.is_a?(Array)
      errors.add(:paths, "must be an array")
      return
    end
    paths.each do |p|
      unless p.is_a?(String) && p.start_with?("/")
        errors.add(:paths, "#{p.inspect} must be a string starting with /")
      end
    end
  end
end
